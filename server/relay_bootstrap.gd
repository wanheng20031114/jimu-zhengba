extends Node
## Both the packaged main scene and the editor-only --script entry use this
## single startup path. Room validation and transport remain in RelayServer.

const PROTOCOL = preload("res://scripts/network/network_protocol.gd")
@onready var relay: Node = $RelayServer

func _ready() -> void:
	Engine.max_fps = 60
	_start.call_deferred()

func _start() -> void:
	var settings := ConfigFile.new()
	var config_path := OS.get_environment("JIMU_RELAY_CONFIG")
	if config_path.is_empty(): config_path = "user://relay.cfg"
	if settings.load(config_path) != OK:
		push_error("RELAY_CONFIG_UNAVAILABLE")
		get_tree().quit(1)
		return
	relay.max_rooms = clampi(int(settings.get_value("relay", "max_rooms", 8)), 1, relay.MAX_ROOMS)
	relay.max_humans = clampi(int(settings.get_value("relay", "max_humans", PROTOCOL.MAX_PLAYERS)), 1, PROTOCOL.MAX_PLAYERS)
	var result: Error = relay.start(str(settings.get_value("relay", "bind", "*")), int(settings.get_value("relay", "port", 24571)), str(settings.get_value("tls", "private_key", "")), str(settings.get_value("tls", "certificate", "")))
	if result != OK:
		push_error("RELAY_START_FAILED code=%d" % result)
		get_tree().quit(1)
		return
	print("JIMU_RELAY_RUNTIME version=%s editor=%s debug=%s dedicated_server=%s" % [Engine.get_version_info().string, OS.has_feature("editor"), OS.is_debug_build(), OS.has_feature("dedicated_server")])
	print("JIMU_RELAY_READY protocol=%d rooms=%d humans=%d" % [PROTOCOL.VERSION, relay.max_rooms, relay.max_humans])
