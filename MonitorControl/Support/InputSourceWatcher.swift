//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//
//  Feature B (guard) — detects that the monitor switched to another computer's input, and back,
//  and moves the main display accordingly.
//
//  DETECTION MECHANISM, chosen from the Phase 1 hardware log (LG 29WK600, Mac on DisplayPort):
//
//   • Monitor switched to the Windows input: VCP 0x60 reads return nil for as long as the other
//     input is shown (16 consecutive one-second probes in the log), while `sleepID` and
//     `reconfigureID` stay 0, no CGDisplayRegisterReconfigurationCallback fires at all, and the
//     display REMAINS enumerated by CoreGraphics.
//   • Monitor asleep: the reconfiguration callback fires repeatedly and the display DROPS OUT of
//     the display list entirely ("online=1").
//
//  So the two are cleanly separable, and the brief's key rule is satisfiable: promote the built-in
//  display only on the input-switch signal — DDC silence while the display is still present and
//  nothing is sleeping or reconfiguring — never on a disconnect event.
//
//  Note this supersedes the earlier assumption (see InputSourceManager) that 0x60 reads are useless
//  here. The *value* is indeed uninformative — it reads 15 whenever the Mac's input is live, so it
//  cannot name which other input is showing — but the presence or absence of a reply is a reliable
//  "is the Mac's input active" signal, which is all this guard needs.

import Cocoa
import CoreGraphics
import os.log

final class InputSourceWatcher {
  static let shared = InputSourceWatcher()

  private enum State {
    /// The monitor is showing the Mac (DDC answers).
    case onHost
    /// The monitor is showing another computer (DDC silent, display still connected).
    case away
    /// Startup, sleep, reconfiguration, monitor absent — we must not act on this.
    case unknown
  }

  /// Probe cadence. At 2 s, `awayThreshold` reports a switch within ~6 s, matching the brief's
  /// 3–5 s expectation without polling DDC as hard as the 1 Hz diagnostic harness did.
  private static let pollInterval: TimeInterval = 2.0
  /// Consecutive silent probes before we believe the monitor really left. The Phase 1 log shows a
  /// single garbage reply (0x2020) at a transition, so one sample is never enough.
  private static let awayThreshold = 3
  /// Consecutive answered probes before we believe it came back.
  private static let backThreshold = 2

  private let queue = DispatchQueue(label: "MonitorControl.InputSourceWatcher")
  private var timer: DispatchSourceTimer?

  // Everything below is confined to `queue`. The displays are captured on the main thread by
  // `refreshTargets()` rather than looked up during a probe, because DisplayManager's arrays are
  // rebuilt on the main thread in `configure()` and reading them concurrently is a data race.
  private var state: State = .unknown
  private var silentProbes = 0
  private var answeredProbes = 0
  private var target: OtherDisplay?
  private var builtinID: CGDirectDisplayID?
  private var externalID: CGDirectDisplayID?

  var isEnabled: Bool {
    prefs.bool(forKey: PrefKey.autoSwitchMainDisplay.rawValue)
  }

  // MARK: - Lifecycle

  func start() {
    self.refreshTargets()
    self.queue.async {
      guard self.timer == nil else {
        return
      }
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(500))
      timer.setEventHandler { [weak self] in
        self?.probe()
      }
      timer.resume()
      self.timer = timer
      os_log("Input source watcher started (enabled=%{public}@).", type: .info, String(self.isEnabled))
    }
  }

  /// Re-captures the displays to work with and drops any accumulated belief, so a fresh baseline is
  /// taken rather than acting on stale counters. Call on the main thread whenever the display
  /// configuration or the setting changes.
  func refreshTargets() {
    // The display we promote must be the very display we probe. Deriving the two separately —
    // "first DDC-capable" for the probe, "first non-built-in" for the promotion — picks different
    // monitors as soon as a third display is attached, so the watcher would probe one monitor's DDC
    // and hand the menu bar to another.
    let target = DisplayManager.shared.getDdcCapableDisplays().first { CGDisplayIsBuiltin($0.identifier) == 0 }
    let builtinID = DisplayManager.shared.getBuiltInDisplay()?.identifier
    self.queue.async {
      self.target = target
      self.builtinID = builtinID
      self.externalID = target?.identifier
      self.state = .unknown
      self.silentProbes = 0
      self.answeredProbes = 0
    }
  }

  // MARK: - Probe

  private func probe() {
    guard self.isEnabled else {
      self.state = .unknown
      self.silentProbes = 0
      self.answeredProbes = 0
      return
    }
    // Sleep and reconfiguration make DDC reads return nil unconditionally, so nothing observed
    // during them means anything. This is also the guard that keeps a sleeping monitor from ever
    // being mistaken for an input switch.
    guard app != nil, app.sleepID == 0, app.reconfigureID == 0 else {
      self.resetCountersKeepingState()
      return
    }
    // No external monitor, no built-in screen, or DDC disabled for it → nothing meaningful to watch.
    // A monitor that has left the display list is asleep or unplugged; macOS handles that, and the
    // brief explicitly says not to interfere.
    guard let display = self.target, self.builtinID != nil,
          !display.readPrefAsBool(key: .forceSw),
          !display.readPrefAsBool(key: .unavailableDDC, for: .inputSelect)
    else {
      self.state = .unknown
      self.resetCountersKeepingState()
      return
    }

    let answered = display.readDDCValues(for: .inputSelect, tries: 2, minReplyDelay: nil) != nil
    if answered {
      self.answeredProbes += 1
      self.silentProbes = 0
    } else {
      self.silentProbes += 1
      self.answeredProbes = 0
    }

    switch self.state {
    case .onHost where self.silentProbes >= Self.awayThreshold:
      self.transitionToAway()
    case .away where self.answeredProbes >= Self.backThreshold:
      self.transitionToHost()
    case .unknown:
      // Take a baseline without moving anything: whatever the monitor is doing when we start
      // watching is simply recorded, never acted upon.
      if self.answeredProbes >= Self.backThreshold {
        self.state = .onHost
      } else if self.silentProbes >= Self.awayThreshold {
        self.state = .away
      }
    default:
      break
    }
  }

  private func resetCountersKeepingState() {
    self.silentProbes = 0
    self.answeredProbes = 0
  }

  // MARK: - Transitions

  private func transitionToAway() {
    self.state = .away
    self.resetCountersKeepingState()
    os_log("Watcher: monitor stopped answering DDC while still connected → showing another input.", type: .info)
    guard let builtinID = self.builtinID else {
      return
    }
    DispatchQueue.main.async {
      DisplayLayoutManager.setMainDisplay(builtinID)
    }
  }

  private func transitionToHost() {
    self.state = .onHost
    self.resetCountersKeepingState()
    os_log("Watcher: monitor answers DDC again → back on the Mac's input.", type: .info)
    guard let externalID = self.externalID else {
      return
    }
    DispatchQueue.main.async {
      InputSourceManager.shared.markActiveAsHost()
      DisplayLayoutManager.setMainDisplay(externalID)
      // The monitor may have come back on its own remembered brightness.
      BrightnessScheduler.shared.reassert(reason: "monitor returned to the Mac input")
    }
  }
}
