extends Node
## Persistent native transport and the small configuration crossing scene changes.
signal load_failed(message: String)
var config: Dictionary = {}
var online: bool = false
@onready var relay: RelayClient = $RelayClient
@onready var settings: GameSettings = $Settings

func _ready() -> void:
	record_diagnostic("startup", {"engine": Engine.get_version_info().string, "display": DisplayServer.get_name(),
		"renderer": RenderingServer.get_current_rendering_method(), "audio": AudioServer.get_driver_name(),
		"shader_uniform_slots": ProjectSettings.get_setting("rendering/limits/global_shader_variables/buffer_size"),
		"gpu": RenderingServer.get_video_adapter_name() if DisplayServer.get_name() != "headless" else "headless"})
	if "--network-smoke" in OS.get_cmdline_user_args():
		get_tree().change_scene_to_file.call_deferred("res://scripts/network/release_probe.tscn")
	elif "--match-smoke" in OS.get_cmdline_user_args():
		add_child.call_deferred(preload("res://scripts/qa/release_match_probe.tscn").instantiate())

func start_offline(mode: String, bot_difficulty: String = "normal") -> Error:
	if mode not in NetworkProtocol.MODES:
		load_failed.emit("所选对局模式无效，请重新选择")
		return ERR_INVALID_PARAMETER
	if bot_difficulty not in NetworkProtocol.BOT_DIFFICULTIES:
		load_failed.emit("所选电脑难度无效，请重新选择")
		return ERR_INVALID_PARAMETER
	record_diagnostic("load_match", {"online": false, "mode": mode})
	online = false
	config = offline_config(mode, bot_difficulty)
	return _load_match_scene()

static func offline_config(mode: String, bot_difficulty: String = "normal") -> Dictionary:
	var match_data: Dictionary = {"mode": mode, "players": []}
	for owner: int in int(NetworkProtocol.MODES[mode].slots):
		match_data.players.append({"owner_id": owner, "team_id": NetworkProtocol.default_alliance(mode, owner),
			"controller": "human" if owner == 0 else "bot", "name": "指挥官" if owner == 0 else "王国将领 %d" % owner,
			"bot_difficulty": "normal" if owner == 0 else bot_difficulty})
	return match_data

func start_online(match_data: Dictionary) -> Error:
	if not NetworkProtocol.match_config_error(match_data).is_empty():
		relay.leave_room()
		online = false
		config.clear()
		load_failed.emit("对局席位配置无效，请重新创建或加入房间")
		return ERR_INVALID_DATA
	record_diagnostic("load_match", {"online": true, "mode": match_data.mode})
	online = true
	config = match_data.duplicate(true)
	return _load_match_scene()

func _load_match_scene() -> Error:
	var error := get_tree().change_scene_to_file("res://scenes/main.tscn")
	if error != OK:
		if online:
			relay.leave_room()
		online = false
		config.clear()
		load_failed.emit("无法载入积木争霸战场，请检查游戏文件后重试")
	return error

func back_to_lobby() -> void:
	record_diagnostic("return_to_lobby")
	get_tree().paused = false
	relay.leave_room()
	online = false
	config.clear()
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")

func record_diagnostic(event: String, details: Dictionary = {}) -> void:
	# Only bounded lifecycle/health facts reach this local log. Never dump the
	# room config, endpoint, invitation or reconnect credentials.
	print("JIMU_DIAGNOSTIC ", JSON.stringify({"event": event, "build": NetworkProtocol.BUILD_ID, "release": NetworkProtocol.RELEASE_ID,
		"pid": OS.get_process_id(), "seconds": snappedf(Time.get_ticks_msec() / 1000.0, 0.001), "details": details}))

func _record_health() -> void:
	var scene: Node = get_tree().current_scene
	if not is_instance_valid(scene):
		return
	var details := {"scene": scene.scene_file_path, "paused": get_tree().paused,
		"fps": Engine.get_frames_per_second(), "nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"video_memory_bytes": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))}
	if scene.scene_file_path == "res://scenes/main.tscn" and scene._match_ready:
		details.merge({"online": scene.online, "authority": scene.is_authority, "tick": scene.simulation_tick,
			"finished": scene.finished, "closing": scene._closing, "units": scene.unit_container.get_child_count(),
			"effects": scene.effect_container.get_child_count()})
	record_diagnostic("health", details)

func _exit_tree() -> void:
	record_diagnostic("session_exit")
