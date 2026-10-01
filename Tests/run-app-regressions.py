"""Run native Debug menu/search integration checks in separate, owned app processes."""
import os
from pathlib import Path
import shutil
import subprocess
import time
import sys

root = Path(__file__).resolve().parent.parent
binary = root / "build/DerivedData/Build/Products/Debug/TidePad.app/Contents/MacOS/TidePad"
for kind in (sys.argv[1:] or ("menu", "search")):
    output = root / "build" / f"performance-{kind}-validation"
    # Start empty: files left by a previous run (the search check's sample.txt) would be noticed as
    # changed on disk and reloaded over the check's own text.
    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(parents=True)
    report = output / "results.txt"
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
