class_name ResourceVein
extends StaticBody3D
## A permanent resource deposit: no military target, depletion or delivery trip.

const radius: float = 2.2
const team: int = -1
const owner_id: int = -1
const alliance_id: int = -1
const CAPACITY: int = 6
const alive: bool = true
const display_name: String = "黄金矿脉"
var order_name: String:
	get: return "每位农民每%.1f秒采集%d金币 · 无需运输" % [BalanceCatalog.ECONOMY.mining_seconds, BalanceCatalog.ECONOMY.mining_gold]
var selected: bool = false
var entity_id: int = 0
var _miners: Array[WeakRef] = []
var _remote_occupancy: int = -1

func _ready() -> void:
	add_to_group("resource_veins")
	_miners.resize(CAPACITY)
	get_tree().current_scene.register_entity(self)

func set_selected(value: bool) -> void:
	selected = value
	$SelectionRing.visible = value

func try_claim(worker: Node3D) -> bool:
	for slot in range(CAPACITY):
		if _miners[slot] != null and _miners[slot].get_ref() == worker:
			return true
	var best_slot := -1
	var nearest := INF
	for slot in range(CAPACITY):
		var miner: Node3D = _miners[slot].get_ref() if _miners[slot] != null else null
		if is_instance_valid(miner) and miner.alive:
			continue
		var distance := worker.global_position.distance_squared_to(_slot_position(slot))
		if distance < nearest:
			nearest = distance
			best_slot = slot
	if best_slot == -1:
		return false
	_miners[best_slot] = weakref(worker)
	return true

func release(worker: Node3D) -> void:
	for slot in range(CAPACITY):
		if _miners[slot] != null and _miners[slot].get_ref() == worker:
			_miners[slot] = null

func occupied_slots() -> int:
	if _remote_occupancy >= 0:
		return _remote_occupancy
	var count := 0
	for reference: WeakRef in _miners:
		var miner: Node3D = reference.get_ref() if reference != null else null
		if is_instance_valid(miner) and miner.alive:
			count += 1
	return count

func set_remote_occupancy(value: int) -> void:
	_remote_occupancy = clampi(value, 0, CAPACITY)

func _slot_position(slot: int) -> Vector3:
	return $GatherSlots.get_child(slot).global_position

func get_work_position(from_position: Vector3, worker: Node3D = null) -> Vector3:
	if worker != null:
		for slot in range(CAPACITY):
			if _miners[slot] != null and _miners[slot].get_ref() == worker:
				return _slot_position(slot)
	var outward: Vector3 = from_position - global_position
	outward.y = 0.0
	if outward.length_squared() < 0.01:
		outward = Vector3.RIGHT
	return global_position + outward.normalized() * (radius + 3.0)
