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
	await _retreat_and_ally_case()
	await _technology_and_lane_search_case()
	await _deferred_and_client_case()
	await _physics_frequency_case()
	await _takeover_without_headquarters_case()
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
	_check(host.players[0].gold == 300 - host.total_spent and host.total_spent >= 240, "counter siege pays the full catalog price")
	await _fresh()
	_ready_base(["swordsman", "archer", "knight"])
	host.players[0].gold = 1000
	host.players[0].military_supply = 59
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(host.players[0].military_supply <= 60, "AI accounts for cavalry/siege supply weights at the cap")

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
	host.players[0].gold = 5000
	host.players[0].active_research.clear()
	var bot: RefCounted = BOT.new(host, 0)
	for second: int in range(250):
		bot.tick(1.0)
		host.advance(1.0)
	var research: Array = host.commands.filter(func(c: Dictionary) -> bool: return c.kind == "research")
	var expected: Array[String] = ["defense_1", "attack_1", "defense_2", "attack_2", "defense_3", "attack_3"]
	_check(research.size() == 6, "developed economy researches exactly six nonduplicate upgrades")
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
	host.players[0].gold = 180
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(host.commands.size() == 1 and host.commands[0].kind == "recruit" and host.commands[0].target == factory.entity_id and host.commands[0].unit_type == "catapult", "factory-only takeover recruits through its remaining completed producer")
	_check(host.total_spent == 180 and host.players[0].military_supply == 3, "factory-only takeover pays the catalog price and siege supply")
	await _fresh()
	factory = host.add_building("factory", 0, Vector3(-30, 0, 0))
	var tower: Node3D = host.add_building("defense_tower", 1, Vector3(20, 0, 0))
	host.visibility[tower.entity_id] = true
	host.players[0].gold = 240
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(host.commands.size() == 1 and host.commands[0].unit_type == "cannon" and host.commands[0].target == factory.entity_id and host.total_spent == 240, "factory-only takeover uses observed fortifications to choose a fully paid cannon")
	await _fresh()
	host.add_building("headquarters", 2, Vector3(-30, 0, 10))
	host.add_unit("farmer", 2, Vector3(-24, 0, 10))
	host.add_unit("swordsman", 2, Vector3(-20, 0, 10))
	bot = BOT.new(host, 0)
	bot.tick(1.0)
	_check(not bot._home_known and host.commands.is_empty(), "allied assets alone never initialize a defeated owner's takeover home")
