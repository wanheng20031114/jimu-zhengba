extends SceneTree
## Actual renderer regression. Run with -- --tps=30, or --tps=10 for visible stress.
## This deliberately samples only a handful of joints; gameplay must use physics poses.
const KINDS: Array[String] = ["swordsman", "archer", "knight", "catapult", "cannon", "farmer"]
const JOINTS: Dictionary = {"swordsman": "ArmRight", "archer": "Bow", "knight": "ArmRight", "catapult": "ThrowArm", "cannon": "Barrel", "farmer": "Pick"}
var tps: int = 30
var failures: Array[String] = []
var checks: int = 0
var report: Dictionary = {}
var game: Node3D
var held_archer: Node3D
var case_units: Array[Node3D] = []
var release_records: Array[Dictionary] = []
var finishing: bool = false

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--tps="):
			tps = argument.trim_prefix("--tps=").to_int()
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _run() -> void:
	create_timer(50.0, true, false, true).timeout.connect(func():
		_check(false, "rendered interpolation regression deadline")
		_finish())
	_check(tps in [10, 30, 60], "requested fixed simulation rate is 10, 30 or 60 TPS")
	_check(DisplayServer.get_name() != "headless", "real renderer is available; headless cannot validate displayed interpolation")
	if not failures.is_empty():
		await _finish()
		return
	Engine.physics_ticks_per_second = tps
	Engine.max_fps = 120
	physics_interpolation = true
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(960, 540))
	seed(46030)
	report["tps"] = tps
	report["engine"] = Engine.get_version_info()
	report["renderer"] = RenderingServer.get_current_rendering_method()
	await _models_case()
	await _combat_case()
	await _finish()

func _models_case() -> void:
	var gallery: Node3D = load("res://assets/models/units/preview.tscn").instantiate()
	gallery.set_script(null)
	root.add_child(gallery)
	current_scene = gallery
	var models: Node3D = gallery.get_node("Units")
	var farmer: Node3D = load("res://assets/models/units/farmer.tscn").instantiate()
	farmer.position = Vector3(7.5, 0, 0)
	models.add_child(farmer)
	var camera: Camera3D = gallery.get_node("Camera3D")
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var probes: Array[Dictionary] = []
	for model: Node3D in models.get_children():
		var locomotion: AnimationPlayer = model.get_node("Locomotion")
		var attack: AnimationPlayer = model.get_node("Attack")
		_check(locomotion.callback_mode_process == AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS and attack.callback_mode_process == AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS,
			model.kind + " both saved animation players run on physics ticks")
		var native_rotations: int = 0
		var animation: Animation = attack.get_animation("strike")
		for track: int in range(animation.get_track_count()):
			if animation.track_get_type(track) == Animation.TYPE_ROTATION_3D:
				native_rotations += 1
		_check(native_rotations > 0, model.kind + " retains native quaternion rotation tracks")
		locomotion.pause()
		attack.pause()
		var joint: Node3D = model.find_child(JOINTS[model.kind])
		joint.get_global_transform_interpolated()
		model.reset_physics_interpolation()
		probes.append({"model": model, "joint": joint, "attack": attack, "last_tick": -1,
			"pairs": 0, "smooth_pairs": 0, "phase_violations": 0, "quaternion_samples": 0,
			"max_quaternion_error_rad": 0.0, "max_normalization_error": 0.0,
			"chain": _joint_chain(joint), "max_global_reference_difference_rad": 0.0})
	# Start all six native attacks at a physics boundary, without manually advancing them.
	await physics_frame
	for probe: Dictionary in probes:
		probe.model.strike()
	var started: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 1550:
		await RenderingServer.frame_post_draw
		for probe: Dictionary in probes:
			_sample_quaternion(probe)
	var summaries: Dictionary = {}
	for probe: Dictionary in probes:
		var kind: String = probe.model.kind
		_check(probe.pairs >= 3, kind + " has repeated rendered frames within one physics tick")
		_check(probe.phase_violations == 0, kind + " animation phase remains fixed between physics ticks")
		_check(probe.smooth_pairs >= 2, kind + " displayed rotation changes between fixed simulation ticks")
		_check(probe.quaternion_samples >= 3 and probe.max_quaternion_error_rad < .006,
			kind + " displayed quaternion follows native local-chain interpolation (max %.6f rad)" % probe.max_quaternion_error_rad)
		_check(probe.max_normalization_error < .0001, kind + " displayed quaternion stays normalized")
		summaries[kind] = {"same_tick_pairs": probe.pairs, "smooth_pairs": probe.smooth_pairs,
			"phase_violations": probe.phase_violations, "quaternion_samples": probe.quaternion_samples,
			"max_quaternion_error_rad": probe.max_quaternion_error_rad,
			"max_normalization_error": probe.max_normalization_error,
			"max_global_reference_difference_rad": probe.max_global_reference_difference_rad}
	report["model_interpolation"] = summaries
	await _bow_hold_case(models, camera)
	gallery.queue_free()
	await process_frame

