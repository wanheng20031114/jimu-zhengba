extends SceneTree
## Expected-negative TLS test. Verification failure diagnostics are expected here.

const Client = preload("res://scripts/network/relay_client.gd")
var client: Node
var temporary_cert: String = ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	Engine.max_fps = 120
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://.local/network/endpoint.json"))
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var wrong_trust := crypto.generate_self_signed_certificate(key, "CN=ashen-crown-relay")
	temporary_cert = "user://wrong-network-trust-%d.crt" % Time.get_ticks_usec()
	wrong_trust.save(temporary_cert)
	client = Client.new()
	client.auto_reconnect = false
	client.certificate_path = temporary_cert
	root.add_child(client)
	client.connect_relay(config.address, int(config.port))
	var deadline := Time.get_ticks_msec() + 10000
	var connected := false
	while Time.get_ticks_msec() < deadline:
		if client.connection_state == "connected":
			connected = true
			break
		if client.connection_state in ["disconnected", "error"]:
			break
		await process_frame
	var rejected: bool = not connected and client.owner_id == -1
	client.disconnect_relay()
	client.certificate_path = Client.CERTIFICATE_PATH
	client.connect_relay(config.address, int(config.port))
	deadline = Time.get_ticks_msec() + 10000
	while client.connection_state != "connected" and Time.get_ticks_msec() < deadline:
		await process_frame
	var valid_connects: bool = client.connection_state == "connected"
	client.disconnect_relay()
	client.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_cert))
	print("NETWORK_CERTIFICATE_RESULTS " + JSON.stringify({"wrong_trust_rejected": rejected, "correct_trust_connects": valid_connects, "expected_negative_tls_diagnostics": true}))
	quit(0 if rejected and valid_connects else 1)
