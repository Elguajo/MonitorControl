//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//
//  Phase 1 diagnostic logger (manual hardware gate).
//
//  Purpose: collect facts on real hardware to answer two questions before Feature B is designed:
//    1. Which macOS signals actually fire when the monitor input is switched (Mac <-> Windows)
//       versus when the monitor simply goes to sleep / wakes up?
//    2. What does VCP 0x60 (input source) report for each physical input of the LG monitor,
//       so input values are never hard-coded blindly (Constraint, section 4 of the brief).
//
//  This module is fully gated behind the global `DEBUG_DIAG` flag. When that flag is false,
//  nothing here runs and the app behaves exactly as before. It reuses the existing DDC layer
//  (OtherDisplay.readDDCValues, which already branches Apple Silicon vs Intel) — no duplicate DDC code.

import Cocoa
import CoreGraphics
import os.log

final class DiagnosticLogger {
  static let shared = DiagnosticLogger()

  // Serial queue: serializes file writes and runs the 1 Hz poll off the main thread,
  // because readDDCValues() blocks on the global DDC queue and must not stall the UI.
  private let queue = DispatchQueue(label: "MonitorControl.DiagnosticLogger")
  private var timer: DispatchSourceTimer?
  private var started = false

  private let logFileURL: URL = {
    let logsDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs", isDirectory: true)
    return logsDir.appendingPathComponent("MonitorControl-diag.log")
  }()

  private lazy var timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  // MARK: - Lifecycle

  /// Starts diagnostics. Safe to call once from applicationDidFinishLaunching behind DEBUG_DIAG.
  func start() {
    guard DEBUG_DIAG, !self.started else {
      return
    }
    self.started = true
    self.log(event: "SESSION", "Diagnostic logger started. arm64=\(Arm64DDC.isArm64). Log file: \(self.logFileURL.path)")
    self.logOnlineDisplays(context: "startup")
    self.startPolling()
  }

  private func startPolling() {
    let timer = DispatchSource.makeTimerSource(queue: self.queue)
    timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
    timer.setEventHandler { [weak self] in
      self?.pollInputSources()
    }
    timer.resume()
    self.timer = timer
  }

  // MARK: - Event hooks (called from AppDelegate, gated by DEBUG_DIAG at the call site)

  func logReconfigure(reconfigureID: Int, sleepID: Int) {
    self.log(event: "RECONFIG", "CGDisplayRegisterReconfigurationCallback fired. reconfigureID=\(reconfigureID), sleepID=\(sleepID)")
    self.logOnlineDisplays(context: "reconfig")
  }

  func logSleep(sleepID: Int, source: String) {
    self.log(event: "SLEEP", "\(source). sleepID=\(sleepID)")
    self.logOnlineDisplays(context: "sleep")
  }

  func logWake(sleepID: Int, source: String) {
    self.log(event: "WAKE", "\(source). sleepID=\(sleepID)")
    self.logOnlineDisplays(context: "wake")
  }

  // MARK: - Polling VCP 0x60 (input source)

  private func pollInputSources() {
    let displays = DisplayManager.shared.getOtherDisplays()
    guard !displays.isEmpty else {
      self.log(event: "INPUT", "No DDC-capable (OtherDisplay) displays present.")
      return
    }
    for display in displays {
      // Reuses the existing unified DDC read path (Arm64DDC / IntelDDC chosen internally).
      // readDDCValues returns nil while app.sleepID != 0 or app.reconfigureID != 0, or when the
      // display does not answer — all of which are informative for distinguishing input-switch vs sleep.
      if let values = display.readDDCValues(for: .inputSelect, tries: 5, minReplyDelay: nil) {
        self.log(event: "INPUT", "display=\(display.identifier) \"\(display.name)\" 0x60 current=\(values.current) (0x\(String(values.current, radix: 16))) max=\(values.max)")
      } else {
        self.log(event: "INPUT", "display=\(display.identifier) \"\(display.name)\" 0x60 NO RESPONSE (nil) [sleepID=\(app?.sleepID ?? -1) reconfigureID=\(app?.reconfigureID ?? -1)]")
      }
    }
  }

  // MARK: - Online display snapshot

  private func logOnlineDisplays(context: String) {
    var onlineDisplayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &onlineDisplayIDs, &displayCount) == .success else {
      self.log(event: "DISPLAYS", "[\(context)] CGGetOnlineDisplayList failed.")
      return
    }
    var lines: [String] = []
    for id in onlineDisplayIDs where id != 0 {
      let builtin = CGDisplayIsBuiltin(id) != 0 ? "builtin" : "external"
      let active = CGDisplayIsActive(id) != 0 ? "active" : "inactive"
      let asleep = CGDisplayIsAsleep(id) != 0 ? "asleep" : "awake"
      let name = DisplayManager.getDisplayNameByID(displayID: id)
      lines.append("    id=\(id) \"\(name)\" \(builtin) \(active) \(asleep)")
    }
    self.log(event: "DISPLAYS", "[\(context)] online=\(displayCount)\n" + lines.joined(separator: "\n"))
  }

  // MARK: - Output

  private func log(event: String, _ message: String) {
    let line = "\(self.timestampFormatter.string(from: Date())) [\(event)] \(message)"
    os_log("DIAG %{public}@", type: .info, line)
    self.queue.async {
      self.appendToFile(line + "\n")
    }
  }

  private func appendToFile(_ text: String) {
    guard let data = text.data(using: .utf8) else {
      return
    }
    let fm = FileManager.default
    if !fm.fileExists(atPath: self.logFileURL.path) {
      try? data.write(to: self.logFileURL)
      return
    }
    if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
      defer { handle.closeFile() }
      handle.seekToEndOfFile()
      handle.write(data)
    }
  }
}
