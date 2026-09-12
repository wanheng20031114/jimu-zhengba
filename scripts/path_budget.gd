class_name PathBudget
extends Node
## Owns intent, budgeted native queries and route progress. NavigationAgent3D
## supplies RVO only; its lazy path getters never drive gameplay or completion.
## https://docs.godotengine.org/en/4.6/tutorials/navigation/navigation_using_navigationpathqueryobjects.html

@export_range(1, 64, 1) var queries_per_tick: int = 24
# Opt in during controlled profiling. Correctness alone is not evidence that
# the shared GDScript follower beats native navigation in a complete battle.
@export var shared_paths_enabled: bool = false
# Independent profiling switches. Configure before spawning units; metadata
# flags describe native waypoint payloads, not geometry or query scheduling.
@export var omit_path_metadata: bool = false
@export var cache_map_iterations: bool = false
const DIRECT_PURSUIT_DISTANCE: float = 20.0

class Route extends RefCounted:
	var unit: WeakRef
	var agent: NavigationAgent3D
	var goal: Vector3
	var next: Vector3
	var path: PackedVector3Array
	var corridor := PathCorridor.new()
	var topology: int = -1
	var active: bool = false
	var finished: bool = true
	var iteration: int = 0
	var sampled_tick: int = -1
	var requested_tick: int = 0
	var pending: bool = false
	var waiting_for_map: bool = false
	var generation: int = 0
	var direct: bool = false
	var plan: MovementPlan
	var shared_following: bool = false

var queries_this_tick: int = 0
var resolved_this_tick: int = 0
var total_direct_routes: int = 0
var query_usec_this_tick: int = 0
var total_queries: int = 0
var max_wait_ticks: int = 0
var max_pending: int = 0
var _routes: Dictionary = {}
var _waiting_for_map: Dictionary = {}
var _queue: Array[Array] = []
var _head: int = 0
var _serial: int = 0
var _walkability: ConstructionNavigation
var shared_samples_this_tick: int = 0
var total_shared_samples: int = 0
var shared_paths := SharedPathService.new()
var map_iteration_native_reads: int = 0
var map_iteration_cache_hits: int = 0
var _map_iteration_tick: int = -1
var _map_iterations: Dictionary = {}
var _query := NavigationPathQueryParameters3D.new()
var _result := NavigationPathQueryResult3D.new()

func _ready() -> void:
	# A region update invalidates this map even if it is published after the
	# first read in a tick. Cache lifetime never extends across physics ticks.
	NavigationServer3D.map_changed.connect(_on_navigation_map_changed)

func _on_navigation_map_changed(map: RID) -> void:
	_map_iterations.erase(map)

func _map_iteration(map: RID, tick: int) -> int:
	if not cache_map_iterations:
		map_iteration_native_reads += 1
		return NavigationServer3D.map_get_iteration_id(map)
	if _map_iteration_tick != tick:
		_map_iteration_tick = tick
		_map_iterations.clear()
	var cached: int = int(_map_iterations.get(map, -1))
	if cached >= 0:
		map_iteration_cache_hits += 1
		return cached
	map_iteration_native_reads += 1
	var iteration: int = NavigationServer3D.map_get_iteration_id(map)
	_map_iterations[map] = iteration
	return iteration

func set_walkability(navigation: ConstructionNavigation) -> void:
	# Authored battlefields publish an authoritative footprint cache. A scene
	# using only a native NavigationRegion keeps the ordinary agent path route.
	_walkability = navigation

func try_direct_pursuit(unit: BattleUnit, at: Vector3) -> bool:
	var route: Route = _routes[unit.get_instance_id()]
	if _walkability == null or route.agent.navigation_layers != 1 or unit.global_position.distance_squared_to(at) > DIRECT_PURSUIT_DISTANCE * DIRECT_PURSUIT_DISTANCE or not _walkability.has_clear_corridor(unit.global_position, at, unit.radius):
		if route.direct:
			cancel(unit)
		return false
	if route.active or route.pending or route.waiting_for_map or route.plan != null:
		# Cancel the old corridor and its queued generation once when local
		# steering takes over; a superseded A* must not consume the next budget.
		cancel(unit)
	route.goal = at
	route.direct = true
	return true

func register(unit: BattleUnit) -> void:
	var route := Route.new()
	route.unit = weakref(unit)
	route.agent = unit.navigation_agent
	route.goal = unit.global_position
	route.next = unit.global_position
	_routes[unit.get_instance_id()] = route

func unregister(unit: BattleUnit) -> void:
	_waiting_for_map.erase(unit.get_instance_id())
	_routes.erase(unit.get_instance_id())

