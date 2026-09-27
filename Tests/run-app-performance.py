"""Opt-in real app launch/RSS/view checks; terminate only the fresh processes started here."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
products = root / "build/DerivedData/Build/Products"
out = root / "build/app-performance"
out.mkdir(exist_ok=True)

def run(configuration, stem, extras, report_key):
    report = out / (stem + ".txt")
    report.unlink(missing_ok=True)
    env = dict(os.environ, **extras)
    env[report_key] = str(report)
    env["TIDEPAD_LAUNCH_START"] = str(time.time())
    binary = products / configuration / "Tidepad.app/Contents/MacOS/Tidepad"
    with (out / (stem + ".log")).open("w") as log:
        process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 60
            while not report.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(.1)
            if not report.exists():
                raise RuntimeError(f"No report from {stem}; inspect its log")
            print(stem, report.read_text().strip(), flush=True)
        finally:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()

for i in range(3):
    run("Release", f"launch-{i}", {}, "TIDEPAD_LAUNCH_REPORT")
run("Debug", "observation", {"TIDEPAD_OBSERVATION_AUDIT": "1"}, "TIDEPAD_OBSERVATION_REPORT")
for size in (1_000_000, 10_000_000, 50_000_000):
    with tempfile.TemporaryDirectory(prefix="TidepadMemory-") as directory:
        fixture = Path(directory) / "fixture.swift"
        line = "let value = 42 // example code with words\n"
        fixture.write_text(line * (size // len(line)))
        run("Release", f"memory-{size}", {"TIDEPAD_MEMORY_FIXTURE": str(fixture)}, "TIDEPAD_MEMORY_REPORT")
