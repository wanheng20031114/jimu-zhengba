extends Node

const UI_SOUNDS := {
	"select": preload("res://assets/audio/select.wav"),
	"order": preload("res://assets/audio/order.wav"),
	"coin": preload("res://assets/audio/coin.wav")
}
var muted: bool = false
var _last_sound: float = -1.0
var _stopping: bool = false
var _playbacks: Array[WeakRef] = []

func _ready() -> void:
	muted = AudioServer.is_bus_mute(0)
	for player: AudioStreamPlayer in [$Wind, $Music]:
		var sound: AudioStreamWAV = player.stream
		sound.loop_mode = AudioStreamWAV.LOOP_FORWARD
		sound.loop_end = int(sound.get_length() * sound.mix_rate)
		player.stream = sound
		player.play()
		_playbacks.append(weakref(player.get_stream_playback()))

func _exit_tree() -> void:
	stop_all()

func stop_all() -> Array[WeakRef]:
	_stopping = true
	$Wind.stop()
	$Music.stop()
	$UI.stop()
	_playbacks = _playbacks.filter(func(reference: WeakRef): return reference.get_ref() != null)
	return _playbacks.duplicate()

func play_ui(kind: String) -> void:
	if _stopping:
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_sound < 0.07:
		return
	_last_sound = now
	$UI.stream = UI_SOUNDS[kind]
	$UI.play()
	# Keep weak handles for every polyphonic voice without extending its lifetime.
	_playbacks = _playbacks.filter(func(reference: WeakRef): return reference.get_ref() != null)
	_playbacks.append(weakref($UI.get_stream_playback()))

func toggle_mute() -> bool:
	muted = not muted
	AudioServer.set_bus_mute(0, muted)
	return muted
