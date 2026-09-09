extends Control

const UNIT_ORDER := ["swordsman", "archer", "knight", "catapult", "cannon", "farmer"]
const UNIT_NAMES := ["剑士", "弓箭手", "骑士", "投石车", "加农炮", "农民"]
const BUILD_ORDER := ["barracks", "factory", "academy", "defense_tower", "headquarters"]
var _actions: Array[Dictionary] = []
var _queue_actions: Array[Dictionary] = []
var _queue_buttons: Array[Button] = []
var _queue_page: int = 0
var _queue_page_count: int = 1
var _queue_selection: Array[int] = []
var game: Node3D
var portraits: Dictionary = {}
var _toast_remaining: float = 0.0
var _refresh_counter: int = 0
var _hovered_preview: String = ""
var _selected_preview: String = "headquarters"
var _preview_alliance: int = -1

@onready var gold_label: Label = %GoldValue
@onready var army_label: Label = %ArmyValue
@onready var farmers_label: Label = %FarmersValue
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
	for kind in UNIT_ORDER + ["headquarters", "gold_vein", "defense_tower", "barracks", "factory", "academy"]:
		portraits[kind] = $ModelPreviews.portrait(kind)
	portraits["attack_upgrade"] = preload("res://assets/ui/attack_upgrade.png")
	portraits["defense_upgrade"] = preload("res://assets/ui/defense_upgrade.png")
	for index in range(buttons.size()):
		buttons[index].pressed.connect(_on_recruit.bind(index))
		buttons[index].mouse_entered.connect(func(): _set_preview_hover(_actions[index].portrait if index < _actions.size() else ""))
		buttons[index].mouse_exited.connect(_set_preview_hover.bind(""))
		var definition := BalanceCatalog.unit(UNIT_ORDER[index])
		buttons[index].tooltip_text = definition.name + " · " + str(definition.cost) + " 金币\n" + definition.description
		buttons[index].get_node("Cost").text = "◈ %d" % definition.cost
		buttons[index].get_node("Portrait").texture = portraits[UNIT_ORDER[index]]
	for child: Button in %QueueStrip.get_node("Slots").get_children():
		var index: int = _queue_buttons.size()
		_queue_buttons.append(child)
		child.pressed.connect(_on_queue_cancel.bind(index))
		child.mouse_entered.connect(_on_queue_hover.bind(index, true))
		child.mouse_exited.connect(_on_queue_hover.bind(index, false))
	%QueuePrevious.pressed.connect(_turn_queue_page.bind(-1))
	%QueueNext.pressed.connect(_turn_queue_page.bind(1))
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
			if game.online and event.physical_keycode == KEY_P:
				game.request_match_pause()
			else:
				game.toggle_pause()
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_M:
			game.toggle_sound()
			get_viewport().set_input_as_handled()

