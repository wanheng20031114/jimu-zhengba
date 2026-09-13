extends Control
## Native sandbox controls share the battle controller's small HUD contract.
var game: Node3D
var _message_time: float = 0.0
const KINDS: PackedStringArray = ["swordsman", "shield_guard", "spearman", "archer", "knight", "war_elephant", "light_cavalry", "catapult", "cannon", "heavy_cannon", "triple_cannon", "engineer", "priest", "farmer"]

func bind_game(controller: Node3D) -> void:
	game = controller
	for mode: String in NetworkProtocol.MODES:
		var map: MapDefinition = load(NetworkProtocol.map_path(mode))
		%Map.add_item(map.display_name)
		%Map.set_item_metadata(%Map.item_count - 1, mode)
		if mode == game.map_mode:
			%Map.select(%Map.item_count - 1)
	%Map.item_selected.connect(func(index: int): game.switch_map(%Map.get_item_metadata(index)))
	for kind: String in KINDS:
		var button: Button = %Kinds.get_node(kind)
		button.pressed.connect(game.set_paint_kind.bind(kind))
	for index: int in FactionPalette.SANDBOX_COLORS.size():
		var button: Button = %Colors.get_child(index)
		button.text = "%02d" % (index + 1)
		button.tooltip_text = "%02d · %s阵营" % [index + 1, FactionPalette.SANDBOX_NAMES[index]]
		button.get_node("Swatch").color = FactionPalette.SANDBOX_COLORS[index]
		button.pressed.connect(game.set_faction.bind(index))
	%Count.value_changed.connect(func(value: float): game.paint_count = int(value))
	%Rotate.pressed.connect(game.rotate_placement)
	%Place.pressed.connect(game.set_placing.bind(true))
	%Select.pressed.connect(game.set_placing.bind(false))
	%Run.pressed.connect(game.handle_pause_action)
	%Clear.pressed.connect(game.clear_units)
	%Remove.pressed.connect(game.remove_selected)
	%Back.pressed.connect(game.return_to_menu)
	%Settings.pressed.connect(func(): game.settings.open_menu())
	refresh()

func refresh() -> void:
	if game == null:
		return
	%Faction.text = game.players[game.local_owner_id].display_name + "阵营"
	%Faction.modulate = FactionPalette.ui_color(game.local_owner_id + FactionPalette.SANDBOX_OFFSET)
	for index: int in %Colors.get_child_count():
		%Colors.get_child(index).set_pressed_no_signal(index == game.local_owner_id)
	for kind: String in KINDS:
		%Kinds.get_node(kind).set_pressed_no_signal(kind == game.paint_kind)
	%Place.set_pressed_no_signal(game.placing)
	%Select.set_pressed_no_signal(not game.placing)
	%Rotate.text = "朝向 %d°   R" % int(rad_to_deg(game.paint_rotation))
	%Run.text = "暂停交战   F5" if game.running else "开始交战   F5"
	%Run.disabled = game._busy
	%State.text = "正在载入地图…" if game._busy else ("交战中" if game.running else "布阵中 · 部队已暂停")
	%Population.text = "%d / 500 单位" % game.sandbox_unit_count
	%Elapsed.text = "%02d:%02d" % [int(game.elapsed) / 60, int(game.elapsed) % 60]
	if game.selection.is_empty():
		%Selection.text = "选择模式：框选当前阵营，右键下令"
	else:
		var entity: Node3D = game.selection[0]
		%Selection.text = "中立 · 黄金矿脉" if entity is ResourceVein else "%s · %s%s" % [game.players[entity.owner_id].display_name, entity.display_name, " · 共 %d 个" % game.selection.size() if game.selection.size() > 1 else ""]
	%Remove.disabled = not game.selection.any(func(entity: Node3D): return entity is BattleUnit)

func toast(message: String, seconds: float = 2.0) -> void:
	%Notice.text = message
	_message_time = seconds
	set_process(true)

func _process(delta: float) -> void:
	_message_time -= delta
	if _message_time <= 0.0:
		%Notice.text = ""
		set_process(false)

func help_visible() -> bool:
	return false
