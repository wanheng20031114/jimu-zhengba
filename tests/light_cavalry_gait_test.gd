extends SceneTree
## Measure actual saved transforms, not just the sign of authoring keyframes.
var checks: int=0
var failures: Array[String]=[]
func _initialize() -> void:
	_run.call_deferred()
func check(ok: bool,label: String) -> void:
	checks+=1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func _run() -> void:
	for folder: String in ["","batched/"]:
		var model: UnitVisual=load("res://assets/models/units/"+folder+"light_cavalry.tscn").instantiate()
		root.add_child(model)
		model.locomotion.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		model.locomotion.play("walk",0)
		var clip: Animation=model.locomotion.get_animation("walk")
		for leg: String in ["LegFrontLeft","LegFrontRight","LegRearLeft","LegRearRight"]:
			var hoof: Node3D=model.get_node("Rig/Action/"+leg+"/"+leg+"Lower/"+leg+"Hoof")
			var previous: Vector3
			var stance: int=0
			var swing: int=0
			var wrong: int=0
			var speed_error: float=0
			var floor_min: float=INF
			var peak: float=0
			var first: Vector3
			for frame: int in 241:
				model.locomotion.seek(clip.length*frame/240.0,true)
				var foot: Vector3=model.to_local(hoof.to_global(Vector3(0,-.063,0)))
				floor_min=minf(floor_min,foot.y)
				peak=maxf(peak,foot.y)
				if frame==0: first=foot
				if frame>0:
					var travel: float=foot.z-previous.z
					# Ignore the brief landing/lift transition at the ends of
					# the stroke; measure the fully planted interior trajectory.
					var relative_z: float=foot.z-model.get_node("Rig/Action/"+leg).position.z
					if foot.y<.003 and previous.y<.003 and travel>.001 and absf(relative_z)<.48:
						stance+=1
						speed_error=maxf(speed_error,absf(travel/(clip.length/240.0)-6.8))
					elif foot.y>.025 and previous.y>.025:
						swing+=1
						if travel>=0: wrong+=1
				previous=foot
			check(stance>=65 and speed_error<.18,folder+leg+" planted speed matches 6.8 with minimal sliding")
			check(swing>=110 and wrong==0,folder+leg+" raised hoof recovers forwards")
			check(floor_min>-.001 and peak>.20 and peak<.25,folder+leg+" ground contact and controlled clearance")
			check(previous.distance_to(first)<.0001,folder+leg+" seamless loop")
			print("LIGHT_GAIT ",folder,leg," stance=",stance," swing=",swing," error=",speed_error," floor=",floor_min)
		model.free()
	print("LIGHT_CAVALRY_GAIT ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
