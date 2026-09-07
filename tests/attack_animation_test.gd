extends SceneTree
## Native attack timing, hand/string contact, recoil, launch socket and recovery.
var failures: Array[String] = []
var checks: int = 0
var rendered: bool
var world: Node3D
var camera: Camera3D

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	checks += 1
	if value:
		print("PASS ", label)
	else:
		failures.append(label)
		push_error("FAIL " + label)

func pose(model: Node3D, time: float) -> void:
	var player: AnimationPlayer = model.get_node("Attack")
	player.stop()
	player.play("strike")
	player.advance(time)
	player.pause()

func capture(model: Node3D, suffix: String) -> void:
	if not rendered:
		return
	for other: Node3D in world.get_node("Units").get_children():
		other.visible = other == model
	camera.global_position = model.global_position + Vector3(3.0, 3.2, -4.4)
	camera.look_at(model.global_position + Vector3(0, 1.05, 0))
	camera.size = 3.8
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://artifacts/attack_%s_%s.png" % [model.kind, suffix])

func _run() -> void:
	create_timer(40.0, true, false, true).timeout.connect(func(): quit(3))
	rendered = DisplayServer.get_name() != "headless"
	if rendered:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	world = load("res://assets/models/units/preview.tscn").instantiate()
	world.set_script(null)
	root.add_child(world)
	current_scene = world
	camera = world.get_node("Camera3D")
	await process_frame
	for model: Node3D in world.get_node("Units").get_children():
		model.get_node("Locomotion").pause()
		var resting: Dictionary = {}
		for node: Node3D in model.find_children("*", "Node3D", true, false):
			resting[node] = node.transform
		var animation: Animation = model.get_node("Attack").get_animation("strike")
		var native_tracks: int = 0
		for index: int in range(animation.get_track_count()):
			if animation.track_get_type(index) in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D]:
				native_tracks += 1
		check(native_tracks >= 6, model.kind + " uses native whole-body transform tracks")
		match model.kind:
			"swordsman":
				pose(model, .15)
				check(model.find_child("Waist").rotation.y > .3, "swordsman winds the torso before striking")
				await capture(model, "prepare")
				pose(model, .22)
				check(model.find_child("Waist").rotation.y < -.3, "swordsman weight turns at .22 second impact")
				check(model.find_child("ArmLeft").rotation.x > .3, "swordsman keeps shield forward")
				check(model.get_node("Rig/Action").position.z < -.15, "swordsman lunges at impact")
				await capture(model, "hit")
			"knight":
				pose(model, .13)
				await capture(model, "prepare")
				pose(model, .20)
				check(model.find_child("Waist").rotation.y < -.3, "knight torso crosses through mounted slash at .20")
				check(model.find_child("HorseHead").rotation.x > .10, "horse head answers rider impact")
				check(model.get_node("Rig/Action").position.z < -.20, "mounted attack carries the whole weight forward")
				await capture(model, "hit")
			"archer":
				pose(model, .24)
				var bow: Node3D = model.find_child("Bow")
				var hand: Node3D = model.find_child("ForearmRight")
				var contact: float = hand.to_global(Vector3(.02, -.24, -.075)).distance_to(bow.to_global(Vector3(0, 0, .46)))
				check(contact < .025, "archer draw hand meets string (distance %.4f m)" % contact)
				check(model.find_child("StringUpper").position.z > .44, "archer visibly draws and holds the bowstring")
				check(bow.global_basis.y.dot(Vector3.UP) > .97, "aimed bow remains upright")
				await capture(model, "aim")
				pose(model, .27)
				check(not model.find_child("Arrow").visible, "arrow releases exactly at .27 seconds")
				check(model.find_child("StringUpper").position.z < .16, "bowstring snaps forward at release")
				await capture(model, "release")
			"catapult":
				pose(model, .44)
				check(model.find_child("ThrowArm").rotation.x > .20, "catapult holds maximum tension before throw")
				await capture(model, "prepare")
				pose(model, .48)
				var arm: Node3D = model.find_child("ThrowArm")
				check(atan2(arm.basis.y.z, arm.basis.y.y) < -1.5, "catapult releases forward at .48 seconds")
				check(not model.find_child("Payload").visible, "catapult stone leaves spoon on launch")
				await capture(model, "launch")
				pose(model, .53)
				check(atan2(arm.basis.y.z, arm.basis.y.y) < -1.78, "catapult arm visibly overshoots then rebounds")
			"cannon":
				pose(model, .25)
				await capture(model, "fire")
				pose(model, .285)
				check(model.find_child("Barrel").position.z > .18, "cannon barrel recoils after .25 second shot")
				check(model.get_node("Rig/Action").position.z > .12, "cannon chassis absorbs the recoil")
				check(model.find_child("WheelLeftKick").rotation.x > .23, "cannon wheel frame rolls back under load")
				await capture(model, "recoil")
		var origin: Vector3 = model.to_local(model.get_projectile_origin())
		check(origin.y > .35 and origin.y < 3.2 and origin.z < .2, model.kind + " has a finite weapon-attached launch socket")
		pose(model, animation.length + .02)
		var recovered: bool = true
		for node: Node3D in resting:
			if not node.transform.is_equal_approx(resting[node]):
				recovered = false
				print("RECOVERY_DIFFERENCE ", model.kind, " ", node.name, " ", node.transform, " expected ", resting[node])
		check(recovered, model.kind + " returns every attack joint to authored resting pose")
		model.set_motion(true)
		model.die()
		check(not model.get_node("Locomotion").is_playing() and not model.get_node("Attack").is_playing(), model.kind + " death pauses new animations")
	var file := FileAccess.open("res://tests/attack_animation_result.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "rendered": rendered}, "\t"))
	print("ATTACK_ANIMATION_RESULT ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 2)
