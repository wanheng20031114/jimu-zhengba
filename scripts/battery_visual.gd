class_name BatteryVisual
extends UnitVisual
## Three authored AnimationPlayers own disjoint barrel tracks. Gameplay clocks
## never depend on playback. Invisible/batched poses are sampled only on demand.
@onready var barrel_players: Array[AnimationPlayer] = [$Barrel0Attack, $Barrel1Attack, $Barrel2Attack]
var _fired_frames := PackedInt64Array([-1, -1, -1])
var _sampled_phases := PackedFloat64Array([-1, -1, -1])
var _active_barrels: int = 0
const RECOIL_SECONDS: float = 1.7

func _ready() -> void:
	super._ready()
	set_physics_process(false)

func fire_barrel(index: int) -> void:
	_synchronize_locomotion()
	_fired_frames[index] = _visual_frame()
	_active_barrels |= 1 << index
	_sample_barrel(index, 0.0)
	_refresh_animation_visibility()

func _refresh_animation_visibility() -> void:
	super._refresh_animation_visibility()
	if not is_node_ready(): return
	set_physics_process(not _dead and not _animations_suspended and not render_sampled_animation
		and _active_barrels != 0 and attack.callback_mode_process != AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL)

func _physics_process(_delta: float) -> void:
	synchronize_animation()
	if _active_barrels == 0: set_physics_process(false)

func synchronize_animation() -> void:
	super.synchronize_animation()
	if _active_barrels == 0 or not is_node_ready() or _dead or attack.callback_mode_process == AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL:
		return
	var frame: int = _visual_frame()
	var tick: float = get_physics_process_delta_time()
	for i: int in 3:
		if not (_active_barrels & (1 << i)): continue
		var phase: float = (frame - _fired_frames[i]) * tick
		_sample_barrel(i, phase)
		if phase >= RECOIL_SECONDS: _active_barrels &= ~(1 << i)

func sample_remote_barrels(older: Array, newer: Array, at: float) -> void:
	for i: int in 3:
		# Absolute release stamps prevent interpolation from showing an unfired
		# gun or restarting another gun when snapshots straddle an independent shot.
		var released: float = float(newer[i]) if float(newer[i]) <= at else float(older[i])
		_sample_barrel(i, at - released if released >= 0 and released <= at else -1.0)

func _sample_barrel(index: int, phase: float) -> void:
	phase = minf(phase, RECOIL_SECONDS)
	if is_equal_approx(_sampled_phases[index], phase): return
	_sampled_phases[index] = phase
	var player: AnimationPlayer = barrel_players[index]
	if player.current_animation != &"recoil": player.play(&"recoil")
	player.seek(maxf(phase, 0.0), true, true)

func die() -> void:
	super.die()
	set_physics_process(false)
