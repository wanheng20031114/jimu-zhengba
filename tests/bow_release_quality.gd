extends RefCounted
## Real BattleUnit presentation audit shared by physics_interpolation_visual_test.
## Classification follows actual Timer/projectile events, not interpolated clip time.
const PALM := Vector3(.02, -.24, -.075)
var test
var game: Node3D
var rate: int
var reference: Node3D
var reference_attack: AnimationPlayer
var reference_hand: Node3D
var reference_string: Node3D
var samples: Array[Dictionary] = []
var cases: Array[Dictionary] = []

func run(owner_test, battle: Node3D, tps: int) -> Dictionary:
	test = owner_test
	game = battle
	rate = tps
	game.camera_rig.focus_at(Vector3(0, 0, 5), true)
	game.camera_rig.set_process(false)
	var camera: Camera3D = game.camera_rig.camera
	camera.global_position = Vector3(6, 5, 5)
	camera.look_at(Vector3(0, 1.1, 3.5))
	camera.size = 7.8
	game.get_node("HUD").hide()
	reference = load("res://assets/models/units/archer.tscn").instantiate()
	reference.visible = false
	reference.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	game.add_child(reference)
	reference.get_node("Locomotion").pause()
	reference_attack = reference.get_node("Attack")
	reference_attack.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	reference_attack.play("strike")
	reference_hand = reference.find_child("ForearmRight")
	reference_string = reference.find_child("StringUpper")
	for mode: String in ["normal", "repeat", "turning", "normal_again", "stop", "hold", "move", "target_disappears"]:
		await _case(mode)
	reference.queue_free()
	await test.process_frame
	var contact_samples: Array[Dictionary] = []
	var segments: Dictionary = {}
	for segment: String in ["reach", "draw", "hold", "released", "cancelled"]:
		var matching: Array[Dictionary] = []
		for sample: Dictionary in samples:
			if sample.segment == segment:
				matching.append(sample)
				if segment in ["draw", "hold"]:
					contact_samples.append(sample)
		segments[segment] = test._bow_contact_statistics(matching)
	var contact: Dictionary = test._bow_contact_statistics(contact_samples)
	test._check(contact_samples.size() >= 16, "real BattleUnit bows provide at least 16 pre-release contact frames")
	var thresholds: Dictionary = {"displayed_contact_p95_m": .025, "displayed_contact_max_m": .05,
		"added_interpolation_p95_m": .01, "added_interpolation_max_m": .025}
	var within_contact: bool = not contact_samples.is_empty() and contact.displayed_contact_m.p95 <= thresholds.displayed_contact_p95_m and contact.displayed_contact_m.max <= thresholds.displayed_contact_max_m
	var within_added: bool = not contact_samples.is_empty() and contact.excess_over_authored_m.p95 <= thresholds.added_interpolation_p95_m and contact.excess_over_authored_m.max <= thresholds.added_interpolation_max_m
	# The same visual budgets apply at all rates, including the diagnostic 10 TPS run.
	test._check(within_contact, "real pre-release bow contact meets 2.5 cm P95 / 5 cm peak")
	test._check(within_added, "real pre-release added interpolation error meets 1 cm P95 / 2.5 cm peak")
	print("BOW_REAL_CONTACT ", rate, " TPS; displayed ", contact.displayed_contact_m, "; extra ", contact.excess_over_authored_m)
	return {"cycles": cases, "samples": samples, "segments": segments, "contact_window_sec": [.135, .26],
		"contact_window": contact, "visual_review_thresholds": thresholds, "within_contact_budget": within_contact,
		"within_added_interpolation_budget": within_added,
		"interpretation": "Real Game.command_attack and BattleUnit.AttackWindup/Projectile creation define release. Authored grasp starts .135, not .075. Frames after a real release remain reported under released even when delayed interpolated clip time is below .26; a hand is no longer expected to hold the string after the shot. All pre-release budgets are asserted, not merely logged."}

