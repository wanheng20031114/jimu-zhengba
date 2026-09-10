class_name ConstructionNavigation
extends Node
## Carve the authored one-metre cells, then merge contiguous cells into convex
## rectangles. Shared edges are split at every T-junction: native paths see the
## same walkable area with fewer polygons. The first three vertices span a real
## corner, as Godot uses them to calculate the polygon's projection plane.
## https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_optimizing_performance.html

const FOOTPRINT_HALF: float = 2.0
const NAV_PADDING: float = 1.15
# Bound portal lengths for local path quality and stable float projections.
const MAX_RECT_EDGE: int = 12

var rebuild_count: int = 0
var last_rebuild_usec: int = 0
var compact_polygon_count: int = 0
var last_request_usec: int = 0
var _sources: Array[Dictionary] = []
var _blocked_cells: Dictionary = {}
var _walkable_cells: Dictionary = {}
var _revision: int = 0
var _task_id: int = -1
var _requested_sources: Array[Dictionary] = []
var _job: MeshJob
var _corridor_origin := Vector2i.ZERO
var _corridor_size := Vector2i.ZERO
var _corridor_stride: int = 0
var _blocked_prefix := PackedInt32Array()
var _flow_blocked := PackedByteArray()

class MeshJob extends RefCounted:
	var revision: int
	var sources: Array[Dictionary]
	var results: Array[NavigationMesh] = []
	var elapsed_usec: int = 0

func _ready() -> void:
	set_physics_process(false)

func _cache_sources() -> void:
	if not _sources.is_empty():
		return
	var game: Node = get_parent()
	var regions: Array[NavigationRegion3D] = [game.map_instance.get_node("NavigationRegion3D")]
	for region: NavigationRegion3D in regions:
		var source: NavigationMesh = region.navigation_mesh
		var vertices: PackedVector3Array = source.get_vertices()
		var cells: Array[Vector2i] = []
		for index: int in source.get_polygon_count():
			var polygon: PackedInt32Array = source.get_polygon(index)
			var center: Vector3 = Vector3.ZERO
			for vertex_index: int in polygon:
				center += vertices[vertex_index]
			center = region.to_global(center / float(polygon.size()))
			cells.append(Vector2i(floori(center.x), floori(center.z)))
		cells.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y if a.y != b.y else a.x < b.x)
		_sources.append({"region": region, "mesh": source, "cells": cells})
	var path_budget: PathBudget = game.get_node("PathBudget")
	path_budget.set_walkability(self)

func refresh() -> void:
	_cache_sources()
	var started: int = Time.get_ticks_usec()
	var occupied: Dictionary = {}
	for building: Node3D in get_tree().get_nodes_in_group("buildings"):
		if building.alive:
			for cell: Vector2i in footprint_cells(building.global_position, building.get_combat_definition().size):
				occupied[cell] = true
	var changed: bool = occupied != _blocked_cells or rebuild_count == 0
	if not changed:
		return
	_blocked_cells = occupied
	_walkable_cells.clear()
	_requested_sources = []
	for source: Dictionary in _sources:
		var region: NavigationRegion3D = source.region
		var walkable: Dictionary = {}
		for cell: Vector2i in source.cells:
			if occupied.has(cell):
				continue
			walkable[cell] = true
			if region.enabled:
				_walkable_cells[cell] = true
		# The worker owns immutable input containers and a new NavigationMesh;
		# it never accesses a Node, live placement cache or active mesh resource.
		_requested_sources.append({"mesh": source.mesh, "cells": source.cells, "walkable": walkable})
	_rebuild_corridor_prefix()
	rebuild_count += 1
	_revision += 1
	if _task_id < 0: _start_job()
	last_request_usec = Time.get_ticks_usec() - started

func _start_job() -> void:
	_job = MeshJob.new()
	_job.revision = _revision
	_job.sources = _requested_sources
	_task_id = WorkerThreadPool.add_task(_build_job.bind(_job), false, "Compact construction navigation")
	set_physics_process(true)

static func _build_job(job: MeshJob) -> void:
	var began: int = Time.get_ticks_usec()
	for source: Dictionary in job.sources:
		job.results.append(_compact_mesh(source.mesh, source.cells, source.walkable))
	job.elapsed_usec = Time.get_ticks_usec() - began

func _physics_process(_delta: float) -> void:
	if not WorkerThreadPool.is_task_completed(_task_id): return
	# Joining a completed task publishes its results and releases its resources.
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	if _job.revision != _revision:
		# Rapid construction only queues the newest occupancy revision.
		_start_job()
		return
	compact_polygon_count = 0
	for index: int in _job.results.size():
		var region: NavigationRegion3D = _sources[index].region
		region.navigation_mesh = _job.results[index]
		compact_polygon_count += _job.results[index].get_polygon_count()
	last_rebuild_usec = _job.elapsed_usec
	_job = null
	set_physics_process(false)