func refresh() -> void:
	if not is_instance_valid(game):
		return
	gold_label.text = str(game.gold)
	var player: PlayerState = game.get_player(game.local_owner_id)
	army_label.text = "军事 %d / %d" % [player.used_military_supply(), PlayerState.SUPPLY_LIMIT]
	army_label.tooltip_text = "在场 %d 人口 · 训练中 %d 人口\n训练队列已预留军事人口" % [player.military_supply, player.reserved_military_supply]
	farmers_label.text = "农民 %d / %d" % [player.farmers + player.reserved_farmers, PlayerState.WORKER_LIMIT]
	farmers_label.tooltip_text = "在场 %d 人 · 训练中 %d 人\n训练中的农民已计入上限" % [player.farmers, player.reserved_farmers]
	var preview_relation: int = FactionPalette.SELF
	if game.selection.size() == 1 and game.selection[0].owner_id >= 0:
		preview_relation = FactionPalette.relation(game.selection[0].owner_id, game.selection[0].alliance_id, game)
	if _preview_alliance != preview_relation:
		_preview_alliance = preview_relation
		$ModelPreviews.set_team(_preview_alliance)
	$TopLeft/Location.text = game.map_definition.display_name + "  ·  " + ("2v2 队伍战" if game.match_config.mode == "2v2" else "1v1 遭遇战")
	$MapFrame/MapTitle.text = game.map_definition.display_name
	timer_label.text = "%02d:%02d" % [int(game.elapsed) / 60, int(game.elapsed) % 60]
	objective_label.text = "摧毁敌队全部军事建筑"
	%EnemyCount.text = "已发现敌军 %d    击败 %d" % [game.enemy_count(), game.kills]
	_refresh_actions()
	if game.selection.is_empty():
		selected_name.text = "等待指令"
		selected_role.text = "你的军团"
		selected_role.modulate = Color("90bcda")
		selected_stats.text = "左键选择 · 拖动框选\n右键行军或攻击"
		selected_portrait.texture = portraits.headquarters
		_selected_preview = "headquarters"
		hp_bar.visible = false
		hp_label.visible = false
	elif game.selection.size() == 1:
		var entity = game.selection[0]
		selected_name.text = entity.display_name
		selected_role.text = "你的部队" if entity.owner_id == game.local_owner_id else ("盟友部队" if entity.alliance_id == player.alliance_id else "敌方部队")
		selected_role.modulate = FactionPalette.ui_color(FactionPalette.relation(entity.owner_id, entity.alliance_id, game))
		hp_bar.visible = true
		hp_label.visible = true
		if entity.is_in_group("resource_veins"):
			hp_bar.visible = false
			hp_label.visible = false
			selected_portrait.texture = portraits.gold_vein
			_selected_preview = "gold_vein"
			selected_role.text = "中立资源 · 金矿"
			selected_role.modulate = Color("e5c76b")
			selected_stats.text = "采集位置 %d / 6\n每人每 3 秒 +3 金币" % entity.occupied_slots()
		else:
			hp_bar.max_value = entity.max_hp
			hp_bar.value = entity.hp
			hp_label.text = "%d / %d" % [int(entity.hp), int(entity.max_hp)]
		if entity.is_in_group("units"):
			selected_portrait.texture = portraits[entity.unit_type]
			_selected_preview = entity.unit_type
			var definition := BalanceCatalog.unit(entity.unit_type)
			# Only the local player's upgrades are part of their private snapshot.
			var own_unit: bool = entity.owner_id == game.local_owner_id
			var attack_bonus: int = player.get_attack_bonus() if own_unit and definition.military else 0
			var defense_bonus: int = player.get_defense_bonus() if own_unit and definition.military else 0
			selected_stats.text = "%s攻 %d · 近甲 %d / 远甲 %d\n%s" % ["" if own_unit else "基础 ", definition.damage + attack_bonus, definition.melee_armor + defense_bonus, definition.ranged_armor + defense_bonus, entity.order_name]
			if entity.unit_type == "farmer":
				var queued_orders: int = int(entity.get_meta("replica_queue_count", 0)) if game.online and not game.is_authority else entity.waypoint_queue.size()
				selected_stats.text = "采矿 +3 / 3秒 · 建筑面板\n%s%s" % [entity.order_name, " · 队列 %d" % queued_orders if queued_orders > 0 else ""]
		elif entity.is_in_group("buildings"):
			var portrait_kind: String = entity.building_type if entity.building_type in portraits else "headquarters"
			selected_portrait.texture = portraits[portrait_kind]
			_selected_preview = portrait_kind
			selected_stats.text = "近甲 10 / 远甲 10\n" + entity.order_name
			if entity.owner_id == game.local_owner_id:
				var production: BuildingProduction = entity.get_node("Production")
				if not entity.is_constructed:
					selected_stats.text = "施工 %d%% · 农民右键接手\n取消返还未完成部分费用" % roundi(entity.construction_progress * 100)
				elif not production.training.is_empty():
					var queued_unit := BalanceCatalog.unit(production.training[0].kind)
					selected_stats.text = "%s训练 %.1f / %d 秒\n队列 %d / 10 · 点击格子取消退款" % [queued_unit.name, production.training[0].elapsed, queued_unit.training_seconds, production.training.size()]
				elif not production.research_id.is_empty():
					var upgrade := BalanceCatalog.upgrade(production.research_id)
					selected_stats.text = "%s · %s\n研究队列 %d / 6 · 点击格子取消退款" % [upgrade.name, "等待前置科技" if production.research_waiting_for_prerequisite() else "%d%%" % roundi(production.research_elapsed / upgrade.research_seconds * 100), production.research_queue.size()]

	else:
		selected_name.text = "%d 个单位与建筑" % game.selection.size()
		selected_role.text = "你的军团 · 联合编队"
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
		var production_focus: BattleBuilding = game.selected_production()
		var first = production_focus if production_focus != null else game.selection[0]
		if production_focus != null:
			selected_role.text = "生产：%s · Tab 切换类别" % production_focus.display_name
		_selected_preview = first.building_type if first is BattleBuilding else first.unit_type
		selected_portrait.texture = portraits[_selected_preview]
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
		button.tooltip_text = "编队 %d · %d 个单位或建筑\nCtrl + %d 覆盖 · Shift + %d 追加\n按 %d 召回 · 双按定位" % [index, count, index, index, index]

func _on_recruit(index: int) -> void:
	if index >= _actions.size():
		return
	var action: Dictionary = _actions[index]
	match action.kind:
		"build": game.set_build_mode(true, action.id)
		"recruit": game.recruit(action.id)
		"demolish": game.demolish_selected_towers()
		"research": game.research_selected(action.id)
		"cancel_site": game.submit_local({"kind": action.kind, "target": game.selected_production().entity_id})

