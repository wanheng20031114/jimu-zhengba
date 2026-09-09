class_name PlayerState
extends RefCounted
## Mutable match state is owned by the authority, separate from shared definitions.

const WORKER_LIMIT := 10
const SUPPLY_LIMIT := 60
const TECH_BONUSES := [0, 1, 2, 4]

var owner_id: int
var alliance_id: int
var display_name: String
var controller: String = "human"
var gold: int = 320
var military_supply: int = 0
var farmers: int = 0
var reserved_farmers: int = 0
var attack_level: int = 0
var defense_level: int = 0
var active_research: Dictionary = {}
var last_command_sequence: int = 0
var revealed: bool = false

func _init(owner: int = 0, alliance: int = 0) -> void:
	owner_id = owner
	alliance_id = alliance
	display_name = "指挥官 %d" % (owner + 1)

func get_attack_bonus() -> int:
	return TECH_BONUSES[attack_level]

func get_defense_bonus() -> int:
	return TECH_BONUSES[defense_level]

func can_reserve_farmer() -> bool:
	return farmers + reserved_farmers < WORKER_LIMIT

func spend(amount: int) -> bool:
	if amount < 0 or gold < amount:
		return false
	gold -= amount
	return true

func public_state() -> Dictionary:
	return {"owner_id": owner_id, "alliance_id": alliance_id, "name": display_name, "controller": controller}

func private_state() -> Dictionary:
	return {"gold": gold, "supply": military_supply, "farmers": farmers, "reserved_farmers": reserved_farmers,
		"attack_level": attack_level, "defense_level": defense_level}
