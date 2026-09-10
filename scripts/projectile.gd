class_name BattleProjectile
extends Node3D
## Reusable presentation; standalone scenes use the same Flight kernel as the pool.

var flight: ProjectileFlight
var pooled: bool = false
var _source: Node3D:
	get: return flight._source if flight != null else null
var _kind: String:
	get: return flight._kind if flight != null else ""
var _start: Vector3:
	get: return flight._start if flight != null else Vector3.ZERO
var _end: Vector3:
	get: return flight._end if flight != null else Vector3.ZERO
var _duration: float:
	get: return flight._duration if flight != null else 0.0
var _active: bool:
	get: return flight != null and flight._active

@onready var _arrow: Node3D = $Arrow
@onready var _stone: MeshInstance3D = $Stone
@onready var _cannonball: MeshInstance3D = $Cannonball
@onready var _trail: CPUParticles3D = $Trail

func initialize_visual(from: Vector3, to: Vector3, kind: String, duration: float, arc: float, target: Node3D = null) -> void:
	var launched := ProjectileFlight.new()
	launched.initialize_visual(get_tree().current_scene, from, to, kind, duration, arc, target)
	bind_flight(launched)

func initialize(source: Node3D, target: Node3D, payload: DamagePayload, kind: String) -> void:
	var launched := ProjectileFlight.new()
	launched.initialize(get_tree().current_scene, source, target, payload, kind)
	bind_flight(launched)

func bind_flight(launched: ProjectileFlight) -> void:
	flight = launched
	flight.visual = self
	_arrow.visible = flight._kind == "arrow"
	_stone.visible = flight._kind == "stone"
	_stone.rotation = Vector3.ZERO
	_cannonball.visible = flight._kind == "cannon"
	_trail.hide()
	_trail.emitting = false
	global_position = flight.position
	_face_direction(flight._end - flight._start + Vector3.UP * (4.0 * flight._arc_height))
	if flight._kind == "cannon":
		# Restart clears particles from the previous borrower before showing the trail.
		_trail.restart()
		_trail.emitting = true
		_trail.show()
	visible = flight._game.can_see_position(flight._game.local_owner_id, global_position)
	reset_physics_interpolation()

func present_flight(delta: float) -> void:
	var direction: Vector3 = flight.position - global_position
	global_position = flight.position
	visible = flight._game.can_see_position(flight._game.local_owner_id, global_position)
	_face_direction(direction)
	if flight._kind == "stone":
		_stone.rotate_x(delta * 5.0)
		_stone.rotate_z(delta * 3.0)

func _face_direction(direction: Vector3) -> void:
	if direction.length_squared() <= 0.0001:
		return
	var up := Vector3.RIGHT if absf(direction.normalized().dot(Vector3.UP)) > 0.99 else Vector3.UP
	look_at(global_position + direction, up)

func reset_visual() -> void:
	_trail.emitting = false
	_trail.hide()
	hide()
	flight = null

func _physics_process(delta: float) -> void:
	if pooled:
		return
	if flight == null or not flight._active:
		# Preserve the final interpolation tick and standalone fixture lifetime.
		queue_free()
		return
	flight.advance(delta)
	present_flight(delta)

func _impact() -> void:
	flight.impact()