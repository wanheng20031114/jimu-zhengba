extends Node3D
## Observable fixture: reading a concealed enemy's combat data is recorded.
var entity_id: int = 0
var owner_id: int = 0
var alliance_id: int = 0
var alive: bool = true
var is_constructed: bool = true
var radius: float = 0.5
var order: int = BattleUnit.Order.IDLE
var work_target: Node3D
var _claimed_mine: bool = false
var work_progress: float = 0.0
var gathering_seconds: float = 0.0
var production: Dictionary = {"training": []}
var privacy_watch: bool = false
var privacy_reads: int = 0
var _unit: String = ""
var _building: String = ""
var _hp: float = 100.0
var _max_hp: float = 100.0

var unit_type: String:
	get:
		privacy_reads += 1 if privacy_watch else 0
		return _unit
	set(value): _unit = value
var building_type: String:
	get:
		privacy_reads += 1 if privacy_watch else 0
		return _building
	set(value): _building = value
var hp: float:
	get:
		privacy_reads += 1 if privacy_watch else 0
		return _hp
	set(value): _hp = value
var max_hp: float:
	get:
		privacy_reads += 1 if privacy_watch else 0
		return _max_hp
	set(value): _max_hp = value