func _case(mode: String) -> void:
	await test.physics_frame
	var fighter: Node3D = game.spawn_unit("archer", 0, Vector3(0, 0, 6))
	var victim: Node3D = game.spawn_unit("knight", 1, Vector3(0, 0, 1))
	victim.set_physics_process(false)
	victim.navigation_agent.avoidance_enabled = false
	var attack: AnimationPlayer = fighter._attack_animation
	var hand: Node3D = fighter._model.find_child("ForearmRight")
	var string: Node3D = fighter._model.find_child("StringUpper")
	var arrow: Node3D = fighter._model.find_child("Arrow")
	hand.get_global_transform_interpolated()
	string.get_global_transform_interpolated()
	var state: Dictionary = {"mode": mode, "previous_phase": 0.0, "current_phase": 0.0, "pose_tick": -1,
		"physics_samples": 0, "outside_physics": 0, "timer_releases": 0, "projectiles_created": 0,
		"projectile": null, "first_projectile_frame": -1, "cancelled": false, "repeat_commands": 0,
		"repeat_resets": 0, "pre_release_arrow_hidden_frames": 0, "held_arrow_hidden_without_projectile_frames": 0}
	var capture_pose := func():
		var tick: int = Engine.get_physics_frames()
		# Timer.advance may apply twice in a single fixed tick. Native interpolation
		# retains the preceding TICK pose, not the preceding mixer callback pose.
		if tick != state.pose_tick:
			state.previous_phase = state.current_phase
			state.pose_tick = tick
		state.current_phase = attack.current_animation_position
		state.physics_samples += 1
		if not Engine.is_in_physics_frame():
			state.outside_physics += 1
	var capture_projectile := func(effect: BattleProjectile):
		# This observes the actual initialized pooled visual, including socket pose.
		state.projectiles_created += 1
		state.projectile = effect
		state.projectile_creation_tick = Engine.get_physics_frames()
		state.projectile_creation_in_physics = Engine.is_in_physics_frame()
	var capture_release := func():
		state.timer_releases += 1
		state.release_in_physics = Engine.is_in_physics_frame()
		state.release_tick = Engine.get_physics_frames()
		state.release_render_frame = Engine.get_frames_drawn()
		state.release_animation_phase = attack.current_animation_position
		state.held_arrow_hidden_at_release = not arrow.visible
		if is_instance_valid(state.projectile):
			state.projectile_source_matches = state.projectile._source == fighter
			state.projectile_socket_error_m = state.projectile._start.distance_to(fighter.get_projectile_origin())
	attack.mixer_applied.connect(capture_pose)
	game.get_node("ProjectilePool").projectile_launched.connect(capture_projectile)
	fighter.attack_windup.timeout.connect(capture_release)
	var move_target := func():
		victim.position.x += 2.0 / float(rate)
	if mode == "turning":
		test.physics_frame.connect(move_target)
	game.select_entities([fighter])
	game.command_attack(victim)
	var started: int = Time.get_ticks_msec()
	var cancel_case: bool = mode in ["stop", "hold", "move", "target_disappears"]
	while Time.get_ticks_msec() - started < (1100 if cancel_case else 700):
		await RenderingServer.frame_post_draw
		var alpha: float = Engine.get_physics_interpolation_fraction()
		var display_phase: float = lerpf(state.previous_phase, state.current_phase, alpha)
		var released: bool = state.projectiles_created > 0
		if released and state.first_projectile_frame < 0:
			state.first_projectile_frame = Engine.get_frames_drawn()
			state.first_projectile_tick = Engine.get_physics_frames()
			state.first_projectile_held_arrow_hidden = not arrow.visible
			state.first_projectile_visible_in_tree = state.projectile.is_visible_in_tree()
			state.first_projectile_display_position = str(state.projectile.get_global_transform_interpolated().origin)
			state.first_projectile_frame_delay = Engine.get_frames_drawn() - state.release_render_frame
			if mode == "normal":
				test.root.get_texture().get_image().save_png("res://artifacts/real_bow_release_%dtps.png" % rate)
		var segment: String = "cancelled" if state.cancelled else ("released" if released else ("reach" if display_phase < .135 else ("draw" if display_phase < .205 else "hold")))
		if not released and not state.cancelled and not arrow.visible:
			state.pre_release_arrow_hidden_frames += 1
		if not released and not arrow.visible:
			state.held_arrow_hidden_without_projectile_frames += 1
		if display_phase <= .40 and state.physics_samples > 0:
			reference_attack.seek(display_phase, true)
			var displayed_contact: float = (hand.get_global_transform_interpolated() * PALM).distance_to(string.get_global_transform_interpolated().origin)
			var reference_contact: float = (reference_hand.global_transform * PALM).distance_to(reference_string.global_position)
			samples.append({"mode": mode, "render_frame": Engine.get_frames_drawn(), "physics_tick": Engine.get_physics_frames(),
				"interpolation_fraction": alpha, "display_phase_sec": display_phase, "authoritative_phase_sec": state.current_phase,
				"segment": segment, "actual_timer_released": state.timer_releases > 0, "actual_projectile_created": released,
				"displayed_contact_m": displayed_contact, "authoritative_contact_m": (hand.global_transform * PALM).distance_to(string.global_position),
				"authored_at_display_phase_contact_m": reference_contact, "excess_over_authored_m": maxf(0, displayed_contact - reference_contact),
				"held_arrow_visible": arrow.visible})
		if mode == "repeat":
			var before: float = fighter.attack_windup.time_left
			var phase_before: float = state.current_phase
			game.command_attack(victim)
			state.repeat_commands += 1
			if not is_equal_approx(before, fighter.attack_windup.time_left) or not is_equal_approx(phase_before, state.current_phase):
				state.repeat_resets += 1
		if cancel_case and not state.cancelled and state.current_phase >= .10:
			state.cancelled = true
			state.cancel_phase = state.current_phase
			match mode:
				"stop": game.stop_selected()
				"hold": game.hold_selected()
				"move": game.command_move(Vector3(8, 0, 9))
				"target_disappears": victim.queue_free()
		elif not cancel_case and state.first_projectile_frame >= 0 and victim.hp < victim.max_hp and state.current_phase >= .45:
			break
	attack.mixer_applied.disconnect(capture_pose)
	game.get_node("ProjectilePool").projectile_launched.disconnect(capture_projectile)
	fighter.attack_windup.timeout.disconnect(capture_release)
	if mode == "turning":
		test.physics_frame.disconnect(move_target)
	test._check(state.outside_physics == 0, "real bow " + mode + " retains only physics animation callbacks")
	if cancel_case:
		test._check(state.cancelled and state.projectiles_created == 0 and fighter.attack_windup.is_stopped(), "real bow " + mode + " does not create a stale projectile")
		test._check(arrow.visible, "real bow " + mode + " restores held arrow after interrupted action recovery")
		if mode != "target_disappears":
			test._check(victim.hp == victim.max_hp, "real bow " + mode + " does not apply cancelled damage")
		else:
			test._check(fighter.target == null and fighter.order == BattleUnit.Order.IDLE,
				"real bow freed target clears the stale reference and returns to idle")
			# A crashed physics callback can also produce no projectile; require the
			# same surviving unit to accept a new command and damage a live target.
			var replacement: Node3D = game.spawn_unit("knight", 1, Vector3(0, 0, 1))
			replacement.set_physics_process(false)
			replacement.navigation_agent.avoidance_enabled = false
			game.command_attack(replacement)
			var recovery_deadline: int = Time.get_ticks_msec() + 2500
			while replacement.hp == replacement.max_hp and Time.get_ticks_msec() < recovery_deadline:
				await RenderingServer.frame_post_draw
			test._check(replacement.hp < replacement.max_hp and fighter.target == replacement,
				"real bow survives target removal, accepts a new order and deals new damage")
			replacement.queue_free()
	else:
		test._check(state.timer_releases == 1 and state.projectiles_created == 1 and state.release_in_physics and state.projectile_creation_in_physics,
			"real bow " + mode + " creates one projectile from the authoritative physics release")
		test._check(state.get("projectile_source_matches", false) and state.get("projectile_socket_error_m", INF) < .0001,
			"real bow " + mode + " projectile begins at the authoritative animated socket")
		test._check(state.pre_release_arrow_hidden_frames == 0, "real bow " + mode + " never hides the held arrow before creating its projectile")
		test._check(state.get("held_arrow_hidden_at_release", false) and state.get("first_projectile_held_arrow_hidden", false),
			"real bow " + mode + " first projectile frame contains no duplicate held arrow")
		test._check(state.get("first_projectile_visible_in_tree", false) and state.get("first_projectile_frame_delay", 100) <= 1,
			"real bow " + mode + " projectile appears in the next actual rendered frame")
		test._check(victim.hp < victim.max_hp, "real bow " + mode + " projectile deals real target damage")
		if mode == "repeat":
			test._check(state.repeat_commands >= 5 and state.repeat_resets == 0, "real bow repeated display-frame commands never reset the windup or pose")
	state.erase("projectile")
	cases.append(state)
	game.select_entities([])
	fighter.set_physics_process(false)
	fighter.navigation_agent.avoidance_enabled = false
	fighter.attack_windup.stop()
	fighter.queue_free()
	if is_instance_valid(victim):
		victim.queue_free()
	game.get_node("ProjectilePool").reset_all()
	for effect: Node in game.effect_container.get_children():
		effect.queue_free()
	await test.physics_frame
	await test.physics_frame
