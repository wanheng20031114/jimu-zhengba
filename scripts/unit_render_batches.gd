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

class ModelEntry extends RefCounted:
	var model: UnitVisual
	var pose_root: Node3D
	var authority: bool
	var id: int
	var parts: Array[Node3D] = []
	var batches: Array[PartBatch] = []
	var slots := PackedInt32Array()
	var custom: Color

var registered_models: int = 0
var visible_models: int = 0
var submitted_parts: int = 0
var capacity_growths: int = 0

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
	# queue_free can flush after this renderer's process callback. Clear its last
	# submitted slots immediately so a deleted unit cannot linger for one frame.
	for part_index: int in entry.batches.size():
		var batch: PartBatch = entry.batches[part_index]
		var slot: int = entry.slots[part_index]
		if slot >= 0 and slot < batch.mesh.visible_instance_count and batch.owners[slot] == id:
			batch.mesh.set_instance_transform(slot, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))
			batch.owners[slot] = 0
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

func set_fade(model: UnitVisual, amount: float) -> void:
	var entry: ModelEntry = _models[_model_index[model.get_instance_id()]]
	entry.custom.a = 1.0 - clampf(amount, 0.0, 1.0)

func _process(_delta: float) -> void:
	visible_models = 0
	submitted_parts = 0
	for batch: PartBatch in _batches:
		batch.count = 0
	for entry: ModelEntry in _models:
		var model: UnitVisual = entry.model
		# Fog visibility is an absolute gate, independent of screen visibility.
		# The original generous notifier also keeps nearby off-screen shadows.
		# Corpses deliberately keep rendering until their fade finishes.
		if not model.is_visible_in_tree() or not model.visibility_notifier.is_on_screen() or entry.custom.a <= 0.0:
			continue
		visible_models += 1
		var pose_to_render := Transform3D.IDENTITY
		if model.render_sampled_animation:
			if not model._dead and model.can_process():
				model.synchronize_animation()
			# One interpolated movement/facing transform per unit instead of an
			# interpolation pump for every animated rigid part on every physics tick.
			pose_to_render = entry.pose_root.get_global_transform_interpolated() * entry.pose_root.global_transform.affine_inverse()
		for part_index: int in entry.parts.size():
			var part: Node3D = entry.parts[part_index]
			if not part.is_visible_in_tree():
				continue
			var batch: PartBatch = entry.batches[part_index]
			var slot: int = batch.count
			var displayed: Transform3D = pose_to_render * part.global_transform if model.render_sampled_animation else part.get_global_transform_interpolated()
			batch.mesh.set_instance_transform(slot, displayed)
			# Dense slot identities can change after fog/culling/death. Cache by
			# output slot, not by unit; only changed colors/fades need an upload.
			if batch.colors[slot] != entry.custom:
				batch.mesh.set_instance_custom_data(slot, entry.custom)
				batch.colors[slot] = entry.custom
			batch.owners[slot] = entry.id
			entry.slots[part_index] = slot
			batch.count += 1
	for batch: PartBatch in _batches:
		if batch.mesh.visible_instance_count != batch.count:
			batch.mesh.visible_instance_count = batch.count
		if batch.node.visible != (batch.count > 0):
			batch.node.visible = batch.count > 0
		submitted_parts += batch.count

func _ensure_capacity(batch: PartBatch, requested: int) -> void:
	if requested <= batch.mesh.instance_count:
		return
	var capacity: int = maxi(initial_capacity, batch.mesh.instance_count)
	while capacity < requested:
		capacity *= 2
	# Native resize clears the buffer; next presentation pass writes all visible
	# transforms and customs. No per-frame resize and no per-unit render nodes.
	batch.mesh.instance_count = capacity
	batch.mesh.visible_instance_count = 0
	batch.colors.resize(capacity)
	batch.colors.fill(Color(-1.0, -1.0, -1.0, -1.0))
	batch.owners.resize(capacity)
	batch.owners.fill(0)
	capacity_growths += 1
