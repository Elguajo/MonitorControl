#!/usr/bin/env python3
"""Check actual upstream shortcut persistence and brightness arithmetic without hardware."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def method(text, declaration):
    start = text.index(declaration)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


with tempfile.TemporaryDirectory(prefix="monitorcontrol-upstream-tests-") as directory:
    staging = Path(directory)
    shortcuts = (ROOT / "MonitorControl/Support/KeyboardShortcuts.swift").read_text()
    checks = (ROOT / "Tests/KeyboardShortcutsCompatibility.swift").read_text()
    (staging / "main.swift").write_text(shortcuts + "\n" + checks)
    binary = staging / "shortcuts"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(staging / "main.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

    brightness = method((ROOT / "MonitorControl/Model/Display.swift").read_text(), "func calcNewBrightness(")
    (staging / "main.swift").write_text("""
import Foundation
struct Probe {
  let value: Float
  func getBrightness() -> Float { value }
""" + brightness + """
}
var passed = 0
for denominator in [16, 64] {
  for index in 0...denominator {
    let value = Float(index) / Float(denominator)
    for up in [false, true] {
      let result = Probe(value: value).calcNewBrightness(isUp: up, isSmallIncrement: denominator == 64)
      let expected = max(0, min(1, value + (up ? 1 : -1) / Float(denominator)))
      precondition(abs(result - expected) < 0.000001, "Brightness step mismatch")
      passed += 1
    }
  }
}
print("PASS: \\(passed) production brightness-step and boundary cases")
""")
    binary = staging / "brightness"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(staging / "main.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
