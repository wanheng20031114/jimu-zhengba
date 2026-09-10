extends SceneTree

const BOOTSTRAP: PackedScene = preload("res://server/relay_bootstrap.tscn")
var relay: Node

func _initialize() -> void:
	call_deferred("_start")

func _start() -> void:
	# Export templates start the authored main scene directly. Keep --script
	# useful for native development checks without maintaining a second startup.
	var application := BOOTSTRAP.instantiate()
	root.add_child(application)
	relay = application.get_node("RelayServer")
