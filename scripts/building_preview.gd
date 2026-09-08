extends Node3D
## One saved model preview; mesh/material references are cached once.
@onready var tint: StandardMaterial3D = $Footprint.material_override

func _ready() -> void:
	for mesh: MeshInstance3D in $Model.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = tint
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func set_valid(valid: bool) -> void:
	tint.albedo_color = Color(0.35, 0.85, 0.69, 0.4) if valid else Color(0.93, 0.31, 0.22, 0.4)
