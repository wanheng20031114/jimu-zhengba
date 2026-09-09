extends SceneTree
## End-to-end encrypted UDP smoke/stress against the explicitly configured relay.
## The endpoint lives in ignored .local; never print it, room tokens, or packet bodies.

const Client = preload("res://scripts/network/relay_client.gd")
const Protocol = preload("res://scripts/network/network_protocol.gd")
var clients: Array = []
var checks: Array = []
var failures: Array = []
var commands_received: int = 0
var snapshot_counts: Array[int] = [0, 0, 0, 0]
var event_counts: Array[int] = [0, 0, 0, 0]
var finished: bool = false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	Engine.max_fps = 120
	var endpoint_path := "res://.local/network/endpoint.json"
	if not FileAccess.file_exists(endpoint_path):
		print("NETWORK_REMOTE_CONFIG_MISSING")
		quit(1)
		return
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(endpoint_path))
	for index in range(4):
		var client := Client.new()
		client.auto_reconnect = false
		root.add_child(client)
		clients.append(client)
		client.error_received.connect(func(code: String, _message: String): failures.append({"client": index, "code": code}))
		client.command_received.connect(func(_owner: int, _command: Dictionary): commands_received += 1)
		client.snapshot_received.connect(func(_snapshot: Dictionary): snapshot_counts[index] += 1)
		client.event_received.connect(func(event: Dictionary):
			if event.get("kind") == "network_probe": event_counts[index] += 1
		)
		client.connect_relay(config.address, int(config.port))
	await _until(func(): return clients.all(func(c): return c.connection_state == "connected"), 12000)
	_check("four native 4.6 clients reach encrypted remote relay", clients.all(func(c): return c.connection_state == "connected"))
	if clients.any(func(c): return c.connection_state != "connected"):
		await _finish()
		return
	clients[0].create_room("2v2", "网络验收房主")
	await _until(func(): return not clients[0].room.is_empty(), 5000)
	if clients[0].room.is_empty():
		_check("remote room available", false)
		await _finish()
		return
	var code: String = clients[0].room.code
	for index in range(1, 4):
		clients[index].join_room(code, "网络验收%d" % index)
		await _until(func(): return clients[index].owner_id == index, 5000)
		clients[index].set_ready(true)
	await _until(func(): return clients[0].room.slots.all(func(s): return s.ready), 5000)
	clients[0].start_match()
	await _until(func(): return clients.all(func(c): return c.connection_state == "match"), 5000)
	_check("four human 2v2 room starts", clients.all(func(c): return c.connection_state == "match"))
	var units: Array = []
	for index in range(280):
		units.append({"id": index + 1, "p": [float(index % 28), 0.0, float(index / 28)], "yaw": 0.5, "hp": 100, "kind": "swordsman", "order": "move"})
	var rounds := 60
	var sent_snapshots := 0
	var sent_commands := 0
	for tick in range(rounds):
		for index in range(1, 4):
			if clients[0].snapshot_to(index, {"tick": tick * 2, "units": units}) == OK:
				sent_snapshots += 1
			if clients[index].send_command({"kind": "move", "units": [index], "at": [float(tick), 0.0, 0.0]}) == OK:
				sent_commands += 1
		if tick % 15 == 0: clients[0].send_event(-1, {"kind": "network_probe", "tick": tick})
		await create_timer(1.0 / 15.0).timeout
	await _until(func(): return commands_received == sent_commands and event_counts.all(func(count): return count == 4), 5000)
	_check("180 commands reliably forwarded", sent_commands == 180 and commands_received == sent_commands)
	_check("reliable events arrive on all four peers", event_counts == [4, 4, 4, 4])
	_check("fragmented snapshots delivered to each recipient", snapshot_counts[0] == 0 and snapshot_counts[1] > 20 and snapshot_counts[2] > 20 and snapshot_counts[3] > 20)
	_check("no protocol or capacity errors", failures.is_empty())
	var sample := Protocol.encode({"op": "snapshot", "to": 1, "sequence": 1, "payload": {"tick": 0, "units": units}})
	print("NETWORK_REMOTE_METRICS " + JSON.stringify({"snapshots_sent": sent_snapshots, "snapshots_received": snapshot_counts, "commands_sent": sent_commands, "commands_received": commands_received, "snapshot_units": 280, "snapshot_wire_bytes": sample.size(), "snapshot_json_bytes": Protocol.decoded_size(sample)}))
	await _finish()

func _until(condition: Callable, duration: int) -> void:
	var deadline := Time.get_ticks_msec() + duration
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame

func _check(name: String, passed: bool) -> void:
	checks.append({"name": name, "passed": passed})
	print("NETWORK_REMOTE_CHECK %s %s" % ["PASS" if passed else "FAIL", name])

func _finish() -> void:
	if finished: return
	finished = true
	if not clients.is_empty() and clients[0].is_host:
		clients[0].finish_match({"reason": "network_validation_complete"})
		await create_timer(0.4).timeout
	for client: Node in clients:
		client.disconnect_relay()
		client.queue_free()
	var count := checks.filter(func(check): return not check.passed).size()
	print("NETWORK_REMOTE_RESULTS " + JSON.stringify({"checks": checks.size(), "failed": count, "error_codes": failures}))
	quit(0 if count == 0 else 1)
