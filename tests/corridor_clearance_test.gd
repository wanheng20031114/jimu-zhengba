extends SceneTree
## The optimized positive certificate is compared to uncached swept-cell tests
## across moving endpoints, body sizes, map identities and topology revisions.
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		if failures.size() <= 8: printerr("FAIL ", label)

func make_grid(hole: bool) -> ConstructionNavigation:
	var navigation := ConstructionNavigation.new()
	for x: int in range(-12, 13):
		for z: int in range(-12, 13):
			if hole and x in [-1, 0, 1] and z in [-1, 0, 1]: continue
			navigation._walkable_cells[Vector2i(x, z)] = true
	navigation._rebuild_corridor_prefix()
	return navigation

func _run() -> void:
	var navigation := make_grid(true)
	var certificate := ConstructionNavigation.Clearance.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 913600
	for path: int in 300:
		var start := Vector3(rng.randf_range(-10, 10), 0, rng.randf_range(-10, 10))
		var goal := start + Vector3(rng.randf_range(-5, 5), 0, rng.randf_range(-5, 5))
		for step: int in 24:
			var radius: float = [0.0, 0.4, 0.78, 1.3][path % 4]
			start += Vector3(rng.randf_range(-0.12, 0.12), 0, rng.randf_range(-0.12, 0.12))
			goal += Vector3(rng.randf_range(-0.12, 0.12), 0, rng.randf_range(-0.12, 0.12))
			check(navigation.has_clear_corridor(start, goal, radius, certificate) == navigation.has_clear_corridor(start, goal, radius), "moving endpoints and body radius match uncached swept cells")
	check(navigation.corridor_cache_hits > 1000, "differential cases actually reuse positive certificates")
	var empty := make_grid(false)
	var from := Vector3(-4, 0, 0)
	var to := Vector3(4, 0, 0)
	check(empty.has_clear_corridor(from, to, 0.4, certificate), "open map publishes a certificate")
	check(not navigation.has_clear_corridor(from, to, 0.4, certificate), "a different map cannot reuse the same revision number")
	check(empty.has_clear_corridor(from, to, 0.4, certificate), "clear answer can be recertified")
	for x: int in [-1, 0, 1]:
		for z: int in [-1, 0, 1]: empty._walkable_cells.erase(Vector2i(x, z))
	empty._revision += 1
	empty._rebuild_corridor_prefix()
	check(not empty.has_clear_corridor(from, to, 0.4, certificate), "new geometry invalidates a previously clear segment immediately")
	from = Vector3(-2.1, 0, -4)
	to = Vector3(-2.1, 0, 4)
	check(empty.has_clear_corridor(from, to, 0.4, certificate), "small body can pass beside obstacle")
	check(not empty.has_clear_corridor(from, to, 1.3, certificate), "a larger body cannot inherit a smaller clearance")
	check(not empty.has_clear_corridor(Vector3.INF, to, 0.4, certificate), "infinite endpoint cannot reuse a cached rectangle")
	check(not empty.has_clear_corridor(from, Vector3(NAN, 0, 0), 0.4, certificate), "NaN endpoint cannot pass Rect2 comparisons")
	navigation.free()
	empty.free()
	print("CORRIDOR_CLEARANCE %d checks; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
