extends SceneTree
## Same-frame positional play/pause regression, including real Master capture.
var game: Node3D
var audio: Node
var capture := AudioEffectCapture.new()
var capture_slot: int
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _peak() -> float:
	var peak := 0.0
	for frame: Vector2 in capture.get_buffer(capture.get_frames_available()):
		peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
	return peak

func _clear_ui() -> void:
	for voice: AudioStreamPlayer in audio.get_node("UI").get_children():
		voice.stop()

func _run() -> void:
	create_timer(15.0).timeout.connect(func(): push_error("AUDIO_PAUSE_BOUNDARY deadline"); quit(3))
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	game.tests_running = true
	game.camera_rig.edge_scroll = false
	audio = game.get_node("Audio")
	for unit: Node in get_nodes_in_group("units"):
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
		unit.attack_windup.stop()
	for building: Node in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	await create_timer(0.2).timeout
	capture.buffer_length = 2.0
	capture_slot = AudioServer.get_bus_effect_count(0)
	AudioServer.add_bus_effect(0, capture)
	_check(audio.get_node("Combat").process_mode == Node.PROCESS_MODE_PAUSABLE and audio.get_node("Foley").process_mode == Node.PROCESS_MODE_PAUSABLE, "world voice branches use native pausable processing")
	var at: Vector3 = game.camera_rig.global_position
	# Do not yield between queueing these 3D streams and pausing the game.
	audio.play_world(&"cannon_shot", at)
	audio.play_world(&"cart_wheel", at)
	game.toggle_pause()
	_clear_ui()
	_check(not audio.get_node("Combat/Voice00").can_process() and not audio.get_node("Foley/Voice00").can_process(), "pause blocks pending 3D playback physics immediately")
	await create_timer(0.15).timeout
	capture.clear_buffer()
	await create_timer(0.25).timeout
	_check(_peak() < 0.00001, "same-frame queued combat and foley remain silent while paused")
	audio.play_ui(&"coin")
	await create_timer(0.15).timeout
	_check(_peak() > 0.005, "UI still produces audible output while world requests are held")
	_clear_ui()
	await create_timer(0.15).timeout
	capture.clear_buffer()
	game.toggle_pause()
	_clear_ui()
	await create_timer(0.3).timeout
	_check(_peak() > 0.005, "resume starts the held positional sounds")
	_check(audio.get_node("Combat/Voice00").get_playback_position() > 0.05, "resumed combat playback advances normally")
	_check(audio.get_node("Foley/Voice00").get_playback_position() > 0.05, "resumed foley playback advances normally")
	# First-event sampling must include index zero; following picks avoid repeats.
	seed(92841)
	var observed: Dictionary = {}
	for iteration in range(48):
		_clear_ui()
		audio._last_variant.erase(&"coin")
		audio._next_sound_ms.erase(&"coin")
		audio.play_ui(&"coin")
		observed[audio._last_variant[&"coin"]] = true
	_check(observed.size() == 3 and observed.has(0), "first-event sampling can choose every variant including index zero")
	var repeated := false
	var previous: int = audio._last_variant[&"coin"]
	for iteration in range(48):
		_clear_ui()
		audio._next_sound_ms.erase(&"coin")
		audio.play_ui(&"coin")
		var next: int = audio._last_variant[&"coin"]
		repeated = repeated or next == previous
		previous = next
	_check(not repeated, "successive samples never repeat the previous variant")
	# Teardown while a fresh world request is paused before its first physics tick.
	audio._next_sound_ms.erase(&"stone_hit")
	audio.play_world(&"stone_hit", at)
	game.toggle_pause()
	var references: Array[WeakRef] = audio._playbacks.duplicate()
	await game.prepare_shutdown()
	_check(references.all(func(reference: WeakRef): return reference.get_ref() == null), "paused pending requests release completely during shutdown")
	paused = false
	AudioServer.remove_bus_effect(0, capture_slot)
	print("AUDIO_PAUSE_BOUNDARY ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
