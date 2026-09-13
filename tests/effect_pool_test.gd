extends SceneTree
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func run() -> void:
	# Native camera projection exercises the same viewport policy as the real game.
	root.size = Vector2i(1600, 900)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 30.0
	camera.position = Vector3(0, 0, 20)
	camera.current = true
	var pool: Node3D = load("res://scenes/effect_pool.tscn").instantiate()
	root.add_child(pool)
	await process_frame
	var count := pool.get_child_count()
	for index in range(250):
		var screen := Vector2(32 + (index % 25) * 64, 32 + (index / 25) * 64)
		pool.play(camera.project_position(screen, 20.0), "hit", Color.WHITE)
	check(pool.active_count() == count and pool.get_child_count() == count, "burst uses bounded authored instances")
	check(pool.dropped == 250 - count, "small effects shed at capacity")
	pool.play(Vector3.ZERO, "explosion", Color.WHITE)
	check(pool.active_count() == count, "important explosion reuses oldest instance at cap")
	pool.reset_all()
	check(pool.active_count() == 0, "reset returns every active instance")
	for index: int in 50:
		pool.play(Vector3.ZERO, "hit", Color.WHITE)
	check(pool.active_count() == 1 and pool.coalesced == 49, "one screen cell coalesces repeated small impacts")
	pool.play(Vector3(500, 0, 0), "hit", Color.WHITE)
	check(pool.active_count() == 1 and pool.offscreen == 1, "offscreen small impacts do not occupy scene instances")
	pool.play(Vector3.ZERO, "explosion", Color.WHITE)
	pool.play(Vector3.ZERO, "move", Color.WHITE)
	check(pool.active_count() == 3, "density never suppresses explosions or command feedback")
	pool.reset_all()
	for kind: String in ["spawn", "hit", "muzzle", "collapse", "move", "arrow_hit", "dust", "charge"]:
		pool.reset_all()
		pool.play(Vector3.ZERO, kind, Color.WHITE)
		var effect: BattleEffect = pool._active.back()
		check(effect.visible, "reused %s is visible" % kind)
		effect._on_lifetime_timeout()
		check(pool.active_count() == 0 and not effect.visible, "completed %s recycled" % kind)
		check(effect._tweens.is_empty(), "completed %s releases its tweens" % kind)
	check(pool.get_child_count() == count, "repeated reuse creates no extra nodes")
	# A command marker or light hit must never restart unrelated dust/debris.
	# Reusing a just-exploded instance exercises the stale-particle regression.
	pool.play(Vector3.ZERO, "collapse", Color.WHITE)
	var recycled: BattleEffect = pool._active.back()
	check(recycled.get_node("Dust").visible and recycled.get_node("Debris").visible, "collapse activates both relevant emitters")
	recycled._on_lifetime_timeout()
	for kind: String in ["move", "attack", "hit", "stone_chip", "spawn"]:
		pool.reset_all()
		pool.play(Vector3.ZERO, kind, Color.WHITE)
		var marker: BattleEffect = pool._active.back()
		check(not marker.get_node("Dust").visible and not marker.get_node("Dust").emitting, kind + " never emits dust")
		check(not marker.get_node("Debris").visible and not marker.get_node("Debris").emitting, kind + " never emits debris")
		if kind in ["move", "attack"]:
			check(not marker.get_node("Sparks").visible and not marker.get_node("Sparks").emitting, kind + " is only a clean command marker")
		marker._on_lifetime_timeout()
	pool.reset_all()
	camera.size = 8.0
	for x: float in [-.5,0,.5]: pool.play(Vector3(x,0,0), "muzzle", Color.WHITE)
	check(pool.active_count() == 3, "close-up independent muzzles each retain their flash")
	pool.reset_all()
	camera.size = 100.0
	var combined_before: int = pool.coalesced
	for index: int in 375: pool.play(Vector3.ZERO, "muzzle", Color.WHITE)
	check(pool.active_count() == 1 and pool.coalesced == combined_before+374, "distant overlapping muzzles do not churn particle pool")
	await physics_frame
	await physics_frame
	pool.play(Vector3.ZERO, "muzzle", Color.WHITE)
	check(pool.active_count() == 2, "another physics tick may show another independent flash")
	pool.play(Vector3(5000,0,0), "muzzle", Color.WHITE)
	check(pool.active_count() == 2, "offscreen muzzle does not displace visible effects")
	pool.reset_all()
	check(pool._muzzle_cells.is_empty(), "muzzle density state is released on reset")
	pool.play(camera.project_position(Vector2(15.9,300),20), "muzzle", Color.WHITE)
	pool.play(camera.project_position(Vector2(16.1,300),20), "muzzle", Color.WHITE)
	check(pool.active_count() == 1, "adjacent screen cells still coalesce overlapping distant guns")
	pool.reset_all()
	camera.size = 8.0
	for index: int in count:
		pool.play(Vector3.ZERO, "muzzle", Color.WHITE)
	var original: Array = pool._active.duplicate()
	for effect: BattleEffect in original: effect.get_node("Lifetime").start(.4)
	var dropped_before: int = pool.dropped
	for index: int in 1000: pool.play(Vector3.ONE, "muzzle", Color.RED)
	check(pool.dropped == dropped_before + 1000, "saturated muzzle bursts drop visuals instead of restarting the pool")
	check(pool._active == original, "same-priority burst preserves every live instance and its age order")
	var untouched: bool = true
	for effect: BattleEffect in original:
		untouched = untouched and is_equal_approx(effect.get_node("Lifetime").time_left, .4) and effect.global_position == Vector3.ZERO
	check(untouched, "rejected flashes never reset timers or relocate playing effects")
	pool.play(Vector3.ONE, "explosion", Color.WHITE)
	check(pool._priority_buckets[2].size() == 1 and pool._priority_buckets[1].size() == count-1, "explosion replaces exactly one lower-priority muzzle")
	check(pool._active.back() == original[0], "replacement selects the oldest effect of the lowest priority")
	pool.play(Vector3.ONE, "move", Color.WHITE)
	check(pool._priority_buckets[3].size() == 1 and pool._priority_buckets[2].size() == 1, "command feedback takes a muzzle slot while preserving the explosion")
	pool.reset_all()
	for index: int in count:
		pool.play(camera.project_position(Vector2(32 + (index % 25) * 32, 32 + (index / 25) * 32), 20), "explosion", Color.WHITE)
	original = pool._active.duplicate()
	pool.play(Vector3.ONE, "explosion", Color.WHITE)
	pool.play(Vector3.ONE, "muzzle", Color.WHITE)
	check(pool._active == original, "full explosions cannot be reset by equal or lower priority bursts")
	pool.reset_all()
	check(pool._effect_priority.is_empty() and pool._priority_buckets.all(func(bucket: Array): return bucket.is_empty()), "reset releases all capacity bookkeeping")
	for kind: String in ["explosion", "explosion", "stone_hit"]: pool.play(Vector3.ZERO, kind, Color.WHITE)
	check(pool.active_count() == 1, "simultaneous cannon and stone impacts share one cosmetic dust burst")
	pool.play(Vector3.ZERO, "muzzle", Color.WHITE)
	check(pool.active_count() == 2, "a muzzle and impact at the same pixel retain distinct feedback")
	pool.play(Vector3.ZERO, "heal", Color.WHITE)
	pool.play(Vector3.ZERO, "collapse", Color.WHITE)
	pool.play(Vector3.ZERO, "move", Color.WHITE)
	check(pool.active_count() == 5, "burst coalescing preserves healing, collapse and command feedback")
	pool.play(Vector3(5000,0,0), "explosion", Color.WHITE)
	check(pool.active_count() == 5, "offscreen impact particles never occupy visible capacity")
	await physics_frame
	await physics_frame
	pool.play(Vector3.ZERO, "explosion", Color.WHITE)
	check(pool.active_count() == 6, "new impact on a later tick remains visible")
	pool.reset_all()
	check(pool._impact_cells.is_empty(), "impact admission cache clears with the pool")
	pool.play(Vector3.ZERO, "muzzle", Color.WHITE)
	var reused: BattleEffect = pool._active.back()
	pool.reset_all()
	reused.reset_effect()
	check(not reused._active and reused.get_node("Sparks").amount == 10 and reused.get_node("Dust").amount == 6, "repeated release is inert and retains reusable particle buffers")
	for kind: String in ["spawn", "muzzle", "dust", "collapse", "explosion", "heal", "hit"]:
		pool.play(Vector3.ZERO, kind, Color.RED)
		check(pool._active.back() == reused, "configuration transition reuses the same authored instance: " + kind)
		if kind == "muzzle":
			check(reused.get_node("Sparks").direction == reused._spark_defaults.direction and reused.get_node("Sparks").color == Color.RED, "muzzle restores direction and color after spawn")
		if kind == "explosion":
			check(reused.get_node("Dust").scale == Vector3.ONE and reused.get_node("Debris").scale == Vector3.ONE, "explosion restores size after building collapse")
		if kind == "hit":
			check(not reused.get_node("Healing").visible and not reused.get_node("Dust").visible, "healing and smoke do not leak into a reused hit")
		pool.reset_all()
	pool.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame
	print("EFFECT_POOL_RESULT ", checks, " checks, ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
