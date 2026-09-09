class_name BattleProjectile
extends Node3D
## Targeted arrows/cannonballs and fixed-point stone blasts carry immutable attack snapshots.

var _source: Node3D
var _target: Node3D
var _payload: DamagePayload
var _kind: String = "arrow"
var _start: Vector3
var _end: Vector3
var _elapsed: float = 0.0
var _duration: float = 1.0
var _arc_height: float = 1.0
var _active: bool = false
var _game: Node
var _blast_query: PhysicsShapeQueryParameters3D
var _blast_radius: float = 0.0
var _visual_only: bool = false

func initialize_visual(from: Vector3, to: Vector3, kind: String, duration: float, arc: float, target: Node3D = null) -> void:
	_visual_only = true
	_game = get_tree().current_scene
	_start = from
	_end = to
	_kind = kind
	_duration = duration
	_arc_height = arc
	_target = target
	$Arrow.visible = kind == "arrow"
	$Stone.visible = kind == "stone"
	$Cannonball.visible = kind == "cannon"
	$Trail.emitting = kind == "cannon"
	global_position = from
	visible = _game.can_see_position(_game.local_owner_id, from)
	_active = true
	reset_physics_interpolation()

func initialize(source: Node3D, target: Node3D, payload: DamagePayload, kind: String) -> void:
	_source = source
	_target = target
	_payload = payload
	_kind = kind
	_game = get_tree().current_scene
	if kind == "stone":
		_blast_radius = 3.0
		var blast_shape := SphereShape3D.new()
		blast_shape.radius = _blast_radius + 0.25
		_blast_query = PhysicsShapeQueryParameters3D.new()
		_blast_query.shape = blast_shape
		_blast_query.collision_mask = (8 | 64) if payload.alliance_id == 0 else (16 | 32)
	_start = source.get_projectile_origin()
	_end = target.global_position + Vector3.UP * (2.0 if target.is_in_group("buildings") else 1.0)
	var direction: Vector3 = (_end - _start).normalized()
	if source.is_in_group("buildings"):
		_start += direction * source.radius * 0.7
	var distance: float = _start.distance_to(_end)
	$Arrow.visible = kind == "arrow"
	$Stone.visible = kind == "stone"
	$Cannonball.visible = kind == "cannon"
	$Trail.emitting = kind == "cannon"
	match kind:
		"arrow":
			_duration = clampf(distance / 22.0, 0.18, 0.9)
			_arc_height = clampf(distance * 0.12, 0.35, 2.0)
		"stone":
			_duration = clampf(distance / 11.0, 0.75, 2.2)
			_arc_height = clampf(distance * 0.42, 3.5, 9.0)
		"cannon":
			_duration = clampf(distance / 25.0, 0.15, 0.85)
			_arc_height = 0.13
	global_position = _start
	visible = _game.can_see_position(_game.local_owner_id, global_position)
	var launch_direction: Vector3 = (_end - _start) + Vector3.UP * (4.0 * _arc_height)
	var launch_up: Vector3 = Vector3.RIGHT if absf(launch_direction.normalized().dot(Vector3.UP)) > 0.99 else Vector3.UP
	look_at(_start + launch_direction, launch_up)
	reset_physics_interpolation()
	_active = true

func _physics_process(delta: float) -> void:
	if not _active:
		# Keep the terminal pose for one tick so the renderer can finish the
		# final interpolated segment. Damage has already been applied exactly once.
		queue_free()
		return
	_elapsed += delta
	var progress: float = minf(1.0, _elapsed / _duration)
	if _kind in ["arrow", "cannon"] and is_instance_valid(_target) and _target.alive:
		_end = _target.global_position + Vector3.UP * (2.0 if _target.is_in_group("buildings") else 1.0)
	var last_position: Vector3 = global_position
	global_position = _start.lerp(_end, progress)
	global_position.y += 4.0 * _arc_height * progress * (1.0 - progress)
	# Presentation follows local vision while the authoritative shot keeps flying and resolving.
	visible = _game.can_see_position(_game.local_owner_id, global_position)
	var flight_direction: Vector3 = global_position - last_position
	if flight_direction.length_squared() > 0.0001:
		look_at(global_position + flight_direction.normalized(), Vector3.UP)
	if _kind == "stone":
		$Stone.rotate_x(delta * 5.0)
		$Stone.rotate_z(delta * 3.0)
	if progress >= 1.0:
		_impact()

func _impact() -> void:
	_active = false
	if _visual_only:
		return
	var damage_source: Node3D = _source if is_instance_valid(_source) else null
	if _kind in ["arrow", "cannon"]:
		var impact_kind: String = "arrow_hit" if _kind == "arrow" else "explosion"
		if is_instance_valid(_target) and _target.alive and _target.alliance_id != _payload.alliance_id:
			if _kind == "arrow" and _target.is_in_group("buildings"):
				impact_kind = _target.get_hit_effect()
			if _game.is_authority:
				_target.receive_hit(_payload, damage_source)
		_game.spawn_effect(_end, impact_kind, Color("ead098"))
	else:
		_blast_query.transform.origin = Vector3(_end.x, 1.0, _end.z)
		for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(_blast_query, 256) if _game.is_authority else []:
			var entity: Node3D = hit.collider
			if not entity.alive or entity.alliance_id == _payload.alliance_id:
				continue
			var building: bool = entity.is_in_group("buildings")
			var contact: Vector3 = entity.get_attack_position(_end) if building else entity.global_position
			var separation: Vector3 = contact - _end
			separation.y = 0.0
			var distance: float = maxf(0.0, separation.length() - (0.0 if building else entity.radius))
			if distance <= _blast_radius:
				entity.receive_hit(_payload, damage_source, DamageResolver.stone_falloff(distance))
		_game.spawn_effect(_end - Vector3.UP * 0.7, "stone_hit", Color("efbb76"))