func _joint_chain(joint: Node3D) -> Array[Node3D]:
	var chain: Array[Node3D] = []
	var ancestor: Node3D = joint
	while ancestor != null:
		chain.push_front(ancestor)
		ancestor = ancestor.get_parent_node_3d()
	return chain

func _sample_quaternion(probe: Dictionary) -> void:
	var tick: int = Engine.get_physics_frames()
	var joint: Node3D = probe.joint
	var authoritative: Quaternion = joint.global_basis.orthonormalized().get_rotation_quaternion()
	var displayed: Quaternion = joint.get_global_transform_interpolated().basis.orthonormalized().get_rotation_quaternion()
	var local_transforms: Array[Transform3D] = []
	for ancestor: Node3D in probe.chain:
		local_transforms.append(ancestor.transform)
	var phase: float = probe.attack.current_animation_position
	if probe.last_tick == tick:
		probe.pairs += 1
		if not is_equal_approx(phase, probe.phase):
			probe.phase_violations += 1
		# acos loses precision near 1; compare quaternion components for tiny frame steps.
		if displayed.dot(probe.displayed) < 0.0:
			displayed = -displayed
		if (displayed - probe.displayed).length_squared() > 0.000000001:
			probe.smooth_pairs += 1
	elif probe.last_tick == tick - 1:
		probe.previous = probe.authoritative
		probe.previous_locals = probe.local_transforms
		probe.have_previous = true
	else:
		probe.have_previous = false
	if probe.get("have_previous", false):
		var alpha: float = Engine.get_physics_interpolation_fraction()
		# Godot 4.6.3 SceneTreeFTI interpolates local transforms, then concatenates parents.
		# Global-endpoint slerp is only a diagnostic; rotations on separate joints do not commute.
		var expected_transform := Transform3D.IDENTITY
		for index: int in range(local_transforms.size()):
			var previous_local: Transform3D = probe.previous_locals[index]
			expected_transform *= previous_local.interpolate_with(local_transforms[index], alpha)
		var expected: Quaternion = expected_transform.basis.orthonormalized().get_rotation_quaternion()
		var global_reference: Quaternion = probe.previous.slerp(authoritative, alpha)
		probe.max_global_reference_difference_rad = maxf(probe.max_global_reference_difference_rad, global_reference.angle_to(displayed))
		# Quaternion.angle_to includes single-precision acos noise; .006 rad is < .35 degree.
		probe.max_quaternion_error_rad = maxf(probe.max_quaternion_error_rad, expected.angle_to(displayed))
		probe.quaternion_samples += 1
	probe.max_normalization_error = maxf(probe.max_normalization_error, absf(displayed.length() - 1.0))
	probe.last_tick = tick
	probe.phase = phase
	probe.authoritative = authoritative
	probe.local_transforms = local_transforms
	probe.displayed = displayed

