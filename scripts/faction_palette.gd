class_name FactionPalette
extends RefCounted
## Presentation is relative to the observer; ownership and combat alliances stay intact.
const SELF := 0
const ENEMY := 1
const ALLY := 2
const SANDBOX_OFFSET := 3
const SANDBOX_NAMES: PackedStringArray = ["海蓝", "正红", "明黄", "鲜绿", "亮紫", "橙焰", "天蓝", "嫩粉", "嫩绿", "靛蓝", "赤陶", "松绿", "杏黄", "水绿", "淡紫", "玫红"]
const SANDBOX_COLORS: Array[Color] = [Color("0072b9"), Color("e6002b"), Color("f8d000"), Color("19b43b"), Color("a34dc7"), Color("f07800"), Color("78c9ec"), Color("f3a4c8"), Color("a4c63b"), Color("555cc5"), Color("ae593d"), Color("008a77"), Color("e9bc83"), Color("69d7bb"), Color("ba9be0"), Color("d41483")]

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
