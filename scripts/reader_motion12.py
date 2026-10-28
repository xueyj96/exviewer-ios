#!/usr/bin/env python3
"""Measure a cached reader's warm/teal seam, decoding from frame zero.

The simulator recording is VFR. Frame numbers are from the same fps=60 graph
used for extraction; they are not physical display timestamps.
"""
import argparse
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("video")
parser.add_argument("output")
args = parser.parse_args()
width, height = 402, 3
proc = subprocess.Popen([
    "ffmpeg", "-v", "error", "-i", args.video,
    "-vf", "fps=60,crop=iw:ih*0.015:0:ih*0.647,scale=402:3,format=rgb24",
    "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
], stdout=subprocess.PIPE)
seams = []
while True:
    data = proc.stdout.read(width * height * 3)
    if not data:
        break
    if len(data) != width * height * 3:
        raise RuntimeError("Incomplete raw frame")
    warm_count = teal_count = seam = 0
    column_counts = [0] * width
    for pixel in range(width * height):
        r, g, b = data[pixel * 3:pixel * 3 + 3]
        warm = 210 < r < 238 and 150 < g < 195 and 60 < b < 115
        teal = 50 < r < 100 and 160 < g < 205 and 160 < b < 205
        warm_count += warm
        teal_count += teal
        column_counts[pixel % width] += warm
    for column, count in enumerate(column_counts):
        if count >= 2:
            seam = column + 1
    seams.append({"frame": len(seams), "warm_edge": seam,
                  "warm_fraction": round(warm_count / (width * height), 5),
                  "teal_fraction": round(teal_count / (width * height), 5)})
if proc.wait() != 0:
    raise RuntimeError("Video decode failed")
full_warm = [s["frame"] for s in seams if s["warm_fraction"] > .90]
if not full_warm:
    raise RuntimeError("No full warm source")
start = full_warm[0]
target = next((s["frame"] for s in seams[start:] if s["teal_fraction"] > .90), None)
if target is None:
    raise RuntimeError("No full teal target after source")
movement = [s for s in seams[start:target + 61]
            if s["frame"] == start or s["warm_edge"] != seams[s["frame"] - 1]["warm_edge"]]
result = {"video": args.video, "method": "decode from zero; same fps=60 graph; seam at fixed three-row ROI",
          "roi": {"y": .647, "height": .015, "output_width": width},
          "sample_fps": 60, "resampled_frames": len(seams), "source_frame": start,
          "target_frame": target, "movement": movement,
          "sampling_limit": "VFR resampling; repeated samples do not prove a physical refresh"}
Path(args.output).write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({k: v for k, v in result.items() if k != "movement"}, indent=2))
print(json.dumps(movement, indent=2))
