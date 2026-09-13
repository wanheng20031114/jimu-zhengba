extends Control
const MINIMAP = preload("res://scripts/minimap.gd")
var reference := true

func _draw() -> void:
	draw_rect(Rect2(0, 0, 320, 180), Color("24251d"))
	for index: int in 180:
		var at := Vector2(9 + (index % 20) * 15, 9 + (index / 20) * 17) + Vector2((index % 7) / 7.0, (index % 11) / 11.0)
		var color := FactionPalette.ui_color(index % 3)
		if reference:
			draw_circle(at, 2.0, color)
		else:
			draw_mesh(MINIMAP._unit_dot_mesh, null, Transform2D(0.0, at), color)
		if index % 3 == 0:
			draw_arc(at, 4.5, 0, TAU, 12, Color("fff1bc"), 1)
		# Retain painter order when later buildings overlap earlier soldiers.
		if index % 5 == 0:
			draw_rect(Rect2(at + Vector2(1, -2), Vector2(6, 6)), FactionPalette.ui_color((index + 1) % 3))
