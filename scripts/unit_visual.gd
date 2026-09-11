class_name UnitVisual
extends Node3D
## Saved rigid-part sculptures driven by native AnimationPlayers.
@export_enum("swordsman", "spearman", "archer", "knight", "catapult", "cannon", "farmer") var kind: String = "swordsman"
@export var projectile_socket: NodePath
## Optional authored rigid-skin representation. The original editable rigs
## continue to use their Marker3D socket and need neither field.
@export_node_path("Skeleton3D") var rigid_skin_skeleton: NodePath
@export var rigid_skin_socket_bone: StringName
@export var batch_parts: Dictionary[NodePath, Mesh] = {}

@onready var locomotion: AnimationPlayer = $Locomotion
@onready var attack: AnimationPlayer = $Attack
@onready var visibility_notifier: VisibleOnScreenNotifier3D = $VisibilityNotifier
var _moving: bool = false
var _working: bool = false
var _work_mode: String = "gather"
var _team: int = 0
var _team_surfaces: Array[MeshInstance3D] = []
var _animations_suspended: bool = false
var _suspended_frame: int = 0
var _locomotion_advanced: float = 0.0
var _attack_advanced: float = 0.0
var _paused_frames: int = 0
var _pause_started_frame: int = -1
var _dead: bool = false
var _rigid_skeleton: Skeleton3D
var _rigid_socket_index: int = -1
var _batch_renderer: UnitRenderBatches

func _ready() -> void:
	if not rigid_skin_skeleton.is_empty():
		_rigid_skeleton = get_node(rigid_skin_skeleton)
		_rigid_socket_index = _rigid_skeleton.find_bone(rigid_skin_socket_bone)
		assert(_rigid_socket_index >= 0, "Rigid skin asset must provide its projectile bone")
	for mesh_node: Node in $Rig.find_children("*", "MeshInstance3D", true, false):
		_team_surfaces.append(mesh_node as MeshInstance3D)
	set_team(_team)
	locomotion.seek(randf() * 2.6, true)
	visibility_changed.connect(_refresh_animation_visibility)
	# The native notifier needs a rendered frame to assess its AABB. Starting
	# suspended also handles a headless host without a separate polling loop.
	_refresh_animation_visibility.call_deferred()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED:
		_pause_started_frame = Engine.get_physics_frames()
	elif what == NOTIFICATION_UNPAUSED and _pause_started_frame >= 0:
		_paused_frames += Engine.get_physics_frames() - _pause_started_frame
		_pause_started_frame = -1

func _visual_frame() -> int:
	var frame: int = _pause_started_frame if _pause_started_frame >= 0 else Engine.get_physics_frames()
	return frame - _paused_frames

func _refresh_animation_visibility() -> void:
	if not is_node_ready() or not is_inside_tree() or _dead:
		return
	# Replicas are driven explicitly by snapshot interpolation, including when
	# their BattleUnit physics callback is disabled. Do not replace that clock.
	if attack.callback_mode_process == AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL:
		_animations_suspended = false
		locomotion.process_mode = Node.PROCESS_MODE_INHERIT
		attack.process_mode = Node.PROCESS_MODE_INHERIT
		return
	var suspend: bool = not is_visible_in_tree() or not visibility_notifier.is_on_screen()
	if suspend == _animations_suspended:
		return
	if suspend:
		_suspended_frame = _visual_frame()
		_locomotion_advanced = 0.0
		_attack_advanced = 0.0
		_animations_suspended = true
		# active=false clears native track caches and makes seek a no-op.
		# Only suspend automatic callbacks: explicit release sampling still works.
		locomotion.process_mode = Node.PROCESS_MODE_DISABLED
		attack.process_mode = Node.PROCESS_MODE_DISABLED
	else:
		synchronize_animation()
		_animations_suspended = false
		locomotion.process_mode = Node.PROCESS_MODE_INHERIT
		attack.process_mode = Node.PROCESS_MODE_INHERIT
		reset_physics_interpolation()

