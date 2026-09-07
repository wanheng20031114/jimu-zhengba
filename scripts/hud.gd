extends Control

const UNIT_ORDER := ["swordsman", "archer", "knight", "catapult", "cannon"]
const UNIT_NAMES := ["剑士", "弓箭手", "骑士", "投石车", "加农炮"]
const COSTS := [45, 60, 100, 140, 180]
const DESCRIPTIONS := ["可靠的近战步兵\n剑盾冲锋，守护远程部队", "远程齐射\n利用射程压制敌方步兵", "重装骑兵\n迅速接敌，冲锋造成额外伤害", "远程攻城器械\n抛射巨石，造成范围伤害", "重型火炮\n炮弹爆炸，适合摧毁建筑"]
var game: Node3D
var portraits: Dictionary = {}
var _toast_remaining: float = 0.0
var _refresh_counter: int = 0

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
@onready var buttons: Array[Button] = [%Recruit0, %Recruit1, %Recruit2, %Recruit3, %Recruit4]

func _ready() -> void:
	for kind in UNIT_ORDER + ["headquarters"]:
		portraits[kind] = load("res://assets/ui/" + kind + ".png")
	for index in range(buttons.size()):
		buttons[index].pressed.connect(_on_recruit.bind(index))
		buttons[index].tooltip_text = UNIT_NAMES[index] + " · " + str(COSTS[index]) + " 金币\n" + DESCRIPTIONS[index] + "\n立即加入战场，无需等待"
		buttons[index].get_node("Portrait").texture = portraits[UNIT_ORDER[index]]
	%AttackButton.pressed.connect(func(): game.set_attack_mode(true))
	%StopButton.pressed.connect(func(): game.stop_selected())
	%HoldButton.pressed.connect(func(): game.hold_selected())
	%BaseButton.pressed.connect(func(): game.select_headquarters())
	%ArmyButton.pressed.connect(func(): game.select_army())
	%HelpButton.pressed.connect(toggle_help)
	%CloseHelp.pressed.connect(toggle_help)
	%PauseButton.pressed.connect(func(): game.toggle_pause())
	%ResumeButton.pressed.connect(func(): game.toggle_pause())
	%RestartButton.pressed.connect(func(): game.restart())
	%ResultRestart.pressed.connect(func(): game.restart())
	%Minimap.map_clicked.connect(func(at: Vector3, command: bool): game._on_minimap_clicked(at, command))
	for index in range(1, 10):
		var button: Button = get_node("Groups/Group" + str(index))
		button.pressed.connect(func(): game.use_control_group(index, Input.is_key_pressed(KEY_CTRL), Input.is_key_pressed(KEY_SHIFT)))

func bind_game(controller: Node3D) -> void:
	game = controller

func _process(delta: float) -> void:
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
	for index in range(buttons.size()):
		buttons[index].disabled = not can_recruit or game.gold < COSTS[index]
		buttons[index].get_node("Cost").modulate = Color("e9c97b") if game.gold >= COSTS[index] else Color("c27055")
	if game.selection.is_empty():
		selected_name.text = "等待指令"
		selected_role.text = "蓝旗军团"
		selected_stats.text = "左键选择 · 拖动框选\n右键行军或攻击"
		selected_portrait.texture = portraits.headquarters
		hp_bar.visible = false
		hp_label.visible = false
	elif game.selection.size() == 1:
		var entity = game.selection[0]
		selected_name.text = entity.display_name
		selected_role.text = "蓝旗军团" if entity.team == 0 else "赤牙守军"
		selected_role.modulate = Color("90bcda") if entity.team == 0 else Color("e98968")
		hp_bar.visible = true
		hp_label.visible = true
		hp_bar.max_value = entity.max_hp
		hp_bar.value = entity.hp
		hp_label.text = "%d / %d" % [int(entity.hp), int(entity.max_hp)]
		if entity.is_in_group("units"):
			selected_portrait.texture = portraits[entity.unit_type]
			selected_stats.text = "攻击 %d    射程 %.1f\n%s" % [entity.attack_damage, entity.attack_range, entity.order_name]
		else:
			selected_portrait.texture = portraits.headquarters
			selected_stats.text = "每秒 +1 金币\n右键地面设置集结点" if entity.team == 0 else "敌方军事建筑\n摧毁获得 90 金币"
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
		button.tooltip_text = "编队 %d · %d 人\nCtrl + %d 设定 · 双按 %d 定位" % [index, count, index, index]

func _on_recruit(index: int) -> void:
	game.recruit(UNIT_ORDER[index])

func toast(message: String, duration: float = 2.0) -> void:
	toast_label.text = message
	_toast_remaining = duration
	toast_label.modulate.a = 1.0
	if is_instance_valid(game):
		game.last_notification = message

func toggle_help() -> void:
	%HelpOverlay.visible = not %HelpOverlay.visible

func help_visible() -> bool:
	return %HelpOverlay.visible

func show_pause(value: bool) -> void:
	%PauseOverlay.visible = value

func show_result(victory: bool, duration: float, defeated: int) -> void:
	%ResultOverlay.visible = true
	%ResultHeading.text = "沙石镇已解放" if victory else "大本营已失守"
	%ResultEyebrow.text = "VICTORY  /  胜利" if victory else "DEFEAT  /  战败"
	%ResultBody.text = ("蓝旗再次升起。你的军队夺回了这片土地。" if victory else "整顿军队，重新部署你的进攻。") + "\n\n用时 %02d:%02d      击败敌军 %d" % [int(duration) / 60, int(duration) % 60, defeated]
