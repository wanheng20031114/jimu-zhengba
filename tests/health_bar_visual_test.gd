extends Node
## Render the real scene materials; verify pixels rather than shader source text.
## Run health_bar_visual_test.tscn with GPU rendering enabled, not --headless.
const SOURCES: Array[PackedScene] = [preload("res://scenes/unit.tscn"), preload("res://scenes/building.tscn")]
@onready var viewport: SubViewport = $Viewport
@onready var camera: Camera3D = $Viewport/Camera3D
@onready var bars: Array[MeshInstance3D] = [$Viewport/UnitBar, $Viewport/BuildingBar]
var failures: Array[String] = []
var checks := 0
var prefix := "health-bar"

func _ready() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_position(Vector2i(-20000, -20000))
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-prefix="):
			prefix = argument.trim_prefix("--capture-prefix=")
	for index: int in bars.size():
		var source: Node = SOURCES[index].instantiate()
		bars[index].material_override = source.get_node("HealthBar").material_override
		bars[index].set_instance_shader_parameter("bar_color", Color("a4c63b"))
		source.free()
	_run.call_deferred()

func _run() -> void:
	var full_counts: Array[int] = [0, 0]
	for amount: float in [1.0, 0.5, 0.0, 0.25, 0.75]:
		for bar: MeshInstance3D in bars:
			bar.set_instance_shader_parameter("health", amount)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var capture: Image = viewport.get_texture().get_image()
		_check(capture.save_png("res://artifacts/%s-%03d.png" % [prefix, roundi(amount * 100.0)]) == OK, "save %d%% capture" % roundi(amount * 100.0))
		for index: int in bars.size():
			var bar: MeshInstance3D = bars[index]
			var left := roundi(camera.unproject_position(bar.to_global(Vector3(-0.5, 0, 0))).x)
			var right := roundi(camera.unproject_position(bar.to_global(Vector3(0.5, 0, 0))).x)
			var y := roundi(camera.unproject_position(bar.global_position).y)
			var filled: Array[int] = []
			for x: int in range(left, right):
				var pixel := capture.get_pixel(x, y)
				if pixel.g > 0.5 and pixel.g > pixel.b * 1.5:
					filled.append(x)
			var label := "%s %d%%" % [bar.name, roundi(amount * 100.0)]
			if amount == 1.0:
				full_counts[index] = filled.size()
				_check(not filled.is_empty(), label + " visibly filled")
				if not filled.is_empty():
					var left_margin: int = filled.front() - left
					var right_margin: int = right - 1 - filled.back()
					_check(absi(left_margin - right_margin) <= 1, "%s symmetric border: left=%d right=%d" % [label, left_margin, right_margin])
			else:
				_check(absi(filled.size() - roundi(full_counts[index] * amount)) <= 1, "%s fill width: %d pixels" % [label, filled.size()])
	print("HEALTH_BAR_VISUAL ", checks, " checks; ", failures.size(), " failures")
	get_tree().quit(0 if failures.is_empty() else 1)

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)
