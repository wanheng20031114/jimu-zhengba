class_name HealingParticles
extends Node3D
## Presentation only: the support component owns every health change.

func play() -> void:
	show()
	for particles: GPUParticles3D in [$Motes, $Glow]:
		particles.restart()
		particles.emitting = true

func stop() -> void:
	for particles: GPUParticles3D in [$Motes, $Glow]:
		particles.emitting = false
	hide()

func set_paused(value: bool) -> void:
	for particles: GPUParticles3D in [$Motes, $Glow]:
		particles.speed_scale = 0.0 if value else 1.0

func _notification(what: int) -> void:
	if is_node_ready() and what in [NOTIFICATION_PAUSED, NOTIFICATION_UNPAUSED]:
		set_paused(what == NOTIFICATION_PAUSED)
