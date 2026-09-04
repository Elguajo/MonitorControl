//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//
//  Feature B (extended) — monitor INPUT source switching over DDC VCP 0x60.
//
//  Writes the input-source VCP code (0x60) to switch the monitor between its inputs
//  (DisplayPort / HDMI 1 / HDMI 2), reusing the existing DDC layer (OtherDisplay.writeDDCValues,
//  Apple Silicon + Intel). No continuous polling — no battery cost.
//
//  HARDWARE FINDINGS for this LG 29WK600 (verified on device):
//   • Switching AWAY from the Mac (DP → HDMI) via a DDC write WORKS.
//   • Switching BACK to the Mac from the Mac does NOT work: the monitor ignores an input-select write
//     received on its inactive (DisplayPort) input while it is displaying another input.
//   • The 0x60 VALUE is uninformative: it reads 15 (DisplayPort) whenever the Mac's input is live,
//     so it can never name which other input is showing. We therefore track the active input by
//     what WE last commanded rather than by reading it back.
//   • The 0x60 REPLY, however, is informative: while another input is shown the monitor does not
//     answer DDC at all. InputSourceWatcher uses that presence/absence signal to detect the
//     monitor leaving for, and returning from, the other computer.
//
//  Consequently the menu checkmark follows the commanded input, and on a "return to Mac" we only
//  best-effort write (never a blind main-display move, so we can't strand the menu bar on a monitor
//  showing the other computer). Returning the monitor to the Mac is done from the other computer or
//  the monitor's own button; InputSourceWatcher then notices and restores the layout.

import Cocoa
import os.log

struct MonitorInput {
  let name: String
  let standardCode: UInt16
  let altCode: UInt16
}

final class InputSourceManager {
  static let shared = InputSourceManager()

  /// Physical inputs of the target monitor (LG 29WK600: DisplayPort, HDMI 1, HDMI 2).
  /// standardCode = MCCS standard 0x60 value; altCode = LG alternate addressing value.
  let inputs: [MonitorInput] = [
    MonitorInput(name: NSLocalizedString("DisplayPort", comment: "Monitor input"), standardCode: 15, altCode: 208),
    MonitorInput(name: NSLocalizedString("HDMI 1", comment: "Monitor input"), standardCode: 17, altCode: 144),
    MonitorInput(name: NSLocalizedString("HDMI 2", comment: "Monitor input"), standardCode: 18, altCode: 145),
  ]

  /// The input MonitorControl last commanded (the source of truth for the active-input checkmark,
  /// since this monitor's 0x60 read is unreliable). nil → assume the Mac's host input (DisplayPort).
  private var commandedInputCode: UInt16?

  var useAlternateAddressing: Bool {
    prefs.bool(forKey: PrefKey.useAlternateInputAddressing.rawValue)
  }

  func code(for input: MonitorInput) -> UInt16 {
    self.useAlternateAddressing ? input.altCode : input.standardCode
  }

  /// The VCP 0x60 value of the input the Mac is connected to (DisplayPort in this setup).
  var hostInputCode: UInt16 {
    self.code(for: self.inputs[0])
  }

  /// Best-known active input code for UI (checkmark). Defaults to the host input.
  var activeInputCode: UInt16 {
    self.commandedInputCode ?? self.hostInputCode
  }

  /// The external DDC-capable display we switch inputs on (the LG). If more than one, the first.
  func targetDisplay() -> OtherDisplay? {
    DisplayManager.shared.getDdcCapableDisplays().first
  }

  /// Marks the monitor as being on the Mac's host input again (e.g. after the user returned it with
  /// the monitor's own button and made the LG main). Keeps the menu checkmark truthful.
  func markActiveAsHost() {
    self.commandedInputCode = self.hostInputCode
  }

  /// Cycles the monitor to the next physical input (DisplayPort → HDMI 1 → HDMI 2 → …). Hotkey.
  func cycleToNextInput() {
    guard self.targetDisplay() != nil else {
      os_log("Input cycle: no DDC-capable display present.", type: .info)
      return
    }
    let codes = self.inputs.map { self.code(for: $0) }
    let index = codes.firstIndex(of: self.activeInputCode) ?? 0
    self.switchTo(code: codes[(index + 1) % codes.count])
  }

  /// Switches the monitor to `code`.
  ///
  /// We write the DDC input FIRST (a CoreGraphics reconfiguration would otherwise make
  /// OtherDisplay.writeDDCValues no-op via its app.reconfigureID guard). Then, only when switching
  /// AWAY from the Mac, we move windows to the built-in screen. When returning to the Mac input we
  /// just best-effort write — we never move the main display blindly (this monitor ignores the
  /// switch-back, and moving the menu bar onto it would strand the user).
  func switchTo(code: UInt16) {
    guard let display = self.targetDisplay() else {
      os_log("Input switch: no DDC-capable display present.", type: .info)
      return
    }
    let returningToHost = (code == self.hostInputCode)
    os_log("Switching monitor input to VCP 0x60 = %{public}@ (returningToHost=%{public}@).", type: .info, String(code), String(returningToHost))
    display.writeDDCValues(command: .inputSelect, value: code)

    if returningToHost {
      // Best-effort only; do not touch the layout or the commanded state (the write is likely
      // ignored by this monitor while it shows another input). If it DID come back, use the
      // "Switch main display" item to put the LG main.
      return
    }

    // Switching away from the Mac: remember it and move windows to the built-in screen.
    self.commandedInputCode = code
    guard let builtin = DisplayManager.shared.getBuiltInDisplay() else {
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
      DisplayLayoutManager.setMainDisplay(builtin.identifier)
    }
  }
}
