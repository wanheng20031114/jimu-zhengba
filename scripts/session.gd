extends Node
## Persistent native transport and the small configuration crossing scene changes.
var config: Dictionary = {}
var online: bool = false
@onready var relay: RelayClient = $RelayClient

func _ready() -> void:
	if "--network-smoke" in OS.get_cmdline_user_args():
		get_tree().change_scene_to_file.call_deferred("res://scripts/network/release_probe.tscn")
	elif "--match-smoke" in OS.get_cmdline_user_args():
		add_child.call_deferred(preload("res://scripts/qa/release_match_probe.tscn").instantiate())

func start_offline(mode: String) -> void:
	online = false
	config = {"mode": mode, "players": []}
	for owner in range(4 if mode == "2v2" else 2):
		config.players.append({"owner_id": owner, "team_id": owner / 2 if mode == "2v2" else owner,
			"controller": "human" if owner == 0 else "bot", "name": "指挥官" if owner == 0 else "王国将领 %d" % owner})
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func start_online(match_data: Dictionary) -> void:
	online = true
	config = match_data.duplicate(true)
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func back_to_lobby() -> void:
	get_tree().paused = false
	relay.leave_room()
	online = false
	config.clear()
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")
