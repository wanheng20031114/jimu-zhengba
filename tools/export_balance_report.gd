extends SceneTree
## Read-only audit of the same resources and resolver used by live combat.
## Run through generate_balance_report.py; this fixture does not create a match.

const BUILDING_IDS: Array[StringName] = [&"headquarters", &"barracks", &"factory", &"academy", &"defense_tower"]
const LEVELS := 4

func _initialize() -> void:
	_export.call_deferred()

func _export() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 1 or args.size() > 2:
		printerr("Expected an absolute output JSON path and optional baseline resource directory.")
		quit(2)
		return
	var unit_data: Array[Dictionary] = []
	var building_data: Array[Dictionary] = []
	var upgrades: Array[Dictionary] = []
	var attack_bonuses: Array[int] = []
	var defense_bonuses: Array[int] = []
	for level: int in range(LEVELS):
		var state := PlayerState.new(0, 0)
		state.attack_level = level
		state.defense_level = level
		attack_bonuses.append(state.get_attack_bonus())
		defense_bonuses.append(state.get_defense_bonus())
	for id: String in BalanceCatalog.UNITS:
		var unit := BalanceCatalog.unit(id)
		var data := _combat_data(unit)
		data.merge({"cost": unit.cost, "supply": unit.supply, "military": unit.military,
			"speed": unit.speed, "min_range": unit.min_range, "sight": unit.sight,
			"training_seconds": unit.training_seconds, "production_building": unit.production_building})
		unit_data.append(data)
	for id: StringName in BUILDING_IDS:
		var building := BalanceCatalog.building(id)
		var data := _combat_data(building)
		data.merge({"cost": building.cost, "build_seconds": building.build_seconds, "cost_progression": Array(building.cost_progression)})
		building_data.append(data)
	for id: String in BalanceCatalog.UPGRADES:
		var upgrade := BalanceCatalog.upgrade(id)
		upgrades.append({"id": upgrade.id, "name": upgrade.name, "track": upgrade.track,
			"level": upgrade.level, "cost": upgrade.cost, "research_seconds": upgrade.research_seconds,
			"total_bonus": upgrade.total_bonus})
	var matchups: Array[Dictionary] = []
	var building_matchups: Array[Dictionary] = []
	var defense_matchups: Array[Dictionary] = []
	for attacker_id: String in BalanceCatalog.UNITS:
		var attacker := BalanceCatalog.unit(attacker_id)
		for defender_id: String in BalanceCatalog.UNITS:
			var defender := BalanceCatalog.unit(defender_id)
			for attack_level: int in range(LEVELS):
				for defense_level: int in range(LEVELS):
					matchups.append(_matchup(attacker, defender, attack_level, defense_level,
						attack_bonuses[attack_level] if attacker.military else 0,
						defense_bonuses[defense_level] if defender.military else 0))
		for building_id: StringName in BUILDING_IDS:
			for attack_level: int in range(LEVELS):
				building_matchups.append(_matchup(attacker, BalanceCatalog.building(building_id), attack_level, 0,
					attack_bonuses[attack_level] if attacker.military else 0, 0))
	for building_id: StringName in BUILDING_IDS:
		var building := BalanceCatalog.building(building_id)
		if building.damage <= 0:
			continue
		for defender_id: String in BalanceCatalog.UNITS:
			var defender := BalanceCatalog.unit(defender_id)
			for defense_level: int in range(LEVELS):
				defense_matchups.append(_matchup(building, defender, 0, defense_level, 0,
					defense_bonuses[defense_level] if defender.military else 0))
	var report := {"schema_version": 3, "build_id": NetworkProtocol.BUILD_ID,
		"source": "BalanceCatalog + PlayerState + DamageResolver + ResourceVein (Godot)",
		"units": unit_data, "buildings": building_data, "upgrades": upgrades,
		"economy": _economy_data(), "support_technology": _support_technology_data(),
		"attack_bonuses": attack_bonuses, "defense_bonuses": defense_bonuses,
		"matchups": matchups, "building_matchups": building_matchups,
		"defense_matchups": defense_matchups}
	if args.size() == 2:
		var baseline_units: Array[UnitDefinition] = []
		var baseline_resolver: Script = load(args[1].path_join("historical_damage_resolver.gd"))
		var baseline_unit_data: Array[Dictionary] = []
		var baseline_matchups: Array[Dictionary] = []
		for id: String in BalanceCatalog.UNITS:
			var definition: UnitDefinition = load(args[1].path_join(id + ".tres"))
			baseline_units.append(definition)
			var historical_data := _combat_data(definition)
			historical_data.merge({"cost": definition.cost, "supply": definition.supply,
				"sight": definition.sight, "training_seconds": definition.training_seconds})
			baseline_unit_data.append(historical_data)
		for attacker: UnitDefinition in baseline_units:
			for defender: UnitDefinition in baseline_units:
				var payload: DamagePayload = baseline_resolver.snapshot(attacker, 0, 0, 0)
				var damage: float = baseline_resolver.resolve(payload, defender)
				baseline_matchups.append(_damage_row(attacker, defender, 0, 0, 0, 0, damage,
					baseline_resolver.armor_for_channel(defender, attacker.damage_channel, 0)))
		var baseline_upgrade_bonuses: Dictionary = {}
		for track: String in ["attack", "defense"]:
			var bonuses: Array[int] = [0]
			for level: int in range(1, 4):
				var upgrade: UpgradeDefinition = load(args[1].path_join("%s_%d.tres" % [track, level]))
				bonuses.append(upgrade.total_bonus)
			baseline_upgrade_bonuses[track] = bonuses
		report["baseline"] = {"build_id": "0.10.0", "units": baseline_unit_data, "matchups": baseline_matchups,
			"upgrade_bonuses": baseline_upgrade_bonuses}
	var file := FileAccess.open(args[0], FileAccess.WRITE)
	if file == null:
		printerr("Cannot write balance export: ", FileAccess.get_open_error())
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("BALANCE_REPORT_EXPORT ", matchups.size(), " unit + ", building_matchups.size(), " siege + ", defense_matchups.size(), " defense rows")
	quit(0)

