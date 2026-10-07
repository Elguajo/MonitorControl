#!/usr/bin/env python3
"""Check update denial and startup migration without launching Sparkle or changing app preferences."""

from pathlib import Path
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
delegate = (ROOT / "MonitorControl/Support/UpdaterDelegate.swift").read_text()
assert delegate.count("import Sparkle") == 1
delegate = delegate.replace("import Sparkle", "")
app = (ROOT / "MonitorControl/Support/AppDelegate.swift").read_text()
start = app.index("func setDefaultPrefs()")
opening = app.index("{", start)
depth = 1
end = opening + 1
while depth:
    depth += (app[end] == "{") - (app[end] == "}")
    end += 1
startup = app[start:end]

with tempfile.TemporaryDirectory(prefix="monitorcontrol-fork-update-tests-") as directory:
    staging = Path(directory)
    # Only the Sparkle types and preference store are simulated; delegate/startup methods are production code.
    harness = """
import Foundation
class SPUUpdater {}
enum SPUUpdateCheck: CaseIterable { case updates, background, information }
protocol SPUUpdaterDelegate { func updater(_ updater: SPUUpdater, mayPerform check: SPUUpdateCheck) throws }
enum PrefKey: String { case appAlreadyLaunched, SUEnableAutomaticChecks }
class TestPreferences {
  var values: [String: Any] = [:]
  func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
  func set(_ value: Any, forKey key: String) { values[key] = value }
}
let prefs = TestPreferences()
""" + delegate + "\nclass Startup {\n" + startup + "\n}\n" + """
for check in SPUUpdateCheck.allCases {
  do {
    try UpdaterDelegate().updater(SPUUpdater(), mayPerform: check)
    fatalError("An update check was allowed")
  } catch let error as NSError {
    precondition(error.domain == "app.monitorcontrol.MonitorControl.ForkUpdates")
    precondition(error.userInfo[NSLocalizedDescriptionKey] != nil)
  }
}
print("PASS: manual, background, and information update checks are rejected")
for launched in [false, true] {
  for checks in [false, true] {
    for installation in [false, true] {
      prefs.values = ["appAlreadyLaunched": launched, "SUEnableAutomaticChecks": checks,
                      "SUAutomaticallyUpdate": installation, "scheduleMorningBrightness": 0.42,
                      "KeyboardShortcuts_toggleMainDisplay": "saved-shortcut"]
      Startup().setDefaultPrefs()
      precondition(prefs.bool(forKey: "appAlreadyLaunched"))
      precondition(!prefs.bool(forKey: "SUEnableAutomaticChecks"))
      precondition(!prefs.bool(forKey: "SUAutomaticallyUpdate"))
      precondition(prefs.values["scheduleMorningBrightness"] as? Double == 0.42)
      precondition(prefs.values["KeyboardShortcuts_toggleMainDisplay"] as? String == "saved-shortcut")
    }
  }
}
print("PASS: eight startup/reset preference combinations disable updates and preserve unrelated settings")
"""
    (staging / "main.swift").write_text(harness)
    binary = staging / "updates"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(staging / "main.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

bundle = plistlib.loads((ROOT / "MonitorControl/Info.plist").read_bytes())
assert "SUFeedURL" not in bundle and "SUPublicEDKey" not in bundle
for key in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates"]:
    assert bundle[key] is False
assert "startUpdater(" not in app
for relative in ["MonitorControl/Support/MenuHandler.swift", "MonitorControl/View Controllers/Preferences/AboutPrefsViewController.swift"]:
    assert "checkForUpdates(" not in (ROOT / relative).read_text()
storyboard = ET.parse(ROOT / "MonitorControl/UI/Base.lproj/Main.storyboard")
assert not storyboard.findall(".//action[@selector='checkForUpdatesWithSender:']")
assert len(storyboard.findall(".//outlet[@property='updateButton'][@destination='PEt-Ef-kWK']")) == 1
print("PASS: official feed/key are absent, updater stays stopped, and menu/storyboard have no update actions")
