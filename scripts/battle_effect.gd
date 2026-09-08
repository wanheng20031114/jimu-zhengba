class_name BattleEffect
extends Node3D
## Reusable authored particle scene. Only the relevant emitters are activated.

func initialize(kind: String, color: Color = Color.WHITE) -> void:
	var duration: float = 1.4
	$Sparks.color = color
	$Ring.material_override.albedo_color = color
	match kind:
		"hit", "arrow_hit", "wood_hit", "stone_chip":
			$Sparks.amount = 7 if kind == "hit" else 3
			$Sparks.restart()
			$Sparks.emitting = true
			duration = 0.8
		"dust":
			$Dust.amount = 5
			$Dust.scale = Vector3.ONE * 0.4
			$Dust.restart()
			$Dust.emitting = true
			duration = 1.5
		"muzzle":
			$Flash.show()
			$Flash.scale = Vector3.ONE * 0.8
			$Sparks.amount = 10
			$Sparks.restart()
			$Sparks.emitting = true
			$Dust.scale = Vector3.ONE * 0.55
			$Dust.restart()
			$Dust.emitting = true
			var flash: Tween = create_tween()
			flash.tween_method(_animate_flash.bind(0.8), 0.0, 1.0, 0.16)
			duration = 1.8
		"explosion", "stone_hit", "collapse":
			var size: float = 2.5 if kind == "collapse" else 1.0
			$Dust.scale = Vector3.ONE * size
			$Dust.amount = 24 if kind == "collapse" else 16
			$Dust.restart()
			$Dust.emitting = true
			$Debris.scale = Vector3.ONE * size
			$Debris.restart()
			$Debris.emitting = true
			_show_ring(Color(0.69, 0.52, 0.31, 0.65), 2.8 * size, 0.7)
			if kind == "explosion":
				$Flash.show()
				$Sparks.amount = 18
				$Sparks.restart()
				$Sparks.emitting = true
				var flash: Tween = create_tween()
				flash.tween_method(_animate_flash.bind(1.0), 0.0, 1.0, 0.27)
			duration = 3.0
		"move", "attack":
			_show_ring(Color("80d9e7") if kind == "move" else Color("eea176"), 1.5, 0.65)
			$Direction.show()
			$Direction.material_override.albedo_color = Color("80d9e7") if kind == "move" else Color("eea176")
			var marker: Tween = create_tween()
			marker.tween_method(_animate_direction, 0.0, 1.0, 0.65)
			duration = 0.8
		"spawn", "heal":
			_show_ring(Color("d8c98d"), 2.0, 0.8)
			$Sparks.direction = Vector3.UP
			$Sparks.initial_velocity_min = 0.6
			$Sparks.initial_velocity_max = 1.8
			$Sparks.color = Color("e6dba5")
			$Sparks.restart()
			$Sparks.emitting = true
			duration = 1.1
		"charge":
			_show_ring(Color("eed6a0"), 2.2, 0.5)
			$Sparks.amount = 14
			$Sparks.restart()
			$Sparks.emitting = true
			duration = 0.8
		_:
			$Dust.restart()
			$Dust.emitting = true
	$Lifetime.start(duration)

func _show_ring(color: Color, end_size: float, duration: float) -> void:
	$Ring.show()
	$Ring.material_override.albedo_color = color
	$Ring.scale = Vector3(0.25, 1.0, 0.25)
	var pulse: Tween = create_tween()
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
	queue_free()
