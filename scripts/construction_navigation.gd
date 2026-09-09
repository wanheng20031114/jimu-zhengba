class_name ConstructionNavigation
extends Node
## Carve authored grid polygons only when building footprints change.
## The original meshes remain immutable and demolition patches retain exclusive
## cell ownership. No per-frame baking and no overlapping replacement regions.

const FOOTPRINT_HALF: float = 2.0
const NAV_PADDING: float = 1.15

var rebuild_count: int = 0
var last_rebuild_usec: int = 0
var _sources: Array[Dictionary] = []
var _blocked_cells: Dictionary = {}
var _walkable_cells: Dictionary = {}

func _cache_sources() -> void:
	if not _sources.is_empty():
		return
	var game: Node = get_parent()
	var regions: Array[NavigationRegion3D] = [game.get_node("NavigationRegion3D")]
	for region: NavigationRegion3D in game.get_node("ClearedNavigation").get_children():
		regions.append(region)
	for region: NavigationRegion3D in regions:
		var source: NavigationMesh = region.navigation_mesh
		var vertices: PackedVector3Array = source.get_vertices()
		var polygons: Array[PackedInt32Array] = []
		var cells: Array[Vector2i] = []
		for index: int in source.get_polygon_count():
			var polygon: PackedInt32Array = source.get_polygon(index)
			var center: Vector3 = Vector3.ZERO
			for vertex_index: int in polygon:
				center += vertices[vertex_index]
			center = region.to_global(center / float(polygon.size()))
			polygons.append(polygon)
			cells.append(Vector2i(floori(center.x), floori(center.z)))
		_sources.append({"region": region, "mesh": source, "polygons": polygons, "cells": cells})

func refresh() -> void:
	_cache_sources()
	var started: int = Time.get_ticks_usec()
	var occupied: Dictionary = {}
	for building: Node3D in get_tree().get_nodes_in_group("buildings"):
		if building.alive:
			for cell: Vector2i in footprint_cells(building.global_position, building.get_combat_definition().size):
				occupied[cell] = true
	var changed: bool = occupied != _blocked_cells
	_blocked_cells = occupied
	_walkable_cells.clear()
	for source: Dictionary in _sources:
		var region: NavigationRegion3D = source.region
		var replacement: NavigationMesh
		if changed and not occupied.is_empty():
			replacement = source.mesh.duplicate()
			replacement.clear_polygons()
		for index: int in source.cells.size():
			var cell: Vector2i = source.cells[index]
			if occupied.has(cell):
				continue
			if region.enabled:
				_walkable_cells[cell] = true
			if replacement != null:
				replacement.add_polygon(source.polygons[index])
		if changed:
			region.navigation_mesh = source.mesh if occupied.is_empty() else replacement
	if changed:
		rebuild_count += 1
	last_rebuild_usec = Time.get_ticks_usec() - started

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
