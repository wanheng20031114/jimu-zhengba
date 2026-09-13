class_name BattleProjectilePool
extends Node3D
## Native nodes are presentation only: all launches receive a Flight, including
## volleys exceeding the visual cap. Retired logical records are reused too.

signal launched(flight: ProjectileFlight)
signal projectile_launched(projectile: BattleProjectile)

const PROJECTILE_SCENE: PackedScene = preload("res://scenes/projectile.tscn")
const GROW_BATCH: int = 16
const MAX_VISUALS: int = 256
const MAX_CACHED_FLIGHTS: int = 1024

var active_flights: Array[ProjectileFlight] = []
var _available_flights: Array[ProjectileFlight] = []
var _available_visuals: Array[BattleProjectile] = []
var _game: Node3D
var launch_count: int = 0
var peak_active: int = 0
var peak_visuals: int = 0
var omitted_visuals: int = 0
var allocated_flights: int = 0
var _advancing: bool = false
var _reset_requested: bool = false
var _dispatch_depth: int = 0

func _ready() -> void:
	_game = get_parent()
	for projectile: BattleProjectile in get_children():
		_register_visual(projectile)
	for index: int in get_child_count():
		_available_flights.append(ProjectileFlight.new())
	allocated_flights = _available_flights.size()
	set_physics_process(false)

func _register_visual(projectile: BattleProjectile) -> void:
	projectile.pooled = true
	projectile.set_physics_process(false)
	projectile.process_mode = Node.PROCESS_MODE_DISABLED
	projectile.hide()
	_available_visuals.append(projectile)

func launch(source: Node3D, target: Node3D, payload: DamagePayload, kind: String, barrel_index: int = 0) -> ProjectileFlight:
	var flight := _borrow_flight()
	flight.initialize(_game, source, target, payload, kind, barrel_index)
	return flight if _activate(flight) else null

func launch_visual(from: Vector3, to: Vector3, kind: String, duration: float, arc: float, target: Node3D) -> ProjectileFlight:
	var flight := _borrow_flight()
	flight.initialize_visual(_game, from, to, kind, duration, arc, target)
	return flight if _activate(flight) else null

func _borrow_flight() -> ProjectileFlight:
	if not _available_flights.is_empty():
		return _available_flights.pop_back()
	allocated_flights += 1
	return ProjectileFlight.new()

func _activate(flight: ProjectileFlight) -> bool:
	_dispatch_depth += 1
	active_flights.append(flight)
	launch_count += 1
	peak_active = maxi(peak_active, active_flights.size())
	if _available_visuals.is_empty() and get_child_count() < MAX_VISUALS:
		for index: int in mini(GROW_BATCH, MAX_VISUALS - get_child_count()):
			var projectile: BattleProjectile = PROJECTILE_SCENE.instantiate()
			add_child(projectile)
			_register_visual(projectile)
	if not _available_visuals.is_empty():
		var projectile: BattleProjectile = _available_visuals.pop_back()
		projectile.process_mode = Node.PROCESS_MODE_INHERIT
		projectile.bind_flight(flight)
		peak_visuals = maxi(peak_visuals, visual_count())
		projectile_launched.emit(projectile)
	else:
		omitted_visuals += 1
	set_physics_process(true)
	launched.emit(flight)
	_dispatch_depth -= 1
	if _reset_requested and not _advancing and _dispatch_depth == 0:
		# A synchronous observer may cancel a launch (e.g. match teardown).
		# Callers receive null and must not publish its now-retired visual state.
		reset_all()
		return false
	return true

func _physics_process(delta: float) -> void:
	# Advance without mutating the array; hit callbacks may request a global reset.
	# Flights created by hit callbacks begin on the next tick.
	_advancing = true
	var count_at_start: int = active_flights.size()
	for index: int in count_at_start:
		if _reset_requested:
			break
		var flight: ProjectileFlight = active_flights[index]
		if not flight._active:
			flight.retiring = true
			continue
		flight.advance(delta)
		if _reset_requested:
			break
		if flight.visual != null:
			flight.visual.present_flight(delta)
	_advancing = false
	if _reset_requested:
		reset_all()
		return
	# Retire/compact only after all callbacks, so every record is returned once.
	var retained: int = 0
	for flight: ProjectileFlight in active_flights:
		if flight.retiring:
			_release(flight)
		else:
			active_flights[retained] = flight
			retained += 1
	active_flights.resize(retained)
	if active_flights.is_empty():
		set_physics_process(false)

func _release(flight: ProjectileFlight) -> void:
	if flight.visual != null:
		var projectile: BattleProjectile = flight.visual
		projectile.reset_visual()
		projectile.process_mode = Node.PROCESS_MODE_DISABLED
		_available_visuals.append(projectile)
	flight.reset()
	if _available_flights.size() < MAX_CACHED_FLIGHTS:
		_available_flights.append(flight)

func reset_all() -> void:
	if _advancing or _dispatch_depth > 0:
		# A hit callback may end a match. Let its shared Flight finish resolving
		# before clearing references, and stop the rest of that simulation batch.
		_reset_requested = true
		return
	_reset_requested = false
	for flight: ProjectileFlight in active_flights:
		_release(flight)
	active_flights.clear()
	set_physics_process(false)

func active_count() -> int:
	return active_flights.size()

func visual_count() -> int:
	return get_child_count() - _available_visuals.size()

func _exit_tree() -> void:
	# Children have already left the tree. Only clear references here.
	for flight: ProjectileFlight in active_flights:
		flight.reset()
	active_flights.clear()
	_available_flights.clear()
	_available_visuals.clear()
	_game = null
