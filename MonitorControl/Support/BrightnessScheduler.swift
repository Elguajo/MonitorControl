//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//
//  Feature A — brightness scheduler.
//
//  Automatically drives the monitor's HARDWARE brightness (DDC VCP 0x10) on a schedule:
//  a morning set-point (brighter) and an evening set-point (dimmer). Both the times and the
//  brightness values are user-editable from the UI (SchedulePrefsViewController) and persisted
//  in UserDefaults, so they survive restarts.
//
//  It reuses MonitorControl's existing brightness path: Display.setBrightness(_, slow: true),
//  which performs a smooth (non-instant) transition and ultimately writes DDC — NOT a software
//  gamma/shade overlay. The DDC write path already no-ops during sleep/reconfiguration, and we
//  additionally guard here so a missed application simply retries on the next tick.

import Cocoa
import os.log

final class BrightnessScheduler {
  static let shared = BrightnessScheduler()

  // Defaults (used when the pref was never set — covers both fresh installs and pre-existing prefs DBs).
  static let defaultMorningTime = 9 * 60 // 09:00
  static let defaultMorningBrightness: Float = 0.96
  static let defaultEveningTime = 19 * 60 // 19:00
  static let defaultEveningBrightness: Float = 0.65

  private static let tickInterval: TimeInterval = 30

  private var timer: Timer?
  /// Which set-point (0 = morning, 1 = evening) was last applied. nil = nothing applied yet.
  /// We only push brightness when the active set-point CHANGES (a boundary is crossed) or on an
  /// explicit force, so the user can still adjust brightness manually between boundaries without
  /// the scheduler yanking it back every tick.
  private var lastAppliedSetpoint: Int?

  // MARK: - Pref accessors (single source of truth for defaults)

  var isEnabled: Bool {
    prefs.bool(forKey: PrefKey.scheduleEnabled.rawValue)
  }

  private func intPref(_ key: PrefKey, default def: Int) -> Int {
    prefs.object(forKey: key.rawValue) == nil ? def : prefs.integer(forKey: key.rawValue)
  }

  private func floatPref(_ key: PrefKey, default def: Float) -> Float {
    prefs.object(forKey: key.rawValue) == nil ? def : prefs.float(forKey: key.rawValue)
  }

  var morningTime: Int {
    self.intPref(.scheduleMorningTime, default: Self.defaultMorningTime)
  }

  var morningBrightness: Float {
    self.floatPref(.scheduleMorningBrightness, default: Self.defaultMorningBrightness)
  }

  var eveningTime: Int {
    self.intPref(.scheduleEveningTime, default: Self.defaultEveningTime)
  }

  var eveningBrightness: Float {
    self.floatPref(.scheduleEveningBrightness, default: Self.defaultEveningBrightness)
  }

  // MARK: - Lifecycle

  /// Starts the periodic scheduler. Safe to call once after the app has configured its displays.
  func start() {
    self.timer?.invalidate()
    let timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
      self?.evaluate()
    }
    timer.tolerance = 5
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    os_log("Brightness scheduler started (enabled=%{public}@).", type: .info, String(self.isEnabled))
    // Apply the catch-up value immediately on launch (e.g. app started at 14:00 → morning value).
    self.evaluate(force: true)
  }

  /// Re-evaluates immediately. Call this whenever the schedule settings change in the UI so the
  /// new values take effect right away (also handy for testing with a near-future set-point).
  func settingsChanged() {
    self.lastAppliedSetpoint = nil
    self.evaluate(force: true)
  }

  // MARK: - Core logic

  private func currentMinutes() -> Int {
    let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
    return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
  }

  /// The currently active set-point: the most recent set-point whose time has passed today,
  /// wrapping to the latest set-point of the previous day when none has passed yet.
  /// Works regardless of whether morning < evening, evening < morning, or they are equal.
  private func activeSetpoint() -> (index: Int, brightness: Float) {
    let now = self.currentMinutes()
    let points: [(time: Int, brightness: Float, index: Int)] = [
      (self.morningTime, self.morningBrightness, 0),
      (self.eveningTime, self.eveningBrightness, 1),
    ]
    let passed = points.filter { $0.time <= now }
    let chosen = passed.max(by: { $0.time < $1.time }) ?? points.max(by: { $0.time < $1.time })!
    return (chosen.index, chosen.brightness)
  }

  func evaluate(force: Bool = false) {
    guard self.isEnabled else {
      self.lastAppliedSetpoint = nil
      return
    }
    // Don't fight sleep/reconfiguration — leave lastAppliedSetpoint untouched so we retry next tick.
    guard app.sleepID == 0, app.reconfigureID == 0 else {
      return
    }
    let setpoint = self.activeSetpoint()
    guard force || setpoint.index != self.lastAppliedSetpoint else {
      return
    }
    self.lastAppliedSetpoint = setpoint.index
    self.apply(brightness: setpoint.brightness, setpointIndex: setpoint.index)
  }

  private func apply(brightness: Float, setpointIndex: Int) {
    let value = max(0, min(1, brightness))
    let displays = DisplayManager.shared.getDdcCapableDisplays()
    guard !displays.isEmpty else {
      os_log("Scheduler: no DDC-capable displays to apply brightness to.", type: .info)
      return
    }
    os_log("Scheduler applying brightness %{public}@ (set-point %{public}@) to %{public}@ display(s).", type: .info, String(value), String(setpointIndex), String(displays.count))
    for display in displays where !display.readPrefAsBool(key: .unavailableDDC, for: .brightness) {
      // slow: true → gentle smooth ramp via existing setSmoothBrightness → DDC 0x10.
      _ = display.setBrightness(value, slow: true)
      if let slider = display.sliderHandler[.brightness] {
        slider.setValue(value, displayID: display.identifier)
      }
    }
  }
}
