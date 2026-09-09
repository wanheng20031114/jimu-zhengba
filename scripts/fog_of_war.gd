class_name FogOfWar
extends Node3D
## Authoritative per-alliance vision, persistent exploration and frozen building memories.
## Cell states: 0 unknown, 1 remembered terrain, 2 currently visible.

signal visibility_updated(revision: int)

const CELL_SIZE: float = 2.0
const UPDATE_SECONDS: float = 0.2
const MAX_GRID_CELLS: int = 9216
var alliance_count: int = 2
const REVEAL_KINDS: Array[String] = ["headquarters", "barracks", "factory", "academy", "defense_tower", "enemy_keep", "tower"]
const MEMORY_MODELS: Dictionary = {
	"headquarters": preload("res://assets/models/environment/headquarters.tscn"),
	"enemy_keep": preload("res://assets/models/environment/enemy_keep.tscn"),
	"barracks": preload("res://assets/models/environment/player_barracks.tscn"),
	"factory": preload("res://assets/models/environment/factory.tscn"),
	"academy": preload("res://assets/models/environment/academy.tscn"),
	"defense_tower": preload("res://assets/models/environment/defense_tower.tscn"),
	"tower": preload("res://assets/models/environment/tower.tscn"),
	"house": preload("res://assets/models/environment/house.tscn"),
}

@export var memory_material: ShaderMaterial
var revision: int = 0
var grid_size: Vector2i = Vector2i.ZERO
var map_size: Vector2 = Vector2.ZERO
var _game: Node3D
var _cells: Array[PackedByteArray] = []
var _last_seen: Array[Dictionary] = []
var _revealed: PackedByteArray = PackedByteArray()
var _tick_time: float = 0.0
var _local_owner: int = -1
var _applied_revision: int = -1
var _received_revision: int = -1
var _image: Image
var _texture: ImageTexture
var _display_nodes: Dictionary = {}
var _memory_nodes: Dictionary = {}
var _memory_versions: Dictionary = {}
var _configured: bool = false
var _base64_pattern: RegEx = RegEx.create_from_string("^[A-Za-z0-9+/]*={0,2}$")

@onready var overlay: MeshInstance3D = $Overlay
@onready var memory_root: Node3D = $Memory

func configure(game: Node3D, size: Vector2) -> void:
	assert(size.x > 0.0 and size.y > 0.0, "Fog requires positive map extents")
	_game = game
	map_size = size
	grid_size = Vector2i(ceili(size.x / CELL_SIZE), ceili(size.y / CELL_SIZE))
	assert(grid_size.x * grid_size.y <= MAX_GRID_CELLS, "Fog exceeds the supported map size")
	alliance_count = 0
	for player: PlayerState in game.players:
		alliance_count = maxi(alliance_count, player.alliance_id + 1)
	assert(alliance_count > 0 and alliance_count <= NetworkProtocol.MAX_PLAYERS)
	_cells.clear()
	_last_seen.clear()
	_revealed.resize(alliance_count)
	_revealed.fill(0)
	for alliance: int in range(alliance_count):
		var mask := PackedByteArray()
		mask.resize(grid_size.x * grid_size.y)
		mask.fill(0)
		_cells.append(mask)
		_last_seen.append({})
	_display_nodes.clear()
	_clear_memory_models()
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
	for alliance: int in range(alliance_count):
		var previous: PackedByteArray = _cells[alliance]
		var mask := PackedByteArray()
		mask.resize(previous.size())
		for index: int in range(previous.size()):
			mask[index] = 1 if previous[index] > 0 else 0
		for source: Node3D in sources:
			if not source.alive or source.alliance_id != alliance:
				continue
			var definition: CombatDefinition = source.get_combat_definition()
			var sight: float = maxf(definition.range + source.radius, 12.0) if source.is_in_group("buildings") else (definition as UnitDefinition).sight
			_stamp_circle(mask, source.global_position, sight)
		_cells[alliance] = mask
	revision += 1
	_remember_buildings(sources)
	visibility_updated.emit(revision)

func _stamp_circle(mask: PackedByteArray, at: Vector3, sight: float) -> void:
	var minimum: Vector2i = _cell_unclamped(at - Vector3(sight, 0, sight))
	var maximum: Vector2i = _cell_unclamped(at + Vector3(sight, 0, sight))
	var radius_squared: float = sight * sight
	for z: int in range(maxi(0, minimum.y), mini(grid_size.y - 1, maximum.y) + 1):
		var dz: float = (z + 0.5) * CELL_SIZE - map_size.y * 0.5 - at.z
		var width_squared: float = radius_squared - dz * dz
		if width_squared < 0.0:
			continue
		# Solve each circle row once; its contiguous span needs no per-cell distance math.
		var half_width: float = sqrt(width_squared)
		var left: int = maxi(0, ceili((at.x - half_width + map_size.x * 0.5) / CELL_SIZE - 0.5))
		var right: int = mini(grid_size.x - 1, floori((at.x + half_width + map_size.x * 0.5) / CELL_SIZE - 0.5))
		var row: int = z * grid_size.x
		for index: int in range(row + left, row + right + 1):
			mask[index] = 2

