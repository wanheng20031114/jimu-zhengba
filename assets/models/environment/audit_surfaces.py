"""Find actual positive-area coplanar triangle overlaps in exported architecture.

Opposite-facing internal joints are reported separately from visible same-facing
overlaps. Adjacent triangles that merely share an edge are not counted.
"""
import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import trimesh
from shapely.geometry import Polygon
from shapely.strtree import STRtree

ROOT = Path(__file__).resolve().parents[3]
NAMES = ("headquarters", "enemy_keep", "house", "barracks", "tower", "ruin", "wall", "palisade", "barrel", "crate", "tree", "rock", "well", "cart", "tent", "sacks", "hay_bale", "campfire", "broken_wheel", "broken_shield", "terrain")


def audit(name):
    scene = trimesh.load_scene(ROOT / "assets/models/environment" / (name + ".glb"))
    planes = defaultdict(list)
    duplicates = 0
    seen = set()
    for family, mesh in scene.geometry.items():
        for triangle, normal in zip(mesh.triangles, mesh.face_normals):
            if np.linalg.norm(normal) < .9:
                continue
            # The underside of the foundation/terrain is never displayed.
            if normal[1] < -.9 and triangle[:, 1].max() <= .3:
                continue
            coordinate_key = tuple(sorted(tuple(v) for v in np.round(triangle, 5)))
            if coordinate_key in seen:
                duplicates += 1
            seen.add(coordinate_key)
            axis = int(np.argmax(np.abs(normal)))
            direction = 1 if normal[axis] >= 0 else -1
            canonical = normal * direction
            distance = float(canonical @ triangle[0])
            key = tuple(np.round(canonical, 5)) + (round(distance, 5),)
            polygon = Polygon(np.delete(triangle, axis, axis=1))
            if polygon.area > 1e-7:
                planes[key].append((polygon, family, direction, triangle.mean(axis=0).tolist()))
    same, opposite, area = 0, 0, 0.0
    examples = []
    for plane, items in planes.items():
        if len(items) < 2:
            continue
        polygons = [item[0] for item in items]
        tree = STRtree(polygons)
        for first, polygon in enumerate(polygons):
            for second in tree.query(polygon):
                if second <= first:
                    continue
                overlap = polygon.intersection(polygons[second]).area
                if overlap < 1e-6:
                    continue
                if items[first][2] != items[second][2]:
                    opposite += 1
                    continue
                same += 1
                area += overlap
                if len(examples) < 500:
                    examples.append({"families": [items[first][1], items[second][1]], "plane": plane, "direction": items[first][2], "center": items[first][3], "projected_area": overlap})
    return {"same_facing_overlaps": same, "opposing_internal_overlaps": opposite, "exact_duplicate_triangles": duplicates, "summed_projected_overlap_area": area, "examples": examples}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("label")
    parser.add_argument("--strict", action="store_true", help="Fail when a visible coplanar overlap or duplicate remains.")
    args = parser.parse_args()
    result = {name: audit(name) for name in NAMES}
    out = ROOT / "artifacts/environment_flicker"
    out.mkdir(parents=True, exist_ok=True)
    (out / ("surfaces_" + args.label + ".json")).write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({name: {key: value for key, value in record.items() if key != "examples"} for name, record in result.items()}, indent=2))
    if args.strict and any(record["same_facing_overlaps"] or record["exact_duplicate_triangles"] for record in result.values()):
        raise SystemExit(1)