func request(unit: BattleUnit, at: Vector3) -> void:
	var route: Route = _routes[unit.get_instance_id()]
	route.plan = null
	route.shared_following = false
	route.direct = false
	at.y = 0.0
	if (route.pending or route.active or route.waiting_for_map) and route.goal.distance_squared_to(at) < 0.0025:
		return
	route.goal = at
	_enqueue(unit.get_instance_id(), route)

func request_shared(unit: BattleUnit, at: Vector3, plan: MovementPlan) -> void:
	# Native paths remain responsive while the shared field is being built.
	# A formation's final per-unit destination is never replaced by its center.
	request(unit, at)
	_routes[unit.get_instance_id()].plan = plan

func release_shared_plan(unit: BattleUnit) -> void:
	# An explicit attack no longer owns a group command. If the old shared
	# route is needed again, next_position performs the native handoff once.
	_routes[unit.get_instance_id()].plan = null

func cancel(unit: BattleUnit) -> void:
	var route: Route = _routes[unit.get_instance_id()]
	route.plan = null
	route.shared_following = false
	route.direct = false
	route.pending = false
	route.waiting_for_map = false
	_waiting_for_map.erase(unit.get_instance_id())
	route.active = false
	route.finished = true
	route.path.clear()
	route.corridor.clear()

func has_pending(unit: BattleUnit) -> bool:
	var route: Route = _routes[unit.get_instance_id()]
	return route.pending or route.waiting_for_map

func is_blocked(unit: BattleUnit) -> bool:
	# An empty corridor is explicitly blocked, not a completed move. It waits
	# for changed map connectivity; unchanged maps never cause periodic queries.
	return _routes[unit.get_instance_id()].waiting_for_map

func target_position(unit: BattleUnit) -> Vector3:
	return _routes[unit.get_instance_id()].goal

func current_path(unit: BattleUnit) -> PackedVector3Array:
	return _routes[unit.get_instance_id()].path

func at_path_end(unit: BattleUnit, tolerance: float) -> bool:
	var route: Route = _routes[unit.get_instance_id()]
	return route.active and route.corridor.at_end(unit.global_position, tolerance)

