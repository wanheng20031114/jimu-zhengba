extends Control
## A native catalogue backed by the same resources as recruitment and combat.
signal closed

const BUILDING_IDS: Array[String] = ["headquarters", "barracks", "factory", "academy", "defense_tower"]
const CLASS_NAMES: Dictionary = {&"infantry": "步兵", &"archer": "弓箭手", &"cavalry": "骑兵", &"siege": "攻城器", &"building": "建筑", &"worker": "农民"}
const BUILDING_DESCRIPTIONS: Dictionary = {
	"headquarters": "城镇的中心。训练农民、守护经济，并为重建保留希望。",
	"barracks": "训练剑士、盾卫、长矛兵、弓箭手、骑士、战象与轻骑兵，用不同兵种组成你的主力。",
	"factory": "制造投石车、加农炮并训练工程兵，为前线提供火力和维修支援。",
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
const TECH_MODELS: Dictionary = {&"attack": "swordsman", &"defense": "knight", &"workforce": "farmer", &"army_capacity": "barracks", &"mining": "farmer", &"cannon_range": "cannon", &"recovery": "farmer"}
const UNIT_FRAMING: Dictionary = {
	"swordsman": Vector2(1.0, 3.2), "shield_guard": Vector2(1.05, 3.4), "spearman": Vector2(1.35, 4.1), "archer": Vector2(1.0, 3.3), "knight": Vector2(1.35, 4.5), "light_cavalry": Vector2(1.3, 4.2), "war_elephant": Vector2(1.85, 6.4),
	"catapult": Vector2(1.25, 5.4), "cannon": Vector2(0.8, 4.4), "farmer": Vector2(1.0, 3.2), "engineer": Vector2(1.0, 3.2),
}
enum PreviewAction { IDLE, WALK, ATTACK, GATHER }
var category: int = 0
var selected_id: String = ""
var _entries: Array[String] = []
var _model: Node3D
var _dragging: bool = false
var _reveal: Tween
var _base_camera_size: float = 3.2
var _preview_unit: UnitVisual
var _preview_action: PreviewAction = PreviewAction.IDLE
var _preview_paused: bool = false
var _preview_complete: bool = false
var _preview_loop: bool = true
var _cycle_elapsed: float = 0.0
var _cycle_seconds: float = 1.0

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
	%PreviewIdle.pressed.connect(_select_preview_action.bind(PreviewAction.IDLE))
	%PreviewWalk.pressed.connect(_select_preview_action.bind(PreviewAction.WALK))
	%PreviewAttack.pressed.connect(_select_preview_action.bind(PreviewAction.ATTACK))
	%PreviewGather.pressed.connect(_select_preview_action.bind(PreviewAction.GATHER))
	%PausePreview.pressed.connect(_toggle_preview_pause)
	%LoopPreview.toggled.connect(_set_preview_loop)
	visibility_changed.connect(_on_codex_visibility_changed)
	_on_category_changed(0)
	_refresh_preview_activity()

func open_codex() -> void:
	show()
	_refresh_preview_activity()
	if _reveal != null:
		_reveal.kill()
	modulate.a = 0.0
	_reveal = create_tween()
	_reveal.tween_property(self, "modulate:a", 1.0, 0.2).set_trans(Tween.TRANS_SINE)
	%Entries.grab_focus()

func close_codex() -> void:
	hide()
	_dragging = false
	if _reveal != null:
		_reveal.kill()
	_refresh_preview_activity()
	closed.emit()

func _process(delta: float) -> void:
	if _dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_dragging = false
		_refresh_preview_activity()
	if category == 0 and _preview_unit != null and not _preview_paused:
		_advance_preview(delta)

func _on_codex_visibility_changed() -> void:
	if not is_node_ready():
		return
	if not is_visible_in_tree():
		_dragging = false
	_refresh_preview_activity()

func _refresh_preview_activity() -> void:
	var showing: bool = is_visible_in_tree()
	var playing: bool = showing and category == 0 and _preview_unit != null and not _preview_paused
	set_process(showing and (playing or _dragging))
	if is_instance_valid(_model):
		_model.process_mode = Node.PROCESS_MODE_INHERIT if showing else Node.PROCESS_MODE_DISABLED
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if playing else (SubViewport.UPDATE_ONCE if showing else SubViewport.UPDATE_DISABLED)

func _request_preview_redraw() -> void:
	if is_visible_in_tree() and _viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _select_preview_action(action: PreviewAction) -> void:
	_preview_action = action
	if _preview_unit.kind == "spearman":
		# The horizontal thrust has a wider silhouette than the upright carry pose.
		_base_camera_size = 5.8 if action == PreviewAction.ATTACK else UNIT_FRAMING["spearman"].y
		_camera.size = _base_camera_size
	_preview_paused = false
	_preview_complete = false
	_cycle_elapsed = 0.0
	# Restore tracks owned by both players before switching away from a partial
	# strike, including weapon visibility and the locomotion resting pose.
	_preview_unit.set_working(false)
	_preview_unit.set_motion(false)
	_preview_unit.attack.play("strike", 0.0)
	_preview_unit.attack.seek(0.0, true, true)
	_preview_unit.attack.stop(true)
	_preview_unit.locomotion.play("walk", 0.0)
	_preview_unit.locomotion.seek(0.0, true, true)
	_preview_unit.locomotion.play("idle", 0.0)
	_preview_unit.locomotion.seek(0.0, true, true)
	match action:
		PreviewAction.IDLE:
			_cycle_seconds = _preview_unit.locomotion.get_animation("idle").length
		PreviewAction.WALK:
			_preview_unit.set_motion(true)
			_preview_unit.locomotion.seek(0.0, true, true)
			_cycle_seconds = _preview_unit.locomotion.get_animation("walk").length
		PreviewAction.ATTACK:
			_preview_unit.strike()
			_preview_unit.attack.seek(0.0, true, true)
			# Preserve the whole authored motion and the unit's real attack cadence.
			_cycle_seconds = maxf(BalanceCatalog.unit(_preview_unit.kind).cooldown, _preview_unit.attack.get_animation("strike").length)
		PreviewAction.GATHER:
			_preview_unit.set_working(true, "repair" if selected_id == "engineer" else "gather")
			_preview_unit.attack.seek(0.0, true, true)
			_cycle_seconds = _preview_unit.attack.get_animation("repair" if selected_id == "engineer" else "gather").length
	_update_preview_controls()
	_refresh_preview_activity()

func _advance_preview(delta: float) -> void:
	# Both native players use MANUAL mode here. This single presentation clock
	# neither advances combat timers nor shares the offscreen simulation clock.
	var remaining: float = delta
	while remaining > 0.0:
		var step: float = minf(remaining, _cycle_seconds - _cycle_elapsed)
		if _preview_unit.locomotion.is_playing():
			_preview_unit.locomotion.advance(step)
		if _preview_unit.attack.is_playing():
			_preview_unit.attack.advance(step)
		_cycle_elapsed += step
		remaining -= step
		if _cycle_elapsed + 0.000001 < _cycle_seconds:
			break
		if not _preview_loop:
			_preview_complete = true
			_preview_paused = true
			_update_preview_controls()
			_refresh_preview_activity()
			break
		_cycle_elapsed = 0.0
		if _preview_action == PreviewAction.ATTACK:
			_preview_unit.strike()
			_preview_unit.attack.seek(0.0, true, true)

func _toggle_preview_pause() -> void:
	if _preview_complete:
		_select_preview_action(_preview_action)
		return
	_preview_paused = not _preview_paused
	_update_preview_controls()
	_refresh_preview_activity()

func _set_preview_loop(value: bool) -> void:
	_preview_loop = value

func _update_preview_controls() -> void:
	%PreviewIdle.set_pressed_no_signal(_preview_action == PreviewAction.IDLE)
	%PreviewWalk.set_pressed_no_signal(_preview_action == PreviewAction.WALK)
	%PreviewAttack.set_pressed_no_signal(_preview_action == PreviewAction.ATTACK)
	%PreviewGather.set_pressed_no_signal(_preview_action == PreviewAction.GATHER)
	%PausePreview.text = "重播" if _preview_complete else ("继续" if _preview_paused else "暂停")
	%PausePreview.tooltip_text = "从头播放当前动作" if _preview_complete else ("从当前姿势继续播放" if _preview_paused else "停在当前姿势，可继续旋转和缩放")

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
			if unit.support_kind == &"repair":
				content += _row("免费维修", "%s生命 / %s秒" % [_number(unit.support_amount), _number(unit.support_period)])
				content += _row("维修距离", _number(unit.support_range))
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
			elif not building.cost_progression.is_empty():
				var prices: PackedStringArray = []
				for price: int in building.cost_progression:
					prices.append(str(price))
				%Special.text = "付费建造依次花费 %s 金币，第 %d 座起维持 %d 金。开局赠送的塔不计入；取消或摧毁不会重置，取消返还实际支付额的未完成部分。" % [" / ".join(prices), prices.size(), building.cost_progression[-1]]
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
			elif upgrade.track == &"cannon_range":
				content += _row("加农炮射程", "%s → %s" % [_number(BalanceCatalog.unit(&"cannon").range), _number(BalanceCatalog.unit(&"cannon").range + upgrade.total_bonus)])
			elif upgrade.track == &"recovery":
				content += _row("未受伤等待", "%d 秒" % BattleUnit.RECOVERY_DELAY)
				content += _row("恢复速率", "%d 生命 / 秒" % upgrade.total_bonus)
				content += _row("作用对象", "全部可移动单位，含农民、攻城器")
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
	if unit.support_kind == &"repair":
		return "免费维修己方和盟友的受损攻城器，工作满1秒恢复5生命。同一目标同时一人维修。不能维修建筑或战象；右键指定目标，停止命令中断维修。"
	if unit.id == &"light_cavalry":
		return "移动速度6.8、视野20的轻装侦察骑兵，适合迂回与追击落单弓手。装备较轻，正面交战需要谨慎，完整承受长矛兵等单位的反骑兵附加伤害。"
	if unit.id == &"war_elephant":
		return "昂贵的骑兵单位，以象牙顶击单个目标，没有范围伤害。长矛兵与剑士的反骑兵附加伤害完整生效，适合在友军支援下承受正面攻击。"
	if unit.id == &"shield_guard":
		return "高远程护甲适合承受箭雨，持盾短剑攻击单个目标。护甲全方向生效，攻击与防御研究同时影响现有和新训练的盾卫。"
	if unit.id == &"catapult":
		return "半径 %s 的范围伤害，范围内伤害一致。巨石落点在发射时确定，可以躲避；不会伤及友军。" % _number(unit.splash_radius)
	if unit.id == &"cannon":
		return "炮弹命中单个目标。适合拆除建筑；需要前排保护，无法攻击贴身敌人。学院研究加长炮管可使射程 +%d。" % BalanceCatalog.upgrade(&"cannon_range_1").total_bonus
	if not unit.military:
		return "每 %.1f 秒采得 %d 金币，无需运输。每座矿脉最多同时容纳 6 名农民。学院可提升采矿效率与农民上限。" % [BalanceCatalog.ECONOMY.mining_seconds, BalanceCatalog.ECONOMY.mining_gold]
	return "攻击与防御研究对现有和新训练的军事单位同时生效。类别附加伤害按目标类别结算。"

func _upgrade_description(upgrade: UpgradeDefinition) -> String:
	match upgrade.track:
		&"attack": return "全部军事单位的攻击力提高 %d 点。农民和建筑不受影响。" % upgrade.total_bonus
		&"defense": return "全部军事单位的近战与远程护甲提高 %d 点。攻城器的近战护甲仍为 0；农民和建筑不受影响。" % upgrade.total_bonus
		&"army_capacity": return "军事人口上限提高至 %d，可容纳更多军队。农民使用独立的人数上限。" % (PlayerState.SUPPLY_LIMIT + upgrade.total_bonus)
		&"mining": return "农民采矿效率提高 %d%%。单次收入不变，采集周期缩短；正在采集的进度保留。" % upgrade.total_bonus
		&"cannon_range": return "现有及未来加农炮的射程增加 %d。其他单位和建筑不受影响，最小射程不变。" % upgrade.total_bonus
		&"recovery": return "现有及未来可移动单位在连续 10 秒未受伤后，每满 1 秒恢复 %d 生命。满血停止，受伤重置；农民与攻城器同样生效，建筑不受益，阵亡单位不会恢复。" % upgrade.total_bonus
	return "农民人数上限提高至 %d，包括存活农民与训练队列中的名额。" % (PlayerState.WORKER_LIMIT + upgrade.total_bonus)

func _row(label: String, value: String) -> String:
	return "[cell][color=#a99b80]%s[/color][/cell][cell][color=#f0dfbb]%s[/color][/cell]" % [label, value]

func _number(value: float) -> String:
	return str(int(value)) if is_equal_approx(value, roundf(value)) else "%.1f" % value

func _set_preview(kind: String) -> void:
	_preview_unit = null
	if is_instance_valid(_model):
		_anchor.remove_child(_model)
		_model.queue_free()
	var unit: bool = BalanceCatalog.UNITS.has(kind)
	var packed: PackedScene = load("res://assets/models/units/%s.tscn" % kind if unit else MODEL_PATHS[kind])
	_model = packed.instantiate()
	_anchor.add_child(_model)
	var center: float = 3.0
	if unit:
		_preview_unit = _model as UnitVisual
		_preview_unit.locomotion.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		_preview_unit.attack.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		_preview_unit.set_team(0)
		_preview_loop = true
		%LoopPreview.set_pressed_no_signal(true)
		_select_preview_action(PreviewAction.IDLE)
		center = UNIT_FRAMING[kind].x
		_base_camera_size = UNIT_FRAMING[kind].y
	else:
		FactionPalette.apply_model(_model, 0)
		center = 3.7 if kind == "headquarters" else 3.0
		_base_camera_size = 14.5 if kind == "headquarters" else 9.5
	_camera.position = Vector3(5, 4, -7) if unit else Vector3(15, 12, 21 if kind == "headquarters" else -21)
	_camera.look_at(Vector3(0, center, 0), Vector3.UP)
	_pedestal.scale = Vector3(1.4, 1.0, 1.4) if unit else Vector3(4.7, 1.0, 4.7)
	%PreviewAnimationControls.visible = category == 0 and unit
	%PreviewGather.visible = kind in ["farmer", "engineer"]
	%PreviewGather.text = "维修" if kind == "engineer" else "采矿"
	%PreviewAttack.text = "开炮" if kind == "cannon" else ("投射" if kind == "catapult" else "攻击")
	_reset_view()
	_refresh_preview_activity()

func _reset_view() -> void:
	_anchor.rotation.y = 0.0
	_camera.size = _base_camera_size
	_request_preview_redraw()

func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
			_refresh_preview_activity()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_camera.size = clampf(_camera.size * (0.92 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.08), _base_camera_size * 0.65, _base_camera_size * 1.5)
			_request_preview_redraw()
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_anchor.rotation.y += event.relative.x * 0.008
		_request_preview_redraw()
		accept_event()
