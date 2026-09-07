"""Author the battlefield navigation and non-overlapping demolition patches.

Every polygon uses the same integer-metre world lattice at Y=0.03. A cleared
building patch contains only cells owned exclusively by that building, so
enabling a NavigationRegion3D cannot open a surviving wall or another building.
Run after saving scenes/main.tscn and rebuilding the environment.
"""
from __future__ import annotations

import argparse
import itertools
import json
import math
import re
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAV_DIR = ROOT / "assets/navigation"
GRID_MIN, GRID_MAX = -40, 40
HEIGHT = 0.03
PADDING = 1.15
BUILDING_NAMES = ("Headquarters", "EnemyKeep", "NorthBarracks", "Watchtower", "WestBarracks")
BUILDING_SIZES = {"headquarters": (9.0, 8.0), "enemy_keep": (9.0, 8.0), "barracks": (6.0, 5.0), "tower": (4.0, 4.0), "house": (6.0, 5.0)}
UNIT_RADII = {"swordsman": .48, "archer": .42, "knight": .78, "catapult": 1.05, "cannon": 1.0}
ALL_CELLS = {(x, z) for x in range(GRID_MIN, GRID_MAX) for z in range(GRID_MIN, GRID_MAX)}


def scene_entities():
    contents = (ROOT / "scenes/main.tscn").read_text(encoding="utf-8")
    buildings, units = [], []
    pattern = r'^\[node (?P<header>[^\n]+)\]\s*\n(?P<body>.*?)(?=^\[|\Z)'
    for node in re.finditer(pattern, contents, re.MULTILINE | re.DOTALL):
        header, body = node["header"], node["body"]
        parent = re.search(r'parent="([^"]+)"', header)
        if parent is None or parent[1] not in ("Units", "Buildings"):
            continue
        name = re.search(r'name="([^"]+)"', header)[1]
        vector = re.search(r'^position\s*=\s*Vector3\(([^)]+)\)', body, re.MULTILINE)
        position = [float(value) for value in vector[1].split(",")]
        kind_key = "building_type" if parent[1] == "Buildings" else "unit_type"
        kind = re.search(rf'^{kind_key}\s*=\s*"([^"]+)"', body, re.MULTILINE)[1]
        team = int(re.search(r'^team\s*=\s*(\d+)', body, re.MULTILINE)[1])
        data = {"name": name, "position": position, "kind": kind, "team": team}
        if parent[1] == "Buildings":
            w, d = BUILDING_SIZES[kind]
            data.update(width=w, depth=d, rotation_y=0.0, size=[w, 8.0, d])
            buildings.append(data)
        else:
            data["radius"] = UNIT_RADII[kind]
            units.append(data)
    actual_names = {item["name"] for item in buildings}
    if actual_names != set(BUILDING_NAMES):
        raise ValueError(f"Expected the five named battle buildings, found {sorted(actual_names)}")
    return buildings, units


def environment_obstacles():
    data = json.loads((ROOT / "assets/environment_obstacles.json").read_text(encoding="utf-8"))
    result = []
    for item in data["obstacles"]:
        entry = dict(item)
        width, depth, angle = entry["size"][0], entry["size"][2], entry["rotation_y"]
        entry["width"] = abs(math.cos(angle)) * width + abs(math.sin(angle)) * depth
        entry["depth"] = abs(math.sin(angle)) * width + abs(math.cos(angle)) * depth
        # Position/size describe the rotated local box. Compute its AABB once;
        # aabb_min/max in the environment file are already rotated world bounds.
        result.append(entry)
    return result


def blocked_cells(obstacle):
    x, _, z = obstacle["position"]
    half_w, half_d = obstacle["width"] / 2 + PADDING, obstacle["depth"] / 2 + PADDING
    return {cell for cell in ALL_CELLS if abs(cell[0] + .5 - x) < half_w and abs(cell[1] + .5 - z) < half_d}


def neighbors(cell):
    x, z = cell
    return ((x - 1, z), (x + 1, z), (x, z - 1), (x, z + 1))


def components(cells):
    unseen, groups = set(cells), []
    while unseen:
        group = {min(unseen)}
        queue = deque(group)
        unseen.difference_update(group)
        while queue:
            for other in neighbors(queue.popleft()):
                if other in unseen:
                    unseen.remove(other)
                    group.add(other)
                    queue.append(other)
        groups.append(group)
    return sorted(groups, key=lambda group: (-len(group), min(group)))


