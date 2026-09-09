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
	var pool: Node3D = load("res://scenes/effect_pool.tscn").instantiate()
	root.add_child(pool)
	await process_frame
	var count := pool.get_child_count()
	for index in range(250):
		pool.play(Vector3(index, 0, 0), "hit", Color.WHITE)
	check(pool.active_count() == count and pool.get_child_count() == count, "burst uses bounded authored instances")
	check(pool.dropped == 250 - count, "small effects shed at capacity")
	pool.play(Vector3.ZERO, "explosion", Color.WHITE)
	check(pool.active_count() == count, "important explosion reuses oldest instance at cap")
	pool.reset_all()
	check(pool.active_count() == 0, "reset returns every active instance")
	for kind: String in ["spawn", "hit", "muzzle", "collapse", "move", "arrow_hit", "dust", "charge"]:
		pool.play(Vector3.ZERO, kind, Color.WHITE)
		var effect: BattleEffect = pool._active.back()
		check(effect.visible, "reused %s is visible" % kind)
		effect._on_lifetime_timeout()
		check(pool.active_count() == 0 and not effect.visible, "completed %s recycled" % kind)
		check(effect._tweens.is_empty(), "completed %s releases its tweens" % kind)
	check(pool.get_child_count() == count, "repeated reuse creates no extra nodes")
	pool.queue_free()
	await process_frame
	await process_frame
	print("EFFECT_POOL_RESULT ", checks, " checks, ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
