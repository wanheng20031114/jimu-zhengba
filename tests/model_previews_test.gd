extends SceneTree
## Real-rendered native viewport checks; bounded, no desktop input.
var _failures: Array[String] = []
var _checks: Array[String] = []
var _previews: Node
const KINDS: Array[String] = ["swordsman", "archer", "knight", "catapult", "cannon", "farmer", "headquarters", "gold_vein", "defense_tower"]

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, label: String) -> void:
	if ok:
		_checks.append(label)
		print("PASS ", label)
	else:
		_failures.append(label)
		push_error("FAIL " + label)

func _run() -> void:
	create_timer(30.0).timeout.connect(func(): quit(3))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_previews = load("res://scenes/model_previews.tscn").instantiate()
	root.add_child(_previews)
	current_scene = _previews
	await create_timer(0.8).timeout
	await RenderingServer.frame_post_draw
	var snapshots: Dictionary = {}
	var positions: Dictionary = {}
	for kind: String in KINDS:
		var viewport: SubViewport = _previews.get_node(kind)
		var texture: Texture2D = _previews.portrait(kind)
		var pic: Image = texture.get_image()
		pic.save_png("res://artifacts/portrait_" + kind + ".png")
		_check(pic.get_size() == Vector2i(192, 216), kind + " native 192x216 texture")
		var bounds := pic.get_used_rect()
		_check(bounds.size.x > 45 and bounds.size.y > 60, kind + " visible model")
		_check(bounds.position.x > 1 and bounds.position.y > 1 and bounds.end.x < 191 and bounds.end.y < 215, kind + " unclipped silhouette")
		print("BOUNDS ", kind, " ", bounds)
		_check(pic.get_pixel(0, 0).a < 0.01, kind + " transparent background")
		# The renderer consumes UPDATE_ONCE internally; the node keeps this policy value.
		_check(viewport.render_target_update_mode == SubViewport.UPDATE_ONCE, kind + " uses one-shot render policy")
		_check(viewport.own_world_3d, kind + " isolated world")
		snapshots[kind] = pic.get_data()
		if kind in ["swordsman", "archer", "knight", "catapult", "cannon", "farmer"]:
			var player: AnimationPlayer = viewport.get_node("World/Model/Locomotion")
			positions[kind] = player.current_animation_position
	_previews.set_animated("swordsman")
	await create_timer(0.8).timeout
	await RenderingServer.frame_post_draw
	for kind: String in KINDS:
		var pic: Image = _previews.portrait(kind).get_image()
		_check((pic.get_data() != snapshots[kind]) == (kind == "swordsman"), kind + " texture updates only when active")
		if kind in ["swordsman", "archer", "knight", "catapult", "cannon", "farmer"]:
			var player: AnimationPlayer = _previews.get_node(kind + "/World/Model/Locomotion")
			_check((player.current_animation_position != positions[kind]) == (kind == "swordsman"), kind + " animation advances only when active")
	_previews.set_animated("headquarters")
	await create_timer(0.8).timeout
	await RenderingServer.frame_post_draw
	_check(_previews.portrait("headquarters").get_image().get_data() != snapshots["headquarters"], "active castle flag changes")
	_previews.set_animated("")
	await process_frame
	await RenderingServer.frame_post_draw
	snapshots.clear()
	for kind: String in KINDS:
		snapshots[kind] = _previews.portrait(kind).get_image().get_data()
	await create_timer(0.35).timeout
	await RenderingServer.frame_post_draw
	for kind: String in KINDS:
		_check(_previews.portrait(kind).get_image().get_data() == snapshots[kind], kind + " stays frozen with no active preview")
	_check(_previews.get_node("PreviewTick").is_stopped(), "empty selection stops timer")
	var file := FileAccess.open("res://artifacts/model_previews_test.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": _checks, "failures": _failures}, "\t"))
	file.close()
	print("PREVIEW RESULT ", _checks.size(), " PASS; ", _failures.size(), " FAIL")
	_previews.queue_free()
	_previews = null
	current_scene = null
	await process_frame
	await process_frame
	quit(0 if _failures.is_empty() else 1)