func _bow_hold_case(models: Node3D, camera: Camera3D) -> void:
	for model: Node3D in models.get_children():
		model.visible = model.kind == "archer"
		if model.kind == "archer":
			held_archer = model
	camera.global_position = held_archer.global_position + Vector3(3, 3.2, -4.4)
	camera.look_at(held_archer.global_position + Vector3.UP * 1.05)
	camera.size = 3.8
	var hand: Node3D = held_archer.find_child("ForearmRight")
	var string: Node3D = held_archer.find_child("StringUpper")
	hand.get_global_transform_interpolated()
	string.get_global_transform_interpolated()
	await physics_frame
	var attack: AnimationPlayer = held_archer.get_node("Attack")
	attack.stop()
	attack.play("strike")
	attack.advance(.24)
	attack.pause()
	held_archer.reset_physics_interpolation()
	physics_frame.connect(_turn_held_archer)
	# Warm interpolation pumps after posing, before checking independently rendered joints.
	for tick: int in range(3):
		await physics_frame
	var started: int = Time.get_ticks_msec()
	var max_displayed_contact: float = 0.0
	var max_authoritative_contact: float = 0.0
	var samples: int = 0
	while Time.get_ticks_msec() - started < 1000:
		await RenderingServer.frame_post_draw
		var palm := Vector3(.02, -.24, -.075)
		max_authoritative_contact = maxf(max_authoritative_contact, (hand.global_transform * palm).distance_to(string.global_position))
		max_displayed_contact = maxf(max_displayed_contact,
			(hand.get_global_transform_interpolated() * palm).distance_to(string.get_global_transform_interpolated().origin))
		samples += 1
	physics_frame.disconnect(_turn_held_archer)
	_check(samples >= 10, "stable draw collects actual rendered bow/hand samples")
	_check(max_authoritative_contact < .025, "authored draw-hand/string contact remains below 2.5 cm")
	_check(max_displayed_contact < .028 and max_displayed_contact < max_authoritative_contact + .003,
		"interpolated independent bow/hand contact stays within 3 mm of authored contact (%.5f m)" % max_displayed_contact)
	report["bow_hold"] = {"samples": samples, "max_authoritative_contact_m": max_authoritative_contact,
		"max_displayed_contact_m": max_displayed_contact, "turn_rate_rad_per_sec": .4}
	root.get_texture().get_image().save_png("res://artifacts/interpolation_bow_%dtps.png" % tps)
	held_archer = null

func _bow_contact_statistics(samples: Array[Dictionary]) -> Dictionary:
	var result: Dictionary = {"samples": samples.size()}
	for field: String in ["displayed_contact_m", "authoritative_contact_m", "authored_at_display_phase_contact_m", "excess_over_authored_m"]:
		var values: Array[float] = []
		var total: float = 0.0
		var peak_phase: float = 0.0
		var peak_value: float = -1.0
		for sample: Dictionary in samples:
			var value: float = sample[field]
			values.append(value)
			total += value
			if value > peak_value:
				peak_value = value
				peak_phase = sample.display_phase_sec
		values.sort()
		if values.is_empty():
			result[field] = {"mean": null, "p95": null, "max": null, "peak_display_phase_sec": null}
		else:
			result[field] = {"mean": total / values.size(), "p95": values[ceili(values.size() * .95) - 1],
				"max": values[-1], "peak_display_phase_sec": peak_phase}
	return result

func _turn_held_archer() -> void:
	held_archer.rotate_y(.4 / float(tps))

func _combat_case() -> void:
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.tests_running = true
	# This fixture replaces the armies. Stop current Bot scheduling and its
	# queued commands before deleting units referenced by the initial match.
	game.bots.clear()
	game.command_bus.pending.clear()
	game.camera_rig.edge_scroll = false
	game.get_node("EnemyTimer").stop()
	game.get_node("IncomeTimer").stop()
	for unit: Node in get_nodes_in_group("units"):
		unit.queue_free()
	for building: Node in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
	await physics_frame
	await physics_frame
	for kind: String in KINDS:
		if kind != "farmer":
			await _release_case(kind)
	var bow_audit = preload("res://tests/bow_release_quality.gd").new()
	report["bow_dynamic_draw"] = await bow_audit.run(self, game, tps)
	report["combat_releases"] = release_records

