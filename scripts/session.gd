extends Node
## Persistent native transport and the small configuration crossing scene changes.
var config: Dictionary = {}
var online: bool = false
@onready var relay: RelayClient = $RelayClient
@onready var settings: GameSettings = $Settings

func _ready() -> void:
	record_diagnostic("startup", {"engine": Engine.get_version_info().string, "display": DisplayServer.get_name(),
		"renderer": RenderingServer.get_current_rendering_method(), "audio": AudioServer.get_driver_name(),
		"gpu": RenderingServer.get_video_adapter_name() if DisplayServer.get_name() != "headless" else "headless"})
	if "--network-smoke" in OS.get_cmdline_user_args():
		get_tree().change_scene_to_file.call_deferred("res://scripts/network/release_probe.tscn")
	elif "--match-smoke" in OS.get_cmdline_user_args():
		add_child.call_deferred(preload("res://scripts/qa/release_match_probe.tscn").instantiate())

func start_offline(mode: String) -> void:
	record_diagnostic("load_match", {"online": false, "mode": mode})
	online = false
	config = {"mode": mode, "players": []}
	for owner in range(4 if mode == "2v2" else 2):
		config.players.append({"owner_id": owner, "team_id": owner / 2 if mode == "2v2" else owner,
			"controller": "human" if owner == 0 else "bot", "name": "指挥官" if owner == 0 else "王国将领 %d" % owner})
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func start_online(match_data: Dictionary) -> void:
	record_diagnostic("load_match", {"online": true, "mode": match_data.mode})
	online = true
	config = match_data.duplicate(true)
	get_tree().change_scene_to_file("res://scenes/main.tscn")

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
	print("ASHEN_DIAGNOSTIC ", JSON.stringify({"event": event, "build": NetworkProtocol.BUILD_ID,
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
