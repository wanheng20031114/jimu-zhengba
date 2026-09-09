"""Authored eight-seat geography, independently of runtime room occupancy."""
from __future__ import annotations

import math
import json
import sys
import unittest
from pathlib import Path

from shapely.geometry import LineString, Point, box

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_skirmish_maps import MAP_DEFINITIONS, rotate_point


class EightPlayerLayoutTest(unittest.TestCase):
    def test_saved_native_maps_match_authoring(self):
        root = Path(__file__).resolve().parents[1]
        for definition in MAP_DEFINITIONS:
            if definition["id"] not in ("four_banners_4v4", "crownfall_ffa"):
                continue
            map_id = definition["id"]
            with self.subTest(map=map_id):
                saved = json.loads((root / "scenes/maps" / f"{map_id}_layout.json").read_text(encoding="utf-8"))
                for field in ("size", "spawns", "starting_towers", "mines", "roads", "symmetry"):
                    self.assertEqual(saved[field], definition[field])
                scene = (root / "scenes/maps" / f"{map_id}.tscn").read_text(encoding="utf-8")
                resource = (root / "data/maps" / f"{map_id}.tres").read_text(encoding="utf-8")
                self.assertIn("slots = 8", resource)
                self.assertEqual(scene.count('type="Marker3D" parent="SpawnPoints"'), 8)
                for owner in range(8):
                    self.assertIn(f'[node name="Player{owner}" type="Marker3D" parent="SpawnPoints"]', scene)
                    self.assertIn(f"metadata/player_id = {owner}", scene)
                self.assertGreater(saved["navigation_polygons"], 20000)
                # Offsets belong to native bodies, not oversized visual trees.
                turn = math.tau / saved["symmetry"]
                obstacles = saved["obstacles"]
                for index, item in enumerate(obstacles):
                    target = obstacles[index - index % saved["symmetry"] + (index + 1) % saved["symmetry"]]
                    point = rotate_point((item["position"][0], item["position"][2]), turn)
                    self.assertLess(math.dist(point, (target["position"][0], target["position"][2])), 0.00001)
                    self.assertEqual(item["model"], target["model"])
                    if item["model"].startswith("tree_"):
                        self.assertLessEqual(item["collision"]["radius"], 0.43)

    def test_resources_roads_and_each_independent_economy(self):
        for definition in MAP_DEFINITIONS:
            if definition["id"] not in ("four_banners_4v4", "crownfall_ffa"):
                continue
            with self.subTest(map=definition["id"]):
                spawns = definition["spawns"]
                self.assertEqual(len(spawns), 8)
                self.assertEqual(len(definition["starting_towers"]), 8)
                self.assertGreaterEqual(len(definition["mines"]), 16)
                width, depth = definition["size"]
                field = box(-width / 2, -depth / 2, width / 2, depth / 2)
                self.assertLessEqual(max(width, depth), 192)
                for owner, (x, z, _alliance) in enumerate(spawns):
                    spawn = Point(x, z)
                    birth = Point(definition["mines"][owner])
                    tower = Point(definition["starting_towers"][owner])
                    expansion = Point(definition["mines"][owner + 8])
                    self.assertTrue(field.covers(spawn.buffer(11.5)))
                    self.assertTrue(field.covers(birth.buffer(5.1)))
                    self.assertTrue(field.covers(tower.buffer(3.15)))
                    self.assertLessEqual(tower.distance(birth), 9)
                    self.assertLess(birth.distance(spawn), expansion.distance(spawn))
                    nearest = min(range(len(definition["mines"])),
                                  key=lambda index: spawn.distance(Point(definition["mines"][index])))
                    self.assertEqual(nearest, owner)
                    magnitude = math.hypot(x, z)
                    left = (-z / magnitude, x / magnitude)
                    self.assertGreater((birth.x - x) * left[0] + (birth.y - z) * left[1], 0)
                    # Birth infrastructure stays clear even if all eight seats
                    # become occupied; empty seats never change marker indices.
                    for other in range(owner + 1, len(spawns)):
                        self.assertGreater(spawn.distance(Point(spawns[other][:2])), 23)
                for mine in definition["mines"]:
                    for road in definition["roads"]:
                        self.assertIn(road["width"], (8, 12))
                        shoulder = LineString(road["points"]).distance(Point(mine)) - road["width"] / 2
                        self.assertGreater(shoulder, 3.35 + 0.75)

    def test_team_and_ffa_rotation_symmetry(self):
        for definition in MAP_DEFINITIONS:
            if definition["id"] not in ("four_banners_4v4", "crownfall_ffa"):
                continue
            with self.subTest(map=definition["id"]):
                seats = definition["spawns"]
                if definition["id"] == "four_banners_4v4":
                    self.assertEqual([seat[2] for seat in seats], [0] * 4 + [1] * 4)
                    rotation, shift = math.pi, 4
                else:
                    self.assertEqual([seat[2] for seat in seats], list(range(8)))
                    rotation, shift = math.pi / 4, 1
                for index in range(8):
                    target = (index + shift) % 8
                    for collection in (seats, definition["starting_towers"], definition["mines"][:8], definition["mines"][8:16]):
                        point = rotate_point(collection[index][:2], rotation)
                        self.assertLess(math.dist(point, collection[target][:2]), 0.00001)


if __name__ == "__main__":
    unittest.main(verbosity=2)
