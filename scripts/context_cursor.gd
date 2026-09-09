extends Node
## Native OS cursor: no UI or world nodes are created while pointing.
const TEXTURES := {
	"attack": preload("res://assets/ui/cursors/attack.svg"),
	"gather": preload("res://assets/ui/cursors/gather.svg"),
	"build": preload("res://assets/ui/cursors/build.svg"),
	"rally_gather": preload("res://assets/ui/cursors/rally_gather.svg"),
	"move": preload("res://assets/ui/cursors/move.svg"),
	"rally": preload("res://assets/ui/cursors/rally.svg"),
	"forbidden": preload("res://assets/ui/cursors/forbidden.svg")}
@onready var game: Node3D = get_parent()
var cursor_kind := "normal"
var _elapsed := 0.0

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.066:
		return
	_elapsed = 0.0
	var kind := "normal"
	if not game.finished and not get_tree().paused and not game._local_menu and not game.settings.is_open():
		var viewport := get_viewport()
		var mouse := viewport.get_mouse_position()
		if viewport.get_visible_rect().has_point(mouse) and viewport.gui_get_hovered_control() == null:
			kind = context_kind(game.entity_at(mouse), game.camera_rig.world_at(mouse))
	set_cursor(kind)

func context_kind(target: Node3D, at: Vector3) -> String:
	var units: Array = game.own_selected_units()
	var has_workers := false
	for unit: BattleUnit in units:
		if unit.unit_type == "farmer":
			has_workers = true
			break
	var has_producer := false
	var has_farmer_producer := false
	for building: BattleBuilding in game.own_selected_buildings():
		var products: PackedStringArray = BalanceCatalog.building(building.building_type).produces
		if not products.is_empty():
			has_producer = true
		if "farmer" in products:
			has_farmer_producer = true
	if units.is_empty() and not has_producer:
		return "normal"
	if game.build_mode:
		return "build" if game.placement_error(game.snap_build_position(at)).is_empty() else "forbidden"
	if game.attack_mode:
		return "attack"
	if is_instance_valid(target) and target.alive and game.can_see_entity(game.local_owner_id, target):
		if target.is_in_group("resource_veins"):
			# Immediate worker orders take precedence in a mixed selection. Only
			# a farmer-producing building makes its future recruits start mining.
			if has_workers:
				return "gather"
			if has_farmer_producer:
				return "rally_gather"
			return "rally" if has_producer else "forbidden"
		if target.alliance_id != game.get_player(game.local_owner_id).alliance_id:
			return "attack" if not units.is_empty() else "rally"
		if target is BattleBuilding:
			if target.owner_id == game.local_owner_id and not target.is_constructed:
				return "build" if has_workers else "forbidden"
	# The Game dispatches movement to units and rally updates to buildings.
	# Prefer the selected units' immediate action when both are selected.
	return "move" if not units.is_empty() else "rally"

func set_cursor(kind: String) -> void:
	if cursor_kind == kind:
		return
	cursor_kind = kind
	if DisplayServer.get_name() != "headless":
		Input.set_custom_mouse_cursor(null if kind == "normal" else TEXTURES[kind], Input.CURSOR_ARROW, Vector2.ZERO if kind == "normal" else Vector2(3, 3))

func _exit_tree() -> void:
	if DisplayServer.get_name() != "headless":
		Input.set_custom_mouse_cursor(null)