func is_rebuilding() -> bool:
	# Resource work only. NavigationServer publishes the replacement through
	# its normal asynchronous region/map iterations after this task finishes.
	return _task_id >= 0

func topology_revision() -> int:
	return _revision

func flow_snapshot() -> Dictionary:
	# Packed arrays use copy-on-write. Rebuild allocates a new buffer before
	# editing, so worker tasks keep a stable immutable navigation snapshot.
	return {"blocked": _flow_blocked, "origin": _corridor_origin, "size": _corridor_size}

func _exit_tree() -> void:
	# A scene cannot release its resource inputs while its own task is active.
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	_job = null

static func _compact_mesh(source: NavigationMesh, ordered_cells: Array[Vector2i], walkable: Dictionary) -> NavigationMesh:
	var remaining: Dictionary = walkable.duplicate()
	var rectangles: Array[Rect2i] = []
	for cell: Vector2i in ordered_cells:
		if not remaining.has(cell): continue
		var end_x: int = cell.x + 1
		while end_x < cell.x + MAX_RECT_EDGE and remaining.has(Vector2i(end_x, cell.y)): end_x += 1
		var end_y: int = cell.y + 1
		while end_y < cell.y + MAX_RECT_EDGE:
			var complete: bool = true
			for x: int in range(cell.x, end_x):
				if not remaining.has(Vector2i(x, end_y)):
					complete = false
					break
			if not complete: break
			end_y += 1
		for x: int in range(cell.x, end_x):
			for y: int in range(cell.y, end_y): remaining.erase(Vector2i(x, y))
		rectangles.append(Rect2i(cell, Vector2i(end_x, end_y) - cell))
	var vertical: Dictionary = {}
	var horizontal: Dictionary = {}
	for rect: Rect2i in rectangles:
		for corner: Vector2i in [rect.position, rect.end, Vector2i(rect.position.x, rect.end.y), Vector2i(rect.end.x, rect.position.y)]:
			if not vertical.has(corner.x): vertical[corner.x] = {}
			if not horizontal.has(corner.y): horizontal[corner.y] = {}
			vertical[corner.x][corner.y] = true
			horizontal[corner.y][corner.x] = true
	for key: int in vertical:
		vertical[key] = vertical[key].keys()
		vertical[key].sort()
	for key: int in horizontal:
		horizontal[key] = horizontal[key].keys()
		horizontal[key].sort()
	var result: NavigationMesh = source.duplicate()
	result.clear_polygons()
	var output := PackedVector3Array()
	var ids: Dictionary = {}
	for rect: Rect2i in rectangles:
		var points: Array[Vector2i] = []
		# Native binary searches visit only this short edge's subdivisions,
		# instead of scanning an entire battlefield row for every rectangle.
		var left: Array = vertical[rect.position.x]
		for index: int in range(left.bsearch(rect.position.y), left.bsearch(rect.end.y)):
			points.append(Vector2i(rect.position.x, left[index]))
		var top: Array = horizontal[rect.end.y]
		for index: int in range(top.bsearch(rect.position.x), top.bsearch(rect.end.x)):
			points.append(Vector2i(top[index], rect.end.y))
		var right: Array = vertical[rect.end.x]
		for index: int in range(right.bsearch(rect.end.y, false) - 1, right.bsearch(rect.position.y, false) - 1, -1):
			points.append(Vector2i(rect.end.x, right[index]))
		var bottom: Array = horizontal[rect.position.y]
		for index: int in range(bottom.bsearch(rect.end.x, false) - 1, bottom.bsearch(rect.position.x, false) - 1, -1):
			points.append(Vector2i(bottom[index], rect.position.y))
		var polygon := PackedInt32Array()
		for point: Vector2i in points:
			if not ids.has(point):
				ids[point] = output.size()
				output.append(Vector3(point.x, 0, point.y))
			polygon.append(ids[point])
		# Starting with three collinear edge subdivisions gives Godot a zero
		# plane normal. The previous bottom-edge point, bottom-left corner and
		# next left-edge point form a nondegenerate upward-facing triangle.
		var rotated := PackedInt32Array([polygon[-1]])
		for index: int in range(polygon.size() - 1): rotated.append(polygon[index])
		result.add_polygon(rotated)
	result.vertices = output
	return result

func footprint_cells(at: Vector3, size: Vector3 = Vector3(4, 6, 4)) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var half_size := Vector2(size.x, size.z) * 0.5 + Vector2.ONE * NAV_PADDING
	for x: int in range(floori(at.x - half_size.x), ceili(at.x + half_size.x)):
		for z: int in range(floori(at.z - half_size.y), ceili(at.z + half_size.y)):
			if absf(float(x) + 0.5 - at.x) < half_size.x and absf(float(z) + 0.5 - at.z) < half_size.y:
				result.append(Vector2i(x, z))
	return result

