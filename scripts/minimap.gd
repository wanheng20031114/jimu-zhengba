extends Control

# A circle's geometry is identical for every soldier and every map refresh.
# Share its native GPU mesh instead of tessellating/uploading each draw_circle.
# Keep the same 64-sided, two-pixel disc and the original entity draw order.
static var _unit_dot_mesh: ArrayMesh = _create_unit_dot_mesh()

static func _create_unit_dot_mesh() -> ArrayMesh:
	var points := PackedVector2Array()
	for index: int in 64:
		points.append(Vector2.from_angle(index * TAU / 64.0) * 2.0)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_INDEX] = Geometry2D.triangulate_polygon(points)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

signal map_clicked(world: Vector3, command: bool)
var game: Node3D
var _elapsed: float = 0
@onready var terrain: TextureRect = $Terrain

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= 0.15:
		_elapsed = 0
		queue_redraw()

func _map(point: Vector3) -> Vector2:
	return (Vector2(point.x, point.z) / game.map_size + Vector2.ONE * 0.5) * size

func _world(point: Vector2) -> Vector3:
	var at: Vector2 = (point / size - Vector2.ONE * 0.5) * game.map_size
	return game.clamp_to_map(Vector3(at.x, 0, at.y))

func _draw() -> void:
	if not is_instance_valid(game) or not game._fog_ready:
		draw_rect(Rect2(Vector2.ZERO, size), Color("24251d"))
		return
	var fog: FogOfWar = game.get_node("FogOfWar")
	var visibility: Texture2D = fog.visibility_texture()
	if terrain.texture != visibility:
		terrain.texture = visibility
	var local_owner: int = game.local_owner_id
	var local_player: PlayerState = game.get_player(local_owner)
	var local_alliance: int = local_player.alliance_id
	var map_size: Vector2 = game.map_size
	var map_scale: Vector2 = size / map_size
	var map_center: Vector2 = size * 0.5
	var self_color: Color = FactionPalette.ui_color(FactionPalette.SELF)
	var ally_color: Color = FactionPalette.ui_color(FactionPalette.ALLY)
	var enemy_color: Color = FactionPalette.ui_color(FactionPalette.ENEMY)
	if local_player.is_participating():
		for mine: ResourceVein in get_tree().get_nodes_in_group("resource_veins"):
			var world_position: Vector3 = mine.position
			if fog.explored(local_owner, world_position):
				var at: Vector2 = Vector2(world_position.x, world_position.z) * map_scale + map_center
				draw_colored_polygon(PackedVector2Array([at + Vector2(0,-3), at + Vector2(3,0), at + Vector2(0,3), at + Vector2(-3,0)]), Color("efc75b"))
		# Keep scene-group order so overlapping dots, squares and selection rings
		# retain their existing layering. Typed branches avoid per-marker dynamic
		# entity/owner lookups; fog and the observer's palette are resolved once.
		for entity: Node in get_tree().get_nodes_in_group("entities"):
			var world_position: Vector3
			var entity_owner: int
			var alliance: int
			var selected: bool
			var is_building: bool = false
			if entity is BattleUnit:
				var unit: BattleUnit = entity
				if not unit.alive:
					continue
				world_position = unit.global_position
				alliance = unit.alliance_id
				if alliance != local_alliance and not fog.position_visible_to_alliance(local_alliance, world_position):
					continue
				entity_owner = unit.owner_id
				selected = unit.selected
			elif entity is BattleBuilding:
				var building: BattleBuilding = entity
				if not building.alive:
					continue
				alliance = building.alliance_id
				if alliance != local_alliance and not fog.building_visible_to_alliance(local_alliance, building):
					continue
				world_position = building.global_position
				entity_owner = building.owner_id
				selected = building.selected
				is_building = true
			else:
				continue
			var tint: Color = self_color if entity_owner == local_owner else (ally_color if alliance == local_alliance else enemy_color)
			var at: Vector2 = Vector2(world_position.x, world_position.z) * map_scale + map_center
			if is_building:
				draw_rect(Rect2(at - Vector2(3, 3), Vector2(6, 6)), tint)
			else:
				draw_mesh(_unit_dot_mesh, null, Transform2D(0.0, at), tint)
			if selected:
				draw_arc(at, 4.5, 0, TAU, 12, Color("fff1bc"), 1)
	var view := get_viewport().get_visible_rect().size
	var corners := PackedVector2Array()
	var camera: Node3D = game.camera_rig
	for point in [Vector2.ZERO, Vector2(view.x, 0), Vector2(view.x, view.y - 172), Vector2(0, view.y - 172)]:
		var world_position: Vector3 = camera.world_at(point)
		corners.append(Vector2(world_position.x, world_position.z) * map_scale + map_center)
	corners.append(corners[0])
	draw_polyline(corners, Color(1, 0.94, 0.73, 0.85), 1.2, true)
	draw_rect(Rect2(Vector2.ZERO, size), Color("b29559"), false, 1)

func _gui_input(event: InputEvent) -> void:
	if not is_instance_valid(game):
		return
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		map_clicked.emit(_world(event.position), event.button_index == MOUSE_BUTTON_RIGHT)
		accept_event()
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		map_clicked.emit(_world(event.position), false)
		accept_event()
