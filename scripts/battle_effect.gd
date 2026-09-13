class_name BattleEffect
extends Node3D
## Reusable authored particle scene. Only the relevant emitters are activated.

signal finished(effect: BattleEffect)
var pooled: bool = false
var _tweens: Array[Tween] = []
var _spark_defaults: Dictionary
var _active: bool = false
var _configured_kind: String = ""

@onready var _sparks: CPUParticles3D = $Sparks
@onready var _dust: CPUParticles3D = $Dust
@onready var _debris: CPUParticles3D = $Debris
@onready var _flash: MeshInstance3D = $Flash
@onready var _ring: MeshInstance3D = $Ring
@onready var _direction: MeshInstance3D = $Direction
@onready var _lifetime: Timer = $Lifetime
@onready var _healing: HealingParticles = $Healing

const SPARK_AMOUNTS: Dictionary = {"hit":7, "arrow_hit":3, "wood_hit":3, "stone_chip":3, "muzzle":10, "explosion":18, "charge":14}
const DUST_AMOUNTS: Dictionary = {"dust":5, "muzzle":6, "explosion":16, "stone_hit":16, "collapse":24}
const DUST_SCALES: Dictionary = {"dust":.4, "muzzle":.55, "collapse":2.5}

func _ready() -> void:
	_spark_defaults = {"direction": _sparks.direction, "min": _sparks.initial_velocity_min, "max": _sparks.initial_velocity_max}

func _new_tween() -> Tween:
	var tween := create_tween()
	_tweens.append(tween)
	return tween

func reset_effect() -> void:
	# Release stops a live borrower once. initialize() may also be used directly
	# by standalone scenes, so a reset on an already returned slot is a no-op.
	if not _active: return
	_active = false
	_lifetime.stop()
	_healing.stop()
	for tween: Tween in _tweens:
		if tween.is_valid():
			tween.kill()
	_tweens.clear()
	for particles: CPUParticles3D in [_sparks, _dust, _debris]:
		particles.emitting = false
		# Restart emits a fresh burst even when emitting is disabled afterwards.
		# Hide old particles; only the requested emitter is restarted below.
		particles.hide()
	for visual: MeshInstance3D in [_flash, _ring, _direction]:
		visual.hide()
		visual.transparency = 0
	_direction.position.y = 0.8

func initialize(kind: String, color: Color = Color.WHITE) -> void:
	reset_effect()
	_active = true
	if _configured_kind != kind:
		_configure_emitters(kind)
		_configured_kind = kind
	var duration: float = 1.4
	_sparks.color = Color("e6dba5") if kind == "spawn" else color
	match kind:
		"hit", "arrow_hit", "wood_hit", "stone_chip":
			_sparks.show()
			_sparks.restart()
			_sparks.emitting = true
			duration = 0.8
		"dust":
			_dust.show()
			_dust.restart()
			_dust.emitting = true
			duration = 1.5
		"muzzle":
			_flash.show()
			_flash.scale = Vector3.ONE * 0.8
			_sparks.show()
			_sparks.restart()
			_sparks.emitting = true
			_dust.show()
			_dust.restart()
			_dust.emitting = true
			var flash: Tween = _new_tween()
			flash.tween_method(_animate_flash.bind(0.8), 0.0, 1.0, 0.16)
			duration = 1.8
		"explosion", "stone_hit", "collapse":
			var size: float = 2.5 if kind == "collapse" else 1.0
			_dust.show()
			_dust.restart()
			_dust.emitting = true
			_debris.show()
			_debris.restart()
			_debris.emitting = true
			_show_ring(Color(0.69, 0.52, 0.31, 0.65), 2.8 * size, 0.7)
			if kind == "explosion":
				_flash.show()
				_sparks.show()
				_sparks.restart()
				_sparks.emitting = true
				var flash: Tween = _new_tween()
				flash.tween_method(_animate_flash.bind(1.0), 0.0, 1.0, 0.27)
			duration = 3.0
		"move", "attack":
			_show_ring(Color("80d9e7") if kind == "move" else Color("eea176"), 1.5, 0.65)
			_direction.show()
			_direction.material_override.albedo_color = Color("80d9e7") if kind == "move" else Color("eea176")
			var marker: Tween = _new_tween()
			marker.tween_method(_animate_direction, 0.0, 1.0, 0.65)
			duration = 0.8
		"spawn":
			_show_ring(Color("d8c98d"), 2.0, 0.8)
			_sparks.show()
			_sparks.restart()
			_sparks.emitting = true
			duration = 1.1
		"heal":
			_healing.play()
			duration = 1.1
		"charge":
			_show_ring(Color("eed6a0"), 2.2, 0.5)
			_sparks.show()
			_sparks.restart()
			_sparks.emitting = true
			duration = 0.8
		_:
			push_error("Unknown battle effect: " + kind)
			duration = 0.01
	_lifetime.start(duration)

func _configure_emitters(kind: String) -> void:
	# Changing CPUParticles3D.amount reallocates its particle buffers. Keep the
	# borrower's configuration between uses instead of default -> effect -> default.
	_sparks.direction = Vector3.UP if kind == "spawn" else _spark_defaults.direction
	_sparks.initial_velocity_min = .6 if kind == "spawn" else _spark_defaults.min
	_sparks.initial_velocity_max = 1.8 if kind == "spawn" else _spark_defaults.max
	var sparks: int = SPARK_AMOUNTS.get(kind, 8)
	var dust: int = DUST_AMOUNTS.get(kind, 12)
	if _sparks.amount != sparks: _sparks.amount = sparks
	if _dust.amount != dust: _dust.amount = dust
	var dust_scale: float = DUST_SCALES.get(kind, 1.0)
	_dust.scale = Vector3.ONE * dust_scale
	_debris.scale = Vector3.ONE * (2.5 if kind == "collapse" else 1.0)

func _show_ring(color: Color, end_size: float, duration: float) -> void:
	_ring.show()
	_ring.material_override.albedo_color = color
	_ring.scale = Vector3(0.25, 1.0, 0.25)
	var pulse: Tween = _new_tween()
	pulse.tween_method(_animate_ring.bind(end_size), 0.0, 1.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _animate_ring(amount: float, end_size: float) -> void:
	var size: float = lerpf(0.25, end_size, amount)
	_ring.scale = Vector3(size, 1.0, size)
	_ring.transparency = amount

func _animate_flash(amount: float, initial_size: float) -> void:
	_flash.scale = Vector3.ONE * lerpf(initial_size, 0.01, amount)
	_flash.transparency = amount

func _animate_direction(amount: float) -> void:
	_direction.position.y = lerpf(0.8, 0.08, amount)
	_direction.transparency = amount

func _on_lifetime_timeout() -> void:
	if pooled:
		finished.emit(self)
	else:
		queue_free()
