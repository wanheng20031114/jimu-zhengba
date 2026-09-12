extends SceneTree
## Check the saved foot trajectory relative to the mount's -Z forward axis.
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func _run() -> void:
	for folder: String in ["", "batched/"]:
		var model: UnitVisual = load("res://assets/models/units/"+folder+"war_elephant.tscn").instantiate()
		root.add_child(model)
		model.locomotion.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		model.locomotion.play("walk", 0.0)
		var clip: Animation = model.locomotion.get_animation("walk")
		for leg: String in ["LegFrontLeft", "LegFrontRight", "LegRearLeft", "LegRearRight"]:
			var step: Node3D = model.get_node("Rig/Action/"+leg+"Step")
			var previous := Vector3.ZERO
			var previous_lift: float = 0.0
			var stance_distance: float = 0.0
			var swing_distance: float = 0.0
			var stance_samples: int = 0
			var swing_samples: int = 0
			var wrong_stance: int = 0
			var wrong_swing: int = 0
			for frame: int in 121:
				model.locomotion.seek(clip.length*float(frame)/120.0, true)
				var foot: Vector3 = model.to_local(step.to_global(Vector3(0,-1.16,0)))
				var lift: float = step.position.y-1.22
				if frame > 0:
					var travel: float = foot.z-previous.z
					if lift > .035 and previous_lift > .035:
						swing_samples += 1
						swing_distance += travel
						if travel >= 0.0: wrong_swing += 1
					elif absf(lift) < .0001 and absf(previous_lift) < .0001:
						stance_samples += 1
						stance_distance += travel
						if travel <= 0.0: wrong_stance += 1
				previous = foot
				previous_lift = lift
			check(swing_samples >= 12 and wrong_swing == 0 and swing_distance < -.30, folder+leg+" lifted foot advances toward the nose (-Z)")
			check(stance_samples >= 70 and wrong_stance == 0 and stance_distance > .45, folder+leg+" planted foot travels backward relative to the body (+Z)")
			print("GAIT_TRAJECTORY ",folder,leg," stance=",stance_distance," swing=",swing_distance)
		model.free()
	print("ELEPHANT_GAIT ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
