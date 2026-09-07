extends Control

signal map_clicked(world: Vector3, command: bool)
var game: Node3D
var obstacles: Array = []
var pulse: float = 0.0

func _ready() -> void:
	game = get_tree().current_scene
	if FileAccess.file_exists("res://assets/environment_obstacles.json"):
		var contents = JSON.parse_string(FileAccess.get_file_as_string("res://assets/environment_obstacles.json"))
		obstacles = contents.obstacles

func _process(delta: float) -> void:
	pulse += delta
	queue_redraw()

func _map(point: Vector3) -> Vector2:
	return Vector2((point.x + 42.0) / 84.0, (point.z + 42.0) / 84.0) * size

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("665839"))
	for i in range(9):
		var step := float(i) / 8.0
		draw_line(Vector2(step * size.x, 0), Vector2(step * size.x, size.y), Color(0.85, 0.78, 0.58, 0.07))
		draw_line(Vector2(0, step * size.y), Vector2(size.x, step * size.y), Color(0.85, 0.78, 0.58, 0.07))
	draw_line(_map(Vector3(-25, 0, 36)), _map(Vector3(23, 0, -34)), Color("9b8556"), 13.0, true)
	draw_line(_map(Vector3(-31, 0, -6)), _map(Vector3(33, 0, 7)), Color("8d7a51"), 5.0, true)
	for obstacle in obstacles:
		var p: Array = obstacle.position
		var s: Array = obstacle.size
		var pos := _map(Vector3(p[0], 0, p[2]))
		var ext := Vector2(s[0], s[2]) / 84.0 * size
		draw_rect(Rect2(pos - ext * 0.5, ext), Color("bba675"))
	if not is_instance_valid(game):
		return
	for entity in get_tree().get_nodes_in_group("entities"):
		if not entity.alive:
			continue
		var tint := Color("70b8ef") if entity.team == 0 else Color("e76446")
		var at := _map(entity.global_position)
		if entity.is_in_group("buildings"):
			draw_rect(Rect2(at - Vector2(4, 4), Vector2(8, 8)), tint)
		else:
			draw_circle(at, 2.2, tint)
		if entity.selected:
			draw_arc(at, 4.5, 0.0, TAU, 12, Color("fff1bc"), 1.0)
	var view := get_viewport().get_visible_rect().size
	var corners := PackedVector2Array()
	for point in [Vector2.ZERO, Vector2(view.x, 0), Vector2(view.x, view.y - 172), Vector2(0, view.y - 172)]:
		corners.append(_map(game.camera_rig.world_at(point)))
	corners.append(corners[0])
	draw_polyline(corners, Color(1.0, 0.94, 0.73, 0.85), 1.2, true)
	draw_rect(Rect2(Vector2.ZERO, size), Color("b29559"), false, 1.0)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			var normalized: Vector2 = event.position / size
			map_clicked.emit(Vector3(normalized.x * 84.0 - 42.0, 0.0, normalized.y * 84.0 - 42.0), event.button_index == MOUSE_BUTTON_RIGHT)
			accept_event()
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var normalized: Vector2 = event.position / size
		map_clicked.emit(Vector3(normalized.x * 84.0 - 42.0, 0.0, normalized.y * 84.0 - 42.0), false)
		accept_event()
