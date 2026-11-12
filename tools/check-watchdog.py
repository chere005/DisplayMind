#!/usr/bin/env python3
"""Exercise the shipped watchdog in a disposable app with a fake display helper."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

root = Path(__file__).resolve().parent.parent
identifier = "00000000-0000-0000-0000-000000000001"


def snapshot(rotation):
    return f"""Persistent screen id: {identifier}
Contextual screen id: 1
Serial screen id: s100
Type: MacBook built in screen
Resolution: 1920x1080
Hertz: 60
Color Depth: 8
Scaling: off
Origin: (0,0) - main display
Rotation: {rotation}
Enabled: true
Resolutions for rotation {rotation}:
  mode 0: res:1920x1080 hz:60 color_depth:8 <-- current mode

displayplacer "id:{identifier} res:1920x1080 hz:60 color_depth:8 enabled:true scaling:off origin:(0,0) degree:{rotation}"
"""


def verified(app):
    """Never launch a copy whose signature does not verify: macOS would show a "damaged" alert."""
    result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise SystemExit(f"Refusing to launch {app.name}: signature does not verify: {result.stderr.strip()}")
    return app


with tempfile.TemporaryDirectory(prefix="DisplayMind-watchdog-") as temporary:
    directory = Path(temporary)
    app = directory / "DisplayMind.app"
    executable = app / "Contents/MacOS/DisplayMind"
    executable.parent.mkdir(parents=True)
    # Fixture and state files live outside the bundle: the bundle is signed once, below, and must never change after.
    fixtures = directory / "fixtures"
    fixtures.mkdir()
    shutil.copy2(root / "dist/DisplayMind.app/Contents/MacOS/DisplayMind", executable)
    shutil.copy2(root / "Resources/Info.plist", app / "Contents/Info.plist")
    helper = executable.with_name("displayplacer")
    helper.write_text(f'''#!/bin/sh
set -eu
cd "{fixtures}"
if [ "$1" = list ]; then cat current.txt; exit 0; fi
printf '%s\\n' "$@" > applied.txt
cp restored.txt current.txt
''')
    helper.chmod(0o700)
    (fixtures / "current.txt").write_text(snapshot(180))
    (fixtures / "restored.txt").write_text(snapshot(0))
    # The copy no longer matches the release signature (new bundle, changed contents); a hardened-runtime binary
    # with a broken signature stalls in dyld, so sign the finished bundle once with its own ad hoc signature.
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, capture_output=True, timeout=60)
    state = directory / "state"
    state.mkdir()
    change_id = str(uuid.uuid4())
    journal = {
        "id": change_id,
        "deadline": time.time() - 978307200 + 0.3,
        "previous": [{"id": identifier, "name": "Test display", "mode": {
            "width": 1920, "height": 1080, "hertz": 60, "depth": 8, "scaled": False
        }, "rotation": 0, "x": 0, "y": 0, "enabled": True}]
    }
    pending = state / "pending-change.json"
    pending.write_text(json.dumps(journal))
    verified(app)
    subprocess.run([str(executable), "--watchdog", str(state)], check=True, timeout=10)
    result = json.loads((state / "recovery-result.json").read_text())
    assert result["id"].lower() == change_id and result.get("error") is None, result
    assert not pending.exists()
    assert "degree:0" in (fixtures / "applied.txt").read_text()

    # A UI that confirms the layout removes the journal; the worker must exit without applying.
    (fixtures / "applied.txt").unlink()
    journal["deadline"] = time.time() - 978307200 + 5
    pending.write_text(json.dumps(journal))
    verified(app)
    worker = subprocess.Popen([str(executable), "--watchdog", str(state)])
    try:
        time.sleep(0.15)
        pending.unlink()
        assert worker.wait(timeout=5) == 0
    finally:
        if worker.poll() is None:
            worker.kill()
            worker.wait()
    assert not (fixtures / "applied.txt").exists()

print("Independent watchdog smoke checks passed with a fake display helper.")
