extends SceneTree
## Render-only experiment. No gameplay/model resources are changed by this fixture.
## -- --mode=idle|barrier|baseline --tps=30|60|10 --render-fps=120|60|30
## IDLE uses a pre-sampled authored release socket for its simulated shot; it never
## reads the render-clock bone to decide a gameplay origin. Barrier uses one rig.
const PALM := Vector3(.02, -.24, -.075)
const CONTACT_START: float = .135
const HOLD_END: float = .26
const RELEASE: float = .27
var mode: String = "idle"
var tps: int = 30
var render_fps: int = 120
var mover: Node3D
var archer: Node3D
var attack: AnimationPlayer
var hand: Node3D
var string: Node3D
var arrow: Node3D
var timer: Timer
var reference: Node3D
var reference_attack: AnimationPlayer
var reference_hand: Node3D
var reference_string: Node3D
var release_local := Vector3.ZERO
var state: Dictionary = {}
var samples: Array[Dictionary] = []
var cycles: Array[Dictionary] = []
var failures: Array[String] = []
var checks: int = 0
var finishing: bool = false

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--mode="):
			mode = argument.trim_prefix("--mode=")
		elif argument.begins_with("--tps="):
			tps = argument.trim_prefix("--tps=").to_int()
		elif argument.begins_with("--render-fps="):
			render_fps = argument.trim_prefix("--render-fps=").to_int()
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _run() -> void:
	_check(mode in ["idle", "barrier", "baseline"] and tps in [10, 30, 60] and render_fps in [30, 60, 120], "valid diagnostic clock configuration")
	_check(DisplayServer.get_name() != "headless", "native displayed-transform probe uses an actual renderer")
	if not failures.is_empty():
		_finish()
		return
	create_timer(15.0, true, false, true).timeout.connect(func():
		_check(false, "probe finishes within its render deadline")
		_finish())
	Engine.physics_ticks_per_second = tps
	Engine.max_fps = render_fps
	physics_interpolation = true
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(Vector2i(960, 540))
	var gallery: Node3D = load("res://tests/model_display_clock_probe.tscn").instantiate()
	gallery.set_script(null)
	root.add_child(gallery)
	current_scene = gallery
	mover = gallery.get_node("Units")
	mover.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	archer = mover.get_node("Archer")
	for model: Node3D in mover.get_children():
		model.visible = model == archer
		model.get_node("Locomotion").seek(0.0, true)
		model.get_node("Locomotion").pause()
		model.get_node("Attack").pause()
	archer.position = Vector3.ZERO
	archer.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF if mode == "idle" else Node.PHYSICS_INTERPOLATION_MODE_INHERIT
	attack = archer.get_node("Attack")
	attack.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE if mode == "idle" else AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	hand = archer.find_child("ForearmRight")
	string = archer.find_child("StringUpper")
	arrow = archer.find_child("Arrow")
	timer = gallery.get_node("AttackWindup")
	timer.timeout.connect(_release)
	var camera: Camera3D = gallery.get_node("Camera3D")
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.global_position = Vector3(4, 4.2, -6)
	camera.look_at(Vector3(.5, 1.1, .3))
	camera.size = 6.2
	reference = load("res://assets/models/units/archer.tscn").instantiate()
	reference.name = "AuthoredClockReference"
	reference.visible = false
	reference.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	gallery.add_child(reference)
	reference.get_node("Locomotion").seek(0.0, true)
	reference.get_node("Locomotion").pause()
	reference_attack = reference.get_node("Attack")
	reference_attack.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	reference_attack.play("strike")
	reference_attack.seek(RELEASE + .000001, true)
	release_local = reference.to_local(reference.get_projectile_origin())
	reference_hand = reference.find_child("ForearmRight")
	reference_string = reference.find_child("StringUpper")
	hand.get_global_transform_interpolated()
	string.get_global_transform_interpolated()
	mover.get_global_transform_interpolated()
	mover.reset_physics_interpolation()
	physics_frame.connect(_move_parent)
	for cycle: int in range(4):
		await _cycle(cycle)
	physics_frame.disconnect(_move_parent)
	root.get_texture().get_image().save_png("res://artifacts/model_clock_%s_%dtps_%dfps.png" % [mode, tps, render_fps])
	_finish()

func _move_parent() -> void:
	# Authoritative parent really translates AND turns every fixed tick.
	mover.position += Vector3(.35, 0, .20) / float(tps)
	mover.rotate_y(.5 / float(tps))

