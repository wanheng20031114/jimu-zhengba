extends SceneTree
## Command-level strategy scenarios; actual entity combat is covered by balance tests.
const BOT: GDScript = preload("res://scripts/skirmish_bot.gd")
var host: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func _fresh() -> void:
	change_scene_to_file("res://tests/bot_test_host.tscn")
	await scene_changed
	host = current_scene

func _opening() -> void:
	host.add_building("headquarters", 0, Vector3(-30, 0, 0))
	host.add_mine(Vector3(-22, 0, 0))
	host.add_mine(Vector3(0, 0, 8))
	for index: int in range(3): host.add_unit("farmer", 0, Vector3(-24, 0, index))

func _ready_base(army: Array[String]) -> void:
	host.add_building("headquarters", 0, Vector3(-30, 0, 0))
	host.add_building("barracks", 0, Vector3(-20, 0, 0))
	host.add_building("factory", 0, Vector3(-30, 0, 8))
	host.add_building("academy", 0, Vector3(-36, 0, -6))
	host.players[0].farmers = 10
	host.players[0].active_research = {"id": "attack_1", "remaining": 9999.0}
	for kind: String in army: host.add_unit(kind, 0, Vector3(-22, 0, 0))

func _run() -> void:
	await _fresh()
	_opening()
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(0.5)
	_check(host.commands.is_empty(), "AI does not issue commands above one Hz")
	bot.tick(0.5)
	_check(host.commands.any(func(c: Dictionary) -> bool: return c.kind == "build" and c.building_type == "barracks"), "first decision orders the 150-gold barracks")
	_check(host.total_spent == 200 and host.players[0].gold == 120, "opening pays for barracks and one ten-second farmer")
	for second: int in range(1, 46):
		host.advance(1.0)
		bot.tick(1.0)
		_check(host.players[0].gold >= 0, "opening second %d never spends free gold" % second)
	var military: Array = host.commands.filter(func(c: Dictionary) -> bool: return c.kind == "recruit" and c.unit_type != "farmer")
	_check(military.size() >= 3, "opening fields a three-unit raiding party within 45 seconds")
	_check(bot.army_state == &"attack", "three-unit army commits to an attack by 45 seconds")
	var composition: Dictionary = {}
	for command: Dictionary in military: composition[command.unit_type] = true
	_check(composition.size() >= 3, "opening recruits swords, archers and cavalry")
	_check(host.players[0].farmers + host.players[0].reserved_farmers <= 10, "opening respects the farmer reservation cap")
	var last_sequence: int = 0
	for command: Dictionary in host.commands:
		_check(int(command.seq) > last_sequence, "command sequence monotonically advances")
		last_sequence = command.seq
	await _fog_memory_case()
	await _siege_and_supply_case()
	await _defense_tower_budget_case()
	await _retreat_and_ally_case()
	await _technology_and_lane_search_case()
	await _workforce_expansion_case()
	await _army_expansion_case()
	await _mining_research_case()
	await _special_research_case()
	await _deferred_and_client_case()
	await _physics_frequency_case()
	await _takeover_without_headquarters_case()
	await _timed_queue_case()
	var file := FileAccess.open("res://artifacts/bot_strategy_results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
	file.close()
	print("BOT_STRATEGY ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _fog_memory_case() -> void:
	await _fresh()
	_ready_base(["swordsman", "archer", "knight"])
	host.players[0].gold = 0
	var enemy: Node3D = host.add_unit("knight", 1, Vector3(20, 0, 0))
	host.visibility[enemy.entity_id] = true
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(1.0)
	var known_position: Vector3 = bot._memory[enemy.entity_id].position
	host.visibility[enemy.entity_id] = false
	enemy.unit_type = "cannon"
	enemy.position = Vector3(50, 0, 40)
	enemy.hp = 1
	enemy.privacy_watch = true
	bot.tick(1.0)
	_check(enemy.privacy_reads == 0, "hidden enemy identity and health are never inspected")
	_check(bot._memory[enemy.entity_id].kind == "knight" and bot._memory[enemy.entity_id].position == known_position, "fog memory retains observation rather than hidden live state")
	_check(float(bot._composition().knight) > 0 and float(bot._composition().siege) == 0, "recruitment uses remembered visible composition")
	bot.tick(26.0)
	_check(not bot._memory.has(enemy.entity_id), "stale mobile-unit memory expires")
	_check(not host.commands.any(func(c: Dictionary) -> bool: return c.kind == "attack" and int(c.get("target", 0)) == enemy.entity_id), "bot never commands a direct attack on a hidden target")

func _siege_and_supply_case() -> void:
	await _fresh()
	_ready_base(["swordsman", "swordsman", "swordsman", "archer", "archer", "knight"])
	host.players[0].gold = 300
	var tower: Node3D = host.add_building("defense_tower", 1, Vector3(25, 0, 0))
	host.visibility[tower.entity_id] = true
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(1.0)
	var recruits: Array = host.commands.filter(func(c: Dictionary) -> bool: return c.kind == "recruit")
	_check(not recruits.is_empty() and recruits[0].unit_type == "cannon", "observed defensive position triggers a paid counter-siege cannon")
	_check(host.players[0].gold == 300 - host.total_spent and host.total_spent >= BalanceCatalog.unit(&"cannon").cost, "counter siege pays the full catalog price")
	await _fresh()
	_ready_base(["swordsman", "archer", "knight"])
	host.players[0].gold = 1000
	host.players[0].military_supply = 49
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(host.players[0].military_supply <= 50, "AI accounts for cavalry/siege supply weights at the default cap")

func _defense_tower_budget_case() -> void:
	await _fresh()
	_opening()
	host.add_building("barracks", 0, Vector3(-20, 0, 0))
	for kind: String in ["swordsman", "archer", "knight"]:
		host.add_unit(kind, 0, Vector3(-22, 0, 0))
	for index in range(3):
		var intruder: Node3D = host.add_unit("knight", 1, Vector3(-25, 0, index))
		host.visibility[intruder.entity_id] = true
	host.players[0].gold = 149
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(1.0)
	_check(not host.commands.any(func(c: Dictionary) -> bool: return c.kind == "build" and c.building_type == "defense_tower"), "emergency tower cannot be built with only 149 gold")
	_check(host.players[0].gold == 149 and host.total_spent == 0, "emergency tower saves all 150 gold instead of spending the shortfall on units")
	host.players[0].gold = 150
	bot.tick(1.0)
	_check(host.commands.any(func(c: Dictionary) -> bool: return c.kind == "build" and c.building_type == "defense_tower")
		and host.total_spent == 150 and host.players[0].gold == 0, "emergency tower is commissioned immediately when 150 gold is available")
	for next_price: int in [185, 225, 255, 280, 270]:
		for tower: Node3D in host.owned_entities(0, "buildings"):
			if tower.building_type == "defense_tower":
				tower.alive = false
		# Actual workers leave a destroyed construction target on the next fixed
		# step; this command-only fixture must advance that lifecycle explicitly.
		for builder: Node3D in host.owned_entities(0, "units"):
			if builder.unit_type == "farmer" and builder.order == BattleUnit.Order.BUILD:
				host._set_worker_order(builder, BattleUnit.Order.IDLE, null)
		var spending_before: int = host.total_spent
		host.players[0].gold = next_price - 1
		bot.tick(4.0)
		_check(host.total_spent == spending_before and host.players[0].gold == next_price - 1, "replacement tower reserves current ladder quote without starving savings: " + str(next_price))
		host.players[0].gold = next_price
		bot.tick(1.0)
		_check(host.total_spent == spending_before + next_price and host.players[0].gold == 0, "Bot pays current replacement price after previous tower destruction: " + str(next_price))

func _retreat_and_ally_case() -> void:
	await _fresh()
	_ready_base(["swordsman", "swordsman", "swordsman"])
	host.players[0].gold = 0
	for unit: Node3D in host.owned_entities(0, "units"): unit.position = Vector3.ZERO
	for index: int in range(6):
		var enemy: Node3D = host.add_unit("knight", 1, Vector3(2, 0, index))
		host.visibility[enemy.entity_id] = true
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(35.0)
	_check(bot.army_state == &"retreat", "outmatched field army retreats instead of feeding units")
	_check(host.commands.back().kind == "move" and not host.commands.back().attack_move, "retreat is a movement order without chasing")
	await _fresh()
	_ready_base(["swordsman", "archer", "knight"])
	host.players[0].gold = 0
	host.add_building("headquarters", 2, Vector3(0, 0, 22))
	var intruder: Node3D = host.add_unit("archer", 1, Vector3(2, 0, 22))
	host.visibility[intruder.entity_id] = true
	bot = BOT.new(host, 0)
	bot.tick(35.0)
	_check(bot.army_state == &"ally_rescue", "shared vision triggers relief of an allied base")
	_check(host.commands.back().kind == "attack" and host.commands.back().target == intruder.entity_id, "ally relief targets the visible hostile unit")

func _deferred_and_client_case() -> void:
	await _fresh()
	_opening()
	host.defer_commands = true
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(1.0)
	var accepted_cost: int = 0
	for command: Dictionary in host.commands: accepted_cost += int(command.cost)
	_check(accepted_cost <= 320, "one decision reserves accepted spend even when authority executes next tick")
	var before: int = host.commands.size()
	host.is_authority = false
	bot.tick(60.0)
	_check(host.commands.size() == before, "client replica never runs AI or submits bot commands")

func _technology_and_lane_search_case() -> void:
	await _fresh()
	_ready_base(["swordsman", "swordsman", "swordsman", "swordsman", "archer", "archer", "knight", "knight"])
	host.players[0].gold = 20000
	host.players[0].active_research.clear()
	var bot: RefCounted = BOT.new(host, 0)
	for second: int in range(400):
		bot.tick(1.0)
		host.advance(1.0)
	var research: Array = host.commands.filter(func(c: Dictionary) -> bool: return c.kind == "research" and BalanceCatalog.upgrade(c.upgrade).track in [&"attack", &"defense"])
	var expected: Array[String] = ["defense_1", "attack_1", "defense_2", "attack_2", "defense_3", "attack_3"]
	_check(research.size() == 6, "developed economy researches exactly six nonduplicate combat upgrades alongside expansion")
	for index: int in range(mini(research.size(), expected.size())):
		_check(research[index].upgrade == expected[index], "research step %d obeys the sequential attack/defense plan" % index)
	_check(host.players[0].attack_level == 3 and host.players[0].defense_level == 3, "bot completes both military technology branches")
	await _fresh()
	_ready_base(["swordsman", "archer", "knight"])
	host.players[0].gold = 0
	host.owned_entities(0, "buildings")[0].position = Vector3(-30, 0, -25)
	host.add_building("headquarters", 2, Vector3(-30, 0, 25))
	for unit: Node3D in host.owned_entities(0, "units"): unit.position = Vector3(30, 0, 0)
	var concealed_hq: Node3D = host.add_building("headquarters", 1, Vector3(30, 0, -25))
	host.visibility[concealed_hq.entity_id] = false
	concealed_hq.privacy_watch = true
	bot = BOT.new(host, 0)
	bot.tick(35.0)
	_check(host.commands.back().kind == "move" and absf(float(host.commands.back().at[2])) == 20.0, "2v2 army searches a flank after reaching the empty enemy center")
	_check(concealed_hq.privacy_reads == 0, "lane scouting never reads concealed headquarters data")

func _physics_frequency_case() -> void:
	await _fresh()
	_opening()
	var bot: RefCounted = BOT.new(host, 0)
	for tick: int in range(29): bot.tick(1.0 / 30.0)
	_check(host.commands.is_empty(), "29 native 30-TPS ticks have not reached an AI decision")
	bot.tick(1.0 / 30.0)
	_check(not host.commands.is_empty(), "30 native ticks make one decision without floating-point delay")
	var before: int = host.commands.size()
	bot.tick(1.0 / 30.0)
	_check(host.commands.size() == before, "rounding at the first second does not cause a duplicate decision next tick")

func _takeover_without_headquarters_case() -> void:
	await _fresh()
	var ally_hq: Node3D = host.add_building("headquarters", 2, Vector3(30, 0, 20))
	var ally_worker: Node3D = host.add_unit("farmer", 2, Vector3(28, 0, 20))
	var barracks: Node3D = host.add_building("barracks", 0, Vector3(-30, 0, -12))
	var worker: Node3D = host.add_unit("farmer", 0, Vector3(-24, 0, -12))
	host.add_unit("swordsman", 0, Vector3(-20, 0, -12))
	host.players[0].gold = 400
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(1.0)
	_check(bot._home_known and bot._home == barracks.global_position, "HQ-less takeover anchors to a surviving own building before a worker or army")
	var builds: Array = host.commands.filter(func(c: Dictionary) -> bool: return c.kind == "build")
	_check(builds.size() == 1 and builds[0].building_type == "headquarters" and builds[0].units == [worker.entity_id], "HQ-less takeover uses its own farmer to submit the headquarters rebuild")
	_check(host.total_spent == 400 and host.players[0].gold == 0, "takeover rebuild pays the full 400 gold before military recruitment")
	_check(host.commands.all(func(c: Dictionary) -> bool: return not c.get("units", []).has(ally_worker.entity_id) and int(c.get("target", 0)) != ally_hq.entity_id), "takeover never commands the allied farmer or recruits through the allied HQ")
	_check(host.owned_entities(0, "buildings").any(func(b: Node3D) -> bool: return b.building_type == "headquarters" and not b.is_constructed), "takeover rebuild command creates an owned HQ construction site")
	await _fresh()
	worker = host.add_unit("farmer", 0, Vector3(-19, 0, 8))
	var worker_home: Vector3 = worker.global_position
	host.players[0].gold = 400
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(bot._home_known and bot._home == worker_home, "farmer-only takeover establishes a home from its own worker")
	_check(host.commands.any(func(c: Dictionary) -> bool: return c.kind == "build" and c.building_type == "headquarters" and c.units == [worker.entity_id]), "farmer-only takeover can rebuild without any prior base history")
	await _fresh()
	var soldier: Node3D = host.add_unit("swordsman", 0, Vector3(-15, 0, 6))
	var soldier_home: Vector3 = soldier.global_position
	var ally_soldier: Node3D = host.add_unit("knight", 2, Vector3(-10, 0, 6))
	host.players[0].gold = 0
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(bot._home_known and bot._home == soldier_home, "army-only takeover retains an operational home")
	_check(host.commands.size() == 1 and host.commands[0].kind == "move" and host.commands[0].units == [soldier.entity_id], "army-only takeover commands its surviving soldier without controlling the allied soldier")
	_check(ally_soldier.global_position == Vector3(-10, 0, 6), "army-only takeover leaves allied units in place")
	await _fresh()
	barracks = host.add_building("barracks", 0, Vector3(-30, 0, 0))
	host.players[0].gold = 45
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(host.commands.size() == 1 and host.commands[0].kind == "recruit" and host.commands[0].target == barracks.entity_id and host.commands[0].unit_type == "swordsman", "barracks-only takeover spends available gold instead of reserving an impossible HQ rebuild")
	_check(host.total_spent == 45 and host.players[0].gold == 0, "barracks-only takeover pays the full military price")
	await _fresh()
	host.add_building("barracks", 0, Vector3(-30, 0, 0))
	host.add_unit("farmer", 0, Vector3(-24, 0, 0))
	host.players[0].gold = 399
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(host.commands.is_empty() and host.players[0].gold == 399, "a surviving farmer preserves the 400-gold rebuild priority ahead of recruiting")
	await _fresh()
	var factory: Node3D = host.add_building("factory", 0, Vector3(-30, 0, 0))
	host.players[0].gold = BalanceCatalog.unit(&"catapult").cost
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(host.commands.size() == 1 and host.commands[0].kind == "recruit" and host.commands[0].target == factory.entity_id and host.commands[0].unit_type == "catapult", "factory-only takeover recruits through its remaining completed producer")
	_check(host.total_spent == BalanceCatalog.unit(&"catapult").cost and host.players[0].military_supply == 3, "factory-only takeover pays the catalog price and siege supply")
	await _fresh()
	factory = host.add_building("factory", 0, Vector3(-30, 0, 0))
	var tower: Node3D = host.add_building("defense_tower", 1, Vector3(20, 0, 0))
	host.visibility[tower.entity_id] = true
	host.players[0].gold = BalanceCatalog.unit(&"cannon").cost
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(host.commands.size() == 1 and host.commands[0].unit_type == "cannon" and host.commands[0].target == factory.entity_id and host.total_spent == BalanceCatalog.unit(&"cannon").cost, "factory-only takeover uses observed fortifications to choose a fully paid cannon")
	await _fresh()
	host.add_building("headquarters", 2, Vector3(-30, 0, 10))
	host.add_unit("farmer", 2, Vector3(-24, 0, 10))
	host.add_unit("swordsman", 2, Vector3(-20, 0, 10))
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(not bot._home_known and host.commands.is_empty(), "allied assets alone never initialize a defeated owner's takeover home")

func _timed_queue_case() -> void:
	await _fresh()
	_ready_base([])
	host.defer_commands = true
	host.players[0].gold = 10000
	var barracks: Node3D = host.owned_entities(0, "buildings").filter(func(b): return b.building_type == "barracks")[0]
	var second: Node3D = host.add_building("barracks", 0, Vector3(-18, 0, 10))
	for index in range(10):
		barracks.production.training.append({"kind": "swordsman", "elapsed": 0.0})
	host.players[0].reserved_military_supply = 10
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(1.0)
	var recruits: Array = host.commands.filter(func(c): return c.kind == "recruit" and c.unit_type != "farmer")
	_check(recruits.size() == 3 and recruits.all(func(c): return c.target == second.entity_id), "bot directs military purchases to the nonfull second barracks")
	_check(recruits[0].unit_type != "swordsman", "already queued swordsmen count toward desired army composition")
	host.commands.clear()
	host.players[0].reserved_military_supply = 50
	bot.tick(1.0)
	_check(not host.commands.any(func(c): return c.kind == "recruit" and c.unit_type != "farmer"), "reserved military supply blocks further bot purchases")
	host.players[0].reserved_military_supply = 20
	for index in range(10):
		second.production.training.append({"kind": "archer", "elapsed": 0.0})
	host.commands.clear()
	bot.tick(1.0)
	_check(not host.commands.any(func(c): return c.kind == "recruit" and c.unit_type in ["swordsman", "archer", "knight"]), "full native-size queues do not produce repeated rejected bot orders")

func _workforce_expansion_case() -> void:
	await _fresh()
	_ready_base(["swordsman", "swordsman", "archer", "archer", "knight", "knight", "swordsman", "archer"])
	host.players[0].active_research.clear()
	host.players[0].farmers = 0
	for index in range(10):
		host.add_unit("farmer", 0, Vector3(-24, 0, index * 0.5))
	host.add_mine(Vector3(-24, 0, -8))
	var second: ResourceVein = host.add_mine(Vector3(-22, 0, 8))
	host.visibility[second.entity_id] = false
	host.players[0].gold = 125
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(1.0)
	_check(not host.commands.any(func(c): return c.kind == "research" and c.upgrade == "workforce_1"), "bot does not expand workforce without a discovered second mine")
	host.visibility[second.entity_id] = true
	host.players[0].gold = 125
	var spent_before: int = host.total_spent
	bot.tick(1.0)
	_check(host.commands.any(func(c): return c.kind == "research" and c.upgrade == "workforce_1" and c.cost == 125), "bot submits a paid workforce research through the shared command entry")
	_check(host.total_spent == spent_before + 125 and host.players[0].gold == 0, "workforce expansion charges exactly 125 gold")
	_check(host.players[0].get_worker_limit() == 10, "bot research does not grant early worker slots")
	for second_index in range(23):
		host.advance(1.0)
		bot.tick(1.0)
	_check(host.players[0].get_worker_limit() == 10 and host.players[0].farmers + host.players[0].reserved_farmers == 10, "bot holds ten workers until the full research time elapses")
	host.advance(1.0)
	_check(host.players[0].get_worker_limit() == 12, "bot receives two worker slots at research completion")
	for second_index in range(60):
		bot.tick(1.0)
		host.advance(1.0)
	_check(host.players[0].farmers == 12 and host.players[0].reserved_farmers == 0, "expanded bot trains the eleventh and twelfth farmers normally")
	_check(host.commands.filter(func(c): return c.kind == "research" and c.upgrade == "workforce_1").size() == 1, "bot never researches the one-time expansion twice")
	_check(host.players[1].get_worker_limit() == 10 and host.players[2].get_worker_limit() == 10, "bot expansion does not improve allies or opponents")

func _army_expansion_case() -> void:
	await _fresh()
	_ready_base(["swordsman", "swordsman", "archer", "archer", "knight", "knight", "swordsman", "archer"])
	var player: PlayerState = host.players[0]
	player.active_research.clear()
	player.military_supply = 45
	player.gold = 499
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(1.0)
	_check(host.total_spent == 0 and player.gold == 499, "near-cap bot saves for the 500-gold expansion without overspending")
	player.gold = 500
	bot.tick(1.0)
	_check(host.commands.any(func(c): return c.kind == "research" and c.upgrade == "army_capacity_1" and c.cost == 500), "near-cap bot orders paid army expansion I")
	_check(player.get_supply_limit() == 50, "queued expansion gives no early military population")
	host.advance(29.0)
	_check(player.get_supply_limit() == 50, "army expansion waits its full thirty seconds")
	host.advance(1.0)
	_check(player.get_supply_limit() == 75, "army expansion I completes at seventy-five population")
	player.military_supply = 70
	player.gold = 500
	bot.tick(30.0)
	_check(host.commands.any(func(c): return c.kind == "research" and c.upgrade == "army_capacity_2" and c.cost == 500), "near second cap bot orders the second paid expansion")
	host.advance(30.0)
	_check(player.get_supply_limit() == 100 and host.players[1].get_supply_limit() == 50, "second expansion reaches one hundred for its owner only")
	player.military_supply = 100
	player.gold = 1000
	var count_before: int = host.commands.size()
	bot.tick(30.0)
	var latest: Array = host.commands.slice(count_before)
	_check(not latest.any(func(c): return c.kind == "recruit" or (c.kind == "research" and String(c.upgrade).begins_with("army_capacity"))), "fully expanded bot neither researches a third level nor overproduces")

func _mining_research_case() -> void:
	await _fresh()
	_ready_base(["swordsman", "swordsman", "archer", "archer", "knight", "knight", "swordsman", "archer"])
	var player: PlayerState = host.players[0]
	player.active_research.clear()
	player.farmers = 0
	for index in range(6):
		host.add_unit("farmer", 0, Vector3(-24, 0, index * 0.5))
	host.add_mine(Vector3(-24, 0, -8))
	player.gold = 139
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(1.0)
	_check(not host.commands.any(func(c): return c.kind == "research" and String(c.upgrade).begins_with("mining")), "mining research preserves a ninety-gold reinforcement budget")
	var costs: Array[int] = [50, 150, 300]
	var seconds: Array[float] = [15.0, 25.0, 35.0]
	for level in range(1, 4):
		player.gold = costs[level - 1] + 90
		bot.tick(1.0 if level == 1 else seconds[level - 2])
		var id := "mining_%d" % level
		_check(host.commands.any(func(c): return c.kind == "research" and c.upgrade == id and c.cost == costs[level - 1]), "developed bot researches " + id + " at its catalog price")
		_check(player.mining_level == level - 1, "mining upgrade does not apply before completion " + id)
		host.advance(seconds[level - 1])
		_check(player.mining_level == level and is_equal_approx(player.get_mining_rate_multiplier(), 1.0 + level * 0.1), "completed mining upgrade applies its total percentage " + id)
	_check(host.players[1].mining_level == 0 and host.players[2].mining_level == 0, "mining research remains independent between owners and allies")

func _special_research_case() -> void:
	await _fresh()
	_ready_base(["cannon", "swordsman", "swordsman", "archer", "archer", "knight", "knight", "swordsman"])
	var player: PlayerState = host.players[0]
	player.active_research.clear()
	player.attack_level = 3
	player.defense_level = 3
	player.mining_level = 3
	player.workforce_level = 1
	player.recovery_level = 1
	player.farmers = 12
	player.gold = 329
	var bot: RefCounted = BOT.new(host, 0)
	bot.tick(1.0)
	_check(not host.commands.any(func(c): return c.kind == "research" and c.upgrade == "cannon_range_1"), "bot cannon range preserves ninety gold for reinforcements")
	player.gold = 330
	bot.tick(1.0)
	_check(host.commands.any(func(c): return c.kind == "research" and c.upgrade == "cannon_range_1" and c.cost == 240), "bot with cannon submits paid 240 gold range research")
	_check(player.cannon_range_level == 0, "bot range does not apply at purchase")
	host.advance(29.0)
	_check(player.cannon_range_level == 0, "bot range observes full thirty second research")
	host.advance(1.0)
	_check(player.cannon_range_level == 1 and host.players[1].cannon_range_level == 0, "bot range completion affects only the researching owner")
	player.recovery_level = 0
	player.gold = 190
	bot.tick(30.0)
	_check(host.commands.any(func(c): return c.kind == "research" and c.upgrade == "recovery_1" and c.cost == 100), "developed bot invests one hundred real gold in recovery")
	_check(player.recovery_level == 0, "bot recovery waits for completion")
	host.advance(20.0)
	_check(player.recovery_level == 1 and host.players[1].recovery_level == 0, "bot recovery completes at twenty seconds without helping allies")
	player.gold = 1000
	bot.tick(30.0)
	_check(host.commands.filter(func(c): return c.kind == "research" and c.upgrade == "cannon_range_1").size() == 1 and host.commands.filter(func(c): return c.kind == "research" and c.upgrade == "recovery_1").size() == 1, "bot never researches either single-level track twice")