func is_finished(unit: BattleUnit) -> bool:
	var route: Route = _routes[unit.get_instance_id()]
	return not route.shared_following and route.finished and not route.pending and not route.waiting_for_map

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
	resolved_this_tick = 0
	query_usec_this_tick = 0
	shared_samples_this_tick = 0
	if not get_parent().is_authority: return
	if _walkability != null:
		shared_paths.poll(_walkability.topology_revision())
		if not _walkability.paths_ready(): return
	var tick: int = Engine.get_physics_frames()
	for id: int in _waiting_for_map.keys():
		var waiting: Route = _waiting_for_map[id]
		var waiting_unit: BattleUnit = waiting.unit.get_ref()
		if not is_instance_valid(waiting_unit) or not waiting_unit.alive:
			_waiting_for_map.erase(id)
			_routes.erase(id)
			continue
		if _map_iteration(waiting.agent.get_navigation_map(), tick) != waiting.iteration:
			_enqueue(id, waiting)
	# Even certified direct routes count against scheduling work. An open-field
	# command to hundreds of units must not become an unbounded single tick.
	while _head < _queue.size() and resolved_this_tick < queries_per_tick:
		var entry: Array = _queue[_head]
		_head += 1
		if not _routes.has(entry[0]): continue
		var route: Route = _routes[entry[0]]
		if not route.pending or route.generation != entry[1]: continue
		var unit: BattleUnit = route.unit.get_ref()
		if not is_instance_valid(unit) or not unit.alive:
			_routes.erase(entry[0])
			continue
		var iteration: int = _map_iteration(route.agent.get_navigation_map(), tick)
		if iteration == 0:
			# Startup synchronization is not a failed/finished move order.
			_head -= 1
			break
		route.pending = false
		route.active = true
		route.finished = false
		max_wait_ticks = maxi(max_wait_ticks, tick - route.requested_tick)
		var began: int = Time.get_ticks_usec()
		if _walkability != null and route.agent.navigation_layers == 1 and _walkability.has_clear_corridor(unit.global_position, route.goal, unit.radius):
			# A whole-body line certificate is both shorter and cheaper than A*.
			# Apply to ordinary MOVE at any distance, not just close pursuit.
			route.path = PackedVector3Array([unit.global_position, route.goal])
			total_direct_routes += 1
		else:
			_query.map = route.agent.get_navigation_map()
			_query.start_position = unit.global_position
			_query.target_position = route.goal
			_query.navigation_layers = route.agent.navigation_layers
			_query.path_search_max_polygons = route.agent.path_search_max_polygons
			_query.metadata_flags = NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_NONE if omit_path_metadata else route.agent.path_metadata_flags
			NavigationServer3D.query_path(_query, _result)
			route.path = _result.path
			queries_this_tick += 1
			total_queries += 1
		route.corridor.reset(route.path, unit.global_position)
		route.path = route.corridor.points
		route.next = unit.global_position
		route.topology = _walkability.topology_revision() if _walkability != null else -1
		resolved_this_tick += 1
		query_usec_this_tick += Time.get_ticks_usec() - began
		route.iteration = iteration
		route.sampled_tick = -1
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
	if shared_paths_enabled and route.plan != null and _walkability != null:
		var shared_next: Vector3 = _shared_next(unit, route)
		if shared_next.is_finite():
			if not route.shared_following:
				route.pending = false
				route.waiting_for_map = false
				_waiting_for_map.erase(unit.get_instance_id())
				route.active = false
				route.finished = false
				route.path.clear()
				route.corridor.clear()
				route.shared_following = true
			shared_samples_this_tick += 1
			total_shared_samples += 1
			return shared_next
	if route.shared_following:
		# A changed footprint, unreachable field cell or blocked final slot
		# resumes the native route without completing the player's order.
		route.shared_following = false
		_enqueue(unit.get_instance_id(), route)
	if not route.active or route.finished: return unit.global_position
	var tick: int = Engine.get_physics_frames()
	var iteration: int = _map_iteration(route.agent.get_navigation_map(), tick)
	if iteration != route.iteration or (_walkability != null and route.topology != _walkability.topology_revision()):
		# A new footprint may remove the old corridor. Wait before advancing.
		_enqueue(unit.get_instance_id(), route)
		return unit.global_position
	if route.sampled_tick == tick: return route.next
	var end_distance: float = route.agent.target_desired_distance
	if not route.path.is_empty() and route.path[-1].distance_squared_to(route.goal) > end_distance * end_distance:
		end_distance = route.agent.path_desired_distance
	var lookahead: float = maxf(unit.radius, unit.speed * 0.25)
	# The authored footprint cache certifies layer 1 only. Other native layers
	# retain their own corridor without taking shortcuts through this cache.
	var navigation: ConstructionNavigation = _walkability if route.agent.navigation_layers == 1 else null
	route.next = route.corridor.next_position(unit.global_position, route.agent.path_desired_distance, end_distance, lookahead, navigation, unit.radius)
	if route.corridor.distance_squared_to_segment(unit.global_position) >= route.agent.path_max_distance * route.agent.path_max_distance:
		_enqueue(unit.get_instance_id(), route)
		return unit.global_position
	route.finished = route.corridor.finished
	route.sampled_tick = tick
	return route.next

func _shared_next(unit: BattleUnit, route: Route) -> Vector3:
	var field: SharedFlowField = shared_paths.resolve(route.plan, _walkability)
	if field == null: return Vector3(INF, INF, INF)
	var at: Vector3 = unit.global_position
	# Once the actual slot is in clear local reach, leave the group direction
	# and converge independently; this avoids piling everyone on the same cell.
	if at.distance_squared_to(route.goal) <= DIRECT_PURSUIT_DISTANCE * DIRECT_PURSUIT_DISTANCE and _walkability.has_clear_corridor(at, route.goal, unit.radius):
		return route.goal
	if field.status_at(Vector2(at.x, at.z)) == SharedFlowField.SampleStatus.ARRIVED:
		# Reaching the group center is not reaching this member's final slot.
		route.plan = null
		return Vector3(INF, INF, INF)
	var next: Vector2 = field.next_position_at(Vector2(at.x, at.z))
	if not next.is_finite():
		route.plan = null
		return Vector3(INF, INF, INF)
	var point := Vector3(next.x, 0.0, next.y)
	# This adjacent field edge crosses only cells validated by the solver
	# (including both side cells on diagonals). A unit displaced within its
	# cell by RVO may fail the padded navigation rectangle even though its
	# actual capsule can sweep to the waypoint. Use the real shape certificate
	# only for this local edge, never for an arbitrary long-distance shortcut.
	if not _walkability.has_clear_corridor(at, point, unit.radius) and not unit._motion_grid.clear_sweep(at, point, unit._motion_clearance):
		route.plan = null
		return Vector3(INF, INF, INF)
	return point

func _exit_tree() -> void:
	NavigationServer3D.map_changed.disconnect(_on_navigation_map_changed)
	_map_iterations.clear()
	shared_paths.shutdown()
