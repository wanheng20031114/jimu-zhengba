extends SceneTree
## Small resource/selection contract; root performs actual render comparison.
const UNIT_SCENE: PackedScene = preload("res://scenes/unit.tscn")
const BUILDING_SCENE: PackedScene = preload("res://scenes/building.tscn")
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures.append(label)

func _spawn(kind: String, faction: int) -> BattleUnit:
	var unit: BattleUnit = UNIT_SCENE.instantiate()
	unit.unit_type = kind
	unit.team = faction
	current_scene.get_node("Units").add_child(unit)
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	return unit

func _run() -> void:
	change_scene_to_file("res://tests/worker_ai_host.tscn")
	await scene_changed
	var units: Array[BattleUnit] = []
	for kind: String in ["swordsman", "archer", "knight", "catapult", "cannon", "farmer"]:
		units.append(_spawn(kind, 0))
	var enemy: BattleUnit = _spawn("swordsman", 1)
	var first_ring: MeshInstance3D = units[0].selection_ring
	var material: ShaderMaterial = first_ring.get_surface_override_material(0)
	var code: String = material.shader.code
	_check(not material.resource_local_to_scene and not material.shader.resource_local_to_scene, "unit selection material and shader are shared resources")
	_check(not code.contains("ALPHA") and code.contains("ALBEDO = ring_color.rgb"), "selection shader stays in the opaque pipeline with its existing solid color")
	_check(code.contains("unshaded") and code.contains("shadows_disabled") and not code.contains("depth_test_disabled") and not code.contains("cull_disabled"), "selection retains unshaded color, default depth test and back-face culling")
	_check(code.contains("instance uniform vec4 ring_color : source_color"), "faction tint uses a color-correct per-instance uniform")
	for unit: BattleUnit in units:
		var ring: MeshInstance3D = unit.selection_ring
		var torus: TorusMesh = ring.mesh
		_check(ring.get_surface_override_material(0) == material and torus.material == material and ring.mesh == first_ring.mesh, unit.unit_type + " reuses the same material and torus mesh")
		_check(ring.get_instance_shader_parameter("ring_color") == Color("74d5f2") and ring.position == Vector3(0, 0.06, 0) and ring.scale.is_equal_approx(Vector3.ONE * unit.radius * 1.65), unit.unit_type + " preserves player tint and authored ring placement/size")
	_check(enemy.selection_ring.get_surface_override_material(0) == material and enemy.selection_ring.get_instance_shader_parameter("ring_color") == Color("f26b52"), "enemy ring shares the material while retaining its independent red tint")
	var torus: TorusMesh = first_ring.mesh
	_check(is_equal_approx(torus.inner_radius, 0.74) and is_equal_approx(torus.outer_radius, 0.82) and torus.rings == 48 and torus.ring_segments == 6 and first_ring.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "authored torus tessellation and disabled shadow casting are unchanged")
	units[0].set_selected(true)
	_check(first_ring.visible and not units[1].selection_ring.visible and not enemy.selection_ring.visible, "shared material never couples independent selection visibility")
	first_ring.set_instance_shader_parameter("ring_color", Color.WHITE)
	_check(units[1].selection_ring.get_instance_shader_parameter("ring_color") == Color("74d5f2") and enemy.selection_ring.get_instance_shader_parameter("ring_color") == Color("f26b52"), "changing one instance tint never changes another unit")
	var health: ShaderMaterial = units[0].health_bar.material_override
	_check(health.shader.code.contains("depth_test_disabled") and health.shader.code.contains("ALPHA = 1.0"), "health overlay keeps its existing depth and alpha behavior")
	var building: Node3D = BUILDING_SCENE.instantiate()
	_check(building.get_node("SelectionRing").get_surface_override_material(0) is StandardMaterial3D, "building selection material remains unchanged")
	building.free()
	for unit: BattleUnit in units:
		unit.queue_free()
	enemy.queue_free()
	await process_frame
	await process_frame
	var report: FileAccess = FileAccess.open("res://artifacts/unit_selection_material_results.json", FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks": checks, "failures": failures}, "  "))
	report.close()
	print("UNIT_SELECTION_MATERIAL ", checks, " checks; ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)
