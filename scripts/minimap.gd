extends Control

signal map_clicked(world: Vector3, command: bool)
var game: Node3D
var _elapsed: float = 0

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
	draw_rect(Rect2(Vector2.ZERO, size), Color("24251d"))
	if not is_instance_valid(game) or not game._fog_ready:
		return
	var fog: FogOfWar = game.get_node("FogOfWar")
	var cell_pixels := size / Vector2(fog.grid_size)
	for z in range(fog.grid_size.y):
		for x in range(fog.grid_size.x):
			var world := Vector3((x + 0.5) * 2 - game.map_size.x * 0.5, 0, (z + 0.5) * 2 - game.map_size.y * 0.5)
			var state := fog.cell_state(game.local_owner_id, world)
			if state > 0:
				draw_rect(Rect2(Vector2(x, z) * cell_pixels, cell_pixels + Vector2.ONE * 0.25), Color("907746") if state == 2 else Color("4b4630"))
	for mine: ResourceVein in get_tree().get_nodes_in_group("resource_veins"):
		if fog.explored(game.local_owner_id, mine.position):
			var at := _map(mine.position)
			draw_colored_polygon(PackedVector2Array([at + Vector2(0,-3), at + Vector2(3,0), at + Vector2(0,3), at + Vector2(-3,0)]), Color("efc75b"))
	for memory: Dictionary in fog.last_seen_buildings(game.local_owner_id).values():
		var position_data: Array = memory.position
		var at := _map(Vector3(position_data[0], 0, position_data[2]))
		draw_rect(Rect2(at - Vector2(3, 3), Vector2(6, 6)), Color("785242"))
	for entity: Node3D in get_tree().get_nodes_in_group("entities"):
		if not entity.alive or not game.can_see_entity(game.local_owner_id, entity):
			continue
		var tint := FactionPalette.ui_color(FactionPalette.relation(entity.owner_id, entity.alliance_id, game))
		var at := _map(entity.global_position)
		if entity is BattleBuilding:
			draw_rect(Rect2(at - Vector2(3, 3), Vector2(6, 6)), tint)
		else:
			draw_circle(at, 2, tint)
		if entity.selected:
			draw_arc(at, 4.5, 0, TAU, 12, Color("fff1bc"), 1)
	var view := get_viewport().get_visible_rect().size
	var corners := PackedVector2Array()
	for point in [Vector2.ZERO, Vector2(view.x, 0), Vector2(view.x, view.y - 172), Vector2(0, view.y - 172)]:
		corners.append(_map(game.camera_rig.world_at(point)))
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
