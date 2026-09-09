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
var eliminated: bool = false
var gold: int = 320
var military_supply: int = 0
var reserved_military_supply: int = 0
var farmers: int = 0
var reserved_farmers: int = 0
var attack_level: int = 0
var defense_level: int = 0
var workforce_level: int = 0
var active_research: Dictionary = {}
var queued_research: Dictionary = {}
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
	return farmers + reserved_farmers < get_worker_limit()

func get_worker_limit() -> int:
	return WORKER_LIMIT + (BalanceCatalog.upgrade(&"workforce_1").total_bonus if workforce_level == 1 else 0)

func get_upgrade_level(track: StringName) -> int:
	match track:
		&"attack": return attack_level
		&"defense": return defense_level
		&"workforce": return workforce_level
	assert(false, "Unknown upgrade track: %s" % track)
	return 0

func complete_upgrade(upgrade: UpgradeDefinition) -> void:
	match upgrade.track:
		&"attack": attack_level = upgrade.level
		&"defense": defense_level = upgrade.level
		&"workforce": workforce_level = upgrade.level
		_: assert(false, "Unknown upgrade track: %s" % upgrade.track)

func used_military_supply() -> int:
	return military_supply + reserved_military_supply

func planned_upgrade_level(track: StringName) -> int:
	var level: int = get_upgrade_level(track)
	while level < int(BalanceCatalog.UPGRADE_TRACKS[track]) and queued_research.has("%s_%d" % [track, level + 1]):
		level += 1
	return level

func refresh_research_tracks() -> void:
	active_research.clear()
	for track: StringName in BalanceCatalog.UPGRADE_TRACKS:
		for level in range(1, int(BalanceCatalog.UPGRADE_TRACKS[track]) + 1):
			var id := "%s_%d" % [track, level]
			if queued_research.has(id):
				active_research[track] = queued_research[id]
				break

func spend(amount: int) -> bool:
	if amount < 0 or gold < amount:
		return false
	gold -= amount
	return true

func public_state() -> Dictionary:
	return {"owner_id": owner_id, "alliance_id": alliance_id, "name": display_name, "controller": controller, "eliminated": eliminated}

func private_state() -> Dictionary:
	return {"gold": gold, "supply": military_supply, "reserved_supply": reserved_military_supply, "farmers": farmers, "reserved_farmers": reserved_farmers,
		"queued_research": queued_research.duplicate(),
		"attack_level": attack_level, "defense_level": defense_level, "workforce_level": workforce_level}
