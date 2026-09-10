class_name SharedFlowField
extends RefCounted
## Shared-goal reverse Dijkstra on an immutable one-metre XZ grid.
## This first implementation builds one dense field per goal/clearance/cost
## class, not a hierarchical or tiled flow. Its owner supplies shared caching.
## Build on a worker; publish only after joining it. No Node/server access.

enum BuildStatus { BUILDING, READY, INVALID_INPUT, GOAL_OUTSIDE, GOAL_BLOCKED }
enum SampleStatus { MOVING, ARRIVED, BLOCKED, UNREACHABLE, OUTSIDE, NOT_READY, INVALID_FIELD }

const INFINITY_COST: int = 2147483647
const ARRIVED_DIRECTION: int = 8
const BLOCKED_DIRECTION: int = 254
const UNREACHABLE_DIRECTION: int = 255
const OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
]
const UNIT_DIRECTIONS: Array[Vector2] = [
	Vector2(1, 0), Vector2(0.7071067811865475, 0.7071067811865475),
	Vector2(0, 1), Vector2(-0.7071067811865475, 0.7071067811865475),
	Vector2(-1, 0), Vector2(-0.7071067811865475, -0.7071067811865475),
	Vector2(0, -1), Vector2(0.7071067811865475, -0.7071067811865475),
]

var status: BuildStatus = BuildStatus.BUILDING
var revision: int = 0
var origin := Vector2i.ZERO
var size := Vector2i.ZERO
var goal_cell := Vector2i.ZERO
var body_radius: float = 0.0
var integration := PackedInt32Array()
var directions := PackedByteArray()
var expanded_cells: int = 0
var heap_peak: int = 0
var build_usec: int = 0


static func build(blocked: PackedByteArray, grid_origin: Vector2i, grid_size: Vector2i,
		goal: Vector2i, radius: float, grid_revision: int,
		costs: PackedByteArray = PackedByteArray()) -> SharedFlowField:
	var builder: Builder = create_builder(blocked, grid_origin, grid_size, goal, radius, grid_revision, costs)
	while not builder.advance(4096):
		pass
	return builder.result


static func create_builder(blocked: PackedByteArray, grid_origin: Vector2i, grid_size: Vector2i,
		goal: Vector2i, radius: float, grid_revision: int,
		costs: PackedByteArray = PackedByteArray()) -> Builder:
	return Builder.new(blocked, grid_origin, grid_size, goal, radius, grid_revision, costs)


func index_at(point: Vector2) -> int:
	var cell := Vector2i(floori(point.x), floori(point.y)) - origin
	if cell.x < 0 or cell.y < 0 or cell.x >= size.x or cell.y >= size.y:
		return -1
	return cell.y * size.x + cell.x


func status_at(point: Vector2) -> SampleStatus:
	if status == BuildStatus.BUILDING:
		return SampleStatus.NOT_READY
	if status != BuildStatus.READY:
		return SampleStatus.INVALID_FIELD
	var index: int = index_at(point)
	if index < 0:
		return SampleStatus.OUTSIDE
	var direction: int = directions[index]
	if direction < ARRIVED_DIRECTION:
		return SampleStatus.MOVING
	if direction == ARRIVED_DIRECTION:
		return SampleStatus.ARRIVED
	if direction == BLOCKED_DIRECTION:
		return SampleStatus.BLOCKED
	return SampleStatus.UNREACHABLE


func direction_at(point: Vector2) -> Vector2:
	if status != BuildStatus.READY:
		return Vector2.ZERO
	var index: int = index_at(point)
	if index < 0 or directions[index] >= ARRIVED_DIRECTION:
		return Vector2.ZERO
	return UNIT_DIRECTIONS[directions[index]]


func next_position_at(point: Vector2) -> Vector2:
	## A centre waypoint, not a guarantee that an arbitrary off-centre point
	## can sweep to it. The movement layer must retain static-collision checks.
	## ARRIVED means this goal cell was reached, not the exact rally position.
	if status != BuildStatus.READY:
		return Vector2(INF, INF)
	var index: int = index_at(point)
	if index < 0 or directions[index] > ARRIVED_DIRECTION:
		return Vector2(INF, INF)
	var cell := Vector2i(floori(point.x), floori(point.y))
	if directions[index] < ARRIVED_DIRECTION:
		cell += OFFSETS[directions[index]]
	return Vector2(cell) + Vector2(0.5, 0.5)


