extends Control
## A native catalogue backed by the same resources as recruitment and combat.
signal closed

const BUILDING_IDS: Array[String] = ["headquarters", "barracks", "factory", "academy", "defense_tower"]
const CLASS_NAMES: Dictionary = {&"infantry": "剑士", &"archer": "弓箭手", &"cavalry": "骑兵", &"siege": "攻城器", &"building": "建筑", &"worker": "农民"}
const BUILDING_DESCRIPTIONS: Dictionary = {
	"headquarters": "城镇的中心。训练农民、守护经济，并为重建保留希望。",
	"barracks": "训练剑士、弓箭手与骑士，用不同兵种组成你的主力。",
	"factory": "制造投石车与加农炮，为前线提供范围火力和攻城支援。",
	"academy": "研究军队、人口与采矿科技。已完成的研究永久保留。",
	"defense_tower": "自动攻击范围内的敌人。无法驻军，需要部队保护。",
}
const MODEL_PATHS: Dictionary = {
	"headquarters": "res://assets/models/environment/headquarters.tscn",
	"barracks": "res://assets/models/environment/player_barracks.tscn",
	"factory": "res://assets/models/environment/factory.tscn",
	"academy": "res://assets/models/environment/academy.tscn",
	"defense_tower": "res://assets/models/environment/defense_tower.tscn",
}
const TECH_MODELS: Dictionary = {&"attack": "swordsman", &"defense": "knight", &"workforce": "farmer", &"army_capacity": "barracks", &"mining": "farmer"}
const UNIT_FRAMING: Dictionary = {
	"swordsman": Vector2(1.0, 3.2), "archer": Vector2(1.0, 3.3), "knight": Vector2(1.35, 4.5),
	"catapult": Vector2(1.25, 5.4), "cannon": Vector2(0.8, 4.4), "farmer": Vector2(1.0, 3.2),
}
var category: int = 0
var selected_id: String = ""
var _entries: Array[String] = []
var _model: Node3D
var _dragging: bool = false
var _reveal: Tween
var _base_camera_size: float = 3.2

@onready var _viewport: SubViewport = %CodexViewport
@onready var _anchor: Node3D = %ModelAnchor
@onready var _camera: Camera3D = %PreviewCamera
@onready var _pedestal: MeshInstance3D = %Pedestal

func _ready() -> void:
	for title: String in ["单位", "建筑", "科技"]:
		%CategoryTabs.add_tab(title)
	%Portrait.texture = _viewport.get_texture()
	%CategoryTabs.tab_changed.connect(_on_category_changed)
	%Entries.item_selected.connect(_on_entry_selected)
	%Portrait.gui_input.connect(_on_preview_input)
	%CloseCodex.pressed.connect(close_codex)
	%ResetView.pressed.connect(_reset_view)
	_on_category_changed(0)
	set_process(false)

func open_codex() -> void:
	show()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_model.process_mode = Node.PROCESS_MODE_INHERIT
	set_process(true)
	if _reveal != null:
		_reveal.kill()
	modulate.a = 0.0
	_reveal = create_tween()
	_reveal.tween_property(self, "modulate:a", 1.0, 0.2).set_trans(Tween.TRANS_SINE)
	%Entries.grab_focus()

func close_codex() -> void:
	hide()
	_dragging = false
	set_process(false)
	_model.process_mode = Node.PROCESS_MODE_DISABLED
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	closed.emit()

func _process(_delta: float) -> void:
	if _dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_dragging = false

func _on_category_changed(value: int) -> void:
	category = value
	_entries.clear()
	match category:
		0:
			for id: String in BalanceCatalog.UNITS:
				_entries.append(id)
		1: _entries.assign(BUILDING_IDS)
		2:
			for id: String in BalanceCatalog.UPGRADES:
				_entries.append(id)
	%Entries.clear()
	for id: String in _entries:
		var definition: Resource = _definition(id)
		%Entries.add_item(definition.name)
	%Count.text = "%d 项" % _entries.size()
	%Entries.select(0)
	_on_entry_selected(0)

func _definition(id: String) -> Resource:
	match category:
		0: return BalanceCatalog.unit(id)
		1: return BalanceCatalog.building(id)
	return BalanceCatalog.upgrade(id)

