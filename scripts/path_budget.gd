class_name PathBudget
extends Node
## Owns every lazy NavigationAgent3D path update. Native agents still follow
## their own corridor and solve RVO; this node schedules only costly replans.
## get_next_path_position AND is_navigation_finished can run a native query:
## https://docs.godotengine.org/en/stable/classes/class_navigationagent3d.html

@export_range(1, 64, 1) var queries_per_tick: int = 24

class Route extends RefCounted:
	var unit: WeakRef
	var agent: NavigationAgent3D
	var goal: Vector3
	var next: Vector3
	var path: PackedVector3Array
	var active: bool = false
	var finished: bool = true
	var iteration: int = 0
	var sampled_tick: int = -1
	var requested_tick: int = 0
	var pending: bool = false
	var waiting_for_map: bool = false
	var generation: int = 0

var queries_this_tick: int = 0
var query_usec_this_tick: int = 0
var total_queries: int = 0
var max_wait_ticks: int = 0
var max_pending: int = 0
var _routes: Dictionary = {}
var _waiting_for_map: Dictionary = {}
var _queue: Array[Array] = []
var _head: int = 0
var _serial: int = 0

func register(unit: BattleUnit) -> void:
	var route := Route.new()
	route.unit = weakref(unit)
	route.agent = unit.navigation_agent
	route.goal = unit.global_position
	route.next = unit.global_position
	_routes[unit.get_instance_id()] = route
	route.agent.navigation_finished.connect(_on_finished.bind(unit.get_instance_id()))
	route.agent.path_changed.connect(_on_path_changed)

func unregister(unit: BattleUnit) -> void:
	_waiting_for_map.erase(unit.get_instance_id())
	_routes.erase(unit.get_instance_id())

func request(unit: BattleUnit, at: Vector3) -> void:
	var route: Route = _routes[unit.get_instance_id()]
	at.y = 0.0
	if (route.pending or route.active or route.waiting_for_map) and route.goal.distance_squared_to(at) < 0.0025:
		return
	route.goal = at
	_enqueue(unit.get_instance_id(), route)

func cancel(unit: BattleUnit) -> void:
	var route: Route = _routes[unit.get_instance_id()]
	route.pending = false
	route.waiting_for_map = false
	_waiting_for_map.erase(unit.get_instance_id())
	route.active = false
	route.finished = true
	route.path.clear()

func has_pending(unit: BattleUnit) -> bool:
	var route: Route = _routes[unit.get_instance_id()]
	return route.pending or route.waiting_for_map

func is_blocked(unit: BattleUnit) -> bool:
	# An empty corridor is explicitly blocked, not a completed move. It waits
	# for changed map connectivity; unchanged maps never cause periodic queries.
	return _routes[unit.get_instance_id()].waiting_for_map

func target_position(unit: BattleUnit) -> Vector3:
	return _routes[unit.get_instance_id()].goal

func is_finished(unit: BattleUnit) -> bool:
	var route: Route = _routes[unit.get_instance_id()]
	return route.finished and not route.pending and not route.waiting_for_map

func pending_count() -> int:
	var count: int = 0
	for route: Route in _routes.values():
		if route.pending or route.waiting_for_map: count += 1
	return count

func _enqueue(id: int, route: Route) -> void:
	if route.pending: return
	route.waiting_for_map = false
	_waiting_for_map.erase(id)
	route.pending = true
	route.requested_tick = Engine.get_physics_frames()
	_serial += 1
	route.generation = _serial
	_queue.append([id, route.generation])
	max_pending = maxi(max_pending, _queue.size() - _head)

func _physics_process(_delta: float) -> void:
	queries_this_tick = 0
	query_usec_this_tick = 0
	if not get_parent().is_authority: return
	var tick: int = Engine.get_physics_frames()
	for id: int in _waiting_for_map.keys():
		var waiting: Route = _waiting_for_map[id]
		var waiting_unit: BattleUnit = waiting.unit.get_ref()
		if not is_instance_valid(waiting_unit) or not waiting_unit.alive:
			_waiting_for_map.erase(id)
			_routes.erase(id)
			continue
		if NavigationServer3D.map_get_iteration_id(waiting.agent.get_navigation_map()) != waiting.iteration:
			_enqueue(id, waiting)
	while _head < _queue.size() and queries_this_tick < queries_per_tick:
		var entry: Array = _queue[_head]
		_head += 1
		if not _routes.has(entry[0]): continue
		var route: Route = _routes[entry[0]]
		if not route.pending or route.generation != entry[1]: continue
		var unit: BattleUnit = route.unit.get_ref()
		if not is_instance_valid(unit) or not unit.alive:
			_routes.erase(entry[0])
			continue
		var iteration: int = NavigationServer3D.map_get_iteration_id(route.agent.get_navigation_map())
		if iteration == 0:
			# Startup synchronization is not a failed/finished move order.
			_head -= 1
			break
		route.pending = false
		route.active = true
		route.finished = false
		max_wait_ticks = maxi(max_wait_ticks, tick - route.requested_tick)
		var began: int = Time.get_ticks_usec()
		route.agent.target_position = route.goal
		# Target assignment invalidates the path. Execute its actual query here.
		route.next = route.agent.get_next_path_position()
		route.path = route.agent.get_current_navigation_path()
		query_usec_this_tick += Time.get_ticks_usec() - began
		route.iteration = iteration
		route.sampled_tick = tick
		if route.path.is_empty():
			# The map can publish its empty first iteration before its asynchronously
			# built region arrives. Retain the intent and retry only on a new map
			# iteration or an explicitly changed order, never at a polling rate.
			route.active = false
			route.finished = false
			route.waiting_for_map = true
			_waiting_for_map[entry[0]] = route
	if _head == _queue.size():
		_queue.clear()
		_head = 0
	elif _head > 512:
		_queue = _queue.slice(_head)
		_head = 0

func next_position(unit: BattleUnit) -> Vector3:
	var route: Route = _routes[unit.get_instance_id()]
	if not route.active or route.finished: return unit.global_position
	var tick: int = Engine.get_physics_frames()
	if route.sampled_tick == tick: return route.next
	var iteration: int = NavigationServer3D.map_get_iteration_id(route.agent.get_navigation_map())
	if iteration != route.iteration:
		# A new footprint may remove the old corridor. Wait before advancing.
		_enqueue(unit.get_instance_id(), route)
		return unit.global_position
	var index: int = route.agent.get_current_navigation_path_index()
	if index > 0 and index < route.path.size():
		var nearest: Vector3 = Geometry3D.get_closest_point_to_segment(unit.global_position, route.path[index - 1], route.path[index])
		if unit.global_position.distance_squared_to(nearest) >= route.agent.path_max_distance * route.agent.path_max_distance:
			# Catch native off-corridor replans before a lazy getter bypasses us.
			_enqueue(unit.get_instance_id(), route)
			return route.next
	route.next = route.agent.get_next_path_position()
	route.sampled_tick = tick
	return route.next

func _on_finished(id: int) -> void:
	_routes[id].finished = true

func _on_path_changed() -> void:
	# Counts actual queries, including accidental budget escapes in tests.
	queries_this_tick += 1
	total_queries += 1
