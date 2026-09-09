class_name FactionPalette
extends RefCounted
## Presentation is relative to the observer; ownership and combat alliances stay intact.
const SELF := 0
const ENEMY := 1
const ALLY := 2

static func relation(owner: int, alliance: int, game: Node) -> int:
	if owner == game.local_owner_id:
		return SELF
	return ALLY if alliance == game.get_player(game.local_owner_id).alliance_id else ENEMY

static func model_color(relation_id: int) -> Color:
	return [Color("367eae"), Color("bb4937"), Color("d5aa35")][relation_id]

static func ui_color(relation_id: int) -> Color:
	return [Color("70b8ef"), Color("e76446"), Color("edca59")][relation_id]

static func apply_model(model: Node3D, relation_id: int) -> void:
	var tint := model_color(relation_id)
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mesh.set_instance_shader_parameter("team_color", tint)
