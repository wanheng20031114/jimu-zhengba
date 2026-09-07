class_name BattleProjectile
extends Node3D
## Visible finite projectiles: arrows follow their target; siege shells land at a fixed point.

var _source: Node3D
var _target: Node3D
var _source_team: int = 0
var _damage: float = 0.0
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

func initialize(source: Node3D, target: Node3D, damage: float, kind: String) -> void:
	_source = source
	_target = target
	_source_team = source.team
	_damage = damage
	_kind = kind
	_game = get_tree().current_scene
	if kind != "arrow":
		_blast_radius = 3.6 if kind == "stone" else 2.8
		var blast_shape := SphereShape3D.new()
		blast_shape.radius = _blast_radius + 0.25
		_blast_query = PhysicsShapeQueryParameters3D.new()
		_blast_query.shape = blast_shape
		_blast_query.collision_mask = (8 | 64) if _source_team == 0 else (16 | 32)
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
	_active = true

func _physics_process(delta: float) -> void:
	if not _active:
		return
	_elapsed += delta
	var progress: float = minf(1.0, _elapsed / _duration)
	if _kind == "arrow" and is_instance_valid(_target) and _target.alive:
		_end = _target.global_position + Vector3.UP * (2.0 if _target.is_in_group("buildings") else 1.0)
	var last_position: Vector3 = global_position
	global_position = _start.lerp(_end, progress)
	global_position.y += 4.0 * _arc_height * progress * (1.0 - progress)
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
	var damage_source: Node3D = _source if is_instance_valid(_source) else null
	if _kind == "arrow":
		if is_instance_valid(_target) and _target.alive and _target.team != _source_team:
			_target.receive_damage(_damage, damage_source)
		_game.spawn_effect(_end, "arrow_hit", Color("ead098"))
	else:
		_blast_query.transform.origin = Vector3(_end.x, 1.0, _end.z)
		for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(_blast_query, 128):
			var entity: Node3D = hit.collider
			if not entity.alive or entity.team == _source_team:
				continue
			var separation: Vector3 = entity.global_position - _end
			separation.y = 0.0
			var distance: float = maxf(0.0, separation.length() - entity.radius)
			if distance <= _blast_radius:
				var falloff: float = lerpf(1.0, 0.42, distance / _blast_radius)
				var siege_bonus: float = 1.7 if entity.is_in_group("buildings") else 1.0
				entity.receive_damage(_damage * falloff * siege_bonus, damage_source)
		_game.spawn_effect(_end - Vector3.UP * 0.7, "explosion" if _kind == "cannon" else "stone_hit", Color("efbb76"))
	queue_free()
