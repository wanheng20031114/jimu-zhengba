extends Node
## Pixel differential against native draw_circle, including fractional centres,
## overlapping factions and selection rings. Both paths use the actual GPU.
@onready var viewport: SubViewport = $Viewport
@onready var canvas: Control = $Viewport/Canvas
var checks := 0
var failures: Array[String] = []

func _ready() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func capture(reference: bool) -> Image:
	canvas.reference = reference
	canvas.queue_redraw()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func _run() -> void:
	check(DisplayServer.get_name() != "headless", "pixel differential uses the real GPU renderer")
	if not failures.is_empty():
		get_tree().quit(1)
		return
	var reference := await capture(true)
	var shared := await capture(false)
	var changed := 0
	var maximum := 0.0
	var coloured := 0
	for y: int in reference.get_height():
		for x: int in reference.get_width():
			var a := reference.get_pixel(x, y)
			var b := shared.get_pixel(x, y)
			var error := maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), maxf(absf(a.b - b.b), absf(a.a - b.a)))
			maximum = maxf(maximum, error)
			if error > 0.01: changed += 1
			if a.r > 0.3 or a.g > 0.3 or a.b > 0.3: coloured += 1
	check(coloured > 1000, "reference contains real faction markers and rings")
	check(changed <= 4, "shared circle preserves pixels (different=%d, maximum=%.6f)" % [changed, maximum])
	var output := ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(output)
	reference.save_png(output.path_join("minimap-mesh-reference.png"))
	shared.save_png(output.path_join("minimap-mesh-shared.png"))
	print("MINIMAP_MESH_VISUAL %d checks; %d failures; different_pixels=%d; max_error=%.6f" % [checks, failures.size(), changed, maximum])
	get_tree().quit(0 if failures.is_empty() else 1)
