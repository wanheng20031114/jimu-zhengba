class_name StaticMotionGrid
extends Node
## A conservative, event-built cache of real static collision shapes in XZ.
## This is a certificate for an unobstructed planar step, not a path planner.
## Call invalidate BEFORE a collider is added, moved, resized, enabled or removed;
## call rebuild after those edits are complete. While invalid, every query rejects.
## https://docs.godotengine.org/en/4.6/classes/class_transform3d.html#class-transform3d-operator-mul-aabb

const CELL_SIZE: float = 0.5
const COLLISION_MASK: int = 3
const GEOMETRY_EPSILON: float = 0.002
const PLANE_EPSILON: float = 0.00001
const CENTER_REGION_SIZE: float = 2.0

@export var fast_path_enabled: bool = false
var fast_steps: int = 0
var native_steps: int = 0
var center_region_queries: int = 0
var movement_plane_y: float = 0.0
var is_current: bool = false
var revision: int = 0
var rebuild_count: int = 0
var obstacle_count: int = 0
var skipped_floor_count: int = 0
var unavailable_reason: String = "not configured"
var grid_size: Vector2i = Vector2i.ZERO

var _map_root: Node3D
var _buildings_root: Node3D
var _bounds: Rect2
var _origin: Vector2
var _stride: int = 0
var _prefix := PackedInt32Array()
var _rebuild_pending: bool = false

func _ready() -> void:
	set_physics_process(false)

func _physics_process(_delta: float) -> void:
	if not _rebuild_pending: return
	_rebuild_pending = false
	rebuild()
	set_physics_process(false)

func schedule_rebuild() -> void:
	# Replicas and isolated scenes may leave this cache unconfigured. Their
	# construction events must not initiate an authoritative collision scan.
	if _map_root == null: return
	# Multiple construction/death events in one tick publish a single new
	# certificate after deferred collision changes. Invalid means native motion.
	_rebuild_pending = true
	set_physics_process(true)

func configure(map_root: Node3D, buildings_root: Node3D, map_bounds: Rect2, floor_y: float = 0.0) -> void:
	_map_root = map_root
	_buildings_root = buildings_root
	_bounds = map_bounds
	movement_plane_y = floor_y
	rebuild()
	set_physics_process(false)

func invalidate() -> void:
	if _map_root == null: return
	is_current = false
	unavailable_reason = "colliders changed; rebuild pending"
	revision += 1

