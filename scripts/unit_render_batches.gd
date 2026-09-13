class_name UnitRenderBatches
extends Node3D
## Batched presentation only. All animation, visibility tracks and sockets
## stay in the original Node3D hierarchy. Authored MultiMeshes share source meshes.
## https://docs.godotengine.org/en/4.6/classes/class_multimesh.html

@export_range(1, 2048, 1) var initial_capacity: int = 128
# Small armies retain native per-part interpolation at high display rates.
@export_range(1, 2048, 1) var render_sampled_threshold: int = 192

class PartBatch extends RefCounted:
	var node: MultiMeshInstance3D
	var mesh: MultiMesh
	var count: int = 0
	var colors := PackedColorArray()
	var owners := PackedInt64Array()
	var part_indices := PackedInt32Array()

class ModelEntry extends RefCounted:
	var model: UnitVisual
	var pose_root: Node3D
	var authority: bool
	var id: int
	var parts: Array[Node3D] = []
	var batches: Array[PartBatch] = []
	var slots := PackedInt32Array()
	var custom: Color
	var active: bool = false

var registered_models: int = 0
var visible_models: int = 0
var submitted_parts: int = 0
var capacity_growths: int = 0
var slot_changes: int = 0
var custom_uploads: int = 0

var _batches: Array[PartBatch] = []
var _batch_by_key: Dictionary[StringName, PartBatch] = {}
var _models: Array[ModelEntry] = []
var _model_index: Dictionary[int, int] = {}
var _kind_count: Dictionary[String, int] = {}
var _render_sampling: bool = false

func _ready() -> void:
	# World-space interpolated transforms are submitted below; applying native
	# MultiMesh interpolation again would interpolate different dense slot owners.
	assert(global_transform.is_equal_approx(Transform3D.IDENTITY), "Batch manager receives world-space transforms")
	for child: Node in get_children():
		var display: MultiMeshInstance3D = child as MultiMeshInstance3D
		assert(display != null and display.has_meta("batch_key"))
		assert(display.transform.is_equal_approx(Transform3D.IDENTITY))
		assert(display.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF)
		var batch := PartBatch.new()
		batch.node = display
		batch.mesh = display.multimesh
		assert(batch.mesh != null and batch.mesh.mesh != null)
		assert(batch.mesh.resource_local_to_scene, "Each match owns mutable MultiMesh buffers")
		assert(batch.mesh.use_custom_data and not batch.mesh.use_colors)
		var key: StringName = display.get_meta("batch_key")
		assert(not _batch_by_key.has(key))
		_batch_by_key[key] = batch
		_batches.append(batch)
		batch.mesh.visible_instance_count = 0
		batch.node.hide()
	set_process(false)

func register_model(model: UnitVisual, relation: int, authority: bool = true) -> void:
	var id: int = model.get_instance_id()
	assert(not _model_index.has(id), "A model must be registered once")
	assert(not model.batch_parts.is_empty(), "Batch model must carry authored part paths")
	var entry := ModelEntry.new()
	entry.model = model
	entry.pose_root = model.get_parent()
	entry.authority = authority
	entry.id = id
	entry.custom = FactionPalette.model_color(relation).srgb_to_linear()
	entry.custom.a = 1.0
	var kind_count: int = int(_kind_count.get(model.kind, 0)) + 1
	_kind_count[model.kind] = kind_count
	for path: NodePath in model.batch_parts:
		var key := StringName(model.kind + "::" + String(path))
		assert(_batch_by_key.has(key), "Missing authored part batch: " + String(key))
		var batch: PartBatch = _batch_by_key[key]
		assert(batch.mesh.mesh == model.batch_parts[path], "Batch must preserve its original mesh and LODs")
		var part: Node3D = model.get_node(path)
		assert(not part is GeometryInstance3D, "Batch rig must use transform proxies")
		entry.parts.append(part)
		entry.batches.append(batch)
		_ensure_capacity(batch, kind_count)
	entry.slots.resize(entry.parts.size())
	entry.slots.fill(-1)
	_model_index[id] = _models.size()
	_models.append(entry)
	for part_index: int in entry.parts.size():
		entry.parts[part_index].visibility_changed.connect(_on_part_visibility_changed.bind(id, part_index))
	registered_models = _models.size()
	_update_animation_sampling()
	if authority:
		model.set_render_sampled_animation(_render_sampling)
	set_process(true)

