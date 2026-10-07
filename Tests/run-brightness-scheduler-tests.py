#!/usr/bin/env python3
"""Exercise the production scheduler and brightness hooks without touching hardware."""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline", action="store_true", help="Reproduce against the committed pre-fix code")
args = parser.parse_args()


def source(path):
    if args.baseline:
        return subprocess.check_output(["git", "show", "HEAD:" + path], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


def method(text, declaration):
    start = text.find(declaration)
    if start == -1:
        return ""
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


scheduler = source("MonitorControl/Support/BrightnessScheduler.swift")
factory = "static let shared = BrightnessScheduler()"
assert scheduler.count(factory) == 1
if "init(now:" in scheduler:
    scheduler = scheduler.replace(factory, "static let shared = BrightnessScheduler(now: { testNow })")
else:
    # The old scheduler has no clock injection. Only its clock read is substituted.
    clock = "dateComponents([.hour, .minute], from: Date())"
    assert scheduler.count(clock) == 1
    scheduler = scheduler.replace(clock, "dateComponents([.hour, .minute], from: testNow)")

display = source("MonitorControl/Model/OtherDisplay.swift")
hooks = "\n\n".join(method(display, name) for name in [
    "override func setBrightness(",
    "func reapplyBrightness(",
])
assert "super.setBrightness" in hooks

with tempfile.TemporaryDirectory(prefix="monitorcontrol-scheduler-tests-") as directory:
    staging = Path(directory)
    (staging / "main.swift").write_text((ROOT / "Tests/BrightnessSchedulerRegression.swift").read_text())
    (staging / "BrightnessScheduler.swift").write_text(scheduler)
    (staging / "OtherDisplay.swift").write_text("class OtherDisplay: TestDisplay {\n" + hooks + "\n}\n")
    binary = staging / "regression"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        str(staging / "main.swift"), str(staging / "BrightnessScheduler.swift"),
        str(staging / "OtherDisplay.swift"), "-o", str(binary),
    ], check=True)
    raise SystemExit(subprocess.run([str(binary)]).returncode)
