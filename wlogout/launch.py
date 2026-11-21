#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path

CELL = 156
COUNT = 5

base = Path.home() / ".config" / "wlogout"

if subprocess.run(["pkill", "-x", "wlogout"], stderr=subprocess.DEVNULL).returncode == 0:
    sys.exit(0)

try:
    outputs = json.loads(subprocess.check_output(["swaymsg", "-t", "get_outputs", "-r"]))
    out = next((o for o in outputs if o.get("focused")), outputs[0])
    width, height = out["rect"]["width"], out["rect"]["height"]
except Exception:
    width, height = 1920, 1080

mx = max(0, (width - CELL * COUNT) // 2)
my = max(0, (height - CELL) // 2)

os.execvp("wlogout", [
    "wlogout",
    "--protocol", "layer-shell",
    "--buttons-per-row", str(COUNT),
    "--column-spacing", "0",
    "--row-spacing", "0",
    "--margin-left", str(mx),
    "--margin-right", str(mx),
    "--margin-top", str(my),
    "--margin-bottom", str(my),
    "--layout", str(base / "layout"),
    "--css", str(base / "style.css"),
])