func unregister_model(model: UnitVisual) -> void:
	var id: int = model.get_instance_id()
	if not _model_index.has(id):
		return
	var index: int = _model_index[id]
	var entry: ModelEntry = _models[index]
	# Deletion can flush after our display callback. Compact native slots now,
	# including the moved owner's reverse index, so no corpse/colour can linger.
	for part_index: int in entry.batches.size():
		entry.parts[part_index].visibility_changed.disconnect(_on_part_visibility_changed.bind(id, part_index))
		_remove_part(entry, part_index)
	_kind_count[model.kind] = int(_kind_count[model.kind]) - 1
	var last: int = _models.size() - 1
	if index != last:
		_models[index] = _models[last]
		_model_index[_models[index].id] = index
	_models.pop_back()
	_model_index.erase(id)
	registered_models = _models.size()
	_update_animation_sampling()
	if _models.is_empty():
		for batch: PartBatch in _batches:
			batch.mesh.visible_instance_count = 0
			batch.node.hide()
		visible_models = 0
		submitted_parts = 0
		set_process(false)

func _update_animation_sampling() -> void:
	var enabled: bool = registered_models >= render_sampled_threshold
	if enabled == _render_sampling:
		return
	_render_sampling = enabled
	for entry: ModelEntry in _models:
		if entry.authority:
			entry.model.set_render_sampled_animation(enabled)

func set_team(model: UnitVisual, relation: int) -> void:
	var entry: ModelEntry = _models[_model_index[model.get_instance_id()]]
	var color: Color = FactionPalette.model_color(relation).srgb_to_linear()
	color.a = entry.custom.a
	entry.custom = color
	_update_custom(entry)

func set_fade(model: UnitVisual, amount: float) -> void:
	var entry: ModelEntry = _models[_model_index[model.get_instance_id()]]
	entry.custom.a = 1.0 - clampf(amount, 0.0, 1.0)
	if entry.custom.a <= 0.0:
		_set_active(entry, false)
	else:
		_update_custom(entry)

func _update_custom(entry: ModelEntry) -> void:
	for part_index: int in entry.parts.size():
		var slot: int = entry.slots[part_index]
		if slot < 0:
			continue
		var batch: PartBatch = entry.batches[part_index]
		if batch.colors[slot] != entry.custom:
			batch.mesh.set_instance_custom_data(slot, entry.custom)
			batch.colors[slot] = entry.custom
			custom_uploads += 1

func _set_active(entry: ModelEntry, active: bool) -> void:
	if entry.active == active:
		return
	entry.active = active
	for part_index: int in entry.parts.size():
		if active and entry.parts[part_index].is_visible_in_tree():
			_add_part(entry, part_index)
		else:
			_remove_part(entry, part_index)

func _on_part_visibility_changed(id: int, part_index: int) -> void:
	var entry: ModelEntry = _models[_model_index[id]]
	# Native visibility_changed also covers ancestor changes and animation
	# visibility tracks. A hidden/off-screen model never acquires a draw slot.
	if entry.active and entry.parts[part_index].is_visible_in_tree():
		_add_part(entry, part_index)
	else:
		_remove_part(entry, part_index)