func _on_screen_entered() -> void:
	_refresh_animation_visibility()

func _on_screen_exited() -> void:
	_refresh_animation_visibility()

func _suspended_seconds() -> float:
	return (_visual_frame() - _suspended_frame) * get_physics_process_delta_time()

func _synchronize_locomotion() -> void:
	if not _animations_suspended:
		return
	var elapsed: float = _suspended_seconds()
	var pending: float = elapsed - _locomotion_advanced
	if pending > 0.0 and locomotion.is_playing():
		locomotion.advance(pending)
	_locomotion_advanced = maxf(_locomotion_advanced, elapsed)

func synchronize_animation() -> void:
	# Snapshots and visibility events consume the same native playback clock.
	# No method/audio tracks exist in these visual-only authored animations.
	_synchronize_locomotion()
	if not _animations_suspended:
		return
	var elapsed: float = _suspended_seconds()
	var pending: float = elapsed - _attack_advanced
	if pending > 0.0 and attack.is_playing():
		attack.advance(pending)
	_attack_advanced = maxf(_attack_advanced, elapsed)

func prepare_attack_release(seconds: float) -> void:
	# The weapon socket inherits the locomotion Rig transform as well as the
	# strike pose. Camera culling must never affect the authoritative origin.
	_synchronize_locomotion()
	var delay: float = seconds - attack.current_animation_position
	if delay > 0.0:
		delay += 0.000001
		attack.advance(delay)
		if _animations_suspended:
			_attack_advanced += delay

func set_motion(moving: bool) -> void:
	if moving and _working:
		set_working(false)
	if _moving == moving:
		return
	synchronize_animation()
	_moving = moving
	if _working:
		return
	locomotion.play("walk" if moving else "idle", 0.16)
	if _animations_suspended:
		_locomotion_advanced = _suspended_seconds()

func set_working(active: bool, mode: String = "gather") -> void:
	if kind != "farmer":
		return
	if _working == active and (not active or _work_mode == mode):
		return
	synchronize_animation()
	_working = active
	_work_mode = mode
	if active:
		locomotion.pause()
		attack.play(mode, 0.12)
	else:
		attack.stop()
		locomotion.play("walk" if _moving else "idle", 0.12)
	if _animations_suspended:
		_locomotion_advanced = _suspended_seconds()
		_attack_advanced = _locomotion_advanced

func strike() -> void:
	synchronize_animation()
	attack.stop()
	attack.play("strike")
	if _animations_suspended:
		_attack_advanced = _suspended_seconds()

func die() -> void:
	synchronize_animation()
	_dead = true
	locomotion.pause()
	attack.pause()

func get_projectile_origin() -> Vector3:
	_synchronize_locomotion()
	if _rigid_skeleton != null:
		# BoneAttachment3D publishes after the Skeleton's deferred update. Read
		# the freshly sampled native pose directly at the authoritative release.
		return _rigid_skeleton.global_transform * _rigid_skeleton.get_bone_global_pose(_rigid_socket_index).origin
	return get_node(projectile_socket).global_position

func set_team(team: int) -> void:
	_team = team
	var tint := FactionPalette.model_color(team)
	for mesh: MeshInstance3D in _team_surfaces:
		mesh.set_instance_shader_parameter("team_color", tint)
	if _batch_renderer != null:
		_batch_renderer.set_team(self, team)

func bind_render_batches(renderer: UnitRenderBatches) -> void:
	assert(not batch_parts.is_empty() and _batch_renderer == null, "Batch models require authored parts and one renderer")
	_batch_renderer = renderer
	_batch_renderer.register_model(self, _team)
	# The connection disappears with the renderer if the entire match exits.
	# Ordinary model deletion releases every batch slot before its nodes free.
	tree_exiting.connect(_batch_renderer.unregister_model.bind(self))

func set_batch_fade(amount: float) -> void:
	if _batch_renderer != null:
		_batch_renderer.set_fade(self, amount)
