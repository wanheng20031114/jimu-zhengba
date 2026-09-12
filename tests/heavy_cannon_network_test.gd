extends SceneTree
## Current-protocol snapshots preserve upgraded reach, recoil pose and host damage.
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
func wire(snapshot: Dictionary) -> Dictionary:
	return NetworkProtocol.decode(NetworkProtocol.encode({"op":"snapshot","payload":snapshot})).payload
func _run() -> void:
	create_timer(30,true,false,true).timeout.connect(func(): quit(3))
	var host: Node3D = FIXTURE.instantiate()
	root.add_child(host)
	host.is_authority = true
	var host_relay: RelayClient = RELAY.instantiate()
	host.add_child(host_relay)
	var sender: MatchReplication = host.get_node("MatchReplication")
	sender.configure(host,host_relay)
	host.get_player(0).complete_upgrade(BalanceCatalog.upgrade("cannon_range_1"))
	var cannon: BattleUnit = host.spawn_unit("heavy_cannon",0,Vector3.ZERO)
	var ally: BattleUnit = host.spawn_unit("heavy_cannon",1,Vector3(4,0,0))
	var hidden: BattleUnit = host.spawn_unit("heavy_cannon",2,Vector3(40,0,40))
	var target: BattleUnit = host.spawn_unit("war_elephant",2,Vector3(0,0,-10))
	host.visible_ids.append(target.entity_id)
	var factory: BattleBuilding = host.spawn_building("factory",0,Vector3(10,0,10))
	check(factory.production.recruit("heavy_cannon").ok,"host queues approved factory unit")
	var payload := DamageResolver.snapshot(cannon._stats,0,0,0)
	target.receive_hit(payload,cannon)
	cannon.model_pivot.rotation.y = .4
	cannon._model.strike()
	cannon._model.attack.seek(.68,true)
	var snapshot: Dictionary = wire(sender.build_snapshot(0))
	check(state_for(snapshot,cannon.entity_id).attack_range == 15 and state_for(snapshot,ally.entity_id).attack_range == 14,"range research remains owner-specific on wire")
	check(state_for(snapshot,hidden.entity_id).is_empty(),"unseen enemy cannon omitted")
	check(state_for(snapshot,cannon.entity_id).anim == "strike" and state_for(snapshot,target.entity_id).hp == 263,"single host hit and firing phase encoded")
	check(state_for(snapshot,factory.entity_id).production.training[0].kind == "heavy_cannon","factory queue carries new unit identifier")
	var client: Node3D = FIXTURE.instantiate()
	root.add_child(client)
	var client_relay: RelayClient = RELAY.instantiate()
	client.add_child(client_relay)
	var receiver: MatchReplication = client.get_node("MatchReplication")
	receiver.configure(client,client_relay)
	receiver.receive_snapshot(snapshot)
	check(receiver.last_received_tick == 0 and client.entities_by_id.has(cannon.entity_id),"client accepts catalog-backed heavy cannon snapshot")
	var replica: BattleUnit = client.entities_by_id[cannon.entity_id]
	receiver.render(.1)
	check(replica.attack_range == 15 and client.get_player(0).get_cannon_range_bonus() == 1,"replica uses transmitted range without applying technology twice")
	check(replica._model.attack.current_animation == "strike" and is_equal_approx(replica._model.attack.current_animation_position,.68),"native recoil sampled at host phase")
	check(replica.get_projectile_origin().distance_to(cannon.get_projectile_origin()) < .0001,"replica muzzle follows identical rotating recoil transform")
	check(not replica.is_physics_processing() and client.entities_by_id[target.entity_id].hp == 263,"client presents host HP without its own attack tick")
	var flight := ProjectileFlight.new()
	flight.initialize_visual(client,cannon.get_projectile_origin(),target.position+Vector3.UP,"cannon",.4,.13,client.entities_by_id[target.entity_id])
	flight.advance(.4)
	check(client.entities_by_id[target.entity_id].hp == 263,"replica cannonball arrival does not duplicate damage")
	flight.reset()
	for invalid: Dictionary in [{"attack_range":15.01},{"attack_range":13.99},{"kind":"catapult","attack_range":15},{"anim":"repair"},{"phase":NAN}]:
		var bad: Dictionary = snapshot.duplicate(true)
		bad.tick = 1
		state_for(bad,cannon.entity_id).merge(invalid,true)
		receiver.receive_snapshot(bad)
		check(receiver.last_received_tick == 0,"reject malformed cannon state: "+str(invalid))
	current_scene = host
	var fresh: BattleUnit = host.spawn_unit("heavy_cannon",0,Vector3(-4,0,0))
	host.simulation_tick = 2
	host.elapsed = 1
	current_scene = client
	receiver.receive_snapshot(wire(sender.build_snapshot(0)))
	receiver.render(1.0)
	check(receiver.last_received_tick == 2 and client.entities_by_id[fresh.entity_id].attack_range == 15,"subsequent and reconnect snapshots create researched cannon")
	client.queue_free()
	host.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/heavy-cannon-20260913/network-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("HEAVY_CANNON_NETWORK ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