func rebuild() -> void:
	is_current = false
	rebuild_count += 1
	revision += 1
	obstacle_count = 0
	skipped_floor_count = 0
	unavailable_reason = ""
	if not is_instance_valid(_map_root) or not is_instance_valid(_buildings_root):
		unavailable_reason = "static collision roots are not available"
		return
	if not _bounds.position.is_finite() or not _bounds.size.is_finite() or not is_finite(movement_plane_y) or _bounds.size.x <= 0.0 or _bounds.size.y <= 0.0:
		unavailable_reason = "map bounds must have positive area"
		return
	_origin = Vector2(floorf(_bounds.position.x / CELL_SIZE), floorf(_bounds.position.y / CELL_SIZE)) * CELL_SIZE
	grid_size = Vector2i(ceili((_bounds.end.x - _origin.x) / CELL_SIZE), ceili((_bounds.end.y - _origin.y) / CELL_SIZE))
	_stride = grid_size.x + 1
	var occupied := PackedByteArray()
	occupied.resize(grid_size.x * grid_size.y)
	occupied.fill(0)
	for source: Node3D in [_map_root, _buildings_root]:
		for node: Node in source.find_children("*", "CollisionShape3D", true, false):
			var collider: CollisionShape3D = node
			if collider.disabled or collider.shape == null:
				continue
			var body: CollisionObject3D = collider.get_parent() as CollisionObject3D
			if body == null or (body.collision_layer & COLLISION_MASK) == 0:
				continue
			# Moving colliders need a different broad phase. Do not certify a
			# region if this cache cannot represent everything in the move mask.
			if not body is StaticBody3D or body is AnimatableBody3D:
				unavailable_reason = "non-static collider in planar movement mask: " + str(body.get_path())
				return
			var static_body: StaticBody3D = body
			if not static_body.constant_linear_velocity.is_zero_approx() or not static_body.constant_angular_velocity.is_zero_approx():
				unavailable_reason = "moving static collider: " + str(body.get_path())
				return
			var shape_bounds: AABB = _local_bounds(collider.shape)
			if not unavailable_reason.is_empty():
				return
			var shape_transform: Transform3D = collider.global_transform
			if not shape_transform.is_finite() or absf(shape_transform.basis.determinant()) < 0.000001:
				unavailable_reason = "invalid collision transform: " + str(collider.get_path())
				return
			var scale: Vector3 = shape_transform.basis.get_scale().abs()
			var scale_bound: float = maxf(scale.x, maxf(scale.y, scale.z))
			var axes: Basis = shape_transform.basis.orthonormalized()
			# Physics backends do not consistently support a sheared collider.
			# Reject that unsupported configuration rather than invent its volume.
			if absf(shape_transform.basis.x.normalized().dot(shape_transform.basis.y.normalized())) > 0.0001 or absf(shape_transform.basis.x.normalized().dot(shape_transform.basis.z.normalized())) > 0.0001 or absf(shape_transform.basis.y.normalized().dot(shape_transform.basis.z.normalized())) > 0.0001:
				unavailable_reason = "sheared collision transform: " + str(collider.get_path())
				return
			if collider.shape is SphereShape3D or collider.shape is CylinderShape3D or collider.shape is CapsuleShape3D:
				# Some native round primitives make a non-uniform scale uniform.
				# The largest authored axis encloses both that and elliptical scaling.
				shape_transform.basis = axes.scaled(Vector3.ONE * scale_bound)
			var world_bounds: AABB = shape_transform * shape_bounds
			# Ground contact is intentional. Only geometry entirely at/below the
			# movement plane is omitted; raised rocks and overhead geometry stay.
			if world_bounds.end.y <= movement_plane_y:
				skipped_floor_count += 1
				continue
			# The cache encloses shape margins too. Primitive boxes conservatively
			# enclose their volume; polygon bounds include every collision vertex.
			world_bounds = world_bounds.grow(collider.shape.margin * scale_bound + GEOMETRY_EPSILON)
			_stamp_bounds(occupied, world_bounds)
			obstacle_count += 1
	_prefix.resize(_stride * (grid_size.y + 1))
	_prefix.fill(0)
	for z: int in range(grid_size.y):
		var row_count: int = 0
		var current: int = (z + 1) * _stride
		var previous: int = z * _stride
		var cells: int = z * grid_size.x
		for x: int in range(grid_size.x):
			row_count += occupied[cells + x]
			_prefix[current + x + 1] = _prefix[previous + x + 1] + row_count
	is_current = true

func clear_sweep(from: Vector3, to: Vector3, radius: float) -> bool:
	# Every shape above the plane contributes its full XZ bound, so the result
	# is safe for all upright capsule heights. The caller supplies its actual
	# collision radius plus CharacterBody3D.safe_margin, not a navigation radius.
	if not is_current or radius <= 0.0 or not is_finite(radius) or not from.is_finite() or not to.is_finite():
		return false
	if absf(from.y - movement_plane_y) > PLANE_EPSILON or absf(to.y - movement_plane_y) > PLANE_EPSILON:
		return false
	var low_x: float = minf(from.x, to.x) - radius - GEOMETRY_EPSILON
	var low_z: float = minf(from.z, to.z) - radius - GEOMETRY_EPSILON
	var high_x: float = maxf(from.x, to.x) + radius + GEOMETRY_EPSILON
	var high_z: float = maxf(from.z, to.z) + radius + GEOMETRY_EPSILON
	if low_x < _bounds.position.x or low_z < _bounds.position.y or high_x >= _bounds.end.x or high_z >= _bounds.end.y:
		return false
	var left: int = floori((low_x - _origin.x) / CELL_SIZE)
	var top: int = floori((low_z - _origin.y) / CELL_SIZE)
	var right: int = floori((high_x - _origin.x) / CELL_SIZE) + 1
	var bottom: int = floori((high_z - _origin.y) / CELL_SIZE) + 1
	# A swept capsule's XZ projection is inside this rectangle. Empty means
	# proven clear in O(1). A blocked rectangle is simply left to native motion;
	# no per-unit collider scan or optimistic corner cutting is performed.
	return _prefix[bottom * _stride + right] - _prefix[top * _stride + right] - _prefix[bottom * _stride + left] + _prefix[top * _stride + left] == 0

