class_name RigidSkinInterpolator
extends SkeletonModifier3D
## Presentation-only interpolation for native 30 TPS skeletal animation.
## Godot 4.6 backs up the authoritative bone poses before running modifiers,
## uploads the modified skin, then restores those poses. Never advance a player.

@export var tracked_bones: PackedStringArray
@export_node_path("AnimationPlayer") var animation_player: NodePath = NodePath("../../../Attack")
@export_node_path("Node3D") var model_root: NodePath = NodePath("../../..")
@export_node_path("VisibleOnScreenNotifier3D") var visibility_notifier: NodePath = NodePath("../../../VisibilityNotifier")

var _skeleton: Skeleton3D
var _player: AnimationPlayer
var _model: Node3D
var _notifier: VisibleOnScreenNotifier3D
var _bone_indices := PackedInt32Array()
var _previous: Array[Transform3D] = []
var _current: Array[Transform3D] = []
var _changed_slots := PackedInt32Array()
var _sample_tick: int = -1
var _sample_serial: int = 0
var _last_present_serial: int = -1
var _last_present_weight: float = -1.0
var _submitting: bool = false
var _refresh_queued: bool = false
var _initialized: bool = false

func _ready() -> void:
	_skeleton = get_skeleton()
	_player = get_node(animation_player)
	_model = get_node(model_root)
	_notifier = get_node(visibility_notifier)
	assert(_skeleton != null and not tracked_bones.is_empty(), "Rigid skin interpolation requires explicit animated bones")
	assert(influence == 1.0, "The presentation modifier must have full influence")
	for bone_name: String in tracked_bones:
		var index: int = _skeleton.find_bone(bone_name)
		assert(index >= 0, "Missing interpolated bone: " + bone_name)
		_bone_indices.append(index)
	_previous.resize(_bone_indices.size())
	_current.resize(_bone_indices.size())
	_skeleton.pose_updated.connect(_on_pose_updated)
	_skeleton.skeleton_updated.connect(_on_skin_submitted)
	_model.visibility_changed.connect(_queue_refresh)
	_notifier.screen_entered.connect(_queue_refresh)
	_notifier.screen_exited.connect(_queue_refresh)
	_initialized = true
	# A headless host has no visible rigs. Avoid the native per-render modifier
	# update entirely while culled; pose sampling is resumed by visibility events.
	active = false
	_skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	_reset_samples()
	_queue_refresh()

func _notification(what: int) -> void:
	if what == NOTIFICATION_UNPAUSED and _initialized:
		_reset_samples()
		_queue_refresh()

func _queue_refresh() -> void:
	if not _initialized or _refresh_queued:
		return
	_refresh_queued = true
	_refresh_activity.call_deferred()

func _refresh_activity() -> void:
	_refresh_queued = false
	# Run after UnitVisual's visibility handler has synchronized its authored
	# playback clocks. Replicas already sample every render frame themselves.
	var enable: bool = _player.callback_mode_process == AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS and _model.is_visible_in_tree() and _notifier.is_on_screen()
	if enable == active:
		return
	_reset_samples()
	active = enable
	_skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE if enable else Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL

func _reset_samples() -> void:
	for slot: int in _bone_indices.size():
		var pose: Transform3D = _skeleton.get_bone_pose(_bone_indices[slot])
		_previous[slot] = pose
		_current[slot] = pose
	_changed_slots.clear()
	_sample_tick = Engine.get_physics_frames()
	_sample_serial += 1
	_last_present_serial = -1
	_last_present_weight = -1.0

func _on_pose_updated() -> void:
	if not _initialized or _submitting or not active:
		return
	if _player.callback_mode_process != AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS:
		# Replica conversion may change callback mode after this node's ready.
		# This explicit transition prevents interpolating an already sampled pose.
		active = false
		_skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
		_reset_samples()
		return
	var tick: int = Engine.get_physics_frames()
	var new_tick: bool = tick != _sample_tick
	_changed_slots.clear()
	for slot: int in _bone_indices.size():
		if new_tick:
			_previous[slot] = _current[slot]
		_current[slot] = _skeleton.get_bone_pose(_bone_indices[slot])
		if _current[slot] != _previous[slot]:
			_changed_slots.append(slot)
	_sample_tick = tick
	_sample_serial += 1
	# Multiple native updates can occur in one tick, including a SceneTree Timer
	# after node physics callbacks. Update current, but shift previous only once.
	# Modifier writes never become samples: native Skeleton3D suppresses
	# pose_updated while updating, and _submitting covers our submission scope.

func _process_modification_with_delta(_delta: float) -> void:
	if not _initialized:
		return
	if _player.callback_mode_process != AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS:
		_queue_refresh()
		return
	if _changed_slots.is_empty():
		return
	# With no new authored pose in a later tick, settle at current. Reusing the
	# fraction would replay the last interval forever for a stopped animation.
	var weight: float = Engine.get_physics_interpolation_fraction() if Engine.get_physics_frames() == _sample_tick else 1.0
	if _sample_serial == _last_present_serial and weight == _last_present_weight:
		return
	_submitting = true
	for slot: int in _changed_slots:
		_skeleton.set_bone_pose(_bone_indices[slot], _previous[slot].interpolate_with(_current[slot], weight))
	_last_present_serial = _sample_serial
	_last_present_weight = weight

func _on_skin_submitted() -> void:
	# Emitted after modifier calculation and before the native skin upload.
	# The remaining native operation restores authoritative poses immediately.
	_submitting = false
