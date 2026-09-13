extends SceneTree
## Host restoration, encoded snapshots, client clips and malformed action rejection.
const FIXTURE = preload("res://tests/network_game_fixture.tscn")
const RELAY = preload("res://scripts/network/relay_client.tscn")
var checks: int = 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func state_for(snapshot: Dictionary, id: int) -> Dictionary:
	for state: Dictionary in snapshot.entities:
		if int(state.id) == id: return state
	return {}
func _run() -> void:
	var host: Node3D = FIXTURE.instantiate()
	root.add_child(host)
	host.is_authority = true
	var host_relay: RelayClient = RELAY.instantiate()
	host.add_child(host_relay)
	var sender: MatchReplication = host.get_node("MatchReplication")
	sender.configure(host,host_relay)
	var priest: BattleUnit = host.spawn_unit("priest",0,Vector3.ZERO)
	var patient: BattleUnit = host.spawn_unit("swordsman",1,Vector3(0,0,-3))
	var hidden: BattleUnit = host.spawn_unit("priest",2,Vector3(30,0,30))
	var academy: BattleBuilding = host.spawn_building("academy",0,Vector3(10,0,10))
	academy.production.recruit("priest")
	academy.production.research("attack_1")
	patient.hp = 20
	priest.order = BattleUnit.Order.SUPPORT
	priest.work_target = patient
	for tick: int in 30:
		host.elapsed += .02
		priest.support.advance_clock(.02)
		if priest.support.select_job(): priest.support.velocity_for_job(.02)
	check(patient.hp == 30 and host.effects == 1,"only host restores ten and creates one visual event")
	priest._model.attack.seek(.66,true)
	var snapshot: Dictionary = sender.build_snapshot(0)
	check(state_for(snapshot,hidden.entity_id).is_empty(),"hidden enemy priest and its action omitted from snapshot")
	check(state_for(snapshot,priest.entity_id).anim == "heal" and state_for(snapshot,priest.entity_id).working,"host publishes healing action")
	var queues: Dictionary = state_for(snapshot,academy.entity_id).production
	check(queues.training[0].kind == "priest" and queues.research_queue[0].id == "attack_1","academy training and research transmit independently")
	var bytes := NetworkProtocol.encode({"op":"snapshot","payload":snapshot})
	var wire: Dictionary = NetworkProtocol.decode(bytes).payload
	check(not bytes.is_empty() and NetworkProtocol.VERSION == 13,"current protocol encodes priest snapshot")
	var client: Node3D = FIXTURE.instantiate()
	root.add_child(client)
	var client_relay: RelayClient = RELAY.instantiate()
	client.add_child(client_relay)
	var receiver: MatchReplication = client.get_node("MatchReplication")
	receiver.configure(client,client_relay)
	receiver.receive_snapshot(wire)
	check(receiver.last_received_tick == 0 and client.entities_by_id.has(priest.entity_id),"client accepts real priest snapshot")
	var replica: BattleUnit = client.entities_by_id[priest.entity_id]
	var patient_replica: BattleUnit = client.entities_by_id[patient.entity_id]
	receiver.render(.1)
	check(replica._model.attack.current_animation == "heal" and is_equal_approx(replica._model.attack.current_animation_position,.66),"client samples native heal clip at host phase")
	check(patient_replica.hp == 30 and not replica.is_physics_processing(),"client receives HP and cannot tick gameplay")
	check(patient_replica.restore_health(10) == 0 and not replica.support.select_job() and replica.support.velocity_for_job(1) == Vector3.ZERO,"replica cannot restore directly or through support component")
	check(patient_replica.hp == 30,"replica visual playback cannot duplicate health")
	var client_academy: BattleBuilding = client.entities_by_id[academy.entity_id]
	check(client_academy.production.training[0].kind == "priest" and client_academy.production.research_queue[0].id == "attack_1","replica retains both academy queues")
	for invalid: Dictionary in [{"kind":"swordsman"},{"anim":"repair"},{"working":false},{"moving":true},{"phase":NAN}]:
		var bad: Dictionary = wire.duplicate(true)
		bad.tick = 1
		state_for(bad,priest.entity_id).merge(invalid,true)
		receiver.receive_snapshot(bad)
		check(receiver.last_received_tick == 0,"reject mismatched or malformed healing state: "+str(invalid))
	priest.support.cancel()
	priest.order = BattleUnit.Order.IDLE
	host.simulation_tick = 2
	host.elapsed = .7
	receiver.receive_snapshot(NetworkProtocol.decode(NetworkProtocol.encode({"op":"snapshot","payload":sender.build_snapshot(0)})).payload)
	for frame: int in 10: receiver.render(.1)
	check(receiver.last_received_tick == 2 and not replica._model._working and not replica._model._support_particles[0].emitting,"stop snapshot cancels client healing animation and particles")
	client.queue_free()
	host.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/priest-20260913/network-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("PRIEST_NETWORK ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
