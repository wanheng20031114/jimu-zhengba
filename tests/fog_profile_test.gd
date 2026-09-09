extends SceneTree
## CPU-only fog update benchmark at the 2v2 all-light-unit population ceiling.
const UNIT: PackedScene = preload("res://scenes/unit.tscn")
var host: Node3D

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	change_scene_to_file("res://tests/fog_test_host.tscn")
	await scene_changed
	host = current_scene
	for owner: int in range(4):
		for index: int in range(70):
			var unit: Node3D = UNIT.instantiate()
			unit.unit_type = "farmer" if index < 10 else ("swordsman" if index % 2 == 0 else "archer")
			unit.owner_id = owner
			unit.alliance_id = host.get_player(owner).alliance_id
			unit.position = Vector3(-55 + (index % 10) * 11 + (owner % 2), 0, -42 + (index / 10) * 13 + (owner / 2))
			host.get_node("Units").add_child(unit)
			unit.set_physics_process(false)
			unit.navigation_agent.avoidance_enabled = false
			unit.process_mode = Node.PROCESS_MODE_DISABLED
	host.fog.configure(host, Vector2(128, 112))
	host.fog.apply_visibility(0)
	var texture_id: RID = host.fog._texture.get_rid()
	var samples: Array[float] = []
	var presentation: Array[float] = []
	for sample: int in range(35):
		var before: int = Time.get_ticks_usec()
		host.fog.tick(0.2)
		var after: int = Time.get_ticks_usec()
		host.fog.apply_visibility(0)
		if sample >= 5:
			samples.append((after - before) / 1000.0)
			presentation.append((Time.get_ticks_usec() - after) / 1000.0)
	samples.sort()
	presentation.sort()
	var stable: bool = host.fog._texture.get_rid() == texture_id
	var result := {"mode": "headless CPU, not rendered FPS", "sources": 280, "cells_per_alliance": 3584,
		"update_hz": 5, "samples": samples.size(), "vision_median_ms": samples[samples.size() / 2],
		"vision_p95_ms": samples[floori(samples.size() * 0.95)], "presentation_median_ms": presentation[presentation.size() / 2],
		"presentation_p95_ms": presentation[floori(presentation.size() * 0.95)], "persistent_texture_rid": stable}
	var file := FileAccess.open("res://artifacts/fog_profile_results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("FOG_PROFILE ", JSON.stringify(result))
	quit(0 if stable else 1)