func _cell_unclamped(at: Vector3) -> Vector2i:
	return Vector2i(floori((at.x + map_size.x * 0.5) / CELL_SIZE), floori((at.z + map_size.y * 0.5) / CELL_SIZE))

func _state(alliance: int, at: Vector3) -> int:
	var cell: Vector2i = _cell_unclamped(at)
	if cell.x < 0 or cell.y < 0 or cell.x >= grid_size.x or cell.y >= grid_size.y:
		return 0
	return _cells[alliance][cell.y * grid_size.x + cell.x]

func cell_state(owner: int, at: Vector3) -> int:
	return _state(_game.get_player(owner).alliance_id, at) if _configured else 0

func position_visible(owner: int, at: Vector3) -> bool:
	return cell_state(owner, at) == 2

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
	return _configured and is_instance_valid(entity) and _entity_visible_to_alliance(_game.get_player(owner).alliance_id, entity)

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

func _remember_buildings(entities: Array[Node]) -> void:
	for alliance: int in range(alliance_count):
		var observed: Dictionary = {}
		for entity: Node3D in entities:
			if not entity.is_in_group("buildings") or entity.alliance_id == alliance or not _entity_visible_to_alliance(alliance, entity):
				continue
			if not entity.alive:
				_last_seen[alliance].erase(entity.entity_id)
				continue
			observed[entity.entity_id] = true
			var at: Vector3 = entity.global_position
			var orientation: Vector3 = entity.global_rotation
			_last_seen[alliance][entity.entity_id] = {"id": entity.entity_id, "kind": entity.building_type,
				"owner_id": entity.owner_id, "alliance_id": entity.alliance_id,
				"position": [at.x, at.y, at.z], "rotation": [orientation.x, orientation.y, orientation.z],
				"radius": entity.radius, "construction_progress": entity.construction_progress,
				"last_seen_revision": revision}
		for id: int in _last_seen[alliance].keys():
			var record: Dictionary = _last_seen[alliance][id]
			var permanently_revealed: bool = _revealed[int(record.alliance_id)] != 0 and record.kind in REVEAL_KINDS
			if not observed.has(id) and (permanently_revealed or _footprint_visible(alliance, _record_position(record), float(record.radius))):
				_last_seen[alliance].erase(id)

func last_seen_buildings(owner: int) -> Dictionary:
	return _last_seen[_game.get_player(owner).alliance_id].duplicate(true)

func _record_position(record: Dictionary) -> Vector3:
	var at: Array = record.position
	return Vector3(float(at[0]), float(at[1]), float(at[2]))

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
	if _local_owner != owner:
		_clear_memory_models()
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
	_update_memory_models(_game.get_player(owner).alliance_id)

func _update_texture(alliance: int) -> void:
	# The shader decodes native byte states directly; no RGBA repacking or texture allocation.
	_image.set_data(grid_size.x, grid_size.y, false, Image.FORMAT_R8, _cells[alliance])
	_texture.update(_image)

func _update_memory_models(alliance: int) -> void:
	var needed: Dictionary = {}
	for id: int in _last_seen[alliance]:
		var record: Dictionary = _last_seen[alliance][id]
		var currently_visible: bool = _footprint_visible(alliance, _record_position(record), float(record.radius)) or (_revealed[int(record.alliance_id)] != 0 and record.kind in REVEAL_KINDS)
		if currently_visible:
			continue
		needed[id] = true
		if _memory_nodes.has(id) and int(_memory_versions[id]) == int(record.last_seen_revision):
			continue
		_remove_memory_model(id)
		var model: Node3D = MEMORY_MODELS[record.kind].instantiate()
		_prepare_static_model(model, float(record.construction_progress) if record.kind == "defense_tower" else 1.0)
		model.name = "Remembered_%d" % id
		memory_root.add_child(model)
		model.global_position = _record_position(record)
		var angles: Array = record.rotation
		model.global_rotation = Vector3(float(angles[0]), float(angles[1]), float(angles[2]))
		if record.kind != "defense_tower":
			model.scale.y *= 0.08 + float(record.construction_progress) * 0.92
		_memory_nodes[id] = model
		_memory_versions[id] = int(record.last_seen_revision)
	for id: int in _memory_nodes.keys():
		if not needed.has(id):
			_remove_memory_model(id)

