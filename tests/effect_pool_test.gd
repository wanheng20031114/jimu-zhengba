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
	pool.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame
	print("EFFECT_POOL_RESULT ", checks, " checks, ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
