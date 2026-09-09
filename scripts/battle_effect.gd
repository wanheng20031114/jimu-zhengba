class_name BattleEffect
extends Node3D
## Reusable authored particle scene. Only the relevant emitters are activated.

signal finished(effect: BattleEffect)
var pooled: bool = false
var _tweens: Array[Tween] = []
var _spark_defaults: Dictionary

func _ready() -> void:
	_spark_defaults = {"direction": $Sparks.direction, "min": $Sparks.initial_velocity_min, "max": $Sparks.initial_velocity_max}

func _new_tween() -> Tween:
	var tween := create_tween()
	_tweens.append(tween)
	return tween

func reset_effect() -> void:
	$Lifetime.stop()
	for tween: Tween in _tweens:
		if tween.is_valid():
			tween.kill()
	_tweens.clear()
	for particles: CPUParticles3D in [$Sparks, $Dust, $Debris]:
		particles.emitting = false
		# Restart emits a fresh burst even when emitting is disabled afterwards.
		# Hide old particles; only the requested emitter is restarted below.
		particles.hide()
	$Sparks.direction = _spark_defaults.direction
	$Sparks.initial_velocity_min = _spark_defaults.min
	$Sparks.initial_velocity_max = _spark_defaults.max
	$Sparks.amount = 8
	$Dust.amount = 12
	$Dust.scale = Vector3.ONE
	$Debris.scale = Vector3.ONE
	for visual: MeshInstance3D in [$Flash, $Ring, $Direction]:
		visual.hide()
		visual.transparency = 0
	$Direction.position.y = 0.8

func initialize(kind: String, color: Color = Color.WHITE) -> void:
	reset_effect()
	var duration: float = 1.4
	$Sparks.color = color
	$Ring.material_override.albedo_color = color
	match kind:
		"hit", "arrow_hit", "wood_hit", "stone_chip":
			$Sparks.amount = 7 if kind == "hit" else 3
			$Sparks.show()
			$Sparks.restart()
			$Sparks.emitting = true
			duration = 0.8
		"dust":
			$Dust.amount = 5
			$Dust.scale = Vector3.ONE * 0.4
			$Dust.show()
			$Dust.restart()
			$Dust.emitting = true
			duration = 1.5
		"muzzle":
			$Flash.show()
			$Flash.scale = Vector3.ONE * 0.8
			$Sparks.amount = 10
			$Sparks.show()
			$Sparks.restart()
			$Sparks.emitting = true
			$Dust.scale = Vector3.ONE * 0.55
			$Dust.amount = 6
			$Dust.show()
			$Dust.restart()
			$Dust.emitting = true
			var flash: Tween = _new_tween()
			flash.tween_method(_animate_flash.bind(0.8), 0.0, 1.0, 0.16)
			duration = 1.8
		"explosion", "stone_hit", "collapse":
			var size: float = 2.5 if kind == "collapse" else 1.0
			$Dust.scale = Vector3.ONE * size
			$Dust.amount = 24 if kind == "collapse" else 16
			$Dust.show()
			$Dust.restart()
			$Dust.emitting = true
			$Debris.scale = Vector3.ONE * size
			$Debris.show()
			$Debris.restart()
			$Debris.emitting = true
			_show_ring(Color(0.69, 0.52, 0.31, 0.65), 2.8 * size, 0.7)
			if kind == "explosion":
				$Flash.show()
				$Sparks.amount = 18
				$Sparks.show()
				$Sparks.restart()
				$Sparks.emitting = true
				var flash: Tween = _new_tween()
				flash.tween_method(_animate_flash.bind(1.0), 0.0, 1.0, 0.27)
			duration = 3.0
		"move", "attack":
			_show_ring(Color("80d9e7") if kind == "move" else Color("eea176"), 1.5, 0.65)
			$Direction.show()
			$Direction.material_override.albedo_color = Color("80d9e7") if kind == "move" else Color("eea176")
			var marker: Tween = _new_tween()
			marker.tween_method(_animate_direction, 0.0, 1.0, 0.65)
			duration = 0.8
		"spawn", "heal":
			_show_ring(Color("d8c98d"), 2.0, 0.8)
			$Sparks.direction = Vector3.UP
			$Sparks.initial_velocity_min = 0.6
			$Sparks.initial_velocity_max = 1.8
			$Sparks.color = Color("e6dba5")
			$Sparks.show()
			$Sparks.restart()
			$Sparks.emitting = true
			duration = 1.1
		"charge":
			_show_ring(Color("eed6a0"), 2.2, 0.5)
			$Sparks.amount = 14
			$Sparks.show()
			$Sparks.restart()
			$Sparks.emitting = true
			duration = 0.8
		_:
			push_error("Unknown battle effect: " + kind)
			duration = 0.01
	$Lifetime.start(duration)

func _show_ring(color: Color, end_size: float, duration: float) -> void:
	$Ring.show()
	$Ring.material_override.albedo_color = color
	$Ring.scale = Vector3(0.25, 1.0, 0.25)
	var pulse: Tween = _new_tween()
	pulse.tween_method(_animate_ring.bind(end_size), 0.0, 1.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _animate_ring(amount: float, end_size: float) -> void:
	var size: float = lerpf(0.25, end_size, amount)
	$Ring.scale = Vector3(size, 1.0, size)
	$Ring.transparency = amount

func _animate_flash(amount: float, initial_size: float) -> void:
	$Flash.scale = Vector3.ONE * lerpf(initial_size, 0.01, amount)
	$Flash.transparency = amount

func _animate_direction(amount: float) -> void:
	$Direction.position.y = lerpf(0.8, 0.08, amount)
	$Direction.transparency = amount

func _on_lifetime_timeout() -> void:
	if pooled:
		finished.emit(self)
	else:
		queue_free()