func _release_case(kind: String) -> void:
	await physics_frame
	var fighter: Node3D = game.spawn_unit(kind, 0, Vector3(0, 0, 6))
	var victim: Node3D = game.spawn_unit("knight", 1, Vector3(0, 0, 4.4))
	case_units.assign([fighter, victim])
	victim.set_physics_process(false)
	victim.navigation_agent.avoidance_enabled = false
	var record: Dictionary = {"kind": kind, "release_count": 0, "render_frames": 0,
		"release_frame_seen": false, "animation_runs_outside_physics": 0}
	var attack: AnimationPlayer = fighter._attack_animation
	attack.mixer_applied.connect(func():
		if not Engine.is_in_physics_frame():
			record.animation_runs_outside_physics += 1)
	fighter.attack_windup.timeout.connect(_record_release.bind(fighter, record))
	game.select_entities([fighter])
	game.command_attack(victim)
	var deadline: int = Time.get_ticks_msec() + 3500
	while (record.release_count == 0 or victim.hp == victim.max_hp or not record.release_frame_seen) and Time.get_ticks_msec() < deadline:
		await RenderingServer.frame_post_draw
		record.render_frames += 1
		if record.release_count > 0 and not record.release_frame_seen:
			record.release_frame_seen = true
			record.first_visible_frame_tick = Engine.get_physics_frames()
			record.first_visible_render_frame = Engine.get_frames_drawn()
			record.release_to_render_usec = Time.get_ticks_usec() - record.release_usec
			record.first_visible_frame_animation_phase = attack.current_animation_position
			if kind == "archer":
				record.held_payload_hidden_at_first_render = not fighter._model.find_child("Arrow").visible
			elif kind == "catapult":
				record.held_payload_hidden_at_first_render = not fighter._model.find_child("Payload").visible
	_check(record.release_count > 0, kind + " native attack timer releases through real game commands")
	if record.release_count > 0:
		_check(record.in_physics_frame, kind + " authoritative damage/projectile release happens inside a physics tick")
		_check(record.animation_runs_outside_physics == 0, kind + " attack mixer never runs on an idle/render callback")
		_check(record.animation_phase + .00001 >= record.authored_windup and record.animation_phase <= record.authored_windup + 1.0 / float(tps) + .0001,
			kind + " release phase is within one simulation tick of the authored impact")
		_check(record.first_visible_render_frame - record.release_render_frame <= 1, kind + " next actual rendered frame includes the released strike")
		if kind in ["archer", "catapult", "cannon"]:
			_check(record.projectile_count == 1, kind + " creates exactly one projectile for the first release")
			_check(record.get("projectile_start_error_m", INF) < .0001, kind + " projectile originates at the authoritative animated socket")
		if kind in ["archer", "catapult"]:
			_check(record.held_payload_hidden_at_release and record.held_payload_hidden_at_first_render,
				kind + " held payload is hidden at the gameplay release and first rendered frame")
	_check(victim.hp < victim.max_hp, kind + " released strike causes real target damage")
	release_records.append(record)
	game.select_entities([])
	for unit: Node3D in case_units:
		unit.set_physics_process(false)
		unit.attack_windup.stop()
		unit.navigation_agent.avoidance_enabled = false
		unit.queue_free()
	case_units.clear()
	game.get_node("ProjectilePool").reset_all()
	for effect: Node in game.effect_container.get_children():
		effect.queue_free()
	await physics_frame
	await physics_frame

func _record_release(fighter: Node3D, record: Dictionary) -> void:
	record.release_count += 1
	if record.release_count != 1:
		return
	record.in_physics_frame = Engine.is_in_physics_frame()
	record.release_tick = Engine.get_physics_frames()
	record.release_render_frame = Engine.get_frames_drawn()
	record.release_usec = Time.get_ticks_usec()
	record.animation_phase = fighter._attack_animation.current_animation_position
	record.authored_windup = fighter.attack_windup.wait_time
	if fighter.unit_type == "archer":
		record.held_payload_hidden_at_release = not fighter._model.find_child("Arrow").visible
	elif fighter.unit_type == "catapult":
		record.held_payload_hidden_at_release = not fighter._model.find_child("Payload").visible
	var projectile_count: int = 0
	for effect: ProjectileFlight in game.get_node("ProjectilePool").active_flights:
		if effect._source == fighter:
			projectile_count += 1
			record.projectile_start_error_m = effect._start.distance_to(fighter.get_projectile_origin())
	record.projectile_count = projectile_count

func _finish() -> void:
	if finishing:
		return
	finishing = true
	if physics_frame.is_connected(_turn_held_archer):
		physics_frame.disconnect(_turn_held_archer)
	if is_instance_valid(game):
		await game.prepare_shutdown()
	report["checks"] = checks
	report["failures"] = failures
	var file := FileAccess.open("res://artifacts/physics_interpolation_%dtps.json" % tps, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("PHYSICS_INTERPOLATION_RESULT ", checks, " checks; ", failures.size(), " failures; ", tps, " TPS")
	quit(0 if failures.is_empty() else 2)
