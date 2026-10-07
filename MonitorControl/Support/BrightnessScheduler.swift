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
  /// The occurrence of the last applied set-point, including its day. A wake after a full day
  /// must still cross a schedule boundary even when the morning/evening index is unchanged.
  /// We only push brightness when the active set-point CHANGES (a boundary is crossed) or on an
  /// explicit force, so the user can still adjust brightness manually between boundaries without
  /// the scheduler yanking it back every tick.
  private var lastAppliedSetpoint: Date?
  private struct ManualBrightness {
    let value: Float
    let setpointDate: Date
  }

  private var manualBrightness: [String: ManualBrightness] = [:]
  private var isApplyingBrightness = false
  private var needsReassert = false
  private let now: () -> Date
  /// Set once `start()` has run, so reassert requests fired during launch (before the scheduler
  /// exists) don't double-apply on top of the initial catch-up.
  private var hasStarted = false
  private var pendingReassert: DispatchWorkItem?

  init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

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
    self.pendingReassert?.cancel()
    self.pendingReassert = nil
    self.manualBrightness.removeAll()
    self.lastAppliedSetpoint = nil
    self.evaluate(force: true)
  }

  /// Remember explicit brightness requests from sliders, keys or brightness sync. Hardware reads
  /// during display setup can overwrite the ordinary brightness preference, so keep the request
  /// independently for this schedule interval and reuse it when the display returns.
  func brightnessChanged(on display: OtherDisplay, to value: Float) {
    guard self.hasStarted, self.isEnabled, !self.isApplyingBrightness, value.isFinite, value >= 0,
          app.sleepID == 0, app.reconfigureID == 0,
          !display.readPrefAsBool(key: .unavailableDDC, for: .brightness),
          self.targetDisplays().contains(where: { $0.prefsId == display.prefsId }),
          let setpoint = self.activeSetpoint()
    else {
      return
    }
    self.manualBrightness[display.prefsId] = ManualBrightness(value: min(value, 1), setpointDate: setpoint.date)
  }

  /// Re-applies the current desired brightness after an event that can leave the monitor back on whatever
  /// brightness its own firmware remembers: waking from sleep, a display reconfiguration, or the
  /// monitor returning from another input. A manual adjustment wins until the next schedule event.
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

  /// The currently active set-point: the most recent set-point whose time has passed today,
  /// wrapping to the latest set-point of the previous day when none has passed yet.
  /// Works regardless of whether morning < evening, evening < morning, or they are equal.
  private func activeSetpoint() -> (index: Int, brightness: Float, date: Date)? {
    let now = self.now()
    let calendar = Calendar.current
    guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
      return nil
    }
    let points: [(time: Int, brightness: Float, index: Int)] = [
      (self.morningTime, self.morningBrightness, 0),
      (self.eveningTime, self.eveningBrightness, 1),
    ]
    return points.compactMap { point -> (index: Int, brightness: Float, date: Date)? in
      guard let today = calendar.date(bySettingHour: point.time / 60, minute: point.time % 60, second: 0, of: now),
            let previous = calendar.date(bySettingHour: point.time / 60, minute: point.time % 60, second: 0, of: yesterday)
      else {
        return nil
      }
      return (point.index, point.brightness, today <= now ? today : previous)
    }.max(by: { $0.date < $1.date })
  }

  func evaluate(force: Bool = false) {
    guard self.isEnabled else {
      self.manualBrightness.removeAll()
      self.lastAppliedSetpoint = nil
      self.needsReassert = false
      return
    }
    if force {
      self.needsReassert = true
    }
    // Don't fight sleep/reconfiguration — leave lastAppliedSetpoint untouched so we retry next tick.
    guard app.sleepID == 0, app.reconfigureID == 0 else {
      return
    }
    guard let setpoint = self.activeSetpoint(), self.needsReassert || setpoint.date != self.lastAppliedSetpoint else {
      return
    }
    self.manualBrightness = self.manualBrightness.filter { $0.value.setpointDate == setpoint.date }
    if self.apply(brightness: setpoint.brightness, setpointIndex: setpoint.index) {
      self.lastAppliedSetpoint = setpoint.date
      self.needsReassert = false
    }
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

  private func apply(brightness: Float, setpointIndex: Int) -> Bool {
    let displays = self.targetDisplays()
    guard !displays.isEmpty else {
      os_log("Scheduler: no target display connected; will re-apply when one appears.", type: .info)
      return false
    }
    os_log("Scheduler restoring brightness (set-point %{public}@) to %{public}@ display(s).", type: .info, String(setpointIndex), String(displays.count))
    self.isApplyingBrightness = true
    defer { self.isApplyingBrightness = false }
    var applied = false
    for display in displays where !display.readPrefAsBool(key: .unavailableDDC, for: .brightness) {
      let value = self.manualBrightness[display.prefsId]?.value ?? max(0, min(1, brightness))
      // slow: true → gentle smooth ramp via existing setSmoothBrightness → DDC 0x10.
      guard display.reapplyBrightness(value, slow: true) else {
        continue
      }
      applied = true
      if let slider = display.sliderHandler[.brightness] {
        slider.setValue(value, displayID: display.identifier)
      }
    }
    return applied
  }
}
