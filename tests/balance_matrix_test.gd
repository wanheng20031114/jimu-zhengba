extends SceneTree
## Approved damage tables, all sixteen upgrade matchups, immutable launch data.

const KINDS: Array[StringName] = [&"swordsman", &"archer", &"knight", &"catapult", &"cannon", &"farmer"]
const EXPECTED_DAMAGE: Array = [
	[18, 20, 24, 20, 20, 20],
	[11, 12, 8, 8, 6, 12],
	[17, 30, 17, 19, 19, 19],
	[43, 26, 44, 72, 70, 26],
	[29, 30, 26, 126, 124, 30],
	[6, 8, 6, 8, 8, 8],
]
const EXPECTED_HITS: Array = [
	[6, 3, 5, 10, 13, 4], [10, 5, 15, 25, 44, 7],
	[6, 2, 8, 11, 14, 4], [3, 3, 3, 3, 4, 3],
	[4, 2, 5, 2, 3, 3], [17, 8, 20, 25, 33, 10],
]
const BUILDING_DAMAGE: Array[int] = [10, 2, 9, 96, 220, 1]
const BONUS: Array[int] = [0, 1, 2, 4]
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func _run() -> void:
	for attacker_index: int in range(KINDS.size()):
		var attacker: UnitDefinition = BalanceCatalog.unit(KINDS[attacker_index])
		for defender_index: int in range(KINDS.size()):
			var defender: UnitDefinition = BalanceCatalog.unit(KINDS[defender_index])
			var label: String = "%s -> %s" % [attacker.id, defender.id]
			var base: float = float(EXPECTED_DAMAGE[attacker_index][defender_index])
			var unupgraded: DamagePayload = DamageResolver.snapshot(attacker, 0, 0, 0)
			var actual: float = DamageResolver.resolve(unupgraded, defender)
			_check(is_equal_approx(actual, base), label + " approved base damage")
			_check(ceili(defender.hp / actual) == EXPECTED_HITS[attacker_index][defender_index], label + " full-health hit count")
			for attack_level: int in range(4):
				for defense_level: int in range(4):
					var attack_bonus: float = BONUS[attack_level] if attacker.military else 0
					var defense_bonus: float = BONUS[defense_level] if defender.military else 0
					var packet: DamagePayload = DamageResolver.snapshot(attacker, attack_bonus, 3, 1)
					var expected: float = maxf(1.0, base + attack_bonus - defense_bonus)
					_check(is_equal_approx(DamageResolver.resolve(packet, defender, defense_bonus), expected), label + " upgrade %d/%d" % [attack_level, defense_level])
		for key: String in BalanceCatalog.BUILDINGS:
			var structure: BuildingDefinition = BalanceCatalog.building(key)
			_check(structure.hp >= 1000 and structure.melee_armor == 10 and structure.ranged_armor == 10, key + " durable ten-armor structure")
			for attack_level: int in range(4):
				var bonus: float = BONUS[attack_level] if attacker.military else 0
				var damage: float = DamageResolver.resolve(DamageResolver.snapshot(attacker, bonus, 0, 0), structure)
				_check(is_equal_approx(damage, BUILDING_DAMAGE[attacker_index] + bonus), str(attacker.id) + " building damage " + key + " level " + str(attack_level))
	_test_upgrade_catalog()
	_test_snapshot()
	_test_siege()
	_test_production_data()
	var report := {"checks": checks, "failures": failures}
	var file := FileAccess.open("res://artifacts/balance_matrix_results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("BALANCE_MATRIX ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)

func _test_upgrade_catalog() -> void:
	var costs: Dictionary = {&"attack": [100, 250, 500], &"defense": [150, 300, 600]}
	var times: Dictionary = {&"attack": [20, 35, 50], &"defense": [25, 40, 60]}
	for track: StringName in [&"attack", &"defense"]:
		for level: int in range(1, 4):
			var upgrade: UpgradeDefinition = BalanceCatalog.upgrade(StringName("%s_%d" % [track, level]))
			_check(upgrade.track == track and upgrade.level == level and upgrade.total_bonus == BONUS[level], upgrade.name + " cumulative bonus")
			_check(upgrade.cost == costs[track][level - 1] and upgrade.research_seconds == times[track][level - 1], upgrade.name + " approved cost/time")

