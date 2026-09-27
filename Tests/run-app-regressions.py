"""Run native Debug menu/search integration checks in separate, owned app processes."""
import os
from pathlib import Path
import subprocess
import time
import sys

root = Path(__file__).resolve().parent.parent
binary = root / "build/DerivedData/Build/Products/Debug/Tidepad.app/Contents/MacOS/Tidepad"
for kind in (sys.argv[1:] or ("menu", "search")):
    output = root / "build" / f"performance-{kind}-validation"
    output.mkdir(exist_ok=True)
    report = output / "results.txt"
    report.unlink(missing_ok=True)
    env = dict(os.environ)
    env[f"TIDEPAD_{kind.upper()}_VALIDATE"] = str(output)
    with (output / "app.log").open("w") as log:
        process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 120
            while not report.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(.2)
            if not report.exists(): raise RuntimeError(f"Missing {kind} report; inspect {output}")
            text = report.read_text()
            print(kind, text, flush=True)
            if "FAIL" in text: raise RuntimeError(f"{kind} regression failure")
        finally:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
