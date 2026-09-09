extends SceneTree

const SERVER_SCENE: PackedScene = preload("res://server/relay.tscn")
const PROTOCOL = preload("res://scripts/network/network_protocol.gd")
var relay: Node

func _initialize() -> void:
	call_deferred("_start")

func _start() -> void:
	Engine.max_fps = 60
	relay = SERVER_SCENE.instantiate()
	root.add_child(relay)
	var settings := ConfigFile.new()
	var config_path := OS.get_environment("ASHEN_RELAY_CONFIG")
	if config_path.is_empty(): config_path = "user://relay.cfg"
	if settings.load(config_path) != OK:
		push_error("RELAY_CONFIG_UNAVAILABLE")
		quit(1)
		return
	relay.max_rooms = clampi(int(settings.get_value("relay", "max_rooms", 1)), 1, 16)
	relay.max_humans = clampi(int(settings.get_value("relay", "max_humans", 4)), 1, 4)
	var result: Error = relay.start(str(settings.get_value("relay", "bind", "*")), int(settings.get_value("relay", "port", 24571)), str(settings.get_value("tls", "private_key", "")), str(settings.get_value("tls", "certificate", "")))
	if result != OK:
		push_error("RELAY_START_FAILED code=%d" % result)
		quit(1)
		return
	print("ASHEN_RELAY_READY protocol=%d rooms=%d humans=%d" % [PROTOCOL.VERSION, relay.max_rooms, relay.max_humans])

func _finalize() -> void:
	if is_instance_valid(relay):
		relay.stop()
