class_name BalanceCatalog
extends RefCounted
## One source of truth for recruitment, tooltips, combat, construction and research.
const ECONOMY: EconomyDefinition = preload("res://data/economy.tres")

const UNITS: Dictionary = {
	"swordsman": preload("res://data/units/swordsman.tres"),
	"spearman": preload("res://data/units/spearman.tres"),
	"archer": preload("res://data/units/archer.tres"),
	"knight": preload("res://data/units/knight.tres"),
	"catapult": preload("res://data/units/catapult.tres"),
	"cannon": preload("res://data/units/cannon.tres"),
	"farmer": preload("res://data/units/farmer.tres"),
}

const BUILDINGS: Dictionary = {
	"headquarters": preload("res://data/buildings/headquarters.tres"),
	"barracks": preload("res://data/buildings/barracks.tres"),
	"factory": preload("res://data/buildings/factory.tres"),
	"academy": preload("res://data/buildings/academy.tres"),
	"defense_tower": preload("res://data/buildings/defense_tower.tres"),
	"enemy_keep": preload("res://data/buildings/enemy_keep.tres"),
	"tower": preload("res://data/buildings/tower.tres"),
	"house": preload("res://data/buildings/house.tres"),
}

const UPGRADE_TRACKS: Dictionary = {&"attack": 3, &"defense": 3, &"workforce": 1, &"army_capacity": 2, &"mining": 3, &"cannon_range": 1, &"recovery": 1}

const UPGRADES: Dictionary = {
	"attack_1": preload("res://data/upgrades/attack_1.tres"),
	"attack_2": preload("res://data/upgrades/attack_2.tres"),
	"attack_3": preload("res://data/upgrades/attack_3.tres"),
	"defense_1": preload("res://data/upgrades/defense_1.tres"),
	"defense_2": preload("res://data/upgrades/defense_2.tres"),
	"defense_3": preload("res://data/upgrades/defense_3.tres"),
	"workforce_1": preload("res://data/upgrades/workforce_1.tres"),
	"army_capacity_1": preload("res://data/upgrades/army_capacity_1.tres"),
	"army_capacity_2": preload("res://data/upgrades/army_capacity_2.tres"),
	"mining_1": preload("res://data/upgrades/mining_1.tres"),
	"mining_2": preload("res://data/upgrades/mining_2.tres"),
	"mining_3": preload("res://data/upgrades/mining_3.tres"),
	"cannon_range_1": preload("res://data/upgrades/cannon_range_1.tres"),
	"recovery_1": preload("res://data/upgrades/recovery_1.tres"),
}

static func unit(kind: StringName) -> UnitDefinition:
	return UNITS[kind]

static func building(kind: StringName) -> BuildingDefinition:
	return BUILDINGS[kind]

static func upgrade(id: StringName) -> UpgradeDefinition:
	return UPGRADES[id]
