extends Control

const UNIT_ORDER := ["swordsman", "archer", "knight", "catapult", "cannon", "farmer"]
const UNIT_NAMES := ["剑士", "弓箭手", "骑士", "投石车", "加农炮", "农民"]
const COSTS := [45, 60, 100, 140, 180, 50]
const DESCRIPTIONS := ["可靠的近战步兵\n剑盾冲锋，守护远程部队", "远程齐射\n利用射程压制敌方步兵", "重装骑兵\n迅速接敌，冲锋造成额外伤害", "远程攻城器械\n抛射巨石，造成范围伤害", "重型火炮\n炮弹爆炸，适合摧毁建筑", "采矿与建造\n矿边每3秒+3金币；建造防御塔"]
var game: Node3D
var portraits: Dictionary = {}
var _toast_remaining: float = 0.0
var _refresh_counter: int = 0
var _hovered_preview: String = ""
var _selected_preview: String = "headquarters"

@onready var gold_label: Label = %GoldValue
@onready var army_label: Label = %ArmyValue
@onready var timer_label: Label = %TimeValue
@onready var objective_label: Label = %Objective
@onready var selected_name: Label = %SelectedName
@onready var selected_role: Label = %SelectedRole
@onready var selected_stats: Label = %SelectedStats
@onready var selected_portrait: TextureRect = %SelectedPortrait
@onready var hp_bar: ProgressBar = %SelectionHP
@onready var hp_label: Label = %SelectionHPText
@onready var toast_label: Label = %Toast
@onready var buttons: Array[Button] = [%Recruit0, %Recruit1, %Recruit2, %Recruit3, %Recruit4, %Recruit5]

func _ready() -> void:
	for kind in UNIT_ORDER + ["headquarters", "gold_vein", "defense_tower"]:
		portraits[kind] = $ModelPreviews.portrait(kind)
	for index in range(buttons.size()):
		buttons[index].pressed.connect(_on_recruit.bind(index))
		buttons[index].mouse_entered.connect(_set_preview_hover.bind(UNIT_ORDER[index]))
		buttons[index].mouse_exited.connect(_set_preview_hover.bind(""))
		buttons[index].tooltip_text = UNIT_NAMES[index] + " · " + str(COSTS[index]) + " 金币\n" + DESCRIPTIONS[index] + "\n立即加入战场，无需等待"
		buttons[index].get_node("Portrait").texture = portraits[UNIT_ORDER[index]]
	%AttackButton.pressed.connect(func(): game.set_attack_mode(true))
	%StopButton.pressed.connect(func(): game.stop_selected())
	%HoldButton.pressed.connect(func(): game.hold_selected())
	%BaseButton.pressed.connect(func(): game.select_headquarters())
	%ArmyButton.pressed.connect(func(): game.select_army())
	%BuildButton.pressed.connect(func(): game.set_build_mode(not game.build_mode))
	%CancelSiteButton.pressed.connect(_on_building_action)
	%IdleWorkerButton.pressed.connect(func(): game.select_idle_worker())
	%TowerPortrait.texture = portraits.defense_tower
	%HelpButton.pressed.connect(toggle_help)
	%CloseHelp.pressed.connect(toggle_help)
	%PauseButton.pressed.connect(func(): game.toggle_pause())
	%ResumeButton.pressed.connect(func(): game.toggle_pause())
	%RestartButton.pressed.connect(func(): game.restart())
	%ResultRestart.pressed.connect(func(): game.restart())
	%SoundVolume.value_changed.connect(_on_sound_volume_changed)
	%SoundVolume.drag_ended.connect(func(_changed: bool): game.get_node("Audio").play_ui(&"select"))
	%SoundMute.toggled.connect(func(_value: bool): game.toggle_sound())
	%Minimap.map_clicked.connect(func(at: Vector3, command: bool): game._on_minimap_clicked(at, command))
	for index in range(1, 10):
		var button: Button = get_node("Groups/Group" + str(index))
		button.pressed.connect(func(): game.use_control_group(index, Input.is_key_pressed(KEY_CTRL), Input.is_key_pressed(KEY_SHIFT)))

func bind_game(controller: Node3D) -> void:
	game = controller
	%Minimap.game = controller
	refresh_sound_settings()

func refresh_sound_settings() -> void:
	var audio: Node = game.get_node("Audio")
	%SoundVolume.set_value_no_signal(audio.volume_percent())
	%SoundMute.set_pressed_no_signal(audio.muted)
	%SoundCaption.text = "音效 %d%%" % roundi(audio.volume_percent())