func _cycle(cycle: int) -> void:
	await physics_frame
	attack.stop()
	attack.play("strike")
	attack.advance(0.0)
	attack.pause()
	archer.reset_physics_interpolation()
	for warmup: int in range(3):
		await physics_frame
	state = {"cycle": cycle, "previous_phase": 0.0, "current_phase": 0.0,
		"last_tick": -1, "last_phase": -1.0, "same_tick_pairs": 0, "smooth_parent_pairs": 0,
		"idle_animation_pairs": 0, "max_inheritance_error_m": 0.0, "max_inheritance_rotation_rad": 0.0,
		"max_parent_render_offset_m": 0.0, "release_count": 0, "mixer_physics_calls": 0,
		"mixer_idle_calls": 0, "first_post_release_frame": -1, "first_hidden_frame": -1,
		"start_tick": 0, "pre_release_pose_exceeded_barrier": false}
	attack.mixer_applied.connect(_capture_mixer)
	await physics_frame
	state.start_tick = Engine.get_physics_frames()
	if mode == "barrier":
		attack.stop()
		attack.play_section("strike", 0.0, HOLD_END)
	else:
		archer.strike()
	timer.start(RELEASE)
	var deadline: int = Time.get_ticks_msec() + 1500
	while (state.release_count == 0 or attack.current_animation_position < .48) and Time.get_ticks_msec() < deadline:
		await RenderingServer.frame_post_draw
		_sample()
	attack.mixer_applied.disconnect(_capture_mixer)
	_check(state.release_count == 1 and state.release_in_physics, "cycle %d: exactly one fixed-clock shot" % cycle)
	# Started from SceneTree.physics_frame, before this tick's Timer notification;
	# the start tick itself is the first elapsed Timer callback.
	_check(state.release_tick - state.start_tick + 1 == ceili(RELEASE * tps), "cycle %d: Timer release uses the expected fixed callback count" % cycle)
	_check(state.first_post_release_frame >= 0, "cycle %d: first displayed frame after release captured" % cycle)
	if mode == "idle":
		_check(state.mixer_idle_calls > 0 and state.idle_animation_pairs > 0 if render_fps > tps else state.mixer_idle_calls > 0,
			"cycle %d: native IDLE animation advances at display cadence" % cycle)
		_check(state.max_inheritance_error_m < .0001 and state.max_inheritance_rotation_rad < .006,
			"cycle %d: OFF child inherits native interpolated moving/turning ON parent" % cycle)
		_check(state.release_socket_error_m < .0001, "cycle %d: fixed-clock shot uses authored offset, never a display bone" % cycle)
	elif mode == "barrier":
		_check(not state.pre_release_pose_exceeded_barrier, "cycle %d: native section never exposes release pose before physics shot" % cycle)
		_check(state.release_socket_error_m < .0001, "cycle %d: one-rig release socket matches original authored release pose" % cycle)
		_check(not state.held_arrow_visible_at_release, "cycle %d: original discrete arrow visibility updates in the release tick" % cycle)
	if render_fps > tps:
		_check(state.smooth_parent_pairs > 0, "cycle %d: moving parent's display advances between fixed ticks" % cycle)
	state.erase("last_parent_display")
	cycles.append(state.duplicate(true))

func _capture_mixer() -> void:
	state.previous_phase = state.current_phase
	state.current_phase = attack.current_animation_position
	if Engine.is_in_physics_frame():
		state.mixer_physics_calls += 1
	else:
		state.mixer_idle_calls += 1
	if state.release_count == 0 and attack.current_animation_position > HOLD_END + .00001:
		state.pre_release_pose_exceeded_barrier = true

func _release() -> void:
	state.release_count += 1
	state.release_in_physics = Engine.is_in_physics_frame()
	state.release_tick = Engine.get_physics_frames()
	state.release_render_frame = Engine.get_frames_drawn()
	state.phase_before_release = attack.current_animation_position
	var authored_world: Vector3 = archer.global_transform * release_local
	var shot_origin: Vector3
	if mode == "idle":
		# This is a proposed authoritative socket contract, not real BattleUnit damage.
		shot_origin = authored_world
		state.render_bone_error_at_release_m = archer.get_projectile_origin().distance_to(authored_world)
	else:
		if mode == "barrier":
			attack.play_section("strike", HOLD_END, -1.0)
			attack.seek(RELEASE + .000001, true)
		else:
			var missing_pose: float = RELEASE - attack.current_animation_position
			if missing_pose > 0.0:
				attack.advance(missing_pose + .000001)
		shot_origin = archer.get_projectile_origin()
	state.release_socket_error_m = shot_origin.distance_to(authored_world)
	state.phase_after_release = attack.current_animation_position
	state.held_arrow_visible_at_release = arrow.visible
	state.shot_origin = [shot_origin.x, shot_origin.y, shot_origin.z]

