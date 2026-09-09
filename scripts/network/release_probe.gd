extends Node
## Explicit --network-smoke release diagnostics. This scene never loads Game,
## creates units, grants resources, or reads private deployment configuration.

const MANIFEST_PATH := "res://data/content_manifest.json"
const ENDPOINT_PATH := "res://data/relay_endpoint.json"

@onready var relay: RelayClient = $RelayClient
var checks: int = 0
var failures: Array[String] = []
var errors: Array[String] = []
var received_config: Dictionary = {}
var received_finish: bool = false
var catalog_files: int = 0
var handshake_msec: int = -1

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if "--network-smoke" not in OS.get_cmdline_user_args():
		check(false, "explicit_probe_flag_required")
		await finish()
		return
	relay.error_received.connect(func(code: String, _message: String): errors.append(code))
	relay.match_started.connect(func(config: Dictionary): received_config = config)
	relay.event_received.connect(func(event: Dictionary):
		if event.get("kind") == "match_finished": received_finish = true)
	var manifest := read_dictionary(MANIFEST_PATH)
	check(manifest.get("build") == NetworkProtocol.BUILD_ID and manifest.get("protocol") == NetworkProtocol.VERSION, "packaged_manifest_matches_protocol_and_build")
	check(manifest.get("files") is Dictionary and not manifest.get("files", {}).is_empty(), "packaged_catalogue_is_present")
	if manifest.get("files") is Dictionary:
		catalog_files = manifest.files.size()
		for relative: String in manifest.files:
			var path := "res://" + relative
			# Native export may convert scenes/resources to binary and remap them.
			check(FileAccess.file_exists(path) if relative.ends_with(".json") else ResourceLoader.exists(path), "catalogue_resource_" + relative)
	check(FileAccess.file_exists(RelayClient.CERTIFICATE_PATH), "packaged_public_trust_certificate_exists")
	var endpoint := read_dictionary(ENDPOINT_PATH)
	check(endpoint.get("address") is String and not endpoint.get("address", "").is_empty() and NetworkProtocol.integer(endpoint.get("port"), 1, 65535), "packaged_public_endpoint_exists")
	check(relay.content_hash.length() == 64 and relay.content_hash == FileAccess.get_sha256(MANIFEST_PATH), "packaged_manifest_fingerprint_loaded")
	if not failures.is_empty():
		await finish()
		return
	var began := Time.get_ticks_msec()
	check(relay.connect_relay(endpoint.address, int(endpoint.port)) == OK, "native_verified_dtls_connection_started")
	check(await until(func(): return relay.connection_state == "connected", 30.0), "deployed_relay_accepts_certificate_and_content_fingerprint")
	handshake_msec = Time.get_ticks_msec() - began
	if not failures.is_empty():
		await finish()
		return
	relay.create_room("2v2", "发布包联网自检")
	check(await until(func(): return relay.connection_state == "lobby" and not relay.room.is_empty(), 10.0), "temporary_room_created")
	if not failures.is_empty():
		await finish()
		return
	check(relay.owner_id == 0 and relay.is_host and relay.room.slots.size() == 4, "server_assigns_four_slot_room_and_host_identity")
	check(relay.room.match_id is String and relay.room.match_id.length() == 32, "server_assigns_independent_match_epoch")
	for owner in range(1, 4):
		relay.configure_slot(owner, "bot", 0 if owner < 2 else 1)
	check(await until(func(): return relay.room.slots.slice(1).all(func(slot): return slot.kind == "bot"), 10.0), "server_accepts_native_bot_slot_configuration")
	if failures.is_empty():
		# Only the room protocol starts, so the probe can confirm reliable finish
		# and capacity release. No main.tscn or gameplay simulation is instantiated.
		relay.start_match()
		check(await until(func(): return relay.connection_state == "match" and not received_config.is_empty(), 10.0), "start_configuration_reaches_packaged_client")
	if failures.is_empty():
		check(received_config.match_id == relay.room.match_id and received_config.players.size() == 4, "start_configuration_preserves_epoch_and_roster")
		relay.finish_match({"winner": -1, "time": 0})
		check(await until(func(): return relay.connection_state == "finished" and received_finish, 10.0), "reliable_finish_confirms_room_release")
	check(errors.is_empty(), "no_transport_error_during_release_probe")
	await finish()

func until(predicate: Callable, duration: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(duration * 1000)
	while Time.get_ticks_msec() < deadline and relay.connection_state != "error":
		if predicate.call(): return true
		await get_tree().process_frame
	return bool(predicate.call())

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition: failures.append(label)

func read_dictionary(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK or not parser.data is Dictionary: return {}
	return parser.data

func finish() -> void:
	if relay.connection_state != "finished" and not relay.room.is_empty():
		relay.leave_room()
		# Allow reliable leave to flush before destroying this test connection.
		await get_tree().create_timer(0.5).timeout
	relay.disconnect_relay()
	print("NETWORK_RELEASE_PROBE " + JSON.stringify({"checks": checks, "failures": failures,
		"error_codes": errors, "build": NetworkProtocol.BUILD_ID, "protocol": NetworkProtocol.VERSION,
		"content_hash": NetworkProtocol.content_hash(), "catalogue_files": catalog_files,
		"exported_template": not OS.has_feature("editor"), "handshake_msec": handshake_msec}))
	get_tree().quit(0 if failures.is_empty() else 1)