func _support_technology_data() -> Dictionary:
	var state := PlayerState.new()
	var base_range: float = BalanceCatalog.unit(&"cannon").range + state.get_cannon_range_bonus()
	state.complete_upgrade(BalanceCatalog.upgrade(&"cannon_range_1"))
	state.complete_upgrade(BalanceCatalog.upgrade(&"recovery_1"))
	var tower_prices: Array[int] = []
	for count in range(8):
		state.paid_tower_count = count
		tower_prices.append(state.get_building_cost(&"defense_tower"))
	return {"cannon_range_before": base_range,
		"cannon_range_after": BalanceCatalog.unit(&"cannon").range + state.get_cannon_range_bonus(),
		"recovery_delay_seconds": BattleUnit.RECOVERY_DELAY, "recovery_per_second": state.get_recovery_per_second(),
		"tower_quotes_first_eight": tower_prices}

func _economy_data() -> Dictionary:
	var definition := BalanceCatalog.ECONOMY
	var worker_state := PlayerState.new(0, 0)
	var worker_limits: Array[Dictionary] = []
	for level in range(int(BalanceCatalog.UPGRADE_TRACKS[&"workforce"]) + 1):
		worker_state.workforce_level = level
		worker_limits.append({"level": level, "worker_limit": worker_state.get_worker_limit()})
	var full_worker_limit: int = worker_state.get_worker_limit()
	var capacity_levels: Array[Dictionary] = []
	for level in range(int(BalanceCatalog.UPGRADE_TRACKS[&"army_capacity"]) + 1):
		var state := PlayerState.new(0, 0)
		state.army_capacity_level = level
		capacity_levels.append({"level": level, "military_supply_limit": state.get_supply_limit()})
	var mining_levels: Array[Dictionary] = []
	for level in range(int(BalanceCatalog.UPGRADE_TRACKS[&"mining"]) + 1):
		var state := PlayerState.new(0, 0)
		state.mining_level = level
		var rate: float = state.get_mining_rate_multiplier()
		var cycle: float = definition.mining_seconds / rate
		var gold_per_minute: float = definition.mining_gold * 60.0 / cycle
		var full_income_per_minute: float = gold_per_minute * full_worker_limit + definition.passive_gold_per_second * 60.0
		mining_levels.append({"level": level, "rate_multiplier": rate, "cycle_seconds": cycle,
			"farmer_gold_per_minute": gold_per_minute, "full_workers": full_worker_limit,
			"full_economy_gold_per_minute": full_income_per_minute,
			"full_economy_gold_per_second": full_income_per_minute / 60.0})
	return {"resource_path": definition.resource_path,
		"passive_gold_per_second": definition.passive_gold_per_second,
		"mining_base_seconds": definition.mining_seconds, "mining_gold_per_cycle": definition.mining_gold,
		"mine_capacity": ResourceVein.CAPACITY, "worker_limits": worker_limits,
		"military_capacity_levels": capacity_levels, "mining_levels": mining_levels}

func _combat_data(definition: CombatDefinition) -> Dictionary:
	return {"id": definition.id, "name": definition.name, "description": definition.description,
		"hp": definition.hp, "damage": definition.damage, "melee_armor": definition.melee_armor,
		"ranged_armor": definition.ranged_armor, "melee_defense_upgrades": definition.melee_defense_upgrades,
		"damage_channel": "melee" if definition.damage_channel == CombatDefinition.DamageChannel.MELEE else "ranged",
		"combat_class": definition.combat_class, "bonuses": definition.bonuses,
		"range": definition.range, "cooldown": definition.cooldown,
		"resource_path": definition.resource_path}

func _matchup(attacker: CombatDefinition, defender: CombatDefinition, attack_level: int, defense_level: int,
		attack_bonus: int, defense_bonus: int) -> Dictionary:
	var payload := DamageResolver.snapshot(attacker, attack_bonus, 0, 0)
	var damage := DamageResolver.resolve(payload, defender, defense_bonus)
	return _damage_row(attacker, defender, attack_level, defense_level, attack_bonus, defense_bonus,
		damage, DamageResolver.armor_for_channel(defender, attacker.damage_channel, defense_bonus))

func _damage_row(attacker: CombatDefinition, defender: CombatDefinition, attack_level: int, defense_level: int,
		attack_bonus: int, defense_bonus: int, damage: float, armor: float) -> Dictionary:
	var hits := ceili(defender.hp / damage)
	return {"attacker": attacker.id, "defender": defender.id,
		"attack_level": attack_level, "defense_level": defense_level,
		"attack_bonus": attack_bonus, "defense_bonus": defense_bonus,
		"applied_armor": armor,
		"damage": damage, "target_hp": defender.hp, "hits": hits,
		"seconds_after_first_hit": (hits - 1) * attacker.cooldown,
		"damage_per_second": damage / attacker.cooldown,
		"remaining_after_penultimate_hit": defender.hp - (hits - 1) * damage}
