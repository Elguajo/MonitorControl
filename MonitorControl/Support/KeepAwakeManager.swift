//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//
//  Keep Awake (caffeine) — BetterDisplay-style.
//
//  Holds public power-management assertions (IOPMAssertionCreateWithName) to optionally prevent the
//  display from sleeping and/or the system from idle-sleeping. Two independent toggles. State is
//  persisted and restored on launch. Releasing the assertion restores normal macOS sleep behaviour.

import Foundation
import IOKit
import IOKit.pwr_mgt
import os.log

final class KeepAwakeManager {
  static let shared = KeepAwakeManager()

  private var displayAssertion: IOPMAssertionID = 0
  private var systemAssertion: IOPMAssertionID = 0

  var isDisplayAwakeEnabled: Bool {
    prefs.bool(forKey: PrefKey.keepDisplayAwake.rawValue)
  }

  var isSystemAwakeEnabled: Bool {
    prefs.bool(forKey: PrefKey.keepSystemAwake.rawValue)
  }

  /// Restore persisted toggles on launch.
  func start() {
    if self.isDisplayAwakeEnabled {
      self.applyDisplay(true)
    }
    if self.isSystemAwakeEnabled {
      self.applySystem(true)
    }
  }

  func setDisplayAwake(_ on: Bool) {
    prefs.set(on, forKey: PrefKey.keepDisplayAwake.rawValue)
    self.applyDisplay(on)
  }

  func setSystemAwake(_ on: Bool) {
    prefs.set(on, forKey: PrefKey.keepSystemAwake.rawValue)
    self.applySystem(on)
  }

  // MARK: - Assertion plumbing

  private func applyDisplay(_ on: Bool) {
    self.toggle(&self.displayAssertion, on: on, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, name: "MonitorControl: keep display awake")
  }

  private func applySystem(_ on: Bool) {
    self.toggle(&self.systemAssertion, on: on, type: kIOPMAssertionTypePreventUserIdleSystemSleep, name: "MonitorControl: keep system awake")
  }

  private func toggle(_ assertion: inout IOPMAssertionID, on: Bool, type: String, name: String) {
    if on {
      guard assertion == 0 else {
        return // already held
      }
      var id: IOPMAssertionID = 0
      let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
      if result == kIOReturnSuccess {
        assertion = id
        os_log("Keep awake assertion ON: %{public}@", type: .info, name)
      } else {
        os_log("Keep awake assertion FAILED (%{public}@) for %{public}@", type: .error, String(result), name)
      }
    } else {
      guard assertion != 0 else {
        return
      }
      IOPMAssertionRelease(assertion)
      assertion = 0
      os_log("Keep awake assertion OFF: %{public}@", type: .info, name)
    }
  }
}