func _test_snapshot() -> void:
	var local_definition: UnitDefinition = BalanceCatalog.unit(&"cannon").duplicate(true)
	var packet: DamagePayload = DamageResolver.snapshot(local_definition, 2, 3, 1)
	local_definition.damage = 999
	local_definition.bonuses[&"siege"] = 999
	_check(packet.base_damage == 30 and packet.attack_bonus == 2 and packet.bonuses[&"siege"] == 100, "launch packet copies attacks and bonuses")
	_check(packet.owner_id == 3 and packet.alliance_id == 1, "launch packet retains player/alliance independently")
	_check(DamageResolver.resolve(packet, BalanceCatalog.unit(&"catapult"), 4) == 124, "impact reads current defense without changing launch attack")
	_check(BalanceCatalog.unit(&"cannon").damage == 30 and BalanceCatalog.unit(&"cannon").bonuses[&"siege"] == 100, "catalog resource stays immutable")

func _test_siege() -> void:
	_check(DamageResolver.stone_falloff(0) == 1 and DamageResolver.stone_falloff(1.2) == 1, "stone full-strength core")
	_check(is_equal_approx(DamageResolver.stone_falloff(2.1), 0.75), "stone annulus midpoint")
	_check(DamageResolver.stone_falloff(3) == 0.5, "stone half-strength outer edge")
	var stone: DamagePayload = DamageResolver.snapshot(BalanceCatalog.unit(&"catapult"), 0, 0, 0)
	_check(DamageResolver.resolve(stone, BalanceCatalog.unit(&"swordsman"), 0, 0.5) == 21, "stone attenuation precedes armor")
	var catapult := BalanceCatalog.unit(&"catapult")
	_check(catapult.range == 14 and catapult.damage == 26 and catapult.cost == 180 and catapult.hp == 200 and catapult.cooldown == 3, "catapult trades reach for higher damage without changing cost, health or cadence")
	_check(BalanceCatalog.unit(&"catapult").min_range == 3 and BalanceCatalog.unit(&"cannon").min_range == 2.5, "siege minimum ranges")
	_check(is_equal_approx(BalanceCatalog.unit(&"cannon").cooldown, 3.2), "cannon uses approved 3.2-second cycle")

func _test_production_data() -> void:
	_check(BalanceCatalog.building(&"headquarters").produces == PackedStringArray(["farmer"]), "HQ recruits farmers only")
	_check(BalanceCatalog.building(&"barracks").produces == PackedStringArray(["swordsman", "archer", "knight"]), "barracks recruits three troop classes")
	_check(BalanceCatalog.building(&"factory").produces == PackedStringArray(["catapult", "cannon"]), "factory recruits siege engines")
	_check(BalanceCatalog.unit(&"farmer").training_seconds == 10, "farmer training takes ten seconds")
	for kind: StringName in KINDS:
		var definition: UnitDefinition = BalanceCatalog.unit(kind)
		var supply: Dictionary = {&"swordsman": 1, &"archer": 1, &"knight": 2, &"catapult": 3, &"cannon": 3, &"farmer": 0}
		_check(definition.supply == supply[kind], str(kind) + " approved military supply")
		_check(BalanceCatalog.building(definition.production_building).produces.has(String(kind)), str(kind) + " production source agrees with building")
		if definition.military:
			var training: Dictionary = {&"swordsman": 6.0, &"archer": 8.0, &"knight": 10.0, &"catapult": 20.0, &"cannon": 20.0}
			_check(definition.training_seconds == training[kind], str(kind) + " timed military production")
	_check(BalanceCatalog.building(&"defense_tower").cost == 100 and BalanceCatalog.building(&"defense_tower").build_seconds == 20, "tower preserves hundred-gold twenty-second contract")