def write_mesh(path, cells):
    # Canonical integer coordinates are shared across ALL six resources. Local
    # vertex indices are compact; common boundary coordinates are byte-identical.
    points = sorted({point for x, z in cells for point in ((x, z), (x, z + 1), (x + 1, z + 1), (x + 1, z))})
    indices = {point: index for index, point in enumerate(points)}
    vertices = ", ".join(f"{x}, 0.03, {z}" for x, z in points)
    polygons = []
    for x, z in sorted(cells):
        polygon = [indices[point] for point in ((x, z), (x, z + 1), (x + 1, z + 1), (x + 1, z))]
        polygons.append("PackedInt32Array(" + ", ".join(map(str, polygon)) + ")")
    content = '[gd_resource type="NavigationMesh" format=3]\n\n[resource]\n'
    content += f'vertices = PackedVector3Array({vertices})\npolygons = Array[PackedInt32Array]([{", ".join(polygons)}])\n'
    content += 'agent_radius = 0.75\ncell_size = 0.25\ncell_height = 0.25\n'
    path.write_text(content, encoding="utf-8")
    return {"vertices": len(points), "polygons": len(cells)}


def center(cell):
    return [cell[0] + .5, HEIGHT, cell[1] + .5]


def closest_point(point, cells):
    px, _, pz = point
    best = None
    for x, z in cells:
        qx, qz = max(x, min(x + 1, px)), max(z, min(z + 1, pz))
        score = (qx - px) ** 2 + (qz - pz) ** 2
        candidate = (score, qx, qz)
        if best is None or candidate < best:
            best = candidate
    return [best[1], HEIGHT, best[2]], math.sqrt(best[0])


def closest_center(point, cells):
    px, _, pz = point
    return min(cells, key=lambda c: ((c[0] + .5 - px) ** 2 + (c[1] + .5 - pz) ** 2, c))


def collision_at(point, radius, obstacle):
    dx, dz = point[0] - obstacle["position"][0], point[2] - obstacle["position"][2]
    angle = obstacle["rotation_y"]
    local_x = math.cos(angle) * dx - math.sin(angle) * dz
    local_z = math.sin(angle) * dx + math.cos(angle) * dz
    outside_x = max(abs(local_x) - obstacle["size"][0] / 2, 0)
    outside_z = max(abs(local_z) - obstacle["size"][2] / 2, 0)
    return outside_x * outside_x + outside_z * outside_z < radius * radius


def point_on_cells(point, cells):
    px, pz = point[0], point[2]
    x, z = math.floor(px), math.floor(pz)
    candidates = {(x, z)}
    if abs(px - x) < 1e-7:
        candidates.add((x - 1, z))
    if abs(pz - z) < 1e-7:
        candidates.add((x, z - 1))
    if abs(px - x) < 1e-7 and abs(pz - z) < 1e-7:
        candidates.add((x - 1, z - 1))
    return bool(candidates & cells)


def direct_walk(a, b, cells):
    distance = math.dist((a[0], a[2]), (b[0], b[2]))
    steps = max(1, math.ceil(distance / .15))
    return all(point_on_cells([a[0] + (b[0] - a[0]) * i / steps, HEIGHT, a[2] + (b[2] - a[2]) * i / steps], cells) for i in range(steps + 1))


def patch_case(building, patch, main_component):
    boundary = {other for cell in patch for other in neighbors(cell) if other in main_component}
    if not boundary:
        raise ValueError(f"Demolition patch {building['name']} has no exact shared edge with the main component")
    pairs = sorted(itertools.combinations(sorted(boundary), 2), key=lambda pair: -math.dist(pair[0], pair[1]))
    union = main_component | patch
    crossing = None
    for a, b in pairs:
        start, end = center(a), center(b)
        if direct_walk(start, end, union) and not direct_walk(start, end, main_component):
            crossing = (start, end)
            break
    if crossing is None:
        raise ValueError(f"No testable crossing through demolition patch {building['name']}")
    return {"name": building["name"], "mesh": f"res://assets/navigation/{building['name']}_cleared.tres", "probe": center(closest_center(building["position"], patch)), "crossing_start": crossing[0], "crossing_end": crossing[1], "cells": [list(c) for c in sorted(patch)], "main_boundary_edges": sum(other in main_component for cell in patch for other in neighbors(cell))}


