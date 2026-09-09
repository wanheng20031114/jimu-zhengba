extends SceneTree
## Approved damage tables, all sixteen upgrade matchups, immutable launch data.

const KINDS: Array[StringName] = [&"swordsman", &"archer", &"knight", &"catapult", &"cannon", &"farmer"]
const EXPECTED_DAMAGE: Array = [
	[2, 4, 20, 4, 4, 4],
	[9, 6, 3, 5, 3, 9],
	[5, 10, 5, 20, 20, 7],
	[24, 15, 12, 14, 12, 18],
	[46, 43, 40, 42, 40, 46],
	[1, 3, 1, 3, 3, 3],
]
const EXPECTED_HITS: Array = [
	[50, 15, 6, 40, 50, 38], [12, 10, 40, 32, 67, 17],
	[20, 6, 24, 8, 10, 22], [5, 4, 10, 12, 17, 9],
	[3, 2, 3, 4, 5, 4], [100, 20, 120, 54, 67, 50],
]
const PREVIOUS_HITS: Array = [
	[6, 3, 3, 8, 10, 4], [10, 5, 15, 20, 34, 7],
	[6, 2, 8, 4, 4, 4], [2, 2, 4, 6, 7, 3],
	[2, 1, 2, 2, 3, 1], [17, 8, 20, 20, 25, 10],
]
const EXPECTED_HP: Array[int] = [100, 60, 120, 160, 200, 150]
# Keep negative pre-floor damage: upgrades apply before the minimum-one clamp.
const BUILDING_RAW_DAMAGE: Array[int] = [-6, -1, -3, 58, 186, -7]
const ATTACK_BONUS: Array[int] = [0, 1, 2, 4]
const DEFENSE_BONUS: Array[int] = [0, 1, 2, 3]
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
		_check(attacker.hp == EXPECTED_HP[attacker_index], str(attacker.id) + " retains compact health, with doubled farmer health")
		for defender_index: int in range(KINDS.size()):
			var defender: UnitDefinition = BalanceCatalog.unit(KINDS[defender_index])
			var label: String = "%s -> %s" % [attacker.id, defender.id]
			var base: float = float(EXPECTED_DAMAGE[attacker_index][defender_index])
			var unupgraded: DamagePayload = DamageResolver.snapshot(attacker, 0, 0, 0)
			var actual: float = DamageResolver.resolve(unupgraded, defender)
			_check(is_equal_approx(actual, base), label + " approved base damage")
			_check(ceili(defender.hp / actual) == EXPECTED_HITS[attacker_index][defender_index], label + " full-health hit count")
			_check(ceili(defender.hp / actual) > PREVIOUS_HITS[attacker_index][defender_index], label + " takes more hits than 0.8.0 without military health inflation")
			for attack_level: int in range(4):
				for defense_level: int in range(4):
					var attack_bonus: float = ATTACK_BONUS[attack_level] if attacker.military else 0
					var defense_bonus: float = DEFENSE_BONUS[defense_level] if defender.military else 0
					var packet: DamagePayload = DamageResolver.snapshot(attacker, attack_bonus, 3, 1)
					# Independent expectation: research never supplies melee armor to siege.
					var applied_defense: float = 0.0 if attacker_index in [0, 2, 5] and defender_index in [3, 4] else defense_bonus
					var expected: float = maxf(1.0, base + attack_bonus - applied_defense)
					_check(is_equal_approx(DamageResolver.resolve(packet, defender, defense_bonus), expected), label + " upgrade %d/%d" % [attack_level, defense_level])
		for key: String in BalanceCatalog.BUILDINGS:
			var structure: BuildingDefinition = BalanceCatalog.building(key)
			_check(structure.hp >= 1000 and structure.melee_armor == 10 and structure.ranged_armor == 10, key + " durable ten-armor structure")
			for attack_level: int in range(4):
				var bonus: float = ATTACK_BONUS[attack_level] if attacker.military else 0
				var damage: float = DamageResolver.resolve(DamageResolver.snapshot(attacker, bonus, 0, 0), structure)
				_check(is_equal_approx(damage, maxf(1.0, BUILDING_RAW_DAMAGE[attacker_index] + bonus)), str(attacker.id) + " building damage " + key + " level " + str(attack_level))
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
		var bonuses: Array[int] = ATTACK_BONUS if track == &"attack" else DEFENSE_BONUS
		for level: int in range(1, 4):
			var upgrade: UpgradeDefinition = BalanceCatalog.upgrade(StringName("%s_%d" % [track, level]))
			_check(upgrade.track == track and upgrade.level == level and upgrade.total_bonus == bonuses[level], upgrade.name + " total bonus replaces previous tier")
			_check(upgrade.cost == costs[track][level - 1] and upgrade.research_seconds == times[track][level - 1], upgrade.name + " approved cost/time")
			var player := PlayerState.new()
			player.complete_upgrade(upgrade)
			var actual: int = player.get_attack_bonus() if track == &"attack" else player.get_defense_bonus()
			_check(actual == bonuses[level], upgrade.name + " runtime player bonus agrees with its resource")