class Builder extends RefCounted:
	## advance() bounds Dijkstra expansions; setup/clearance is O(grid cells).
	## Both setup and expansion belong on the worker. Each builder has exactly
	## one writer, and its result must not be sampled until the worker joins.
	var result: SharedFlowField
	var _costs := PackedByteArray()
	var _heap := PackedInt32Array()
	var _heap_positions := PackedInt32Array()
	var _heap_count: int = 0
	var _began_usec: int = 0

	func _init(blocked: PackedByteArray, grid_origin: Vector2i, grid_size: Vector2i,
			goal: Vector2i, radius: float, grid_revision: int, costs: PackedByteArray) -> void:
		_began_usec = Time.get_ticks_usec()
		result = SharedFlowField.new()
		result.origin = grid_origin
		result.size = grid_size
		result.goal_cell = goal
		result.body_radius = radius
		result.revision = grid_revision
		var count: int = grid_size.x * grid_size.y
		if grid_size.x <= 0 or grid_size.y <= 0 or blocked.size() != count or not is_finite(radius) or radius < 0.0:
			_finish(BuildStatus.INVALID_INPUT)
			return
		if not costs.is_empty() and costs.size() != count:
			_finish(BuildStatus.INVALID_INPUT)
			return
		var maximum_cost: int = 1
		for index: int in costs.size():
			if blocked[index] == 0 and costs[index] == 0:
				_finish(BuildStatus.INVALID_INPUT)
				return
			maximum_cost = maxi(maximum_cost, costs[index])
		# An optimal positive-cost route never needs more than count-1 edges.
		# Refuse an input whose distance cannot fit the public packed Int32 data.
		if count * 14 * maximum_cost >= INFINITY_COST:
			_finish(BuildStatus.INVALID_INPUT)
			return
		var relative_goal: Vector2i = goal - grid_origin
		if relative_goal.x < 0 or relative_goal.y < 0 or relative_goal.x >= grid_size.x or relative_goal.y >= grid_size.y:
			_finish(BuildStatus.GOAL_OUTSIDE)
			return
		result.integration.resize(count)
		result.integration.fill(INFINITY_COST)
		if radius * 2.0 >= float(mini(grid_size.x, grid_size.y)):
			# No centre can fit this body inside the grid; avoid allocating a
			# radius-sized stencil for a mathematically impossible request.
			result.directions.resize(count)
			result.directions.fill(BLOCKED_DIRECTION)
			_finish(BuildStatus.GOAL_BLOCKED)
			return
		result.directions = _clearance_directions(blocked, grid_size, radius)
		var goal_index: int = relative_goal.y * grid_size.x + relative_goal.x
		if result.directions[goal_index] == BLOCKED_DIRECTION:
			_finish(BuildStatus.GOAL_BLOCKED)
			return
		_costs = costs.duplicate()
		_heap.resize(count)
		_heap_positions.resize(count)
		_heap_positions.fill(-1)
		result.integration[goal_index] = 0
		result.directions[goal_index] = ARRIVED_DIRECTION
		_push_or_decrease(goal_index)

	func advance(max_expansions: int) -> bool:
		if result.status != BuildStatus.BUILDING:
			return true
		var budget: int = maxi(0, max_expansions)
		var width: int = result.size.x
		var height: int = result.size.y
		while _heap_count > 0 and budget > 0:
			budget -= 1
			var current: int = _pop()
			result.expanded_cells += 1
			var x: int = current % width
			@warning_ignore("integer_division")
			var y: int = current / width
			var base_cost: int = result.integration[current]
			# Reverse the directed edge: a predecessor pays for entering current.
			var traversal_cost: int = 1 if _costs.is_empty() else int(_costs[current])
			for direction: int in 8:
				var offset: Vector2i = OFFSETS[direction]
				var next_x: int = x + offset.x
				var next_y: int = y + offset.y
				if next_x < 0 or next_y < 0 or next_x >= width or next_y >= height:
					continue
				var next: int = current + offset.x + offset.y * width
				if result.directions[next] == BLOCKED_DIRECTION or _heap_positions[next] == -2:
					continue
				var diagonal: bool = offset.x != 0 and offset.y != 0
				if diagonal and (result.directions[current + offset.x] == BLOCKED_DIRECTION or result.directions[current + offset.y * width] == BLOCKED_DIRECTION):
					continue
				var candidate: int = base_cost + (14 if diagonal else 10) * traversal_cost
				if candidate < result.integration[next]:
					result.integration[next] = candidate
					result.directions[next] = (direction + 4) % 8
					_push_or_decrease(next)
		if _heap_count == 0:
			_finish(BuildStatus.READY)
			return true
		return false

	func _finish(completion: BuildStatus) -> void:
		result.status = completion
		result.build_usec = Time.get_ticks_usec() - _began_usec

	func _precedes(a: int, b: int) -> bool:
		var a_cost: int = result.integration[a]
		var b_cost: int = result.integration[b]
		return a_cost < b_cost or (a_cost == b_cost and a < b)

	func _push_or_decrease(cell: int) -> void:
		var at: int = _heap_positions[cell]
		if at < 0:
			at = _heap_count
			_heap_count += 1
			result.heap_peak = maxi(result.heap_peak, _heap_count)
		while at > 0:
			@warning_ignore("integer_division")
			var parent: int = (at - 1) / 2
			var parent_cell: int = _heap[parent]
			if not _precedes(cell, parent_cell):
				break
			_heap[at] = parent_cell
			_heap_positions[parent_cell] = at
			at = parent
		_heap[at] = cell
		_heap_positions[cell] = at

	func _pop() -> int:
		var result_cell: int = _heap[0]
		_heap_count -= 1
		_heap_positions[result_cell] = -2
		if _heap_count == 0:
			return result_cell
		var tail: int = _heap[_heap_count]
		var at: int = 0
		while at * 2 + 1 < _heap_count:
			var child: int = at * 2 + 1
			if child + 1 < _heap_count and _precedes(_heap[child + 1], _heap[child]):
				child += 1
			var child_cell: int = _heap[child]
			if not _precedes(child_cell, tail):
				break
			_heap[at] = child_cell
			_heap_positions[child_cell] = at
			at = child
		_heap[at] = tail
		_heap_positions[tail] = at
		return result_cell

	static func _clearance_directions(blocked: PackedByteArray, grid_size: Vector2i, radius: float) -> PackedByteArray:
		# Test a circular body at the cell centre against blocked cell squares.
		# Adjacent squares begin .5 metres away: radius .48 keeps them clear,
		# radius .5 touches them and is rejected. Each stencil row is one prefix
		# lookup, without per-cell obstacle scans or overly wide square padding.
		var padding: int = floori(radius + 0.5)
		var row_extents := PackedInt32Array()
		row_extents.resize(padding * 2 + 1)
		for offset: int in range(-padding, padding + 1):
			var dy: float = maxf(0.0, absf(float(offset)) - 0.5)
			row_extents[offset + padding] = floori(sqrt(maxf(0.0, radius * radius - dy * dy)) + 0.5)
		var width: int = grid_size.x
		var height: int = grid_size.y
		var stride: int = width + 1
		var prefix := PackedInt32Array()
		prefix.resize(stride * (height + 1))
		for y: int in height:
			var row_total: int = 0
			for x: int in width:
				row_total += 1 if blocked[y * width + x] != 0 else 0
				prefix[(y + 1) * stride + x + 1] = prefix[y * stride + x + 1] + row_total
		var output := PackedByteArray()
		output.resize(width * height)
		output.fill(UNREACHABLE_DIRECTION)
		for y: int in height:
			for x: int in width:
				var index: int = y * width + x
				if y - padding < 0 or y + padding >= height:
					output[index] = BLOCKED_DIRECTION
					continue
				for offset: int in range(-padding, padding + 1):
					var extent: int = row_extents[offset + padding]
					var left: int = x - extent
					var right: int = x + extent + 1
					if left < 0 or right > width:
						output[index] = BLOCKED_DIRECTION
						break
					var row: int = y + offset
					var blockers: int = prefix[(row + 1) * stride + right] - prefix[row * stride + right] - prefix[(row + 1) * stride + left] + prefix[row * stride + left]
					if blockers > 0:
						output[index] = BLOCKED_DIRECTION
						break
		return output
