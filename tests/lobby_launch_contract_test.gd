extends SceneTree
## Legacy automation flags must cross the lobby without a network handshake.

const Fixtures = preload("res://tests/lobby_ui_test.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var original_session: Node = root.get_node_or_null("Session")
	if original_session != null:
		original_session.name = "OriginalSession"
	var session := Fixtures.FakeSession.new()
	session.name = "Session"
	session.relay = Fixtures.FakeRelay.new()
	session.add_child(session.relay)
	root.add_child(session)
	var lobby: Node3D = load("res://scenes/lobby.tscn").instantiate()
	root.add_child(lobby)
	current_scene = lobby
	for frame: int in 3:
		await process_frame
	var expected: String = "2v2" if "--2v2" in OS.get_cmdline_user_args() else "1v1"
	var correct: bool = session.offline_modes == [expected] and session.relay.calls.is_empty()
	if not correct:
		printerr("FAIL legacy launch should immediately request offline ", expected)
	lobby.queue_free()
	await process_frame
	session.queue_free()
	await process_frame
	if original_session != null:
		original_session.name = "Session"
	print("LOBBY_LAUNCH_CONTRACT ", expected, " ", "PASS" if correct else "FAIL")
	quit(0 if correct else 1)