func _on_sound_volume_changed(value: float) -> void:
	game.get_node("Audio").set_volume_percent(value)
	refresh_sound_settings()

func _process(delta: float) -> void:
	$ModelPreviews.set_animated((_hovered_preview if not _hovered_preview.is_empty() else _selected_preview) if visible and not get_tree().paused else "")
	if _toast_remaining > 0.0:
		_toast_remaining -= delta
		toast_label.modulate.a = minf(_toast_remaining * 2.5, 1.0)
	else:
		toast_label.modulate.a = 0.0

func _input(event: InputEvent) -> void:
	if get_tree().paused and event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE or event.physical_keycode == KEY_P:
			game.toggle_pause()
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_M:
			game.toggle_sound()
			get_viewport().set_input_as_handled()

func refresh() -> void:
	if not is_instance_valid(game):
		return
	gold_label.text = str(game.gold)
	army_label.text = "%d / %d" % [game.player_count(), game.MAX_ARMY]
	timer_label.text = "%02d:%02d" % [int(game.elapsed) / 60, int(game.elapsed) % 60]
	objective_label.text = "摧毁敌方军事建筑  %d / 4" % game.buildings_destroyed
	%EnemyCount.text = "敌军 %d    击败 %d" % [game.enemy_count(), game.kills]
	var can_recruit: bool = is_instance_valid(game.headquarters) and game.headquarters.alive and game.headquarters in game.selection and not game.finished
	%RecruitHint.text = "消耗金币 · 即刻出兵" if can_recruit else "选中大本营以招募  [B]"
	var selected_site: BattleBuilding
	if game.selection.size() == 1 and game.selection[0] is BattleBuilding:
		selected_site = game.selection[0]
	var construction_selected: bool = selected_site != null and selected_site.team == 0 and selected_site.building_type == "defense_tower"
	var workers_selected: bool = not game.own_selected_workers().is_empty()
	var worker_panel: bool = workers_selected or construction_selected
	$CommandBar/Recruitment/RecruitTitle.text = "防御建设" if worker_panel else "即时招募"
	%BuildPanel.visible = worker_panel
	%BuildButton.disabled = not workers_selected or game.gold < game.TOWER_COST or game.finished
	%CancelSiteButton.visible = construction_selected
	%CancelSiteButton.text = "拆除防御塔  [Ctrl+Delete]" if construction_selected and selected_site.is_constructed else "取消施工  [Delete]"
	%BuildQueueHint.visible = not %CancelSiteButton.visible
	if worker_panel:
		%RecruitHint.text = "Shift 排队 · 20 秒施工" if workers_selected else "农民右键可接手工地"
		if construction_selected and selected_site.is_constructed:
			%RecruitHint.text = "自动警戒 · 可拆除腾出道路"
		%BuildInfo.text = "防御塔 · 100 金币\n施工 20 秒 · 自动攻击 · 无需驻军"
		if construction_selected:
			%BuildInfo.text = "防御塔已就绪\n自动警戒 · 射程 12 · 无需驻军" if selected_site.is_constructed else "防御塔施工 %d%%\n取消返还未完成部分的金币" % roundi(selected_site.construction_progress * 100)
	for index in range(buttons.size()):
		buttons[index].visible = not worker_panel
		buttons[index].disabled = not can_recruit or game.gold < COSTS[index]
		buttons[index].get_node("Cost").modulate = Color("e9c97b") if game.gold >= COSTS[index] else Color("c27055")
	if game.selection.is_empty():
		selected_name.text = "等待指令"
		selected_role.text = "蓝旗军团"
		selected_stats.text = "左键选择 · 拖动框选\n右键行军或攻击"
		selected_portrait.texture = portraits.headquarters
		_selected_preview = "headquarters"
		hp_bar.visible = false
		hp_label.visible = false
	elif game.selection.size() == 1:
		var entity = game.selection[0]
		selected_name.text = entity.display_name
		selected_role.text = "蓝旗军团" if entity.team == 0 else "赤牙守军"
		selected_role.modulate = Color("90bcda") if entity.team == 0 else Color("e98968")
		hp_bar.visible = true
		hp_label.visible = true
		if entity.is_in_group("resource_veins"):
			hp_bar.visible = false
			hp_label.visible = false
			selected_portrait.texture = portraits.gold_vein
			_selected_preview = "gold_vein"
			selected_role.text = "中立资源 · 金矿"
			selected_role.modulate = Color("e5c76b")
			selected_stats.text = "农民右键开始采集\n每人每 3 秒 +3 金币"
		else:
			hp_bar.max_value = entity.max_hp
			hp_bar.value = entity.hp
			hp_label.text = "%d / %d" % [int(entity.hp), int(entity.max_hp)]
		if entity.is_in_group("units"):
			selected_portrait.texture = portraits[entity.unit_type]
			_selected_preview = entity.unit_type
			selected_stats.text = "攻击 %d    射程 %.1f\n%s" % [entity.attack_damage, entity.attack_range, entity.order_name]
			if entity.unit_type == "farmer":
				selected_stats.text = "采矿 +3 / 3秒 · 建塔 [V]\n%s%s" % [entity.order_name, " · 队列 %d" % entity.waypoint_queue.size() if not entity.waypoint_queue.is_empty() else ""]
		elif entity.is_in_group("buildings"):
			selected_portrait.texture = portraits.headquarters
			_selected_preview = "headquarters"
			selected_stats.text = "每秒 +1 金币\n右键地面设置集结点" if entity.team == 0 else "敌方军事建筑\n摧毁获得 90 金币"
			if entity.building_type == "defense_tower":
				selected_portrait.texture = portraits.defense_tower
				_selected_preview = "defense_tower"
				selected_stats.text = "自动攻击范围内敌军\n无法进驻单位" if entity.is_constructed else "施工 %d%%\n农民右键继续建造" % roundi(entity.construction_progress * 100)
	else:
		selected_name.text = "%d 支部队" % game.selection.size()
		selected_role.text = "蓝旗军团 · 联合编队"
		selected_role.modulate = Color("90bcda")
		var total_hp: float = 0.0
		var maximum: float = 0.0
		var counts: Dictionary = {}
		for entity in game.selection:
			total_hp += entity.hp
			maximum += entity.max_hp
			counts[entity.display_name] = counts.get(entity.display_name, 0) + 1
		var descriptions: Array[String] = []
		for key in counts:
			descriptions.append(key + " " + str(counts[key]))
		selected_stats.text = " · ".join(descriptions)
		selected_portrait.texture = portraits.knight
		_selected_preview = "knight"
		hp_bar.visible = true
		hp_label.visible = true
		hp_bar.max_value = maximum
		hp_bar.value = total_hp
		hp_label.text = "%d / %d" % [int(total_hp), int(maximum)]
	%AttackButton.button_pressed = game.attack_mode
	var has_units: bool = not game.own_selected_units().is_empty()
	%AttackButton.disabled = not has_units
	%StopButton.disabled = not has_units
	%HoldButton.disabled = not has_units
	for index in range(1, 10):
		var count: int = 0
		if game.control_groups.has(index):
			for unit in game.control_groups[index]:
				if is_instance_valid(unit) and unit.alive:
					count += 1
		var button: Button = get_node("Groups/Group" + str(index))
		button.text = str(index) + ("  ·  " + str(count) if count > 0 else "")
		button.modulate.a = 1.0 if count > 0 else 0.48
		button.tooltip_text = "编队 %d · %d 人\nCtrl + %d 覆盖 · Shift + %d 追加\n按 %d 召回 · 双按定位" % [index, count, index, index, index]

