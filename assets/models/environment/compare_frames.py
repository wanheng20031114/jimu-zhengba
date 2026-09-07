"""Measure temporal residuals after undoing the known orthographic camera pan.

These are visual diagnostics, not a universal flicker detector: animated cloth,
subpixel silhouettes, TAA, and soft shadows can still contribute to residuals.
"""
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import shift

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "artifacts/environment_flicker"
VIEWS = {
    "headquarters": (14, (12, 12, 18)),
    "keep": (15, (14, 12, 18)),
    "house": (11, (13, 10, 15)),
    "ruin": (10, (-12, 11, 17)),
    "tower": (9, (11, 14, 15)),
    "road": (16, (11, 18, 14)),
}


def measure(folder, name, size, offset):
    offset = np.asarray(offset, dtype=float)
    right = np.cross(-offset, [0, 1, 0])
    right /= np.linalg.norm(right)
    up = np.cross(right, -offset / np.linalg.norm(offset))
    frames = []
    for index in range(12):
        pixels = np.asarray(Image.open(folder / (name + "_micro_%02d.png" % index)))[:, :, :3].astype(np.float32)
        pixels_per_meter = pixels.shape[0] / size
        dx = -.006 * right[0] * pixels_per_meter
        dy = .006 * up[0] * pixels_per_meter
        # Restore each camera-translated frame to the initial world registration.
        registered = shift(pixels, (-index * dy, -index * dx, 0), order=1, mode="nearest", prefilter=False)
        h, w = pixels.shape[:2]
        frames.append(registered[int(h*.10):int(h*.84), int(w*.22):int(w*.78)])
    stack = np.stack(frames)
    spread = np.max(np.std(stack, axis=0), axis=2)
    delta = np.mean(np.abs(np.diff(stack, axis=0)), axis=(0, 3))
    return {"mean_temporal_std_255": round(float(spread.mean()), 4), "std_p99_255": round(float(np.percentile(spread, 99)), 4), "pixels_std_over_12_percent": round(float((spread > 12).mean() * 100), 4), "mean_frame_delta_255": round(float(delta.mean()), 4)}


if __name__ == "__main__":
    result = {label: {name: measure(OUT / label, name, size, offset) for name, (size, offset) in VIEWS.items()} for label in ("before", "final")}
    (OUT / "temporal_report.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