func _add_part(entry: ModelEntry, part_index: int) -> void:
	if entry.slots[part_index] >= 0:
		return
	var batch: PartBatch = entry.batches[part_index]
	var slot: int = batch.count
	entry.slots[part_index] = slot
	batch.owners[slot] = entry.id
	batch.part_indices[slot] = part_index
	batch.colors[slot] = entry.custom
	batch.mesh.set_instance_custom_data(slot, entry.custom)
	batch.mesh.set_instance_transform(slot, entry.parts[part_index].global_transform)
	batch.count += 1
	batch.mesh.visible_instance_count = batch.count
	if batch.count == 1:
		batch.node.show()
	slot_changes += 1
	custom_uploads += 1

func _remove_part(entry: ModelEntry, part_index: int) -> void:
	var slot: int = entry.slots[part_index]
	if slot < 0:
		return
	var batch: PartBatch = entry.batches[part_index]
	batch.count -= 1
	var last: int = batch.count
	if slot != last:
		# Swap the last visible instance into the hole. Copy its last displayed
		# pose as well: deletion/visibility can occur after the renderer ran.
		var moved: ModelEntry = _models[_model_index[batch.owners[last]]]
		moved.slots[batch.part_indices[last]] = slot
		batch.owners[slot] = batch.owners[last]
		batch.part_indices[slot] = batch.part_indices[last]
		batch.colors[slot] = batch.colors[last]
		batch.mesh.set_instance_transform(slot, batch.mesh.get_instance_transform(last))
		batch.mesh.set_instance_custom_data(slot, batch.colors[slot])
		custom_uploads += 1
	entry.slots[part_index] = -1
	batch.owners[last] = 0
	batch.mesh.visible_instance_count = batch.count
	if batch.count == 0:
		batch.node.hide()
	slot_changes += 1

func _process(_delta: float) -> void:
	visible_models = 0
	submitted_parts = 0
	for entry: ModelEntry in _models:
		var model: UnitVisual = entry.model
		# Fog visibility is an absolute gate, independent of screen visibility.
		# The original generous notifier also keeps nearby off-screen shadows.
		# Corpses deliberately keep rendering until their fade finishes.
		var active: bool = model.is_visible_in_tree() and model.visibility_notifier.is_on_screen() and entry.custom.a > 0.0
		_set_active(entry, active)
		if not active:
			continue
		visible_models += 1
		var pose_to_render := Transform3D.IDENTITY
		var sampled: bool = model.render_sampled_animation
		if sampled:
			if not model._dead and model.can_process():
				model.synchronize_animation()
			# One interpolated movement/facing transform per unit instead of an
			# interpolation pump for every animated rigid part on every physics tick.
			pose_to_render = entry.pose_root.get_global_transform_interpolated() * entry.pose_root.global_transform.affine_inverse()
		for part_index: int in entry.parts.size():
			var slot: int = entry.slots[part_index]
			if slot < 0:
				continue
			var part: Node3D = entry.parts[part_index]
			var batch: PartBatch = entry.batches[part_index]
			var displayed: Transform3D = pose_to_render * part.global_transform if sampled else part.get_global_transform_interpolated()
			batch.mesh.set_instance_transform(slot, displayed)
	for batch: PartBatch in _batches:
		submitted_parts += batch.count

func _ensure_capacity(batch: PartBatch, requested: int) -> void:
	if requested <= batch.mesh.instance_count:
		return
	var capacity: int = maxi(initial_capacity, batch.mesh.instance_count)
	while capacity < requested:
		capacity *= 2
	# Native resize clears its buffer. Preserve live slots during recruitment;
	# ownership and colours now persist between display frames.
	var poses: Array[Transform3D] = []
	for slot: int in batch.count:
		poses.append(batch.mesh.get_instance_transform(slot))
	batch.mesh.instance_count = capacity
	batch.colors.resize(capacity)
	batch.owners.resize(capacity)
	batch.part_indices.resize(capacity)
	for slot: int in batch.count:
		batch.mesh.set_instance_transform(slot, poses[slot])
		batch.mesh.set_instance_custom_data(slot, batch.colors[slot])
		custom_uploads += 1
	batch.mesh.visible_instance_count = batch.count
	capacity_growths += 1
