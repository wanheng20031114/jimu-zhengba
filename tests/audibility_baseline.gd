extends Node3D
## Run only in the fixture prepared by prepare_audibility_baseline.py.
## No music, no product scripts, no system-volume mutations.

var capture := AudioEffectCapture.new()
var results: Array[Dictionary] = []
var peak := 0.0
var energy := 0.0
var active_energy := 0.0
var frames := 0
var active_frames := 0
var recording := false
@onready var ground_listener: AudioListener3D = $GroundListener

func _ready() -> void:
	if AudioServer.get_driver_name() != "Dummy":
		push_error("Run this isolated capture with --headless --audio-driver Dummy.")
		get_tree().quit(2)
		return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_position(Vector2i(-20000, -20000))
	# A lone AudioListener3D reselects itself when clear_current() scans for
	# another listener. Keep the fixture node outside the tree for camera cases.
	remove_child(ground_listener)
	capture.buffer_length = 4.0
	AudioServer.add_bus_effect(0, capture)
	var state := {"audio_driver": AudioServer.get_driver_name(), "output_device": AudioServer.output_device, "output_devices": AudioServer.get_output_device_list(), "master_mute": AudioServer.is_bus_mute(0), "master_db": AudioServer.get_bus_volume_db(0), "bus_count": AudioServer.bus_count, "mix_rate": AudioServer.get_mix_rate(), "camera_distance": $Camera3D.global_position.distance_to($WorldSound.global_position), "source_commit": "03aa6fc", "note": "PCM WAV loaded directly; original imports had normalize=false. No BGM played."}
	state["active_rms_definition"] = "Nonzero sample frames above 1e-7 amplitude; distinct from soundbank 20-ms block activity RMS."
	print("BASELINE_STATE ", JSON.stringify(state))
	await get_tree().create_timer(0.3).timeout
	for sample in ["select", "order", "coin"]:
		await measure("old_ui_" + sample, sample, false)
	await measure("old_camera_sword", "sword_hit", true)
	$WorldSound.volume_db = -7.0
	await measure("old_camera_cannon", "cannon", true)
	$WorldSound.volume_db = -9.0
	$WorldSound.attenuation_filter_cutoff_hz = 20500.0
	await measure("old_camera_sword_no_filter", "sword_hit", true)
	$WorldSound.attenuation_filter_cutoff_hz = 5000.0
	add_child(ground_listener)
	ground_listener.make_current()
	await measure("listener_y6_sword_old_settings", "sword_hit", true)
	$WorldSound.volume_db = -7.0
	await measure("listener_y6_cannon_old_settings", "cannon", true)
	$WorldSound.volume_db = -9.0
	$WorldSound.unit_size = 12.0
	$WorldSound.max_db = 0.0
	$WorldSound.max_distance = 70.0
	$WorldSound.attenuation_filter_cutoff_hz = 12000.0
	await measure("listener_y6_sword_unit12", "sword_hit", true)
	$WorldSound.position.x = 18.0
	await measure("listener_y6_sword_unit12_offset18", "sword_hit", true)
	state["cases"] = results
	state["discarded_frames"] = capture.get_discarded_frames()
	var file := FileAccess.open("res://capture_report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(state, "\t"))
	file.close()
	AudioServer.remove_bus_effect(0, 0)
	print("AUDIBILITY_BASELINE_COMPLETE")
	get_tree().quit(0)

func measure(label: String, sample: String, world: bool) -> void:
	$UI.stop()
	$WorldSound.stop()
	await get_tree().create_timer(0.18).timeout
	capture.clear_buffer()
	peak = 0.0
	energy = 0.0
	active_energy = 0.0
	frames = 0
	active_frames = 0
	var stream := AudioStreamWAV.load_from_file("res://old_audio/" + sample + ".wav")
	var duration := stream.get_length()
	recording = true
	if world:
		$WorldSound.stream = stream
		$WorldSound.play()
	else:
		$UI.stream = stream
		$UI.play()
	await get_tree().create_timer(duration + 0.25).timeout
	consume()
	recording = false
	var result := {"case": label, "peak_dbfs": db(peak), "rms_dbfs": db(sqrt(energy / maxf(frames * 2.0, 1.0))), "active_rms_dbfs": db(sqrt(active_energy / maxf(active_frames * 2.0, 1.0))), "frames": frames, "active_frames": active_frames, "duration": duration}
	if world:
		result["volume_db"] = $WorldSound.volume_db
		result["unit_size"] = $WorldSound.unit_size
		result["max_distance"] = $WorldSound.max_distance
		result["filter_cutoff_hz"] = $WorldSound.attenuation_filter_cutoff_hz
		result["filter_db"] = $WorldSound.attenuation_filter_db
		result["distance"] = (ground_listener.global_position if ground_listener.is_inside_tree() else $Camera3D.global_position).distance_to($WorldSound.global_position)
	results.append(result)
	print("BASELINE_CASE ", JSON.stringify(result))

func _process(_delta: float) -> void:
	if recording:
		consume()

func consume() -> void:
	var count := capture.get_frames_available()
	if count == 0:
		return
	for frame in capture.get_buffer(count):
		peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
		var power: float = frame.length_squared()
		energy += power
		frames += 1
		if maxf(absf(frame.x), absf(frame.y)) > 0.0000001:
			active_energy += power
			active_frames += 1

func db(value: float) -> float:
	return snappedf(linear_to_db(maxf(value, 0.0000000001)), 0.01)
