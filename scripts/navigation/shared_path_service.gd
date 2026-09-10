class_name SharedPathService
extends RefCounted
## One immutable reverse-search field serves a whole movement command. Building
## runs on one native worker; publication and all Node access stay on the host.
## This first implementation is shared Dijkstra, not hierarchical pathfinding.

const CACHE_LIMIT: int = 16

class Entry extends RefCounted:
	var goal: Vector2i
	var radius: float
	var revision: int
	var field: SharedFlowField
	var blocked: PackedByteArray
	var origin: Vector2i
	var size: Vector2i
	var key: Vector3i
	var consumers: Array[WeakRef] = []

class Job extends RefCounted:
	var entry: Entry
	var result: SharedFlowField
	var elapsed_usec: int = 0

var fields_built: int = 0
var invalid_fields: int = 0
var cache_hits: int = 0
var last_build_usec: int = 0
var total_build_usec: int = 0
var stale_results: int = 0
var _revision: int = -1
var _cache: Dictionary = {}
var _queue: Array[WeakRef] = []
var _head: int = 0
var _task_id: int = -1
var _active: Job

func resolve(plan: MovementPlan, navigation: ConstructionNavigation) -> SharedFlowField:
	var revision: int = navigation.topology_revision()
	if plan.entry != null and plan.entry.revision == revision:
		return plan.entry.field
	if _revision != revision:
		_cache.clear()
		_revision = revision
	var cell := Vector2i(floori(plan.goal.x), floori(plan.goal.z))
	var key := Vector3i(cell.x, cell.y, ceili(plan.radius * 1000.0))
	if _cache.has(key):
		plan.entry = _cache[key]
		if plan.entry.field == null:
			plan.entry.consumers.append(weakref(plan))
		cache_hits += 1
		return plan.entry.field
	var snapshot: Dictionary = navigation.flow_snapshot()
	if snapshot.blocked.is_empty(): return null
	var entry := Entry.new()
	entry.goal = cell
	entry.radius = float(key.z) / 1000.0
	entry.revision = revision
	entry.blocked = snapshot.blocked
	entry.origin = snapshot.origin
	entry.size = snapshot.size
	entry.key = key
	entry.consumers.append(weakref(plan))
	plan.entry = entry
	# Eviction removes only the cache's reference. Active commands keep their
	# own entries alive; unused pending entries are weak and never build later.
	if _cache.size() >= CACHE_LIMIT:
		_cache.erase(_cache.keys()[0])
	_cache[key] = entry
	_queue.append(weakref(entry))
	return null

func poll(revision: int) -> void:
	if _task_id >= 0:
		if not WorkerThreadPool.is_task_completed(_task_id): return
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
		if _active.entry.revision == revision:
			_active.entry.field = _active.result
			fields_built += 1
			if _active.result.status != SharedFlowField.BuildStatus.READY:
				invalid_fields += 1
			last_build_usec = _active.elapsed_usec
			total_build_usec += last_build_usec
		else:
			stale_results += 1
		_active.entry.blocked = PackedByteArray()
		_active.entry.consumers.clear()
		_active = null
	while _head < _queue.size():
		var entry: Entry = _queue[_head].get_ref()
		_head += 1
		if entry == null or entry.revision != revision: continue
		var consumed: bool = false
		for consumer: WeakRef in entry.consumers:
			if consumer.get_ref() != null:
				consumed = true
				break
		if not consumed:
			if _cache.get(entry.key) == entry: _cache.erase(entry.key)
			continue
		_active = Job.new()
		_active.entry = entry
		_task_id = WorkerThreadPool.add_task(_build.bind(_active), false, "Shared movement field")
		break
	if _head == _queue.size():
		_queue.clear()
		_head = 0

static func _build(job: Job) -> void:
	var began: int = Time.get_ticks_usec()
	var entry: Entry = job.entry
	job.result = SharedFlowField.build(entry.blocked, entry.origin, entry.size, entry.goal, entry.radius, entry.revision)
	job.elapsed_usec = Time.get_ticks_usec() - began

func shutdown() -> void:
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	_active = null
	_queue.clear()
	_cache.clear()