def audit_spawns(units, obstacles, walkable, main_component):
    result, occupied = [], {unit["name"]: (unit["position"], unit["radius"]) for unit in units}
    for unit in units:
        position, radius = unit["position"], unit["radius"]
        collisions = [o["name"] for o in obstacles if collision_at(position, radius * .85, o)]
        unit_overlaps = [other["name"] for other in units if other["name"] != unit["name"] and math.dist((position[0], position[2]), (other["position"][0], other["position"][2])) < .85 * (radius + other["radius"])]
        projection, nav_distance = closest_point(position, walkable)
        component_projection, component_distance = closest_point(position, main_component)
        item = {**unit, "physics_overlaps": collisions, "unit_overlaps": unit_overlaps, "distance_to_navigation": round(nav_distance, 4), "navigation_projection": projection, "reaches_main_component": component_distance < .021}
        if collisions or unit_overlaps or nav_distance > .021 or component_distance > .021:
            candidates = sorted(main_component, key=lambda c: ((c[0] + .5 - position[0]) ** 2 + (c[1] + .5 - position[2]) ** 2, c))
            for cell in candidates:
                proposal = center(cell)
                proposal[1] = 0.0
                if any(collision_at(proposal, radius * .85, o) for o in obstacles):
                    continue
                if any(name != unit["name"] and math.dist((proposal[0], proposal[2]), (p[0], p[2])) < radius + r + .20 for name, (p, r) in occupied.items()):
                    continue
                item["suggested_position"] = proposal
                occupied[unit["name"]] = proposal, radius
                break
            if "suggested_position" not in item:
                raise ValueError(f"No safe position for {unit['name']}")
        result.append(item)
    return result


def build():
    NAV_DIR.mkdir(parents=True, exist_ok=True)
    buildings, units = scene_entities()
    environment = environment_obstacles()
    environment_cells = set().union(*(blocked_cells(obstacle) for obstacle in environment))
    building_cells = {building["name"]: blocked_cells(building) for building in buildings}
    all_building_cells = set().union(*building_cells.values())
    walkable = ALL_CELLS - environment_cells - all_building_cells
    groups = components(walkable)
    main_component = groups[0]
    base_stats = write_mesh(ROOT / "assets/battle_navigation.tres", walkable)
    patches, patch_stats = [], {}
    claimed = set(walkable)
    for building in buildings:
        name = building["name"]
        others = set().union(*(mask for key, mask in building_cells.items() if key != name))
        cells = building_cells[name] - environment_cells - others
        if cells & claimed:
            raise ValueError(f"Overlapping navigation ownership in patch {name}")
        claimed.update(cells)
        patch_stats[name] = write_mesh(NAV_DIR / f"{name}_cleared.tres", cells)
        patches.append(patch_case(building, cells, main_component))
    spawns = audit_spawns(units, buildings + environment, walkable, main_component)
    anchor = center(closest_center([-10, 0, 20], main_component))
    targets = [("CentralBattlefield", [0, 0, 0]), ("EnemyFront", [16, 0, -10]), ("KeepWestApproach", [14, 0, -25]), ("WestWarehouseApproach", [-10, 0, -13])]
    routes = [{"name": name, "start": anchor, "end": center(closest_center(position, main_component))} for name, position in targets]
    component_bounds = [{"cells": len(group), "min": [min(c[0] for c in group), min(c[1] for c in group)], "max": [max(c[0] for c in group) + 1, max(c[1] for c in group) + 1]} for group in groups]
    manifest = {"grid_min": GRID_MIN, "grid_max": GRID_MAX, "grid_spacing": 1, "height": HEIGHT, "obstacle_padding": PADDING, "environment_obstacles": len(environment), "base": base_stats, "components": [len(group) for group in groups], "component_bounds": component_bounds, "anchor": anchor, "routes": routes, "patches": patches, "patch_stats": patch_stats, "spawns": spawns}
    (NAV_DIR / "audit_manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    issues = [unit for unit in spawns if "suggested_position" in unit]
    print(json.dumps({"main_polygons": len(walkable), "components": manifest["components"], "patch_polygons": {name: stats["polygons"] for name, stats in patch_stats.items()}, "spawn_issues": [{"name": item["name"], "position": item["position"], "physics_overlaps": item["physics_overlaps"], "distance_to_navigation": item["distance_to_navigation"], "suggested_position": item["suggested_position"]} for item in issues]}, ensure_ascii=False, indent=2))
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict-spawns", action="store_true", help="Exit nonzero when authored initial units overlap or lie outside reachable navigation")
    args = parser.parse_args()
    result = build()
    if args.strict_spawns and any("suggested_position" in spawn for spawn in result["spawns"]):
        raise SystemExit(1)