func _refresh_actions() -> void:
	_actions.clear()
	%BuildPanel.hide()
	var building: BattleBuilding = game.selected_production()
	var workers: bool = building == null and not game.own_selected_workers().is_empty()
	$CommandBar/Recruitment/RecruitTitle.text = "建造" if workers else "生产与研究"
	%RecruitHint.text = "选中农民或生产建筑"
	if workers:
		%RecruitHint.text = "Shift 连续指派 · 单人施工"
		for kind: String in BUILD_ORDER:
			var definition := BalanceCatalog.building(kind)
			_actions.append({"kind": "build", "id": kind, "portrait": kind, "name": definition.name, "cost": definition.cost, "hint": "%d 秒施工" % definition.build_seconds})
	elif building != null:
		if not building.is_constructed:
			_actions.append({"kind": "cancel_site", "id": "", "portrait": building.building_type, "name": "取消施工", "cost": 0, "hint": "返还未完成部分的费用"})
		elif building.building_type == "defense_tower":
			_actions.append({"kind": "demolish", "id": "", "portrait": "defense_tower", "name": "拆除防御塔", "cost": 0, "hint": "Delete · 不返还金币"})
		elif building.building_type == "academy":
			var player: PlayerState = game.get_player(game.local_owner_id)
			for track: String in ["attack", "defense"]:
				var level: int = player.planned_upgrade_level(StringName(track))
				if level < 3:
					var upgrade := BalanceCatalog.upgrade("%s_%d" % [track, level + 1])
					_actions.append({"kind": "research", "id": upgrade.id, "portrait": track + "_upgrade", "name": upgrade.name, "cost": upgrade.cost, "hint": "%d 秒 · 全军总加成 +%d · 可连续加入队列" % [upgrade.research_seconds, upgrade.total_bonus]})
		else:
			for kind: String in building.get_combat_definition().produces:
				var definition := BalanceCatalog.unit(kind)
				_actions.append({"kind": "recruit", "id": kind, "portrait": kind, "name": definition.name, "cost": definition.cost, "hint": "训练 %d 秒 · 每座建筑最多 10 项" % definition.training_seconds})
		%RecruitHint.text = "右键设置集结点 · 研究取消全额退款" if building.building_type == "academy" else "右键设置集结点"
	for index in range(buttons.size()):
		var button := buttons[index]
		button.visible = index < _actions.size()
		if not button.visible:
			continue
		var action := _actions[index]
		button.get_node("Portrait").texture = portraits[action.portrait]
		button.get_node("Name").text = action.name
		button.get_node("Cost").text = "◈ %d" % action.cost if action.cost > 0 else ("无退款" if action.kind == "demolish" else "退款")
		button.get_node("Hotkey").text = ""
		button.tooltip_text = action.name + " · " + action.hint
		button.disabled = game.finished or game.gold < action.cost
		if action.kind in ["recruit", "research"]:
			var error := _queue_action_error(action)
			button.disabled = button.disabled or not error.is_empty()
			if not error.is_empty():
				button.tooltip_text += "\n" + error
	_refresh_queue(building)

func _queue_action_error(action: Dictionary) -> String:
	var error := "需要选中自己的生产建筑"
	for entity in game.selection:
		if entity is BattleBuilding and entity.alive and entity.owner_id == game.local_owner_id:
			error = entity.production.recruit_error(action.id) if action.kind == "recruit" else entity.production.research_error(action.id)
			if error.is_empty():
				return ""
	return error

