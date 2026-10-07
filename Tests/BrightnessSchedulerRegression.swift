// Runs with the production BrightnessScheduler and OtherDisplay brightness methods.
// Only preferences, display discovery and the hardware write implementation are replaced.

import Cocoa
import Darwin

enum PrefKey: String {
  case scheduleEnabled, scheduleMorningTime, scheduleMorningBrightness
  case scheduleEveningTime, scheduleEveningBrightness, scheduleTargetDisplay, unavailableDDC
}

enum Command {
  case brightness, contrast
}

final class TestApp {
  var sleepID = 0
  var reconfigureID = 0
}

let app = TestApp()
let testDomain = "MonitorControl.SchedulerRegression." + UUID().uuidString
let prefs = UserDefaults(suiteName: testDomain)!

final class TestSlider {
  var value: Float = 0
  func setValue(_ value: Float, displayID _: UInt32) {
    self.value = value
  }
}

class TestDisplay {
  let prefsId: String
  let identifier: UInt32
  var brightness: Float = 1
  var hardwareBrightness: Float = 1
  var hardwareWrites = 0
  var unavailable = false
  var software = false
  var rejectWrites = false
  var sliderHandler: [Command: TestSlider] = [.brightness: TestSlider()]
  let writeDDCQueue = DispatchQueue(label: "Test brightness cache")
  var writeDDCLastSavedValue: [Command: UInt16] = [:]

  init(_ prefsId: String, identifier: UInt32 = 1) {
    self.prefsId = prefsId
    self.identifier = identifier
  }

  func checkGammaInterference() {}

  func readPrefAsBool(key _: PrefKey, for _: Command) -> Bool {
    self.unavailable
  }

  func setBrightness(_ to: Float = -1, slow _: Bool = false) -> Bool {
    guard !self.rejectWrites, app.sleepID == 0, app.reconfigureID == 0, to.isFinite, to >= 0 else {
      return false
    }
    self.brightness = max(0, min(1, to))
    let value = UInt16((self.brightness * 100).rounded())
    self.writeDDCQueue.sync {
      // Reproduce the actual DDC writer's duplicate-value suppression.
      if self.writeDDCLastSavedValue[.brightness] != value {
        self.hardwareBrightness = self.brightness
        self.hardwareWrites += 1
        self.writeDDCLastSavedValue[.brightness] = value
      }
    }
    return true
  }
}

final class DisplayManager {
  static let shared = DisplayManager()
  var displays: [OtherDisplay] = []
  func getDdcCapableDisplays() -> [OtherDisplay] {
    self.displays.filter { !$0.software }
  }
}

func date(_ value: String) -> Date {
  ISO8601DateFormatter().date(from: value)!
}

NSTimeZone.default = TimeZone(identifier: "Asia/Tashkent")!
var testNow = date("2026-10-05T12:00:00+05:00")
let scheduler = BrightnessScheduler.shared
var passed = 0

struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() {
    throw TestFailure(description: message)
  }
}

func expectBrightness(_ display: OtherDisplay, _ expected: Float) throws {
  try expect(abs(display.hardwareBrightness - expected) < 0.00001,
             "Expected \(expected) on \(display.prefsId), got \(display.hardwareBrightness)")
}

func reset(at time: String = "2026-10-05T12:00:00+05:00", displays: [OtherDisplay]? = nil,
           morning: Int = 540, evening: Int = 1140, target: String = "") -> OtherDisplay
{
  NSTimeZone.default = TimeZone(identifier: "Asia/Tashkent")!
  testNow = date(time)
  app.sleepID = 0
  app.reconfigureID = 0
  prefs.removePersistentDomain(forName: testDomain)
  prefs.set(true, forKey: PrefKey.scheduleEnabled.rawValue)
  prefs.set(morning, forKey: PrefKey.scheduleMorningTime.rawValue)
  prefs.set(evening, forKey: PrefKey.scheduleEveningTime.rawValue)
  prefs.set(Float(0.96), forKey: PrefKey.scheduleMorningBrightness.rawValue)
  prefs.set(Float(0.65), forKey: PrefKey.scheduleEveningBrightness.rawValue)
  prefs.set(target, forKey: PrefKey.scheduleTargetDisplay.rawValue)
  let display = displays?.first ?? OtherDisplay("LG")
  DisplayManager.shared.displays = displays ?? [display]
  scheduler.settingsChanged()
  return display
}

func test(_ name: String, _ body: () throws -> Void) throws {
  try body()
  passed += 1
  print("PASS: " + name)
}

