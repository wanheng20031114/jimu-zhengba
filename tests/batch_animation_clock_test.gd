extends SceneTree
## Sparse display sampling versus the same native rig advanced every simulation
## tick. Exact release sockets, pause, visibility and replica ownership matter.
var game: Node3D
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func ticks(count: int) -> void:
	var until: int = Engine.get_physics_frames() + count
	while Engine.get_physics_frames() < until:
		await physics_frame
		await process_frame

func spawn(kind: String, batched: bool) -> BattleUnit:
	game.unit_batches_enabled = batched
	var unit: BattleUnit = game.spawn_unit(kind, 0, Vector3.ZERO)
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	game.get_node("UnitRenderBatches").set_process(false)
	return unit

func _run() -> void:
	create_timer(90.0, true, false, true).timeout.connect(func(): quit(3))
	var session: Node = root.get_node("Session")
	session.online = false
	session.config = session.offline_config("1v1")
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.set_process(false)
	game.get_node("IncomeTimer").stop()
	game.get_node("UnitRenderBatches").render_sampled_threshold = 1
	for unit: Node in game.unit_container.get_children(): unit.queue_free()
	await ticks(2)
	for rate: int in [30, 60]:
		Engine.physics_ticks_per_second = rate
		for kind: String in BalanceCatalog.UNITS:
			await compare_native_rig(kind, rate)
	game.get_node("UnitRenderBatches").render_sampled_threshold = 2
	var small := spawn("knight", true)
	check(not small._model.render_sampled_animation, "small armies retain native pose interpolation")
	var extra := spawn("knight", true)
	check(small._model.render_sampled_animation and extra._model.render_sampled_animation, "crossing the army threshold changes both existing and new rigs")
	extra.queue_free()
	await ticks(1)
	check(not small._model.render_sampled_animation, "shrinking the army restores native animation")
	small.queue_free()
	await ticks(1)
	game.is_authority = false
	var replica := spawn("archer", true)
	check(not replica._model.render_sampled_animation, "a batched network replica keeps snapshot animation ownership")
	replica.queue_free()
	game.is_authority = true
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("BATCH_ANIMATION_CLOCK %d checks; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func compare_native_rig(kind: String, rate: int) -> void:
	var sparse_unit := spawn(kind, true)
	var reference_unit := spawn(kind, false)
	var sparse: UnitVisual = sparse_unit._model
	var dense: UnitVisual = reference_unit._model
	await ticks(2)
	check(sparse.render_sampled_animation and sparse._animations_suspended, kind + " batched authority defers automatic pose evaluation")
	# The reference uses the identical authored batched rig without registration.
	# Advance its native players every tick, independently of UnitVisual's clock.
	dense._animations_suspended = false
	dense.locomotion.process_mode = Node.PROCESS_MODE_DISABLED
	dense.attack.process_mode = Node.PROCESS_MODE_DISABLED
	for model: UnitVisual in [sparse, dense]:
		model.locomotion.play("walk", 0.0)
		model.locomotion.seek(0.0, true)
		model.attack.stop()
	sparse._suspended_frame = sparse._visual_frame()
	sparse._locomotion_advanced = 0.0
	sparse._attack_advanced = 0.0
	sparse.strike()
	dense.strike()
	var previous: int = Engine.get_physics_frames()
	var elapsed := 0.0
	var release: float = sparse_unit._stats.attack_windup_seconds
	var sampled_release := false
	while elapsed < maxf(0.65, release + 0.1):
		await ticks(1)
		var frame: int = Engine.get_physics_frames()
		for step: int in frame - previous:
			dense.locomotion.advance(1.0 / rate)
			if dense.attack.is_playing(): dense.attack.advance(1.0 / rate)
		elapsed += (frame - previous) / float(rate)
		previous = frame
		if not sampled_release and elapsed + 0.000001 >= release:
			# A real release must read today's socket even after no display samples.
			sparse.prepare_attack_release(release)
			# Release sampling selects the exact authored strike time; the reference
			# may be one coarse tick beyond it, so seek its strike to that time.
			var reference_phase: float = dense.attack.current_animation_position
			dense.attack.seek(release, true)
			check(sparse.get_projectile_origin().distance_to(dense.get_projectile_origin()) < 0.015,
				"%s %d TPS exact release socket after skipped display frames" % [kind, rate])
			dense.attack.seek(reference_phase, true)
			sampled_release = true
		if elapsed > 0.5:
			sparse.synchronize_animation()
			var phase: float = sparse.locomotion.current_animation_position
			check(absf(phase - dense.locomotion.current_animation_position) < 0.0001, kind + " locomotion keeps normal simulation speed")
			sparse.synchronize_animation()
			check(absf(phase - sparse.locomotion.current_animation_position) < 0.0001, kind + " repeated display sampling cannot double advance")
	# Hidden poses still sample correctly, and pausing does not accrue animation.
	sparse.hide()
	sparse.process_mode = Node.PROCESS_MODE_DISABLED
	sparse.synchronize_animation()
	var paused_phase: float = sparse.locomotion.current_animation_position
	await ticks(5)
	sparse.synchronize_animation()
	check(absf(paused_phase - sparse.locomotion.current_animation_position) < 0.0001, kind + " pause freezes the simulation animation clock")
	sparse.process_mode = Node.PROCESS_MODE_INHERIT
	sparse.show()
	sparse.synchronize_animation()
	check(absf(paused_phase - sparse.locomotion.current_animation_position) < 0.0001, kind + " unpause does not catch up paused time")
	sparse_unit.queue_free()
	reference_unit.queue_free()
	await ticks(1)
