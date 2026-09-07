extends Control

var box_start := Vector2.ZERO
var box_end := Vector2.ZERO
var box_visible := false
var attack_cursor := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	if box_visible:
		var rectangle := Rect2(box_start, box_end - box_start).abs()
		draw_rect(rectangle, Color(0.30, 0.65, 0.95, 0.10), true)
		draw_rect(rectangle, Color(0.66, 0.85, 1.0, 0.9), false, 1.5)
		for corner in [rectangle.position, Vector2(rectangle.end.x, rectangle.position.y), rectangle.end, Vector2(rectangle.position.x, rectangle.end.y)]:
			draw_circle(corner, 2.0, Color(0.87, 0.92, 1.0, 1.0))
	if attack_cursor:
		var at := get_local_mouse_position()
		var tint := Color(1.0, 0.42, 0.20, 0.95)
		draw_arc(at, 13.0, 0.0, TAU, 32, tint, 1.5, true)
		draw_line(at + Vector2(-19, 0), at + Vector2(-8, 0), tint, 2.0)
		draw_line(at + Vector2(8, 0), at + Vector2(19, 0), tint, 2.0)
		draw_line(at + Vector2(0, -19), at + Vector2(0, -8), tint, 2.0)
		draw_line(at + Vector2(0, 8), at + Vector2(0, 19), tint, 2.0)