func select_entry(value: int, id: String) -> void:
	%CategoryTabs.current_tab = value
	if category != value:
		_on_category_changed(value)
	var index: int = _entries.find(id)
	assert(index >= 0, "Unknown codex entry " + id)
	%Entries.select(index)
	%Entries.ensure_current_is_visible()
	_on_entry_selected(index)

func _on_entry_selected(index: int) -> void:
	selected_id = _entries[index]
	var definition: Resource = _definition(selected_id)
	%EntryTitle.text = definition.name
	var content: String = ""
	match category:
		0:
			var unit: UnitDefinition = definition
			%EntryType.text = "单位  /  " + ("军事部队" if unit.military else "经济单位")
			%Description.text = unit.description
			content += _row("训练费用", "%d 金币" % unit.cost)
			content += _row("训练时间", _number(unit.training_seconds) + " 秒")
			content += _row("生产建筑", BalanceCatalog.building(unit.production_building).name)
			content += _row("人口", "%d 军事人口" % unit.supply if unit.military else "1 名农民")
			content += _combat_rows(unit)
			content += _row("移动速度", _number(unit.speed))
			content += _row("视野", _number(unit.sight))
			if unit.min_range > 0.0:
				content += _row("最小射程", _number(unit.min_range))
			%Special.text = _unit_notes(unit)
			_set_preview(selected_id)
		1:
			var building: BuildingDefinition = definition
			%EntryType.text = "建筑  /  城镇建设"
			%Description.text = BUILDING_DESCRIPTIONS[selected_id]
			content += _row("建造费用", "%d 金币" % building.cost + (" · 开局免费" if selected_id == "headquarters" else ""))
			content += _row("建造时间", _number(building.build_seconds) + " 秒")
			content += _combat_rows(building)
			var recruits: PackedStringArray = []
			for kind: String in building.produces:
				recruits.append(BalanceCatalog.unit(kind).name)
			if not recruits.is_empty():
				content += _row("训练部队", "、".join(recruits))
			%Special.text = "需一座已完工兵营才能建造。" if selected_id in ["factory", "academy"] else "由一名农民施工。支持连续建造与接手未完成工地。"
			if selected_id == "headquarters":
				%Special.text = "每位玩家最多拥有一座大本营（含工地）。大本营被毁后可以重建。"
			_set_preview(selected_id)
		2:
			var upgrade: UpgradeDefinition = definition
			%EntryType.text = "科技  /  学院研究"
			%Description.text = _upgrade_description(upgrade)
			content += _row("研究费用", "%d 金币" % upgrade.cost)
			content += _row("研究时间", _number(upgrade.research_seconds) + " 秒")
			content += _row("研究建筑", "学院")
			content += _row("前置研究", BalanceCatalog.upgrade("%s_%d" % [upgrade.track, upgrade.level - 1]).name if upgrade.level > 1 else "无")
			if upgrade.track == &"army_capacity":
				content += _row("军事人口上限", str(PlayerState.SUPPLY_LIMIT + upgrade.total_bonus))
			elif upgrade.track == &"mining":
				content += _row("每次采矿收入", "%d 金币" % BalanceCatalog.ECONOMY.mining_gold)
				content += _row("采矿周期", "%.2f 秒" % (BalanceCatalog.ECONOMY.mining_seconds / (1.0 + upgrade.total_bonus / 100.0)))
			elif upgrade.track == &"workforce":
				content += _row("农民上限", str(PlayerState.WORKER_LIMIT + upgrade.total_bonus))
			else:
				content += _row("研究后总加成", "+%d" % upgrade.total_bonus)
			%Special.text = "同一路线依次研究。可排队研究，手动取消全额退款；学院被毁会失去未完成的研究。"
			_set_preview(TECH_MODELS[upgrade.track])
	%Stats.text = "[table=2]" + content + "[/table]"
	%DetailScroll.scroll_vertical = 0
	%DataNote.text = "初始数值 · 未研究科技" if category != 2 else "升级效果为本级完成后的总效果"

