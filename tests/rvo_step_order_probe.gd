extends SceneTree
## Native-only diagnostic: identical two-agent states with reversed registration.
## No game, rendering, path search, CharacterBody, or timers affect the velocities.
var output := ""
var records: Array[Dictionary] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--output="): output = argument.trim_prefix("--output=")
	assert(not output.is_empty(), "Provide an output JSON path")
	Engine.physics_ticks_per_second = 30
	for threaded: bool in [false, true]:
		ProjectSettings.set_setting("navigation/avoidance/thread_model/avoidance_use_multiple_threads", threaded)
		for trial: int in 12:
			var forward := _create_pair([0, 1])
			var backward := _create_pair([1, 0])
			var deadline := Time.get_ticks_msec() + 3000
			while (forward.received.size() < 2 or backward.received.size() < 2) and Time.get_ticks_msec() < deadline:
				await physics_frame
			assert(forward.received.size() == 2 and backward.received.size() == 2, "Both maps dispatch velocities")
			var difference := 0.0
			for index: int in 2:
				difference = maxf(difference, forward.velocities[index].distance_to(backward.velocities[index]))
			records.append({"threaded": threaded, "trial": trial, "max_velocity_difference": difference,
				"forward": forward.velocities.map(func(v: Vector3): return [v.x, v.y, v.z]),
				"reverse": backward.velocities.map(func(v: Vector3): return [v.x, v.y, v.z])})
			for entry: Dictionary in [forward, backward]:
				for agent: RID in entry.agents: NavigationServer3D.free_rid(agent)
				NavigationServer3D.free_rid(entry.map)
			await physics_frame
	await physics_frame
	FileAccess.open(output, FileAccess.WRITE).store_string(JSON.stringify({
		"godot": Engine.get_version_info().string, "physics_tps": 30, "records": records,
		"notes": "Diagnostic only. Reversing creation may affect scheduling and neighbor traversal. This is not a race detector or proof of a cause in game movement."}, "  "))
	print("RVO_STEP_ORDER_PROBE ", records.size(), " paired trials")
	quit()

func _create_pair(order: Array[int]) -> Dictionary:
	var map := NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(map, true)
	var entry := {"map": map, "agents": [], "received": {}, "velocities": [Vector3.ZERO, Vector3.ZERO]}
	var positions: Array[Vector3] = [Vector3(-1, 0, 0), Vector3(1, 0, 0.2)]
	var velocities: Array[Vector3] = [Vector3(3, 0, 0), Vector3(-3, 0, 0)]
	for index: int in order:
		var agent := NavigationServer3D.agent_create()
		entry.agents.append(agent)
		NavigationServer3D.agent_set_map(agent, map)
		NavigationServer3D.agent_set_use_3d_avoidance(agent, false)
		NavigationServer3D.agent_set_avoidance_enabled(agent, true)
		NavigationServer3D.agent_set_neighbor_distance(agent, 5.5)
		NavigationServer3D.agent_set_max_neighbors(agent, 1)
		NavigationServer3D.agent_set_radius(agent, 0.6)
		NavigationServer3D.agent_set_height(agent, 2.0)
		NavigationServer3D.agent_set_max_speed(agent, 3.0)
		NavigationServer3D.agent_set_time_horizon_agents(agent, 0.6)
		NavigationServer3D.agent_set_time_horizon_obstacles(agent, 0.5)
		NavigationServer3D.agent_set_position(agent, positions[index])
		NavigationServer3D.agent_set_velocity_forced(agent, velocities[index])
		NavigationServer3D.agent_set_velocity(agent, velocities[index])
		NavigationServer3D.agent_set_avoidance_callback(agent, _received_velocity.bind(entry, index))
	return entry

func _received_velocity(velocity: Vector3, entry: Dictionary, index: int) -> void:
	if entry.received.has(index): return
	entry.received[index] = true
	entry.velocities[index] = velocity
