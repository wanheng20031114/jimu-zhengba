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
	var mouse := get_viewport().get_mouse_position()
	var viewport_size := get_viewport().get_visible_rect().size
	if edge_scroll and not dragging and DisplayServer.window_is_focused():
		if mouse.x >= 0.0 and mouse.x < 9.0:
			direction.x -= 1.0
		if mouse.x <= viewport_size.x and mouse.x > viewport_size.x - 9.0:
			direction.x += 1.0
		if mouse.y >= 0.0 and mouse.y < 9.0:
			direction.z -= 1.0
		if mouse.y <= viewport_size.y and mouse.y > viewport_size.y - 9.0:
			direction.z += 1.0
	if direction.length_squared() > 0.0:
		destination += direction.normalized() * pan_speed * (zoom_target / 37.0) * delta
	clamp_destination()
	position = position.lerp(destination, 1.0 - exp(-12.0 * delta))
	camera.size = lerpf(camera.size, zoom_target, 1.0 - exp(-13.0 * delta))

func clamp_destination() -> void:
	destination.x = clampf(destination.x, -35.0, 35.0)
	destination.z = clampf(destination.z, -34.0, 35.0)
	destination.y = 0.0

func focus_at(world: Vector3, instant: bool = false) -> void:
	destination = Vector3(world.x, 0.0, world.z)
	clamp_destination()
	if instant:
		position = destination

func zoom_by(amount: float) -> void:
	zoom_target = clampf(zoom_target + amount, minimum_zoom, maximum_zoom)

func drag_by(relative: Vector2) -> void:
	var world_per_pixel := camera.size / get_viewport().get_visible_rect().size.y
	destination -= Vector3(relative.x * world_per_pixel, 0.0, relative.y * world_per_pixel / 0.819)
	clamp_destination()

func world_at(screen: Vector2) -> Vector3:
	var ground := Plane(Vector3.UP, 0.0)
	var point = ground.intersects_ray(camera.project_ray_origin(screen), camera.project_ray_normal(screen))
	if point == null:
		return Vector3.ZERO
	return Vector3(clampf(point.x, -40.0, 40.0), 0.0, clampf(point.z, -40.0, 40.0))
