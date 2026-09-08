extends Node3D
## Real CharacterBody movement and native particle-state checks without rendering.
## Run: Godot --headless --path . res://tests/movement_dust_test.tscn
## The dummy renderer cannot read GPU particle occupancy. Tail checks therefore
## verify the native lifetime/alpha/world-space contract and retained emitter.

const HEAVY: Array[String] = ["knight", "catapult", "cannon"]
var units: Array[BattleUnit] = []
var snapshots: Dictionary = {}
var checks: int = 0
var failures: Array[String] = []
var effects: Array[String] = []
var deaths: Array[String] = []
var completed: bool = false

func _ready() -> void:
	for unit: BattleUnit in $Units.get_children():
		units.append(unit)
		# Exercise the production RVO callback with measured native displacement;
		# AI/path selection is outside this six-body collision test.
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error(label)

func _run() -> void:
	await get_tree().physics_frame
	for unit: BattleUnit in units:
		var dust: GPUParticles3D = unit.movement_dust
		var material: ParticleProcessMaterial = dust.process_material
		var kind: String = unit.unit_type
		snapshots[kind] = {"node": dust.get_instance_id(), "instance": dust.get_instance(), "start": unit.global_position}
		_check(dust.get_parent() == unit, kind + ": saved persistent emitter")
		_check(not dust.emitting, kind + ": starts idle")
		_check(dust.visible == (kind in HEAVY), kind + ": visible only for heavy units")
		_check(not dust.local_coords and not dust.one_shot, kind + ": continuous world-space tail")
		_check(dust.fixed_fps == 30 and dust.interpolate, kind + ": fixed simulation and smooth particle interpolation")
		_check(is_equal_approx(dust.lifetime, 1.65) and absf(dust.amount / dust.lifetime - 10.0) < 0.5, kind + ": preserved lifetime and emission rate")
		_check(is_equal_approx(dust.scale.x, 0.4), kind + ": preserved dust scale")
		_check(is_equal_approx(material.color_ramp.gradient.get_color(material.color_ramp.gradient.get_point_count() - 1).a, 0.0), kind + ": native lifetime curve fades to transparent")
		var box: AABB = dust.transform * dust.visibility_aabb
		_check(box.has_point(Vector3(12, 0, 0)) and box.has_point(Vector3(-12, 0, 0)) and box.has_point(Vector3(0, 0, 12)) and box.has_point(Vector3(0, 0, -12)), kind + ": cull bounds include full-speed cavalry tail")
	await _drive(Vector3.BACK, 8)
	for unit: BattleUnit in units:
		_check(unit.global_position.distance_to(snapshots[unit.unit_type].start) > 0.1, unit.unit_type + ": native movement occurred")
		_check(unit.movement_dust.emitting == (unit.unit_type in HEAVY), unit.unit_type + ": only moving heavy units emit")
		snapshots[unit.unit_type].seed = unit.movement_dust.seed
	await _drive(Vector3.ZERO, 1)
	for unit: BattleUnit in units:
		_check(not unit.movement_dust.emitting, unit.unit_type + ": stop immediately disables new particles")
		_check_retained_tail(unit, "stopped")
	await get_tree().create_timer(1.8).timeout
	for unit: BattleUnit in units:
		_check(not unit.movement_dust.emitting, unit.unit_type + ": remains off beyond full tail lifetime")
		_check_retained_tail(unit, "after tail lifetime")
	# Continue asking for forward speed until every body hits the authored wall.
	await _drive(Vector3.BACK, 90)
	for unit: BattleUnit in units:
		_check(unit.get_slide_collision_count() > 0, unit.unit_type + ": real wall collision blocks movement")
		_check(unit.get_position_delta().length() < 0.005, unit.unit_type + ": nonzero requested speed yields no actual displacement")
		_check(not unit.movement_dust.emitting, unit.unit_type + ": blocked body produces no movement dust")
	_check(effects.is_empty(), "movement and obstruction spawn no temporary BattleEffect scenes")
	await _drive(Vector3.FORWARD, 1)
	for unit: BattleUnit in units:
		_check(unit.movement_dust.emitting == (unit.unit_type in HEAVY), unit.unit_type + ": reversing away from wall resumes eligible emitters")
		unit.receive_damage(unit.max_hp + 100.0)
		_check(not unit.alive and not unit.movement_dust.emitting, unit.unit_type + ": death disables emission")
		_check_retained_tail(unit, "dead")
		unit._apply_velocity(Vector3.BACK * unit.speed)
		_check(not unit.movement_dust.emitting, unit.unit_type + ": late velocity callback cannot restart dead emitter")
	_check(deaths.size() == units.size(), "all six normal death callbacks delivered")
	_check(effects.size() == units.size() and effects.all(func(kind: String) -> bool: return kind == "dust"), "one original death dust burst per unit remains")
	await get_tree().create_timer(1.8).timeout
	for unit: BattleUnit in units:
		_check_retained_tail(unit, "dead after tail lifetime")
		_check(not unit.movement_dust.emitting, unit.unit_type + ": death does not resume emission later")
	_finish()

func _drive(direction: Vector3, frames: int) -> void:
	for frame: int in range(frames):
		await get_tree().physics_frame
		for unit: BattleUnit in units:
			unit._apply_velocity(direction * unit.speed)

func _check_retained_tail(unit: BattleUnit, stage: String) -> void:
	var dust: GPUParticles3D = unit.movement_dust
	var original: Dictionary = snapshots[unit.unit_type]
	_check(dust.get_instance_id() == original.node and dust.get_instance() == original.instance, unit.unit_type + ": " + stage + " retains native emitter")
	_check(dust.seed == original.seed, unit.unit_type + ": " + stage + " does not restart particles")
	_check(dust.visible == (unit.unit_type in HEAVY) and is_equal_approx(dust.speed_scale, 1.0) and not dust.local_coords, unit.unit_type + ": " + stage + " allows existing world-space particles to finish")

func spawn_effect(_at: Vector3, kind: String, _color: Color = Color.WHITE) -> void:
	effects.append(kind)

func on_entity_died(entity: Node3D) -> void:
	deaths.append(entity.unit_type)

func _on_timeout() -> void:
	_check(false, "test finished within 20 seconds")
	_finish()

func _finish() -> void:
	if completed:
		return
	completed = true
	var report: Dictionary = {"checks": checks, "failures": failures, "physics_ticks": Engine.physics_ticks_per_second, "renderer": RenderingServer.get_current_rendering_method(), "coverage": "Native movement, wall collisions and emission-state/lifetime contract; no GPU visual occupancy readback in headless mode."}
	var output: FileAccess = FileAccess.open("res://artifacts/movement_dust_test.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("Movement dust: ", checks - failures.size(), "/", checks, " PASS")
	get_tree().quit(0 if failures.is_empty() else 1)
