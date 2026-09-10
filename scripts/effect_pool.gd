class_name BattleEffectPool
extends Node3D
## Fixed authored instances bound the cost of combat bursts and preserve sound tails.
var _available: Array[BattleEffect] = []
var _active: Array[BattleEffect] = []
var peak_active: int = 0
var dropped: int = 0
var coalesced: int = 0
var offscreen: int = 0
var _small_effects: Dictionary = {}
var _density_cells: Dictionary = {}
var _camera: Camera3D

const SMALL_EFFECTS: Array[String] = ["hit", "arrow_hit", "wood_hit", "stone_chip", "dust"]
const CELL_PIXELS: float = 64.0
const DENSITY_WINDOW_MS: int = 100

func _ready() -> void:
	_camera = get_viewport().get_camera_3d()
	for effect: BattleEffect in get_children():
		effect.pooled = true
		effect.finished.connect(_release)
		effect.hide()
		effect.process_mode = Node.PROCESS_MODE_DISABLED
		_available.append(effect)

func play(at: Vector3, kind: String, color: Color) -> void:
	var small: bool = kind in SMALL_EFFECTS
	if small and not _accept_small_effect(at):
		return
	if _available.is_empty():
		# Small impacts are deliberately the first visual detail shed at the cap.
		if small:
			dropped += 1
			return
		# Keep explosions and command feedback ahead of expendable small impacts.
		var victim: BattleEffect = _active.front()
		for candidate: BattleEffect in _active:
			if _small_effects.has(candidate):
				victim = candidate
				break
		_release(victim)
	var effect: BattleEffect = _available.pop_back()
	_active.append(effect)
	if small:
		_small_effects[effect] = true
	peak_active = maxi(peak_active, _active.size())
	effect.global_position = at
	effect.process_mode = Node.PROCESS_MODE_INHERIT
	effect.show()
	effect.initialize(kind, color)
	effect.reset_physics_interpolation()

func _accept_small_effect(at: Vector3) -> bool:
	# Only cosmetic small impacts are culled/coalesced. Sound is already dispatched
	# by Game; large explosions, collapse and player command markers never enter here.
	if _camera.is_position_behind(at):
		offscreen += 1
		return false
	var screen: Vector2 = _camera.unproject_position(at)
	if not get_viewport().get_visible_rect().grow(48.0).has_point(screen):
		offscreen += 1
		return false
	var now: int = Time.get_ticks_msec()
	var cell := Vector2i(floori(screen.x / CELL_PIXELS), floori(screen.y / CELL_PIXELS))
	if _density_cells.has(cell) and now - int(_density_cells[cell]) < DENSITY_WINDOW_MS:
		coalesced += 1
		return false
	# Keys are screen cells, bounded by the viewport rather than battle/world size.
	_density_cells[cell] = now
	return true

func _release(effect: BattleEffect) -> void:
	effect.reset_effect()
	effect.hide()
	effect.process_mode = Node.PROCESS_MODE_DISABLED
	_active.erase(effect)
	_small_effects.erase(effect)
	if effect not in _available:
		_available.append(effect)

func reset_all() -> void:
	for effect: BattleEffect in _active.duplicate():
		_release(effect)
	_density_cells.clear()

func active_count() -> int:
	return _active.size()