func _sample() -> void:
	var tick: int = Engine.get_physics_frames()
	var phase: float = attack.current_animation_position
	var parent_display: Transform3D = mover.get_global_transform_interpolated()
	var actual_hand: Transform3D = hand.get_global_transform_interpolated()
	var expected_hand: Transform3D = parent_display * mover.global_transform.affine_inverse() * hand.global_transform
	var inherited_error: float = (actual_hand * PALM).distance_to(expected_hand * PALM)
	var rotation_error: float = actual_hand.basis.orthonormalized().get_rotation_quaternion().angle_to(expected_hand.basis.orthonormalized().get_rotation_quaternion())
	state.max_inheritance_error_m = maxf(state.max_inheritance_error_m, inherited_error)
	state.max_inheritance_rotation_rad = maxf(state.max_inheritance_rotation_rad, rotation_error)
	state.max_parent_render_offset_m = maxf(state.max_parent_render_offset_m, parent_display.origin.distance_to(mover.global_position))
	if state.last_tick == tick:
		state.same_tick_pairs += 1
		if parent_display.origin.distance_to(state.last_parent_display) > .000001:
			state.smooth_parent_pairs += 1
		if phase > state.last_phase + .000001:
			state.idle_animation_pairs += 1
	state.last_tick = tick
	state.last_phase = phase
	state.last_parent_display = parent_display.origin
	if not arrow.visible and state.first_hidden_frame < 0:
		state.first_hidden_frame = Engine.get_frames_drawn()
		state.first_hidden_tick = tick
		state.first_hidden_phase = phase
	if state.release_count > 0 and state.first_post_release_frame < 0:
		state.first_post_release_frame = Engine.get_frames_drawn()
		state.first_post_release_phase = phase
		state.first_post_release_arrow_hidden = not arrow.visible
		state.release_to_visible_frame_count = Engine.get_frames_drawn() - state.release_render_frame
	var alpha: float = Engine.get_physics_interpolation_fraction()
	var display_phase: float = phase if mode == "idle" else lerpf(state.previous_phase, state.current_phase, alpha)
	reference_attack.seek(display_phase, true)
	var authored_contact: float = (reference_hand.global_transform * PALM).distance_to(reference_string.global_position)
	var displayed_contact: float = (actual_hand * PALM).distance_to(string.get_global_transform_interpolated().origin)
	samples.append({"cycle": state.cycle, "render_frame": Engine.get_frames_drawn(), "physics_tick": tick,
		"display_phase_sec": display_phase, "animation_phase_sec": phase, "interpolation_fraction": alpha,
		"after_physics_release": state.release_count > 0, "held_arrow_visible": arrow.visible,
		"displayed_contact_m": displayed_contact, "authored_at_display_phase_contact_m": authored_contact,
		"added_error_m": maxf(0, displayed_contact - authored_contact),
		"inheritance_error_m": inherited_error, "inheritance_rotation_rad": rotation_error})

func _statistics(field: String, contact: Array[Dictionary]) -> Dictionary:
	var values: Array[float] = []
	for sample: Dictionary in contact:
		values.append(sample[field])
	values.sort()
	return {"max": values[-1], "p95": values[ceili(values.size() * .95) - 1]} if not values.is_empty() else {"max": null, "p95": null}

func _finish() -> void:
	if finishing:
		return
	finishing = true
	if physics_frame.is_connected(_move_parent):
		physics_frame.disconnect(_move_parent)
	var contact: Array[Dictionary] = []
	for sample: Dictionary in samples:
		# Physics release is a hard presentation boundary for the section candidate.
		# Released frames are retained in samples; they are not still bow-hold frames.
		if sample.display_phase_sec >= CONTACT_START and sample.display_phase_sec < HOLD_END and not sample.after_physics_release:
			contact.append(sample)
	var displayed: Dictionary = _statistics("displayed_contact_m", contact)
	var authored: Dictionary = _statistics("authored_at_display_phase_contact_m", contact)
	var added: Dictionary = _statistics("added_error_m", contact)
	_check(contact.size() >= 8, "multiple native draws supply at least eight actual pre-release contact frames")
	if mode != "baseline" and not contact.is_empty():
		_check(displayed.p95 <= .025 and displayed.max <= .05, "actual pre-release contact meets 2.5 cm P95 / 5 cm peak budget")
		_check(added.p95 <= .01 and added.max <= .025, "extra interpolation error meets 1 cm P95 / 2.5 cm peak budget")
	var report: Dictionary = {"engine": Engine.get_version_info(), "mode": mode, "tps": tps,
		"render_fps_limit": render_fps, "checks": checks, "failures": failures, "cycles": cycles,
		"contact_window_sec": [CONTACT_START, HOLD_END], "pre_release_contact_samples": contact.size(),
		"displayed_contact_m": displayed, "authored_contact_m": authored, "added_error_m": added,
		"samples": samples, "interpretation": "Fixture-only experiment, not a gameplay regression. IDLE shot origin is the pre-sampled authored local release socket transformed by the authoritative parent; damage/release still comes solely from the physics Timer. Barrier retains PHYSICS animations and the same rig, capped at hold .26 until physical release. Released-frame contact is separately retained and is not scored as a pre-release hold."}
	var file := FileAccess.open("res://artifacts/model_clock_%s_%dtps_%dfps.json" % [mode, tps, render_fps], FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("MODEL_DISPLAY_CLOCK_RESULT ", mode, " ", tps, " TPS / ", render_fps, " FPS; ", checks, " checks; ", failures.size(), " failures; contact ", displayed, "; added ", added)
	quit(0 if failures.is_empty() else 2)