func walkable_footprint(at: Vector3, size: Vector3 = Vector3(4, 6, 4)) -> bool:
	for cell: Vector2i in footprint_cells(at, size):
		if not _walkable_cells.has(cell):
			return false
	return true

func is_placement_clear(at: Vector3) -> bool:
	return walkable_footprint(at)

func _rebuild_corridor_prefix() -> void:
	# A summed-area table makes a conservative local corridor check O(1).
	# Publish it with the logical footprint, before asynchronous mesh baking;
	# a newly placed building therefore blocks direct pursuit immediately.
	_blocked_prefix.clear()
	_flow_blocked = PackedByteArray()
	_corridor_size = Vector2i.ZERO
	if _walkable_cells.is_empty():
		return
	var low: Vector2i = _walkable_cells.keys()[0]
	var high: Vector2i = low
	for cell: Vector2i in _walkable_cells:
		low = low.min(cell)
		high = high.max(cell)
	_corridor_origin = low
	_corridor_size = high - low + Vector2i.ONE
	_corridor_stride = _corridor_size.x + 1
	_flow_blocked.resize(_corridor_size.x * _corridor_size.y)
	_flow_blocked.fill(0)
	_blocked_prefix.resize(_corridor_stride * (_corridor_size.y + 1))
	_blocked_prefix.fill(0)
	for z: int in range(_corridor_size.y):
		var blocked_in_row: int = 0
		var previous_row: int = z * _corridor_stride
		var current_row: int = previous_row + _corridor_stride
		for x: int in range(_corridor_size.x):
			if not _walkable_cells.has(_corridor_origin + Vector2i(x, z)):
				blocked_in_row += 1
				_flow_blocked[z * _corridor_size.x + x] = 1
			_blocked_prefix[current_row + x + 1] = _blocked_prefix[previous_row + x + 1] + blocked_in_row

func has_clear_corridor(from: Vector3, to: Vector3, body_radius: float) -> bool:
	if _blocked_prefix.is_empty():
		return false
	# An empty bounding rectangle is the O(1) common case. For a diagonal near
	# an obstacle, narrow each grid row to the body's conservative swept square:
	# a rock beside the route must not force every pursuer to repeat native A*.
	var margin: float = body_radius + 0.001
	var low := Vector2i(floori(minf(from.x, to.x) - margin), floori(minf(from.z, to.z) - margin)) - _corridor_origin
	var high := Vector2i(floori(maxf(from.x, to.x) + margin), floori(maxf(from.z, to.z) + margin)) - _corridor_origin + Vector2i.ONE
	if low.x < 0 or low.y < 0 or high.x > _corridor_size.x or high.y > _corridor_size.y:
		return false
	var blocked: int = _blocked_prefix[high.y * _corridor_stride + high.x] - _blocked_prefix[low.y * _corridor_stride + high.x] - _blocked_prefix[high.y * _corridor_stride + low.x] + _blocked_prefix[low.y * _corridor_stride + low.x]
	if blocked == 0:
		return true
	var dz: float = to.z - from.z
	if absf(dz) < 0.000001:
		return false # The bounding rectangle already is the horizontal sweep.
	var inverse_z: float = 1.0 / dz
	var dx: float = to.x - from.x
	for row: int in range(low.y, high.y):
		var z: float = float(row + _corridor_origin.y)
		var enter: float = (z - margin - from.z) * inverse_z
		var leave: float = (z + 1.0 + margin - from.z) * inverse_z
		var start: float = clampf(minf(enter, leave), 0.0, 1.0)
		var finish: float = clampf(maxf(enter, leave), 0.0, 1.0)
		var first_x: float = from.x + dx * start
		var last_x: float = from.x + dx * finish
		var left: int = floori(minf(first_x, last_x) - margin) - _corridor_origin.x
		var right: int = floori(maxf(first_x, last_x) + margin) - _corridor_origin.x + 1
		# Floating-point endpoint arithmetic may widen by one cell; retain the
		# already checked outer bounds instead of indexing outside the prefix.
		left = maxi(low.x, left)
		right = mini(high.x, right)
		var current: int = row * _corridor_stride
		var next: int = current + _corridor_stride
		if _blocked_prefix[next + right] - _blocked_prefix[current + right] - _blocked_prefix[next + left] + _blocked_prefix[current + left] > 0:
			return false
	return true

func contains_walkable_point(at: Vector3) -> bool:
	var cell := Vector2i(floori(at.x), floori(at.z))
	if _walkable_cells.has(cell):
		return true
	# A point on a polygon's shared boundary belongs to either adjacent cell.
	var on_x_edge: bool = is_equal_approx(at.x, float(cell.x))
	var on_z_edge: bool = is_equal_approx(at.z, float(cell.y))
	if on_x_edge and _walkable_cells.has(cell + Vector2i.LEFT):
		return true
	if on_z_edge and _walkable_cells.has(cell + Vector2i.UP):
		return true
	return on_x_edge and on_z_edge and _walkable_cells.has(cell + Vector2i(-1, -1))
