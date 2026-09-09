extends Node3D
## One saved model preview; mesh/material references are cached once.
@onready var tint: StandardMaterial3D = $Footprint.material_override

func _ready() -> void:
	for mesh: MeshInstance3D in $Model.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = tint
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func set_valid(valid: bool) -> void:
	tint.albedo_color = Color(0.35, 0.85, 0.69, 0.4) if valid else Color(0.93, 0.31, 0.22, 0.4)

func configure(kind: String, size: Vector3) -> void:
	var previous := $Model
	remove_child(previous)
	previous.queue_free()
	var scene: PackedScene = preload("res://assets/models/environment/defense_tower.tscn") if kind == "defense_tower" else BattleBuilding.MODELS[BalanceCatalog.building(kind).model]
	var model: Node3D = scene.instantiate()
	model.name = "Model"
	add_child(model)
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = tint
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	$Footprint.scale = Vector3((size.x + 0.4) / 4.4, 1, (size.z + 0.4) / 4.4)
