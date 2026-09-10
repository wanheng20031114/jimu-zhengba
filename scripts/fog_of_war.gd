class_name FogOfWar
extends Node3D
## Authoritative per-alliance vision and persistent terrain exploration.
## Enemy models exist only while currently visible; no remembered entity silhouettes.
## Cell states: 0 unknown, 1 remembered terrain, 2 currently visible.

signal visibility_updated(revision: int)

const CELL_SIZE: float = 2.0
const UPDATE_SECONDS: float = 0.2
const MAX_GRID_CELLS: int = 9216
var alliance_count: int = 2
const REVEAL_KINDS: Array[String] = ["headquarters", "barracks", "factory", "academy", "defense_tower", "enemy_keep", "tower"]
var revision: int = 0
var grid_size: Vector2i = Vector2i.ZERO
var map_size: Vector2 = Vector2.ZERO
var _game: Node3D
var _cells: Array[PackedByteArray] = []
var _participating_alliances: Array[int] = []
var _revealed: PackedByteArray = PackedByteArray()
var _tick_time: float = 0.0
var _local_owner: int = -1
var _applied_revision: int = -1
var _received_revision: int = -1
var _image: Image
var _texture: ImageTexture
var _display_nodes: Dictionary = {}
var _configured: bool = false
var _base64_pattern: RegEx = RegEx.create_from_string("^[A-Za-z0-9+/]*={0,2}$")

@onready var overlay: MeshInstance3D = $Overlay

func configure(game: Node3D, size: Vector2) -> void:
	assert(size.x > 0.0 and size.y > 0.0, "Fog requires positive map extents")
	_game = game
	map_size = size
	grid_size = Vector2i(ceili(size.x / CELL_SIZE), ceili(size.y / CELL_SIZE))
	assert(grid_size.x * grid_size.y <= MAX_GRID_CELLS, "Fog exceeds the supported map size")
	alliance_count = 0
	_participating_alliances.clear()
	for player: PlayerState in game.players:
		alliance_count = maxi(alliance_count, player.alliance_id + 1)
		if player.is_participating() and player.alliance_id not in _participating_alliances:
			_participating_alliances.append(player.alliance_id)
	assert(alliance_count > 0 and alliance_count <= NetworkProtocol.MAX_PLAYERS)
	_cells.clear()
	_revealed.resize(alliance_count)
	_revealed.fill(0)
	for alliance: int in range(alliance_count):
		var mask := PackedByteArray()
		mask.resize(grid_size.x * grid_size.y)
		mask.fill(0)
		_cells.append(mask)
	_display_nodes.clear()
	revision = 0
	_tick_time = 0.0
	_applied_revision = -1
	_received_revision = -1
	(overlay.mesh as PlaneMesh).size = size
	var material: ShaderMaterial = overlay.material_override
	material.set_shader_parameter("battlefield_size", size)
	_image = Image.create_from_data(grid_size.x, grid_size.y, false, Image.FORMAT_R8, _cells[0])
	_texture = ImageTexture.create_from_image(_image)
	material.set_shader_parameter("visibility_mask", _texture)
	_configured = true
	if _game.is_authority:
		_recompute()

func tick(delta: float) -> void:
	if not _configured or not _game.is_authority:
		return
	_tick_time += delta
	if _tick_time + 0.000001 < UPDATE_SECONDS:
		return
	_tick_time = maxf(0.0, fmod(_tick_time - UPDATE_SECONDS, UPDATE_SECONDS))
	_recompute()

func _recompute() -> void:
	var sources: Array[Node] = _game.get_tree().get_nodes_in_group("entities")
	for alliance: int in _participating_alliances:
		var previous: PackedByteArray = _cells[alliance]
		var mask := PackedByteArray()
		mask.resize(previous.size())
		# Each circular source contributes two endpoints per row. Resolve their
		# union once per cell instead of writing every overlapping soldier's disc.
		# Work is O(sources * sight_rows + map_cells), independent of overlap.
		var stride: int = grid_size.x + 1
		var spans := PackedInt32Array()
		spans.resize(stride * grid_size.y)
		spans.fill(0)
		for source: Node3D in sources:
			if source is BattleUnit:
				var unit: BattleUnit = source
				if unit.alive and unit.alliance_id == alliance:
					_accumulate_sight_spans(spans, unit.global_position, unit._stats.sight)
			elif source is BattleBuilding:
				var building: BattleBuilding = source
				if building.alive and building.alliance_id == alliance:
					_accumulate_sight_spans(spans, building.global_position, maxf(building.get_combat_definition().range + building.radius, 12.0))
		for z: int in range(grid_size.y):
			var row: int = z * grid_size.x
			var span_row: int = z * stride
			var coverage: int = 0
			for x: int in range(grid_size.x):
				coverage += spans[span_row + x]
				var index: int = row + x
				mask[index] = 2 if coverage > 0 else (1 if previous[index] > 0 else 0)
		_cells[alliance] = mask
	revision += 1
	visibility_updated.emit(revision)

