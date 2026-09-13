class_name BattleEffectPool
extends Node3D
## Fixed authored instances bound the cost of combat bursts and preserve sound tails.
var _available: Array[BattleEffect] = []
var _active: Array[BattleEffect] = []
var peak_active: int = 0
var dropped: int = 0
var coalesced: int = 0
var offscreen: int = 0
var _effect_priority: Dictionary = {}
var _priority_buckets: Array[Array] = [[], [], [], []]
var _density_cells: Dictionary = {}
var _muzzle_cells: Dictionary = {}
var _impact_cells: Dictionary = {}
var _burst_frame: int = -1
var _camera: Camera3D

const SMALL_EFFECTS: Array[String] = ["hit", "arrow_hit", "wood_hit", "stone_chip", "dust"]
const CELL_PIXELS: float = 64.0
const DENSITY_WINDOW_MS: int = 100
const BURST_CELL_PIXELS: float = 16.0

func _ready() -> void:
	_camera = get_viewport().get_camera_3d()
	for effect: BattleEffect in get_children():
		effect.pooled = true
		effect.finished.connect(_release)
		effect.hide()
		effect.process_mode = Node.PROCESS_MODE_DISABLED
		_available.append(effect)

func play(at: Vector3, kind: String, color: Color) -> void:
	if kind in ["muzzle", "explosion", "stone_hit"] and not _accept_burst(at, kind == "muzzle"):
		return
	var small: bool = kind in SMALL_EFFECTS
	if small and not _accept_small_effect(at):
		return
	var priority: int = _priority(kind)
	if _available.is_empty():
		# Admission is monotonic: only a strictly more important effect may replace
		# a live one. Equal-priority bursts cannot repeatedly reset the same slots.
		var victim: BattleEffect
		for level: int in priority:
			if not _priority_buckets[level].is_empty():
				victim = _priority_buckets[level].front()
				break
		if victim == null:
			dropped += 1
			return
		_release(victim)
	var effect: BattleEffect = _available.pop_back()
	_active.append(effect)
	_effect_priority[effect] = priority
	_priority_buckets[priority].append(effect)
	peak_active = maxi(peak_active, _active.size())
	effect.global_position = at
	effect.process_mode = Node.PROCESS_MODE_INHERIT
	effect.show()
	effect.initialize(kind, color)
	effect.reset_physics_interpolation()

func _priority(kind: String) -> int:
	match kind:
		"move", "attack": return 3
		"explosion", "stone_hit", "collapse", "heal": return 2
		"muzzle", "spawn", "charge": return 1
	return 0

func _accept_burst(at: Vector3, muzzle: bool) -> bool:
	# Synchronized guns can replace the entire particle pool several times in
	# one tick. At distance, overlapping flashes already occupy the same pixels.
	# Retain every close-up muzzle. Coincident impacts share one dust/debris burst;
	# damage and projectile simulation never enter this cosmetic admission policy.
	if _camera.is_position_behind(at):
		offscreen += 1
		return false
	var screen: Vector2 = _camera.unproject_position(at)
	if not get_viewport().get_visible_rect().grow(48.0).has_point(screen):
		offscreen += 1
		return false
	var barrel_spacing: Vector2 = _camera.unproject_position(at + _camera.global_basis.x * .5)
	if muzzle and screen.distance_squared_to(barrel_spacing) >= BURST_CELL_PIXELS * BURST_CELL_PIXELS:
		return true
	var frame: int = Engine.get_physics_frames()
	if frame != _burst_frame:
		_burst_frame = frame
		_muzzle_cells.clear()
		_impact_cells.clear()
	var cells: Dictionary = _muzzle_cells if muzzle else _impact_cells
	var cell := Vector2i(floori(screen.x / BURST_CELL_PIXELS), floori(screen.y / BURST_CELL_PIXELS))
	# Check adjacent cells so a pixel-grid boundary cannot split overlapping guns.
	for x: int in range(-1,2):
		for y: int in range(-1,2):
			var neighbor := cell + Vector2i(x,y)
			if cells.has(neighbor) and screen.distance_squared_to(cells[neighbor]) < BURST_CELL_PIXELS * BURST_CELL_PIXELS:
				coalesced += 1
				return false
	cells[cell] = screen
	return true

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
	_priority_buckets[_effect_priority[effect]].erase(effect)
	_effect_priority.erase(effect)
	if effect not in _available:
		_available.append(effect)

func reset_all() -> void:
	for effect: BattleEffect in _active.duplicate():
		_release(effect)
	_density_cells.clear()
	_muzzle_cells.clear()
	_impact_cells.clear()
	_burst_frame = -1

func active_count() -> int:
	return _active.size()
