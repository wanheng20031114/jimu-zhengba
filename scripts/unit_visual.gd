extends Node3D
## Saved rigid-part sculptures driven by native AnimationPlayers.
@export_enum("swordsman", "archer", "knight", "catapult", "cannon") var kind: String = "swordsman"

@onready var locomotion: AnimationPlayer = $Locomotion
@onready var attack: AnimationPlayer = $Attack
var _moving: bool = false
var _team: int = 0
var _team_surfaces: Array[MeshInstance3D] = []

func _ready() -> void:
	for mesh_node: Node in $Rig.find_children("*", "MeshInstance3D", true, false):
		_team_surfaces.append(mesh_node as MeshInstance3D)
	set_team(_team)
	locomotion.seek(randf() * 2.6, true)

func set_motion(moving: bool) -> void:
	if _moving == moving:
		return
	_moving = moving
	locomotion.play("walk" if moving else "idle", 0.16)

func strike() -> void:
	attack.stop()
	attack.play("strike")

func die() -> void:
	locomotion.pause()
	attack.pause()

func set_team(team: int) -> void:
	_team = team
	var tint := Color("aa4934") if team == 1 else Color("2e648b")
	for mesh: MeshInstance3D in _team_surfaces:
		mesh.set_instance_shader_parameter("team_color", tint)
