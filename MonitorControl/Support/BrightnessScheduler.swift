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

  /// How long we wait after a wake/reconfiguration before re-asserting. Displays need a moment to
  /// come back before they will accept DDC, and the same event usually reaches us twice.
  private static let reassertDelay: TimeInterval = 2.0

  private var timer: Timer?
  /// Which set-point (0 = morning, 1 = evening) was last applied. nil = nothing applied yet.
  /// We only push brightness when the active set-point CHANGES (a boundary is crossed) or on an
  /// explicit force, so the user can still adjust brightness manually between boundaries without
  /// the scheduler yanking it back every tick.
  private var lastAppliedSetpoint: Int?
  /// Set once `start()` has run, so reassert requests fired during launch (before the scheduler
  /// exists) don't double-apply on top of the initial catch-up.
  private var hasStarted = false
  private var pendingReassert: DispatchWorkItem?

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

  /// prefsId of the display the schedule drives. Empty → every DDC-capable display.
  var targetDisplayPrefsId: String {
    prefs.string(forKey: PrefKey.scheduleTargetDisplay.rawValue) ?? ""
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
    self.hasStarted = true
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

  /// Re-applies the active set-point after an event that can leave the monitor back on whatever
  /// brightness its own firmware remembers: waking from sleep, a display reconfiguration, or the
  /// monitor returning from another input.
  ///
  /// Without this the schedule silently stops holding: `evaluate()` bails out while
  /// `app.sleepID`/`app.reconfigureID` are non-zero, and once the system is sober again the active
  /// set-point still equals `lastAppliedSetpoint`, so the boundary-crossing check skips it and the
  /// monitor keeps the brightness it woke up with until the next boundary — up to a day later.
  ///
  /// Debounced, because a single wake normally reaches us from both `soberNow` and `configure`.
  func reassert(reason: String) {
    guard self.hasStarted, self.isEnabled else {
      return
    }
    self.pendingReassert?.cancel()
    let work = DispatchWorkItem { [weak self] in
      os_log("Scheduler re-asserting brightness after %{public}@.", type: .info, reason)
      self?.evaluate(force: true)
    }
    self.pendingReassert = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.reassertDelay, execute: work)
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

  /// The displays the schedule drives: the one picked in Settings, or all DDC-capable ones when
  /// none is picked. A pick that isn't currently connected yields nothing rather than falling back
  /// to "all" — dimming the wrong monitor is worse than doing nothing, and `reassert(reason:)`
  /// re-applies as soon as the chosen display comes back.
  private func targetDisplays() -> [OtherDisplay] {
    let all = DisplayManager.shared.getDdcCapableDisplays()
    let picked = self.targetDisplayPrefsId
    guard !picked.isEmpty else {
      return all
    }
    return all.filter { $0.prefsId == picked }
  }

  private func apply(brightness: Float, setpointIndex: Int) {
    let value = max(0, min(1, brightness))
    let displays = self.targetDisplays()
    guard !displays.isEmpty else {
      os_log("Scheduler: no target display connected; will re-apply when one appears.", type: .info)
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