func _prepare_static_model(node: Node, construction: float) -> void:
	node.set_script(null)
	node.process_mode = Node.PROCESS_MODE_DISABLED
	for child: Node in node.get_children():
		if child is CollisionObject3D or child is CollisionShape3D or child is AnimationPlayer or child is AnimationTree or child is AudioStreamPlayer3D or child is GPUParticles3D or child is CPUParticles3D:
			child.free()
		else:
			_prepare_static_model(child, construction)
	if node is MeshInstance3D:
		node.material_override = memory_material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.set_instance_shader_parameter("memory_construction_height", 6.0 * construction if construction < 1.0 else 1000000.0)

func _remove_memory_model(id: int) -> void:
	if not _memory_nodes.has(id):
		return
	var model: Node3D = _memory_nodes[id]
	memory_root.remove_child(model)
	model.queue_free()
	_memory_nodes.erase(id)
	_memory_versions.erase(id)

func _clear_memory_models() -> void:
	for id: int in _memory_nodes.keys():
		_remove_memory_model(id)

func snapshot_for(owner: int) -> Dictionary:
	var alliance: int = _game.get_player(owner).alliance_id
	return {"owner_id": owner, "alliance_id": alliance, "map_size": [map_size.x, map_size.y],
		"width": grid_size.x, "height": grid_size.y, "revision": revision,
		"cells": Marshalls.raw_to_base64(_cells[alliance]), "buildings": _last_seen[alliance].values().duplicate(true),
		"revealed_building_alliances": Array(_revealed)}

func apply_snapshot(data: Dictionary) -> bool:
	if not _configured or _game.is_authority:
		return false
	var required: Array[String] = ["owner_id", "alliance_id", "map_size", "width", "height", "revision", "cells", "buildings", "revealed_building_alliances"]
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
	if owner < 0 or owner >= _game.players.size() or alliance < 0 or alliance >= alliance_count or _game.get_player(owner).alliance_id != alliance:
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
	if not data.buildings is Array or data.buildings.size() > 512:
		return false
	var memories: Dictionary = {}
	for value: Variant in data.buildings:
		if not value is Dictionary:
			return false
		var record: Dictionary = value
		if not _valid_memory_record(record, alliance, int(data.revision)) or memories.has(int(record.id)):
			return false
		# Copy exactly the public memory contract. Extra live-health fields never enter it.
		memories[int(record.id)] = {"id": int(record.id), "kind": record.kind, "owner_id": int(record.owner_id),
			"alliance_id": int(record.alliance_id), "position": record.position.duplicate(), "rotation": record.rotation.duplicate(),
			"radius": float(record.radius), "construction_progress": float(record.construction_progress),
			"last_seen_revision": int(record.last_seen_revision)}
	if not data.revealed_building_alliances is Array or data.revealed_building_alliances.size() != alliance_count:
		return false
	for value: Variant in data.revealed_building_alliances:
		if not _wire_integer(value) or int(value) < 0 or int(value) > 1:
			return false
	var revealed := PackedByteArray(data.revealed_building_alliances)
	_cells[alliance] = cells.duplicate()
	_last_seen[alliance] = memories
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

func _valid_memory_record(record: Dictionary, receiving_alliance: int, packet_revision: int) -> bool:
	for key: String in ["id", "kind", "owner_id", "alliance_id", "position", "rotation", "radius", "construction_progress", "last_seen_revision"]:
		if not record.has(key):
			return false
	for key: String in ["id", "owner_id", "alliance_id", "last_seen_revision"]:
		if not _wire_integer(record[key]):
			return false
	if not record.kind is String or not MEMORY_MODELS.has(record.kind) or int(record.id) <= 0:
		return false
	var owner: int = int(record.owner_id)
	if owner < 0 or owner >= _game.players.size() or int(record.alliance_id) == receiving_alliance or _game.get_player(owner).alliance_id != int(record.alliance_id):
		return false
	if int(record.last_seen_revision) < 0 or int(record.last_seen_revision) > packet_revision:
		return false
	if not _wire_vector(record.position, 3) or not _wire_vector(record.rotation, 3):
		return false
	if absf(float(record.position[0])) > map_size.x * 0.5 or absf(float(record.position[2])) > map_size.y * 0.5 or absf(float(record.position[1])) > 32.0:
		return false
	for angle: Variant in record.rotation:
		if absf(float(angle)) > TAU:
			return false
	for key: String in ["radius", "construction_progress"]:
		if not (record[key] is int or record[key] is float) or not is_finite(float(record[key])):
			return false
	return float(record.radius) > 0.0 and float(record.radius) <= 12.0 and float(record.construction_progress) >= 0.0 and float(record.construction_progress) <= 1.0
