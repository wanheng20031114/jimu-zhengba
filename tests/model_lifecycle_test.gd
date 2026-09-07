extends SceneTree
## Reproduces model loading/recoloring/freeing without battle nodes or effects.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	create_timer(25.0, true, false, true).timeout.connect(func(): quit(3))
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	for variant: String in ["team_before_tree", "team_after_tree", "repeated_recolor"]:
		for kind: String in ["swordsman", "knight", "archer", "catapult", "cannon"]:
			for repeat: int in range(8):
				print("MODEL_LIFECYCLE ", variant, " ", kind, " ", repeat)
				var packed: PackedScene = load("res://assets/models/units/%s.tscn" % kind)
				var model: Node3D = packed.instantiate()
				if variant == "team_before_tree":
					model.set_team(repeat % 2)
				world.add_child(model)
				if variant == "team_after_tree":
					model.set_team(repeat % 2)
				if variant == "repeated_recolor":
					model.set_team(1)
					model.set_team(0)
					model.set_team(1)
				model.set_motion(true)
				model.strike()
				await process_frame
				model.die()
				model.queue_free()
				await process_frame
				await process_frame
	print("MODEL_LIFECYCLE_COMPLETE 120 create/recolor/destroy cycles")
	quit()