func _test_snapshot() -> void:
	var local_definition: UnitDefinition = BalanceCatalog.unit(&"cannon").duplicate(true)
	var packet: DamagePayload = DamageResolver.snapshot(local_definition, 1, 3, 1)
	local_definition.damage = 999
	local_definition.bonuses[&"building"] = 999
	_check(packet.base_damage == 46 and packet.attack_bonus == 1 and packet.bonuses == {&"building": 150}, "launch packet copies attacks and bonuses")
	_check(packet.owner_id == 3 and packet.alliance_id == 1, "launch packet retains player/alliance independently")
	_check(DamageResolver.resolve(packet, BalanceCatalog.unit(&"catapult"), 2) == 41, "impact reads current defense without changing launch attack")
	_check(BalanceCatalog.unit(&"cannon").damage == 46 and BalanceCatalog.unit(&"cannon").bonuses == {&"building": 150}, "catalog resource stays immutable")

func _test_siege() -> void:
	for kind: StringName in [&"swordsman", &"archer"]:
		var defender := BalanceCatalog.unit(kind)
		var raw_damage: float = 24.0 if kind == &"swordsman" else 18.0
		var base_armor: float = 0.0 if kind == &"swordsman" else 3.0
		for attack_bonus: int in ATTACK_BONUS:
			for defense_bonus: int in DEFENSE_BONUS:
				var packet := DamageResolver.snapshot(BalanceCatalog.unit(&"catapult"), attack_bonus, 0, 0)
				var expected: float = raw_damage + attack_bonus - base_armor - defense_bonus
				var actual: float = DamageResolver.resolve(packet, defender, defense_bonus)
				_check(is_equal_approx(actual, expected), "full stone damage: %s attack %d defense %d" % [kind, attack_bonus, defense_bonus])
				_check(ceili(defender.hp / actual) >= 4, "stone needs at least four hits: %s attack %d defense %d" % [kind, attack_bonus, defense_bonus])
	var catapult := BalanceCatalog.unit(&"catapult")
	var cannon := BalanceCatalog.unit(&"cannon")
	var tower := BalanceCatalog.building(&"defense_tower")
	_check(catapult.range == 13 and catapult.damage == 18 and catapult.cost == 200 and catapult.hp == 160 and catapult.cooldown == 3, "catapult lowers attack while preserving health, range, price and cycle")
	_check(catapult.bonuses == {&"infantry": 6, &"building": 50}, "catapult has compact infantry bonus and building bonus only")
	_check(cannon.range == 14 and cannon.damage == 46 and cannon.cost == 250 and cannon.hp == 200, "cannon lowers attack while preserving health, range and price")
	_check(cannon.bonuses == {&"building": 150}, "cannon only gains its one-hundred-fifty-damage building bonus")
	var cannon_damage: float = DamageResolver.resolve(DamageResolver.snapshot(cannon, 0, 0, 0), cannon)
	_check(cannon_damage == 40 and ceili(cannon.hp / cannon_damage) == 5, "unupgraded cannon mirror requires exactly five hits")
	for level: int in range(4):
		var upgraded: DamagePayload = DamageResolver.snapshot(cannon, ATTACK_BONUS[level], 0, 0)
		var damage: float = DamageResolver.resolve(upgraded, cannon, DEFENSE_BONUS[level])
		_check(ceili(cannon.hp / damage) == 5, "equal-tech cannon mirror requires five hits at level " + str(level))
	var maximum_attack := DamageResolver.snapshot(cannon, ATTACK_BONUS[3], 0, 0)
	_check(ceili(cannon.hp / DamageResolver.resolve(maximum_attack, cannon)) == 5, "attack III cannon still needs five hits against defense zero")
	var knight := BalanceCatalog.unit(&"knight")
	for siege: UnitDefinition in [catapult, cannon]:
		var knight_damage: float = DamageResolver.resolve(DamageResolver.snapshot(knight, 0, 0, 0), siege)
		var expected_hits: int = 8 if siege.id == &"catapult" else 10
		_check(knight_damage == 20 and ceili(siege.hp / knight_damage) == expected_hits, "knight retains compact anti-siege damage against " + String(siege.id))
	_check(tower.range == cannon.range and catapult.range == cannon.range - 1, "arrow tower matches cannon reach and catapult is one unit shorter")
	for definition: UnitDefinition in [catapult, cannon]:
		_check(definition.melee_armor == 0 and not definition.melee_defense_upgrades, str(definition.id) + " cannot gain melee armor from research")
		for defense: int in DEFENSE_BONUS:
			_check(DamageResolver.armor_for_channel(definition, CombatDefinition.DamageChannel.MELEE, defense) == 0, str(definition.id) + " zero melee armor at defense bonus " + str(defense))
			_check(DamageResolver.armor_for_channel(definition, CombatDefinition.DamageChannel.RANGED, defense) == definition.ranged_armor + defense, str(definition.id) + " retains ranged armor research at bonus " + str(defense))
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
	var tower := BalanceCatalog.building(&"defense_tower")
	_check(tower.cost == 150 and tower.hp == 1000 and tower.build_seconds == 20, "tower costs one-hundred-fifty gold, has one thousand health and takes twenty seconds")
	_check(tower.damage == 14 and BalanceCatalog.building(&"headquarters").damage == 10, "defensive building attacks are reduced alongside military attacks")