func _accumulate_sight_spans(spans: PackedInt32Array, at: Vector3, sight: float) -> void:
	var minimum: Vector2i = _cell_unclamped(at - Vector3(sight, 0, sight))
	var maximum: Vector2i = _cell_unclamped(at + Vector3(sight, 0, sight))
	var radius_squared: float = sight * sight
	for z: int in range(maxi(0, minimum.y), mini(grid_size.y - 1, maximum.y) + 1):
		var dz: float = (z + 0.5) * CELL_SIZE - map_size.y * 0.5 - at.z
		var width_squared: float = radius_squared - dz * dz
		if width_squared < 0.0:
			continue
		# The same cell-centre circle as gameplay visibility, including map edges.
		var half_width: float = sqrt(width_squared)
		var left: int = maxi(0, ceili((at.x - half_width + map_size.x * 0.5) / CELL_SIZE - 0.5))
		var right: int = mini(grid_size.x - 1, floori((at.x + half_width + map_size.x * 0.5) / CELL_SIZE - 0.5))
		if left <= right:
			var row: int = z * (grid_size.x + 1)
			spans[row + left] += 1
			spans[row + right + 1] -= 1

func _cell_unclamped(at: Vector3) -> Vector2i:
	return Vector2i(floori((at.x + map_size.x * 0.5) / CELL_SIZE), floori((at.z + map_size.y * 0.5) / CELL_SIZE))

func _state(alliance: int, at: Vector3) -> int:
	var cell: Vector2i = _cell_unclamped(at)
	if cell.x < 0 or cell.y < 0 or cell.x >= grid_size.x or cell.y >= grid_size.y:
		return 0
	return _cells[alliance][cell.y * grid_size.x + cell.x]

func cell_state(owner: int, at: Vector3) -> int:
	return _state(_game.get_player(owner).alliance_id, at) if _configured and _game.get_player(owner).is_participating() else 0

func position_visible(owner: int, at: Vector3) -> bool:
	return cell_state(owner, at) == 2

func position_visible_to_alliance(alliance: int, at: Vector3) -> bool:
	# Authoritative units already bind their alliance at spawn. Resolve the cell
	# directly, without repeating player lookup for every target/range check.
	return _configured and _state(alliance, at) == 2

func building_visible_to_alliance(alliance: int, building: BattleBuilding) -> bool:
	return _configured and ((_revealed[building.alliance_id] != 0 and building.building_type in REVEAL_KINDS) or _footprint_visible(alliance, building.global_position, building.radius))

func explored(owner: int, at: Vector3) -> bool:
	return cell_state(owner, at) > 0

func _footprint_visible(alliance: int, at: Vector3, radius: float) -> bool:
	if _state(alliance, at) == 2:
		return true
	var low: Vector2i = _cell_unclamped(at - Vector3(radius, 0, radius))
	var high: Vector2i = _cell_unclamped(at + Vector3(radius, 0, radius))
	for z: int in range(maxi(0, low.y), mini(grid_size.y - 1, high.y) + 1):
		for x: int in range(maxi(0, low.x), mini(grid_size.x - 1, high.x) + 1):
			if _cells[alliance][z * grid_size.x + x] == 2:
				return true
	return false

func _entity_visible_to_alliance(alliance: int, entity: Node3D) -> bool:
	if entity.alliance_id == alliance:
		return true
	if entity.is_in_group("buildings"):
		if _revealed[entity.alliance_id] != 0 and entity.building_type in REVEAL_KINDS:
			return true
		return _footprint_visible(alliance, entity.global_position, entity.radius)
	return _state(alliance, entity.global_position) == 2

func entity_visible(owner: int, entity: Node3D) -> bool:
	return _configured and _game.get_player(owner).is_participating() and is_instance_valid(entity) and _entity_visible_to_alliance(_game.get_player(owner).alliance_id, entity)

func visible_entities(owner: int) -> Array[Node3D]:
	var result: Array[Node3D] = []
	for entity: Node3D in _game.get_tree().get_nodes_in_group("entities"):
		if entity.alive and entity_visible(owner, entity):
			result.append(entity)
	return result

