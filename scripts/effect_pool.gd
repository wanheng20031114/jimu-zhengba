class_name BattleEffectPool
extends Node3D
## Fixed authored instances bound the cost of combat bursts and preserve sound tails.
var _available: Array[BattleEffect] = []
var _active: Array[BattleEffect] = []
var peak_active: int = 0
var dropped: int = 0

func _ready() -> void:
	for effect: BattleEffect in get_children():
		effect.pooled = true
		effect.finished.connect(_release)
		effect.hide()
		effect.process_mode = Node.PROCESS_MODE_DISABLED
		_available.append(effect)

func play(at: Vector3, kind: String, color: Color) -> void:
	if _available.is_empty():
		# Small impacts are deliberately the first visual detail shed at the cap.
		if kind in ["hit", "arrow_hit", "wood_hit", "stone_chip", "dust"]:
			dropped += 1
			return
		_release(_active.front())
	var effect: BattleEffect = _available.pop_back()
	_active.append(effect)
	peak_active = maxi(peak_active, _active.size())
	effect.global_position = at
	effect.process_mode = Node.PROCESS_MODE_INHERIT
	effect.show()
	effect.initialize(kind, color)
	effect.reset_physics_interpolation()

func _release(effect: BattleEffect) -> void:
	effect.reset_effect()
	effect.hide()
	effect.process_mode = Node.PROCESS_MODE_DISABLED
	_active.erase(effect)
	if effect not in _available:
		_available.append(effect)

func reset_all() -> void:
	for effect: BattleEffect in _active.duplicate():
		_release(effect)

func active_count() -> int:
	return _active.size()
