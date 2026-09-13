extends Node
## Cached isolated native render targets. Only the active portrait advances at 15 Hz.
const KINDS: Array[String] = ["swordsman", "shield_guard", "spearman", "archer", "knight", "war_elephant", "light_cavalry", "catapult", "cannon", "heavy_cannon", "triple_cannon", "engineer", "priest", "farmer", "headquarters", "gold_vein", "defense_tower", "barracks", "factory", "academy"]
const FRAME_TIME := 1.0 / 15.0

var _viewports: Dictionary[String, SubViewport] = {}
var _idle_players: Dictionary[String, AnimationPlayer] = {}
var _models: Dictionary[String, Node3D] = {}
var _animated_kind: String = ""
@onready var _tick: Timer = $PreviewTick

func _ready() -> void:
	for kind: String in KINDS:
		var viewport: SubViewport = get_node(kind)
		var model: Node3D = viewport.get_node("World/Model")
		_viewports[kind] = viewport
		_models[kind] = model
		model.process_mode = Node.PROCESS_MODE_DISABLED
		var camera: Camera3D = viewport.get_node("World/Camera3D")
		camera.look_at(viewport.get_node("World/LookAt").global_position, Vector3.UP)
		if kind in ["swordsman", "shield_guard", "spearman", "archer", "knight", "war_elephant", "light_cavalry", "catapult", "cannon", "heavy_cannon", "triple_cannon", "engineer", "priest", "farmer"]:
			model.set_team(0)
			var idle: AnimationPlayer = model.get_node("Locomotion")
			var attack: AnimationPlayer = model.get_node("Attack")
			idle.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
			attack.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
			attack.stop()
			idle.play("idle")
			idle.seek(0.4, true)
			_idle_players[kind] = idle
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func portrait(kind: String) -> Texture2D:
	return _viewports[kind].get_texture()

func set_animated(kind: String) -> void:
	assert(kind.is_empty() or kind in KINDS, "Unknown portrait: " + kind)
	if _animated_kind == kind:
		return
	# Keep any pending UPDATE_ONCE from set_team(): production buttons share the
	# old portrait texture. One-shot rendering stops itself after that repaint.
	_animated_kind = kind
	if kind.is_empty():
		_tick.stop()
		return
	_tick.start()
	_advance_portrait()

func set_team(team: int) -> void:
	for kind: String in KINDS:
		if kind in ["swordsman", "shield_guard", "spearman", "archer", "knight", "war_elephant", "light_cavalry", "catapult", "cannon", "heavy_cannon", "triple_cannon", "engineer", "priest", "farmer"]:
			_models[kind].set_team(team)
		elif kind != "gold_vein":
			FactionPalette.apply_model(_models[kind], team)
		_viewports[kind].render_target_update_mode = SubViewport.UPDATE_ONCE

func _advance_portrait() -> void:
	if _animated_kind.is_empty():
		return
	if _idle_players.has(_animated_kind):
		_idle_players[_animated_kind].advance(FRAME_TIME)
	# Shader-driven cloth advances visually only when this target is rendered.
	_viewports[_animated_kind].render_target_update_mode = SubViewport.UPDATE_ONCE
