extends Node
## Fixed native voice pools, shared samples, screen-focused spatial audio.
signal sound_played(kind: StringName, at: Vector3, spatial: bool)

const BANK = preload("res://scripts/sound_bank.gd")
var muted: bool = false
var _stopping: bool = false
var _playbacks: Array[WeakRef] = []
var _pools: Dictionary = {}
var _next_sound_ms: Dictionary = {}
var _last_variant: Dictionary = {}
var _listener: AudioListener3D
var _world_paused: bool = false
@onready var settings: GameSettings = get_node("/root/Session/Settings")

func _ready() -> void:
	muted = AudioServer.is_bus_mute(0)
	settings.changed.connect(_sync_preferences)
	_listener = get_parent().get_node("CameraRig/AudioListener3D")
	_listener.make_current()
	for branch: StringName in [&"UI", &"Combat", &"Foley"]:
		_pools[branch] = get_node(NodePath(branch)).get_children()

func _exit_tree() -> void:
	stop_all()

func stop_all() -> Array[WeakRef]:
	_stopping = true
	for voices: Array in _pools.values():
		for voice: Node in voices:
			voice.stop()
			# Teardown is final. Freeing the native player also releases Godot 4.6's
			# pending 3D playback when shutdown arrives before its first physics frame.
			voice.queue_free()
	_pools.clear()
	_playbacks = _playbacks.filter(func(reference: WeakRef): return reference.get_ref() != null)
	return _playbacks.duplicate()

func set_world_paused(value: bool) -> void:
	_world_paused = value
	for branch: StringName in [&"Combat", &"Foley"]:
		for voice: AudioStreamPlayer3D in _pools[branch]:
			voice.stream_paused = value

func play_ui(kind: StringName) -> void:
	_play(kind, Vector3.ZERO, false)

func play_world(kind: StringName, at: Vector3) -> void:
	_play(kind, at, true)

func _play(kind: StringName, at: Vector3, spatial: bool) -> void:
	if _stopping or (spatial and _world_paused):
		return
	var info: Dictionary = BANK.EVENTS[kind]
	# Cull before rate limiting, so off-screen footsteps cannot silence visible troops.
	if spatial:
		var max_range := 32.0 if info.bus == &"Foley" else 64.0
		if _listener.global_position.distance_squared_to(at) > max_range * max_range:
			return
	var now: int = Time.get_ticks_msec()
	if now < int(_next_sound_ms.get(kind, 0)):
		return
	var voices: Array = _pools[info.bus]
	var active := 0
	for candidate: Node in voices:
		if candidate.playing and candidate.get_meta("kind") == kind:
			active += 1
	if active >= int(info.limit):
		return
	var voice: Node = _available_voice(voices, int(info.priority))
	if voice == null:
		return
	_next_sound_ms[kind] = now + int(info.gap_ms)
	var choices: Array = info.streams
	var index: int = 0
	if choices.size() > 1:
		if _last_variant.has(kind):
			index = randi_range(0, choices.size() - 2)
			if index >= int(_last_variant[kind]):
				index += 1
		else:
			index = randi_range(0, choices.size() - 1)
	_last_variant[kind] = index
	voice.stop()
	voice.stream = choices[index]
	voice.volume_db = float(info.gain_db)
	voice.pitch_scale = randf_range(0.97, 1.03)
	voice.set_meta("kind", kind)
	voice.set_meta("priority", info.priority)
	voice.set_meta("started", now)
	if spatial:
		voice.global_position = at
		voice.stream_paused = false
	voice.play()
	_playbacks = _playbacks.filter(func(reference: WeakRef): return reference.get_ref() != null)
	_playbacks.append(weakref(voice.get_stream_playback()))
	sound_played.emit(kind, at, spatial)

func _available_voice(voices: Array, priority: int) -> Node:
	var replace: Node
	var oldest := 2147483647
	for voice: Node in voices:
		if not voice.playing:
			return voice
		if int(voice.get_meta("priority")) < priority and int(voice.get_meta("started")) < oldest:
			replace = voice
			oldest = int(voice.get_meta("started"))
	# Native stop fades replaced low-priority voices; equal-priority tails finish.
	return replace

func volume_percent() -> float:
	return db_to_linear(AudioServer.get_bus_volume_db(0)) * 100.0

func set_volume_percent(value: float) -> void:
	settings.set_volume_percent(value)
	if value > 0.0 and muted:
		toggle_mute()

func toggle_mute() -> bool:
	settings.set_muted(not settings.muted)
	return muted

func _sync_preferences() -> void:
	muted = settings.muted
