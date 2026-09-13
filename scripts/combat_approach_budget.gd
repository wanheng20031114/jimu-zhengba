class_name CombatApproachBudget
extends RefCounted
## Fair FIFO for optional congestion decisions, separate from immediate contact
## targeting and ordinary path queries. No more than four jobs per physics tick.
const JOBS_PER_TICK: int = 4
var jobs_this_tick: int = 0
var total_jobs: int = 0
var _queue: Array[WeakRef] = []
var _head: int = 0

func enqueue(unit: BattleUnit) -> void:
	if unit._approach_queued:
		return
	unit._approach_queued = true
	_queue.append(weakref(unit))

func tick() -> void:
	jobs_this_tick = 0
	while _head < _queue.size() and jobs_this_tick < JOBS_PER_TICK:
		var unit: BattleUnit = _queue[_head].get_ref()
		_head += 1
		jobs_this_tick += 1
		if not is_instance_valid(unit):
			continue
		unit._approach_queued = false
		unit._resolve_combat_congestion()
		total_jobs += 1
	if _head == _queue.size():
		_queue.clear()
		_head = 0
	elif _head > 512:
		_queue = _queue.slice(_head)
		_head = 0
