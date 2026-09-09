extends Node3D

@export var pan_speed: float = 25.0
@export var minimum_zoom: float = 16.0
@export var maximum_zoom: float = 62.0
@onready var camera: Camera3D = $Camera3D
var destination: Vector3
var zoom_target: float = 37.0
var dragging: bool = false
var edge_scroll: bool = true

func _ready() -> void:
	destination = position
	zoom_target = camera.size

func _process(delta: float) -> void:
	if get_tree().paused:
		return
	var direction := Vector3.ZERO
	direction.x = float(Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_LEFT))
	direction.z = float(Input.is_physical_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_UP))
	if edge_scroll and not dragging and DisplayServer.window_is_focused():
		# Native window pixels include letterbox margins; viewport coordinates do not.
		var local_mouse := Vector2(DisplayServer.mouse_get_position() - DisplayServer.window_get_position())
		var window_size := Vector2(DisplayServer.window_get_size())
		var edge := edge_direction(local_mouse, window_size)
		direction += Vector3(edge.x, 0.0, edge.y)
	if direction.length_squared() > 0.0:
		var right := camera.global_basis.x
		var down := Vector3(camera.global_basis.z.x, 0.0, camera.global_basis.z.z).normalized()
		destination += (right * direction.x + down * direction.z).normalized() * pan_speed * (zoom_target / 37.0) * delta
	clamp_destination()
	position = position.lerp(destination, 1.0 - exp(-12.0 * delta))
	camera.size = lerpf(camera.size, zoom_target, 1.0 - exp(-13.0 * delta))

func clamp_destination() -> void:
	destination = get_parent().clamp_to_map(destination)

func edge_direction(mouse: Vector2, window_size: Vector2) -> Vector2:
	if mouse.x < 0.0 or mouse.y < 0.0 or mouse.x > window_size.x or mouse.y > window_size.y:
		return Vector2.ZERO
	var edge_width := clampf(window_size.y / 75.0, 10.0, 20.0)
	return Vector2(float(mouse.x >= window_size.x - edge_width) - float(mouse.x <= edge_width), float(mouse.y >= window_size.y - edge_width) - float(mouse.y <= edge_width))

func focus_at(world: Vector3, instant: bool = false) -> void:
	destination = Vector3(world.x, 0.0, world.z)
	clamp_destination()
	if instant:
		position = destination

func zoom_by(amount: float) -> void:
	zoom_target = clampf(zoom_target + amount, minimum_zoom, maximum_zoom)

func drag_by(relative: Vector2) -> void:
	var world_per_pixel := camera.size / get_viewport().get_visible_rect().size.y
	var right := camera.global_basis.x
	var down := Vector3(camera.global_basis.z.x, 0.0, camera.global_basis.z.z).normalized()
	var vertical_factor := absf(sin(camera.rotation.x))
	destination -= (right * relative.x + down * relative.y / vertical_factor) * world_per_pixel
	clamp_destination()

func world_at(screen: Vector2) -> Vector3:
	var ground := Plane(Vector3.UP, 0.0)
	var point = ground.intersects_ray(camera.project_ray_origin(screen), camera.project_ray_normal(screen))
	if point == null:
		return Vector3.ZERO
	return get_parent().clamp_to_map(point)
