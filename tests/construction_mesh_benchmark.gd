extends SceneTree
## Isolate navigation mutation cost from rendering, assets and battle simulation.

class Site extends Node3D:
	var alive: bool = true
	var building_type: String = "defense_tower"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var fixture := Node3D.new()
	root.add_child(fixture)
	var base := NavigationRegion3D.new()
	base.name = "NavigationRegion3D"
	base.navigation_mesh = load("res://assets/battle_navigation.tres")
	fixture.add_child(base)
	var cleared := Node3D.new()
	cleared.name = "ClearedNavigation"
	fixture.add_child(cleared)
	for building: String in ["Headquarters", "EnemyKeep", "NorthBarracks", "Watchtower", "WestBarracks"]:
		var region := NavigationRegion3D.new()
		region.name = building
		region.enabled = false
		region.navigation_mesh = load("res://assets/navigation/" + building + "_cleared.tres")
		cleared.add_child(region)
	var controller := ConstructionNavigation.new()
	fixture.add_child(controller)
	controller.refresh()
	var timings: Array[int] = []
	var sites: Array[Site] = []
	for z: int in range(-28, 29, 8):
		for x: int in range(-28, 29, 8):
			var at := Vector3(x, 0, z)
			if not controller.walkable_footprint(at):
				continue
			var site := Site.new()
			site.position = at
			fixture.add_child(site)
			site.add_to_group("buildings")
			sites.append(site)
			controller.refresh()
			timings.append(controller.last_rebuild_usec)
	var unchanged: int = controller.rebuild_count
	controller.refresh()
	var unchanged_usec: int = controller.last_rebuild_usec
	var stable: bool = unchanged == controller.rebuild_count
	for site: Site in sites:
		site.alive = false
	controller.refresh()
	var restored: bool = base.navigation_mesh == load("res://assets/battle_navigation.tres")
	timings.sort()
	var report: Dictionary = {"sites": sites.size(), "rebuilds": unchanged, "median_usec": timings[timings.size() / 2] if not timings.is_empty() else 0, "max_usec": timings.back() if not timings.is_empty() else 0, "unchanged_usec": unchanged_usec, "stable": stable, "restored": restored}
	var file := FileAccess.open("res://artifacts/construction_mesh_benchmark.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("CONSTRUCTION_MESH_BENCHMARK ", JSON.stringify(report))
	fixture.queue_free()
	await process_frame
	await physics_frame
	quit(0 if stable and restored and not sites.is_empty() else 1)