func center_region_for_sweep(from: Vector3, to: Vector3) -> Rect2:
	# Cover whole 2 m center tiles, not merely the current displacement. Both
	# endpoints must be inside this convex region before reusing its certificate.
	if not from.is_finite() or not to.is_finite(): return Rect2()
	var low := Vector2(floorf(minf(from.x, to.x) / CENTER_REGION_SIZE), floorf(minf(from.z, to.z) / CENTER_REGION_SIZE)) * CENTER_REGION_SIZE
	var high := (Vector2(floorf(maxf(from.x, to.x) / CENTER_REGION_SIZE), floorf(maxf(from.z, to.z) / CENTER_REGION_SIZE)) + Vector2.ONE) * CENTER_REGION_SIZE
	return Rect2(low, high - low)

func certify_center_region(region: Rect2, radius: float) -> bool:
	# The prefix query encloses the ENTIRE center rectangle plus capsule margin.
	# A rejection can also be cached: native motion remains safe anywhere inside.
	center_region_queries += 1
	if not region.has_area(): return false
	return clear_sweep(Vector3(region.position.x, movement_plane_y, region.position.y), Vector3(region.end.x, movement_plane_y, region.end.y), radius)

func _stamp_bounds(occupied: PackedByteArray, bounds: AABB) -> void:
	var left: int = clampi(floori((bounds.position.x - _origin.x) / CELL_SIZE), 0, grid_size.x)
	var top: int = clampi(floori((bounds.position.z - _origin.y) / CELL_SIZE), 0, grid_size.y)
	var right: int = clampi(floori((bounds.end.x - _origin.x) / CELL_SIZE) + 1, 0, grid_size.x)
	var bottom: int = clampi(floori((bounds.end.z - _origin.y) / CELL_SIZE) + 1, 0, grid_size.y)
	for z: int in range(top, bottom):
		var row: int = z * grid_size.x
		for x: int in range(left, right): occupied[row + x] = 1

func _local_bounds(shape: Shape3D) -> AABB:
	var half: Vector3
	if shape is BoxShape3D:
		half = (shape as BoxShape3D).size * 0.5
	elif shape is SphereShape3D:
		half = Vector3.ONE * (shape as SphereShape3D).radius
	elif shape is CylinderShape3D:
		var cylinder: CylinderShape3D = shape
		half = Vector3(cylinder.radius, cylinder.height * 0.5, cylinder.radius)
	elif shape is CapsuleShape3D:
		var capsule: CapsuleShape3D = shape
		half = Vector3(capsule.radius, capsule.height * 0.5, capsule.radius)
	elif shape is ConvexPolygonShape3D:
		return _points_bounds((shape as ConvexPolygonShape3D).points)
	elif shape is ConcavePolygonShape3D:
		return _points_bounds((shape as ConcavePolygonShape3D).get_faces())
	else:
		unavailable_reason = "unsupported finite collision shape: " + shape.get_class()
		return AABB()
	return AABB(-half, half * 2.0)

func _points_bounds(points: PackedVector3Array) -> AABB:
	if points.is_empty():
		unavailable_reason = "collision polygon has no vertices"
		return AABB()
	var result := AABB(points[0], Vector3.ZERO)
	for point: Vector3 in points: result = result.expand(point)
	return result