func runTests() throws {
  scheduler.start()
  try test("manual brightness survives wake and firmware reset") {
    let display = reset()
    try expect(display.setBrightness(0.42), "Manual request failed")
    display.hardwareBrightness = 1
    scheduler.evaluate(force: true)
    try expectBrightness(display, 0.42)
  }
  try test("a hardware read cannot overwrite the remembered manual request") {
    let display = reset()
    _ = display.setBrightness(0.42)
    display.brightness = 1
    display.hardwareBrightness = 1
    scheduler.evaluate(force: true)
    try expectBrightness(display, 0.42)
    try expect(display.sliderHandler[.brightness]!.value == 0.42, "Slider did not follow restoration")
  }
  try test("reconnection replaces the display object without losing the manual value") {
    let display = reset()
    _ = display.setBrightness(0.42)
    let reconnected = OtherDisplay("LG")
    DisplayManager.shared.displays = [reconnected]
    scheduler.evaluate(force: true)
    try expectBrightness(reconnected, 0.42)
  }
  try test("each display has its own manual adjustment") {
    let first = OtherDisplay("LG")
    let second = OtherDisplay("Second", identifier: 2)
    _ = reset(displays: [first, second])
    _ = first.setBrightness(0.42)
    _ = second.setBrightness(0.73)
    first.hardwareBrightness = 1
    second.hardwareBrightness = 1
    scheduler.evaluate(force: true)
    try expectBrightness(first, 0.42)
    try expectBrightness(second, 0.73)
  }
  try test("ordinary ticks preserve manual brightness without extra hardware writes") {
    let display = reset()
    _ = display.setBrightness(0.42)
    let writes = display.hardwareWrites
    scheduler.evaluate()
    try expect(display.hardwareWrites == writes, "Tick unnecessarily wrote brightness")
    try expectBrightness(display, 0.42)
  }
  try test("the next evening event expires the manual adjustment") {
    let display = reset()
    _ = display.setBrightness(0.42)
    testNow = date("2026-10-05T19:00:00+05:00")
    scheduler.evaluate()
    try expectBrightness(display, 0.65)
  }
  try test("manual brightness expires after a full day of sleep in the same period") {
    let display = reset()
    _ = display.setBrightness(0.42)
    testNow = date("2026-10-06T12:00:00+05:00")
    scheduler.evaluate(force: true)
    try expectBrightness(display, 0.96)
  }
  try test("before morning the previous evening wins, then morning expires the override") {
    let display = reset(at: "2026-10-05T08:59:00+05:00")
    try expectBrightness(display, 0.65)
    _ = display.setBrightness(0.42)
    testNow = date("2026-10-05T09:00:00+05:00")
    scheduler.evaluate()
    try expectBrightness(display, 0.96)
  }
  try test("reversed schedule times choose the most recent event") {
    let display = reset(morning: 1140, evening: 540)
    try expectBrightness(display, 0.65)
    _ = display.setBrightness(0.42)
    testNow = date("2026-10-05T19:00:00+05:00")
    scheduler.evaluate()
    try expectBrightness(display, 0.96)
  }
  try test("equal schedule times retain the existing first-point precedence") {
    let display = reset(morning: 540, evening: 540)
    try expectBrightness(display, 0.96)
  }
  try test("schedule edits explicitly replace a manual adjustment") {
    let display = reset()
    _ = display.setBrightness(0.42)
    prefs.set(Float(0.8), forKey: PrefKey.scheduleMorningBrightness.rawValue)
    scheduler.settingsChanged()
    try expectBrightness(display, 0.8)
  }
  try test("restoration only resets the brightness cache, not contrast") {
    let display = reset()
    _ = display.setBrightness(0.42)
    display.writeDDCLastSavedValue[.contrast] = 75
    let writes = display.hardwareWrites
    display.hardwareBrightness = 1
    scheduler.evaluate(force: true)
    try expectBrightness(display, 0.42)
    try expect(display.hardwareWrites == writes + 1, "Duplicate-value cache suppressed restoration")
    try expect(display.writeDDCLastSavedValue[.contrast] == 75, "Contrast cache was invalidated")
  }
  try test("selected display isolation and no fallback while it is absent") {
    let first = OtherDisplay("LG")
    let second = OtherDisplay("Second", identifier: 2)
    _ = reset(displays: [first, second], target: "LG")
    _ = first.setBrightness(0.42)
    _ = second.setBrightness(0.73)
    let writes = second.hardwareWrites
    DisplayManager.shared.displays = [second]
    scheduler.evaluate(force: true)
    try expect(second.hardwareWrites == writes, "Missing target fell back to another display")
    let reconnected = OtherDisplay("LG")
    DisplayManager.shared.displays = [second, reconnected]
    scheduler.evaluate()
    try expectBrightness(reconnected, 0.42)
    try expectBrightness(second, 0.73)
  }
  try test("restoration blocked by sleep or reconfiguration remains pending") {
    for sleeping in [true, false] {
      let display = reset()
      _ = display.setBrightness(0.42)
      display.hardwareBrightness = 1
      app.sleepID = sleeping ? 1 : 0
      app.reconfigureID = sleeping ? 0 : 1
      let writes = display.hardwareWrites
      scheduler.evaluate(force: true)
      try expect(display.hardwareWrites == writes, "Wrote while asleep or reconfiguring")
      app.sleepID = 0
      app.reconfigureID = 0
      scheduler.evaluate()
      try expectBrightness(display, 0.42)
    }
  }
  try test("an unavailable display is retried when brightness becomes available") {
    let display = OtherDisplay("LG")
    display.unavailable = true
    _ = reset(displays: [display])
    try expect(display.hardwareWrites == 0, "Unavailable brightness was written")
    display.unavailable = false
    scheduler.evaluate()
    try expectBrightness(display, 0.96)
  }
  try test("failed manual changes do not replace the schedule") {
    let display = reset()
    display.rejectWrites = true
    try expect(!display.setBrightness(0.42), "Expected failure")
    display.rejectWrites = false
    scheduler.evaluate(force: true)
    try expectBrightness(display, 0.96)
  }
  try test("failed scheduled changes are retried") {
    let display = OtherDisplay("LG")
    display.rejectWrites = true
    _ = reset(displays: [display])
    display.rejectWrites = false
    scheduler.evaluate()
    try expectBrightness(display, 0.96)
  }
  try test("disabling the scheduler prevents restoration writes") {
    let display = reset()
    _ = display.setBrightness(0.42)
    prefs.set(false, forKey: PrefKey.scheduleEnabled.rawValue)
    scheduler.settingsChanged()
    let writes = display.hardwareWrites
    scheduler.evaluate(force: true)
    try expect(display.hardwareWrites == writes, "Disabled scheduler wrote brightness")
  }
  try test("wake and reconnect requests are debounced into one restoration") {
    let display = reset()
    _ = display.setBrightness(0.42)
    let writes = display.hardwareWrites
    display.hardwareBrightness = 1
    scheduler.reassert(reason: "test wake")
    scheduler.reassert(reason: "test reconnect")
    RunLoop.main.run(until: Date().addingTimeInterval(2.3))
    try expectBrightness(display, 0.42)
    try expect(display.hardwareWrites == writes + 1, "Duplicate restoration was not debounced")
  }
  try test("schedule changes cancel a pending restoration") {
    let display = reset()
    _ = display.setBrightness(0.42)
    scheduler.reassert(reason: "test wake")
    prefs.set(Float(0.8), forKey: PrefKey.scheduleMorningBrightness.rawValue)
    scheduler.settingsChanged()
    let writes = display.hardwareWrites
    RunLoop.main.run(until: Date().addingTimeInterval(2.3))
    try expect(display.hardwareWrites == writes, "Canceled restoration still wrote")
    try expectBrightness(display, 0.8)
  }
  try test("spring DST gap resolves the schedule to the next valid wall-clock time") {
    let display = reset(at: "2026-03-08T01:59:00-05:00", morning: 150, evening: 1140)
    NSTimeZone.default = TimeZone(identifier: "America/New_York")!
    scheduler.settingsChanged()
    _ = display.setBrightness(0.42)
    testNow = date("2026-03-08T03:00:00-04:00")
    scheduler.evaluate()
    try expectBrightness(display, 0.96)
  }
  try test("fall DST repetition does not invent a second schedule occurrence") {
    let display = reset(at: "2026-11-01T01:45:00-04:00", morning: 90, evening: 1140)
    NSTimeZone.default = TimeZone(identifier: "America/New_York")!
    scheduler.settingsChanged()
    _ = display.setBrightness(0.42)
    testNow = date("2026-11-01T01:45:00-05:00")
    scheduler.evaluate(force: true)
    try expectBrightness(display, 0.42)
  }
}

do {
  try runTests()
  prefs.removePersistentDomain(forName: testDomain)
  print("PASS: \(passed) scheduler regression scenarios; no real monitor or app settings touched")
} catch {
  prefs.removePersistentDomain(forName: testDomain)
  print("FAIL: \(error)")
  exit(1)
}
