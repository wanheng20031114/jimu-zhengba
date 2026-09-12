class_name PathCorridor
extends RefCounted
## A route has one forward-only cursor. Search results are data; sampling never
## invokes NavigationAgent's lazy replanning or changes the movement command.

const SHORTCUT_LOOKAHEAD: int = 12
var points := PackedVector3Array()
var index: int = 0
var segment_start := Vector3.ZERO
var finished: bool = false

func clear() -> void:
	points.clear()
	index = 0
	finished = true

func reset(path: PackedVector3Array, start: Vector3) -> void:
	# Remove numerical/collinear portal points, not obstacle-scale corners.
	points = NavigationServer3D.simplify_path(path, 0.001)
	index = 0
	segment_start = start
	finished = false

func next_position(at: Vector3, waypoint_distance: float, end_distance: float,
		lookahead: float, navigation: ConstructionNavigation, radius: float) -> Vector3:
	if points.is_empty() or finished:
		return at
	var last: int = points.size() - 1
	# Only a certified sweep can bypass an unreached corner. A passed waypoint
	# alone does not prove that cutting across a wall or a hairpin is safe.
	if navigation != null and index < last:
		if navigation.has_clear_corridor(at, points[last], radius):
			index = last
			segment_start = at
		else:
			var furthest: int = mini(last - 1, index + SHORTCUT_LOOKAHEAD)
			for candidate: int in range(furthest, index, -1):
				if navigation.has_clear_corridor(at, points[candidate], radius):
					index = candidate
					segment_start = at
					break
	while index < last:
		var point: Vector3 = points[index]
		var reached: bool = at.distance_squared_to(point) <= waypoint_distance * waypoint_distance
		var incoming: Vector3 = point - segment_start
		var passed: bool = incoming.length_squared() > 0.000001 and (at - point).dot(incoming) >= 0.0
		if not reached:
			# RVO can carry a unit beside a waypoint without entering its small
			# arrival circle. Rejoin the outgoing segment ahead, never chase that
			# old circle backwards if the entire forward connection is clear.
			var ahead: Vector3 = point.move_toward(points[index + 1], lookahead)
			if not passed or navigation == null or not navigation.has_clear_corridor(at, ahead, radius):
				break
		segment_start = point
		index += 1
	if index == last and at.distance_squared_to(points[last]) <= end_distance * end_distance:
		finished = true
		return at
	return points[index]

func distance_squared_to_segment(at: Vector3) -> float:
	if points.is_empty():
		return INF
	return at.distance_squared_to(Geometry3D.get_closest_point_to_segment(at, segment_start, points[index]))

func at_end(at: Vector3, tolerance: float) -> bool:
	return not points.is_empty() and index == points.size() - 1 and at.distance_squared_to(points[-1]) <= tolerance * tolerance