func reveal_alliance_buildings(alliance: int) -> void:
	assert(alliance >= 0 and alliance < alliance_count)
	_revealed[alliance] = 1
	if _configured and _game.is_authority:
		_recompute()

func apply_entity_visibility(owner: int, entity: Node3D) -> void:
	if not _configured:
		return
	_display_nodes[entity.entity_id] = weakref(entity)
	var show: bool = explored(owner, entity.global_position) if entity.is_in_group("resource_veins") else entity_visible(owner, entity)
	if entity.visible != show:
		entity.visible = show
	if not show and entity.is_in_group("entities") and entity.selected:
		entity.set_selected(false)

func apply_visibility(owner: int) -> void:
	if not _configured or (_local_owner == owner and _applied_revision == revision):
		return
	_local_owner = owner
	_applied_revision = revision
	for entity: Node3D in _game.get_tree().get_nodes_in_group("entities"):
		_display_nodes[entity.entity_id] = weakref(entity)
	for mine: Node3D in _game.get_tree().get_nodes_in_group("resource_veins"):
		_display_nodes[mine.entity_id] = weakref(mine)
	for id: int in _display_nodes.keys():
		var entity: Node3D = _display_nodes[id].get_ref()
		if not is_instance_valid(entity):
			_display_nodes.erase(id)
			continue
		apply_entity_visibility(owner, entity)
	_update_texture(_game.get_player(owner).alliance_id)

func _update_texture(alliance: int) -> void:
	# The shader decodes native byte states directly; no RGBA repacking or texture allocation.
	_image.set_data(grid_size.x, grid_size.y, false, Image.FORMAT_R8, _cells[alliance])
	_texture.update(_image)

func visibility_texture() -> Texture2D:
	# The local battlefield and minimap consume the very same fog revision.
	return _texture

func snapshot_for(owner: int) -> Dictionary:
	var alliance: int = _game.get_player(owner).alliance_id
	return {"owner_id": owner, "alliance_id": alliance, "map_size": [map_size.x, map_size.y],
		"width": grid_size.x, "height": grid_size.y, "revision": revision,
		"cells": Marshalls.raw_to_base64(_cells[alliance]),
		"revealed_building_alliances": Array(_revealed)}

func apply_snapshot(data: Dictionary) -> bool:
	if not _configured or _game.is_authority:
		return false
	var required: Array[String] = ["owner_id", "alliance_id", "map_size", "width", "height", "revision", "cells", "revealed_building_alliances"]
	# Fog carries terrain states and explicit public reveal rules, never entity memories.
	if data.size() != required.size():
		return false
	for key: String in required:
		if not data.has(key):
			return false
	for key: String in ["owner_id", "alliance_id", "width", "height", "revision"]:
		if not _wire_integer(data[key]):
			return false
	if not _wire_vector(data.map_size, 2) or Vector2(float(data.map_size[0]), float(data.map_size[1])) != map_size:
		return false
	var owner: int = int(data.owner_id)
	var alliance: int = int(data.alliance_id)
	if owner < 0 or owner >= _game.players.size() or not _game.get_player(owner).is_participating() or alliance < 0 or alliance >= alliance_count or _game.get_player(owner).alliance_id != alliance:
		return false
	if int(data.width) != grid_size.x or int(data.height) != grid_size.y or int(data.revision) <= _received_revision or int(data.revision) > 2147483647:
		return false
	if not data.cells is String:
		return false
	var encoded: String = data.cells
	if encoded.length() != 4 * ceili(grid_size.x * grid_size.y / 3.0) or _base64_pattern.search(encoded) == null:
		return false
	var cells: PackedByteArray = Marshalls.base64_to_raw(encoded)
	if cells.size() != grid_size.x * grid_size.y:
		return false
	for state: int in cells:
		if state > 2:
			return false
	if not data.revealed_building_alliances is Array or data.revealed_building_alliances.size() != alliance_count:
		return false
	for value: Variant in data.revealed_building_alliances:
		if not _wire_integer(value) or int(value) < 0 or int(value) > 1:
			return false
	var revealed := PackedByteArray(data.revealed_building_alliances)
	_cells[alliance] = cells.duplicate()
	_revealed = revealed.duplicate()
	revision = int(data.revision)
	_received_revision = revision
	_applied_revision = -1
	visibility_updated.emit(revision)
	return true

func _wire_integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and absf(float(value)) <= 2147483647.0

func _wire_vector(value: Variant, length: int) -> bool:
	if not value is Array or value.size() != length:
		return false
	for component: Variant in value:
		if not (component is int or component is float) or not is_finite(float(component)):
			return false
	return true