func _combat_rows(definition: CombatDefinition) -> String:
	var rows: String = _row("生命值", _number(definition.hp))
	rows += _row("近战护甲", _number(definition.melee_armor))
	rows += _row("远程护甲", _number(definition.ranged_armor))
	if definition.damage > 0.0:
		rows += _row("攻击力", _number(definition.damage) + (" · 近战" if definition.damage_channel == CombatDefinition.DamageChannel.MELEE else " · 远程"))
		rows += _row("攻击间隔", _number(definition.cooldown) + " 秒")
		rows += _row("射程", _number(definition.range))
	for target_class: StringName in definition.bonuses:
		rows += _row("对" + String(CLASS_NAMES[target_class]), "+%s 伤害" % _number(definition.bonuses[target_class]))
	return rows

func _unit_notes(unit: UnitDefinition) -> String:
	if unit.id == &"catapult":
		return "半径 3 的范围伤害，范围内伤害一致。巨石落点在发射时确定，可以躲避；不会伤及友军。"
	if unit.id == &"cannon":
		return "炮弹命中单个目标。适合拆除建筑；需要前排保护，无法攻击贴身敌人。"
	if not unit.military:
		return "每 %.1f 秒采得 %d 金币，无需运输。每座矿脉最多同时容纳 6 名农民。学院可提升采矿效率与农民上限。" % [BalanceCatalog.ECONOMY.mining_seconds, BalanceCatalog.ECONOMY.mining_gold]
	return "攻击与防御研究对现有和新训练的军事单位同时生效。类别附加伤害按目标类别结算。"

func _upgrade_description(upgrade: UpgradeDefinition) -> String:
	match upgrade.track:
		&"attack": return "全部军事单位的攻击力提高 %d 点。农民和建筑不受影响。" % upgrade.total_bonus
		&"defense": return "全部军事单位的近战与远程护甲提高 %d 点。攻城器的近战护甲仍为 0；农民和建筑不受影响。" % upgrade.total_bonus
		&"army_capacity": return "军事人口上限提高至 %d，可容纳更多军队。农民使用独立的人数上限。" % (PlayerState.SUPPLY_LIMIT + upgrade.total_bonus)
		&"mining": return "农民采矿效率提高 %d%%。单次收入不变，采集周期缩短；正在采集的进度保留。" % upgrade.total_bonus
	return "农民人数上限提高至 %d，包括存活农民与训练队列中的名额。" % (PlayerState.WORKER_LIMIT + upgrade.total_bonus)

func _row(label: String, value: String) -> String:
	return "[cell][color=#a99b80]%s[/color][/cell][cell][color=#f0dfbb]%s[/color][/cell]" % [label, value]

func _number(value: float) -> String:
	return str(int(value)) if is_equal_approx(value, roundf(value)) else "%.1f" % value

func _set_preview(kind: String) -> void:
	if is_instance_valid(_model):
		_anchor.remove_child(_model)
		_model.queue_free()
	var unit: bool = BalanceCatalog.UNITS.has(kind)
	var packed: PackedScene = load("res://assets/models/units/%s.tscn" % kind if unit else MODEL_PATHS[kind])
	_model = packed.instantiate()
	_anchor.add_child(_model)
	var center: float = 3.0
	if unit:
		_model.set_team(0)
		_model.set_motion(false)
		center = UNIT_FRAMING[kind].x
		_base_camera_size = UNIT_FRAMING[kind].y
	else:
		FactionPalette.apply_model(_model, 0)
		center = 3.7 if kind == "headquarters" else 3.0
		_base_camera_size = 14.5 if kind == "headquarters" else 9.5
	_camera.position = Vector3(5, 4, -7) if unit else Vector3(15, 12, 21 if kind == "headquarters" else -21)
	_camera.look_at(Vector3(0, center, 0), Vector3.UP)
	_pedestal.scale = Vector3(1.4, 1.0, 1.4) if unit else Vector3(4.7, 1.0, 4.7)
	_reset_view()
	_model.process_mode = Node.PROCESS_MODE_INHERIT if visible else Node.PROCESS_MODE_DISABLED
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if visible else SubViewport.UPDATE_ONCE

func _reset_view() -> void:
	_anchor.rotation.y = 0.0
	_camera.size = _base_camera_size

func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_camera.size = clampf(_camera.size * (0.92 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.08), _base_camera_size * 0.65, _base_camera_size * 1.5)
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_anchor.rotation.y += event.relative.x * 0.008
		accept_event()
