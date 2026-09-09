extends SceneTree
## Actual authored Game + RelayClient state machine. No socket is opened here:
## only the local monotonic deadline is advanced, never production grace values.

var checks: int = 0
var failures: Array[String] = []
var errors: Array[String] = []
var session: Node

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func _run() -> void:
	session = root.get_node("Session")
	session.relay.error_received.connect(func(code: String, _message: String): errors.append(code))
	for owner in range(2):
		var relay: RelayClient = session.relay
		relay.disconnect_relay()
		relay.owner_id = owner
		relay.is_host = owner == 0
		relay.connection_state = "connected"
		relay._token = "expiry-test-in-memory-identity"
		var config := {"mode": "1v1", "map_id": "duel", "match_id": "expiry-test-%d" % owner, "players": [
			{"owner_id": 0, "team_id": 0, "controller": "human", "name": "期限测试房主"},
			{"owner_id": 1, "team_id": 1, "controller": "human", "name": "期限测试玩家"}]}
		relay._match = config
		session.start_online(config)
		check(await until(func(): return current_scene != null and current_scene.scene_file_path == "res://scenes/main.tscn" and current_scene._match_ready, 15.0), "authored_game_ready_owner_%d" % owner)
		var game: Node3D = current_scene
		game.tests_running = true
		game.camera_rig.edge_scroll = false
		relay._set_state("match")
		var before := Time.get_ticks_msec()
		relay._lost(before)
		check(relay._reconnect_deadline == before + (30000 if owner == 0 else 120000), "native_grace_duration_owner_%d" % owner)
		check(relay.connection_state == "reconnecting", "lost_transport_enters_reconnect_owner_%d" % owner)
		check(paused == (owner == 0), "only_disconnected_host_pauses_authority_owner_%d" % owner)
		check(not game.finished, "match_retained_before_expiry_owner_%d" % owner)
		# Deliberate test-clock jump across the stored deadline. This covers the
		# exact callback that must release an offline host's paused result screen.
		relay._reconnect_deadline = Time.get_ticks_msec() - 1
		relay._retry_at = Time.get_ticks_msec()
		relay._process(0.0)
		check(relay.connection_state == "error" and errors.back() == "reconnect_expired", "expiry_emits_terminal_connection_error_owner_%d" % owner)
		check(game.finished and not paused, "expiry_finishes_game_and_releases_pause_owner_%d" % owner)
		check(game.hud.get_node("%ResultHeading").text == "对局连接已中断", "expiry_presents_interruption_result_owner_%d" % owner)
		check(relay._retry_at == 0 and relay._connection == null, "expiry_stops_retry_and_transport_owner_%d" % owner)
		await game.prepare_shutdown()
		relay.disconnect_relay()
		current_scene = null
		game.queue_free()
		await process_frame
		await process_frame
	check(errors == ["reconnect_expired", "reconnect_expired"], "only_expected_clock_jump_errors")
	print("NETWORK_GAME_EXPIRY_RESULTS " + JSON.stringify({"checks": checks, "failures": failures,
		"clock_method": "advance local deadline; no wall-clock 30/120-second wait", "production_grace_seconds": [30, 120]}))
	quit(0 if failures.is_empty() else 1)

func until(predicate: Callable, duration: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(duration * 1000)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return bool(predicate.call())

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