func _on_recruit(index: int) -> void:
	game.recruit(UNIT_ORDER[index])

func _on_building_action() -> void:
	if game.selection.size() == 1 and game.selection[0] is BattleBuilding and game.selection[0].is_constructed:
		game.demolish_selected_towers()
	else:
		game.cancel_selected_construction()

func _set_preview_hover(kind: String) -> void:
	_hovered_preview = kind

func toast(message: String, duration: float = 2.0) -> void:
	toast_label.text = message
	_toast_remaining = duration
	toast_label.modulate.a = 1.0
	if is_instance_valid(game):
		game.last_notification = message

func toggle_help() -> void:
	%HelpOverlay.visible = not %HelpOverlay.visible
	game.get_node("Audio").play_ui(&"select")

func help_visible() -> bool:
	return %HelpOverlay.visible

func show_pause(value: bool) -> void:
	%PauseOverlay.visible = value

func show_result(victory: bool, duration: float, defeated: int) -> void:
	%ResultOverlay.visible = true
	%ResultHeading.text = "沙石镇已解放" if victory else "大本营已失守"
	%ResultEyebrow.text = "VICTORY  /  胜利" if victory else "DEFEAT  /  战败"
	%ResultBody.text = ("蓝旗再次升起。你的军队夺回了这片土地。" if victory else "整顿军队，重新部署你的进攻。") + "\n\n用时 %02d:%02d      击败敌军 %d" % [int(duration) / 60, int(duration) % 60, defeated]