func _refresh_queue(_building: BattleBuilding) -> void:
	_queue_actions.clear()
	var items: Array[Dictionary] = []
	var buildings: Array[BattleBuilding] = []
	var selected_ids: Array[int] = []
	for entity in game.selection:
		if entity is BattleBuilding and entity.alive and entity.owner_id == game.local_owner_id and entity.is_constructed:
			buildings.append(entity)
			selected_ids.append(entity.entity_id)
	if selected_ids != _queue_selection:
		_queue_page = 0
		_queue_selection = selected_ids
	for building: BattleBuilding in buildings:
		var production: BuildingProduction = building.production
		for index in range(production.training.size()):
			var job: Dictionary = production.training[index]
			var definition := BalanceCatalog.unit(job.kind)
			items.append({"portrait": job.kind, "name": definition.name, "source": building.display_name, "active": index == 0, "order": index + 1, "level": 0,
				"elapsed": float(job.elapsed), "duration": definition.training_seconds, "cost": int(job.cost), "waiting": false,
				"action": {"kind": "cancel_training", "target": building.entity_id, "job_id": job.job_id}})
		for index in range(production.research_queue.size()):
			var job: Dictionary = production.research_queue[index]
			var upgrade := BalanceCatalog.upgrade(job.id)
			items.append({"portrait": String(upgrade.track) + "_upgrade", "name": upgrade.name, "source": building.display_name, "active": index == 0, "order": index + 1, "level": upgrade.level,
				"elapsed": float(job.elapsed), "duration": upgrade.research_seconds, "cost": upgrade.cost,
				"waiting": index == 0 and production.research_waiting_for_prerequisite(),
				"action": {"kind": "cancel_research", "target": building.entity_id, "upgrade": job.id, "job_id": job.job_id}})
	_queue_page_count = maxi(1, ceili(float(items.size()) / _queue_buttons.size()))
	_queue_page = mini(_queue_page, _queue_page_count - 1)
	%QueueStrip.visible = not items.is_empty()
	$CommandBar/Recruitment/RecruitTitle.visible = items.is_empty()
	%RecruitHint.visible = items.is_empty()
	%QueueStrip.get_node("Caption").text = "队列 %d 项 · 点击取消" % items.size()
	%QueuePrevious.visible = _queue_page_count > 1
	%QueueNext.visible = _queue_page_count > 1
	%QueuePage.visible = _queue_page_count > 1
	%QueuePrevious.disabled = _queue_page == 0
	%QueueNext.disabled = _queue_page >= _queue_page_count - 1
	%QueuePage.text = "%d / %d" % [_queue_page + 1, _queue_page_count]
	for index in range(_queue_buttons.size()):
		var button: Button = _queue_buttons[index]
		var item_index: int = _queue_page * _queue_buttons.size() + index
		button.visible = item_index < items.size()
		if not button.visible:
			button.get_node("Cancel").hide()
			continue
		var item: Dictionary = items[item_index]
		_queue_actions.append(item.action)
		var active: bool = item.active
		var remaining: int = ceili(maxf(0.0, item.duration - item.elapsed))
		button.get_node("Portrait").texture = portraits[item.portrait]
		button.get_node("Level").visible = item.level > 0
		button.get_node("Level").text = ["", "I", "II", "III"][item.level]
		button.get_node("Progress").value = clampf(item.elapsed / item.duration, 0.0, 1.0)
		button.get_node("Progress").visible = active
		button.get_node("Status").text = ("等前置" if item.waiting else ("%ds" % remaining if remaining > 0 else "待出场")) if active else str(item.order)
		button.set_pressed_no_signal(active)
		button.disabled = game.finished
		var status: String = ("等待其他学院完成前置科技" if item.waiting else ("剩余 %d 秒" % remaining if remaining > 0 else "训练完成 · 等待出口空位")) if active else "等待中 · 第 %d 项" % item.order
		button.tooltip_text = "%s · %s · %s\n点击取消 · 返还 %d 金币" % [item.source, item.name, status, item.cost]
		if item.action.kind == "cancel_research":
			button.tooltip_text += "\n后续依赖此项的科技也会取消并退款"

func _turn_queue_page(direction: int) -> void:
	_queue_page = clampi(_queue_page + direction, 0, _queue_page_count - 1)
	_refresh_queue(game.selected_production())

func _on_queue_cancel(index: int) -> void:
	if index < _queue_actions.size() and not game.finished:
		game.submit_local(_queue_actions[index].duplicate())

func _on_queue_hover(index: int, entered: bool) -> void:
	_queue_buttons[index].get_node("Cancel").visible = entered
	if not entered:
		_set_preview_hover("")

func _on_building_action() -> void:
	if game.selection.size() == 1 and game.selection[0] is BattleBuilding and game.selection[0].is_constructed:
		game.demolish_selected_towers()
	else:
		game.cancel_selected_construction()

func _set_preview_hover(kind: String) -> void:
	_hovered_preview = "" if kind.ends_with("_upgrade") else kind

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
	$PauseOverlay/Paper/Title.text = "战场菜单" if game.online else "战斗已暂停"
	$PauseOverlay/Paper/Eyebrow.text = ("全局已暂停 · 房主按 P 继续" if get_tree().paused else "联机菜单 · 打开菜单不会暂停对局") if game.online else "ASHEN CROWN"
	%RestartButton.text = "返回大厅" if game.online else "重新开始"
	%PauseOverlay.visible = value

func show_result(victory: bool, duration: float, defeated: int) -> void:
	%ResultOverlay.visible = true
	%ResultHeading.text = "战场属于你" if victory else "你的队伍已战败"
	%ResultEyebrow.text = "VICTORY  /  胜利" if victory else "DEFEAT  /  战败"
	%ResultBody.text = ("敌队全部军事建筑已被摧毁。" if victory else "整顿军队，重新部署你的进攻。") + "\n\n用时 %02d:%02d      击败敌军 %d" % [int(duration) / 60, int(duration) % 60, defeated]
