extends SceneTree
## Real notifier, animation visibility, native buffers and deletion timing.
var game: Node3D
var renderer: UnitRenderBatches
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func frames(count: int = 3) -> void:
	for index: int in count:
		await process_frame
		await RenderingServer.frame_post_draw

func spawn(kind: String, x: float) -> BattleUnit:
	var unit: BattleUnit = game.spawn_unit(kind, 0, Vector3(x, 0, 0))
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	unit._model.locomotion.pause()
	unit._model.attack.pause()
	renderer.set_process(false)
	return unit

func consistent(label: String, check_pose: bool = false) -> void:
	var valid := true
	for entry: UnitRenderBatches.ModelEntry in renderer._models:
		for part_index: int in entry.parts.size():
			valid = valid and (entry.slots[part_index] >= 0) == (entry.active and entry.parts[part_index].is_visible_in_tree())
	for batch: UnitRenderBatches.PartBatch in renderer._batches:
		valid = valid and batch.count == batch.mesh.visible_instance_count
		valid = valid and batch.node.visible == (batch.count > 0)
		for slot: int in batch.count:
			var entry: UnitRenderBatches.ModelEntry = renderer._models[renderer._model_index[batch.owners[slot]]]
			var part_index: int = batch.part_indices[slot]
			valid = valid and entry.active and entry.slots[part_index] == slot and entry.batches[part_index] == batch
			valid = valid and entry.parts[part_index].is_visible_in_tree()
			valid = valid and batch.mesh.get_instance_custom_data(slot).is_equal_approx(entry.custom)
			if check_pose:
				valid = valid and batch.mesh.get_instance_transform(slot).is_equal_approx(entry.parts[part_index].global_transform)
	check(valid, label + " dense slots preserve ownership, colour, visibility and pose")

func _run() -> void:
	create_timer(100.0, true, false, true).timeout.connect(func(): quit(3))
	check(DisplayServer.get_name() != "headless", "native screen notifiers require the real renderer")
	if not failures.is_empty():
		quit(1)
		return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_size(Vector2i(960, 540))
	var session: Node = root.get_node("Session")
	session.online = false
	session.config = session.offline_config("1v1")
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	Engine.max_fps = 60
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.set_process(false)
	game.get_node("IncomeTimer").stop()
	renderer = game.get_node("UnitRenderBatches")
	renderer.render_sampled_threshold = 1
	renderer.initial_capacity = 1
	for unit: Node in game.unit_container.get_children(): unit.queue_free()
	await frames()
	game.camera_rig.edge_scroll = false
	game.camera_rig.focus_at(Vector3.ZERO, true)
	game.camera_rig.zoom_target = 26.0
	game.camera.size = 26.0
	for kind: String in BalanceCatalog.UNITS:
		await model_case(kind)
	check(renderer.registered_models == 0, "all event subscriptions release their model entries")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("BATCH_SLOT_EVENTS %d checks; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func model_case(kind: String) -> void:
	# Some starting units already grew their kind's buffers before this test.
	# Empty them explicitly so *every* kind exercises growth with live slots.
	for key: StringName in renderer._batch_by_key:
		if String(key).begins_with(kind + "::"):
			var batch: UnitRenderBatches.PartBatch = renderer._batch_by_key[key]
			batch.mesh.instance_count = 0
			batch.mesh.visible_instance_count = 0
	var first := spawn(kind, -3.0)
	await frames()
	renderer._process(0.0)
	check(renderer.visible_models == 1, kind + " native screen visibility activates the model")
	var growths := renderer.capacity_growths
	# Grow after a visible instance exists; resizing must retain its GPU data.
	var second := spawn(kind, 0.0)
	second._model.set_team(FactionPalette.ALLY)
	var third := spawn(kind, 3.0)
	third._model.set_team(FactionPalette.ENEMY)
	check(renderer.capacity_growths > growths, kind + " buffer really grew while the first unit was visible")
	consistent(kind + " capacity growth")
	check(first._stats == second._stats, kind + " definitions share one resource")
	check(first._model.batch_parts.values()[0] == second._model.batch_parts.values()[0], kind + " identical parts share one GPU mesh")
	check(first._model.locomotion.get_animation("walk") == second._model.locomotion.get_animation("walk"), kind + " animation clips share one resource")
	check(first.get_node("CollisionShape3D").shape != second.get_node("CollisionShape3D").shape, kind + " mutable collision setup stays independent")
	await frames()
	renderer._process(0.0)
	consistent(kind + " initial presentation", true)
	var changes := renderer.slot_changes
	var uploads := renderer.custom_uploads
	for index: int in 12: renderer._process(0.0)
	check(renderer.slot_changes == changes and renderer.custom_uploads == uploads, kind + " unchanged display frames do no slot or colour work")
	game.camera_rig.focus_at(Vector3(100, 0, 100), true)
	await frames(4)
	renderer._process(0.0)
	check(renderer.visible_models == 0, kind + " native screen exit releases model slots")
	consistent(kind + " off-screen")
	game.camera_rig.focus_at(Vector3.ZERO, true)
	await frames(4)
	renderer._process(0.0)
	check(renderer.visible_models == 3, kind + " screen re-entry restores all three models")
	consistent(kind + " screen re-entry", true)
	var entry: UnitRenderBatches.ModelEntry = renderer._models[renderer._model_index[first._model.get_instance_id()]]
	var part: Node3D = entry.parts[0]
	part.hide()
	check(entry.slots[0] == -1, kind + " part hiding immediately releases its slot")
	consistent(kind + " part compaction", true)
	part.show()
	check(entry.slots[0] >= 0, kind + " part showing immediately acquires a slot")
	first._model.get_node("Rig").hide()
	check(entry.slots.count(-1) == entry.slots.size(), kind + " hidden ancestor immediately releases all parts")
	first._model.get_node("Rig").show()
	first._model.set_team(FactionPalette.ENEMY)
	first._model.set_batch_fade(0.4)
	consistent(kind + " team and fade events", true)
	first._model.set_batch_fade(1.0)
	check(entry.slots.count(-1) == entry.slots.size(), kind + " complete fade removes the whole model")
	first._model.set_batch_fade(0.0)
	renderer._process(0.0)
	consistent(kind + " restored fade", true)
	# Attack visibility tracks (arrows/stones) run while the renderer samples.
	first._model.strike()
	check(not second._model.attack.is_playing(), kind + " shared clips retain independent playback state")
	for phase: float in [0.0, first._stats.attack_windup_seconds, 0.65]:
		first._model.attack.seek(phase, true)
		consistent(kind + " attack visibility")
	first._model.attack.pause()
	# Fog changes the ancestor, including on a paused render loop.
	first.hide()
	check(entry.slots.count(-1) == entry.slots.size(), kind + " fog cannot leave old parts visible")
	first.show()
	await frames()
	renderer._process(0.0)
	# Keep the renderer stopped: deletion must repair the *last displayed* buffer.
	second.free()
	consistent(kind + " deletion after display")
	first.free()
	third.free()
	consistent(kind + " final deletion")
	await frames(1)
