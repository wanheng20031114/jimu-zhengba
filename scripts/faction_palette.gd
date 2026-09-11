class_name FactionPalette
extends RefCounted
## Presentation is relative to the observer; ownership and combat alliances stay intact.
const SELF := 0
const ENEMY := 1
const ALLY := 2
const SANDBOX_OFFSET := 3
const SANDBOX_NAMES: PackedStringArray = ["苍蓝", "朱红", "金黄", "翠绿", "紫罗", "橙焰", "青空", "蔷薇", "青柠", "深蓝", "棕木", "松石", "象牙", "墨黑", "银白", "酒红"]
const SANDBOX_COLORS: Array[Color] = [Color("367eae"), Color("bb4937"), Color("d5aa35"), Color("329c59"), Color("985fc4"), Color("e98132"), Color("27b4c1"), Color("dd6eaa"), Color("a4c63b"), Color("304d85"), Color("865331"), Color("237b75"), Color("ead8ab"), Color("343946"), Color("cdd6dc"), Color("8c354e")]

static func relation(owner: int, alliance: int, game: Node) -> int:
	return game.presentation_faction(owner, alliance)

static func model_color(relation_id: int) -> Color:
	if relation_id >= SANDBOX_OFFSET:
		return SANDBOX_COLORS[relation_id - SANDBOX_OFFSET]
	return [Color("367eae"), Color("bb4937"), Color("d5aa35")][relation_id]

static func ui_color(relation_id: int) -> Color:
	if relation_id >= SANDBOX_OFFSET:
		return SANDBOX_COLORS[relation_id - SANDBOX_OFFSET].lightened(0.22)
	return [Color("70b8ef"), Color("e76446"), Color("edca59")][relation_id]

static func apply_model(model: Node3D, relation_id: int) -> void:
	var tint := model_color(relation_id)
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mesh.set_instance_shader_parameter("team_color", tint)
