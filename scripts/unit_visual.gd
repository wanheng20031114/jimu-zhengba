extends Node3D
## Saved rigid-part sculptures driven by native AnimationPlayers.
@export_enum("swordsman", "archer", "knight", "catapult", "cannon", "farmer") var kind: String = "swordsman"
@export var projectile_socket: NodePath

@onready var locomotion: AnimationPlayer = $Locomotion
@onready var attack: AnimationPlayer = $Attack
var _moving: bool = false
var _working: bool = false
var _work_mode: String = "gather"
var _team: int = 0
var _team_surfaces: Array[MeshInstance3D] = []

func _ready() -> void:
	for mesh_node: Node in $Rig.find_children("*", "MeshInstance3D", true, false):
		_team_surfaces.append(mesh_node as MeshInstance3D)
	set_team(_team)
	locomotion.seek(randf() * 2.6, true)

func set_motion(moving: bool) -> void:
	if moving and _working:
		set_working(false)
	if _moving == moving:
		return
	_moving = moving
	if _working:
		return
	locomotion.play("walk" if moving else "idle", 0.16)

func set_working(active: bool, mode: String = "gather") -> void:
	if kind != "farmer":
		return
	if _working == active and (not active or _work_mode == mode):
		return
	_working = active
	_work_mode = mode
	if active:
		locomotion.pause()
		attack.play(mode, 0.12)
	else:
		attack.stop()
		locomotion.play("walk" if _moving else "idle", 0.12)

func strike() -> void:
	attack.stop()
	attack.play("strike")

func die() -> void:
	locomotion.pause()
	attack.pause()

func get_projectile_origin() -> Vector3:
	return get_node(projectile_socket).global_position

func set_team(team: int) -> void:
	_team = team
	var tint := FactionPalette.model_color(team)
	for mesh: MeshInstance3D in _team_surfaces:
		mesh.set_instance_shader_parameter("team_color", tint)
