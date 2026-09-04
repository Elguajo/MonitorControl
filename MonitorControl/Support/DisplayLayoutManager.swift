//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//
//  Feature B — main display switching via public CoreGraphics APIs only.
//
//  The "main" display in macOS is the one whose origin is (0, 0). To make a given display main
//  we translate every active display by -targetOrigin inside a single atomic display-configuration
//  transaction (CGBeginDisplayConfiguration / CGConfigureDisplayOrigin / CGCompleteDisplayConfiguration —
//  the same family already used by DisplayManager.engageMirror). This deterministically realizes the
//  two arrangements the brief asks for ("LG main" and "built-in main") while preserving the relative
//  positions of all other displays, so no extra persisted coordinates can go stale.

import Cocoa
import CoreGraphics
import os.log

enum DisplayLayoutManager {
  /// True if the given display is currently the main display (origin at (0,0)).
  static func isMain(_ displayID: CGDirectDisplayID) -> Bool {
    let origin = CGDisplayBounds(displayID).origin
    return origin.x == 0 && origin.y == 0
  }

  /// The built-in display and the first external display, if both are present.
  static func builtinAndExternal() -> (builtin: CGDirectDisplayID, external: CGDirectDisplayID)? {
    guard let builtin = DisplayManager.shared.getBuiltInDisplay()?.identifier,
          let external = DisplayManager.shared.displays.first(where: { CGDisplayIsBuiltin($0.identifier) == 0 })?.identifier
    else {
      return nil
    }
    return (builtin, external)
  }

  /// True only when a built-in and at least one external display are both connected, so that
  /// toggling the main display makes sense (used to show/enable the menu item and pane button).
  static func canSwitch() -> Bool {
    self.builtinAndExternal() != nil
  }

  /// Toggles the main display between the external display and the built-in one.
  /// If the external is currently main → makes the built-in main, and vice versa.
  @discardableResult
  static func toggleMain() -> Bool {
    guard let pair = self.builtinAndExternal() else {
      os_log("toggleMain: need both a built-in and an external display.", type: .info)
      return false
    }
    if self.isMain(pair.external) {
      return self.setMainDisplay(pair.builtin)
    } else {
      return self.setMainDisplay(pair.external)
    }
  }

  /// Makes `targetID` the main display by shifting all active displays so the target sits at (0,0).
  /// Returns true on success (or if it was already main). Uses only public CoreGraphics APIs.
  @discardableResult
  static func setMainDisplay(_ targetID: CGDirectDisplayID) -> Bool {
    let targetOrigin = CGDisplayBounds(targetID).origin
    if targetOrigin.x == 0, targetOrigin.y == 0 {
      return true // already main
    }
    var activeIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(16, &activeIDs, &count) == .success, count > 0 else {
      os_log("setMainDisplay: could not get active display list.", type: .error)
      return false
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else {
      os_log("setMainDisplay: CGBeginDisplayConfiguration failed.", type: .error)
      return false
    }
    for id in activeIDs where id != 0 {
      let bounds = CGDisplayBounds(id)
      let newX = Int32(bounds.origin.x - targetOrigin.x)
      let newY = Int32(bounds.origin.y - targetOrigin.y)
      CGConfigureDisplayOrigin(config, id, newX, newY)
    }
    let result = CGCompleteDisplayConfiguration(config, .permanently)
    if result == .success {
      os_log("setMainDisplay: display %{public}@ is now main.", type: .info, String(targetID))
      return true
    } else {
      os_log("setMainDisplay: CGCompleteDisplayConfiguration failed (%{public}@).", type: .error, String(result.rawValue))
      CGCancelDisplayConfiguration(config)
      return false
    }
  }
}
