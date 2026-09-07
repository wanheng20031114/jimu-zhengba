extends Node3D

func _ready() -> void:
	for i: int in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://assets/models/units/preview.png")
	for unit: Node in $Units.get_children():
		unit.set_team(1)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://assets/models/units/preview_enemy.png")
	var camera: Camera3D = $Camera3D
	for unit: Node3D in $Units.get_children():
		unit.set_team(0)
		for other: Node3D in $Units.get_children():
			other.visible = other == unit
		camera.global_position = unit.global_position + Vector3(3.0, 3.2, -4.4)
		camera.look_at(unit.global_position + Vector3(0, 1.05, 0))
		camera.size = 3.8
		for i: int in range(20):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://assets/models/units/detail_%s.png" % unit.name.to_lower())
		unit.strike()
		var attack_player: AnimationPlayer = unit.get_node("Attack")
		var impact: float = 0.49 if unit.name == "Catapult" else 0.29
		attack_player.advance(impact)
		attack_player.pause()
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://assets/models/units/detail_%s_attack.png" % unit.name.to_lower())
		if unit.name == "Catapult":
			assert(not unit.get_node("Rig/ThrowArm/Payload").visible, "Catapult payload must leave the spoon at release")
		if unit.name == "Archer":
			assert(not unit.get_node("Rig/ArmRight/Arrow").visible, "Archer must release the readied arrow")
		unit.set_motion(true)
		assert(unit.get_node("Locomotion").current_animation == "walk")
		unit.die()
		assert(not unit.get_node("Locomotion").is_playing())
		assert(not attack_player.is_playing())
	print("UNIT VISUAL VALIDATION PASSED: all 5 models, heraldry, walk, strike, payload and death pause")
	get_tree().quit()
