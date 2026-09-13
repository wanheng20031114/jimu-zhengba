extends SceneTree
## Native query boundaries and host-only independent recoil over protocol snapshots.
const FIXTURE = preload("res://tests/network_game_fixture.tscn")
const RELAY = preload("res://scripts/network/relay_client.tscn")
var checks: int = 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool,label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func state_for(snapshot: Dictionary,id: int) -> Dictionary:
	for state: Dictionary in snapshot.entities:
		if int(state.id) == id: return state
	return {}
func wire(snapshot: Dictionary) -> Dictionary:
	return NetworkProtocol.decode(NetworkProtocol.encode({"op":"snapshot","payload":snapshot})).payload
func reset_guns(cannon: BattleUnit) -> void:
	cannon._cancel_attack()
	for gun: UnitBattery.Gun in cannon.battery.guns:
		gun.target = null
		gun.ready_at = 0
	cannon.battery._next_query = 0
func has_target(cannon: BattleUnit,candidate: Node3D) -> bool:
	for gun: UnitBattery.Gun in cannon.battery.guns:
		if gun.target == candidate: return true
	return false
func _run() -> void:
	create_timer(35,true,false,true).timeout.connect(func():quit(3))
	var host: Node3D = FIXTURE.instantiate()
	root.add_child(host)
	host.is_authority = true
	var host_relay: RelayClient = RELAY.instantiate()
	host.add_child(host_relay)
	var sender: MatchReplication = host.get_node("MatchReplication")
	sender.configure(host,host_relay)
	var cannon: BattleUnit = host.spawn_unit("triple_cannon",0,Vector3.ZERO)
	var target: BattleUnit = host.spawn_unit("war_elephant",2,Vector3(0,0,-5))
	var candidate: BattleUnit = host.spawn_unit("swordsman",2,Vector3.ZERO)
	var ally: BattleUnit = host.spawn_unit("swordsman",1,Vector3(0,0,-4))
	var hidden: BattleUnit = host.spawn_unit("swordsman",2,Vector3(-1,0,-4))
	var structure: BattleBuilding = host.spawn_building("barracks",2,Vector3(4,0,-5))
	host.visible_ids.assign([target.entity_id,candidate.entity_id,structure.entity_id])
	var fog: FogOfWar = host.get_node("FogOfWar")
	fog.tick(.2)
	var cell: Vector2i = fog._cell_unclamped(hidden.position)
	fog._cells[0][cell.y*fog.grid_size.x+cell.x] = 0
	for angle: float in [-45.1,-45.0,0,45.0,45.1,180]:
		candidate.position = Vector3(sin(deg_to_rad(angle))*6,0,-cos(deg_to_rad(angle))*6)
		await physics_frame
		await physics_frame
		reset_guns(cannon)
		cannon.target = target
		cannon.battery.engage(target)
		check(has_target(cannon,candidate) == (absf(angle)<=45),"90 degree boundary "+str(angle))
		check(not has_target(cannon,ally) and not has_target(cannon,hidden),"allies and hidden targets excluded")
	reset_guns(cannon)
	candidate.position = Vector3(0,0,-1-cannon.radius-candidate.radius+.01)
	await physics_frame
	await physics_frame
	cannon.battery.engage(target)
	check(not has_target(cannon,candidate),"minimum-range candidate excluded")
	reset_guns(cannon)
	candidate.position = Vector3(0,0,-7-cannon.radius-candidate.radius+.01)
	await physics_frame
	await physics_frame
	cannon.target = structure
	cannon.battery.engage(structure)
	check(has_target(cannon,structure) and has_target(cannon,candidate),"building primary and unit at outer edge")
	cannon._cancel_attack()
	var factory: BattleBuilding = host.spawn_building("factory",0,Vector3(12,0,12))
	check(factory.production.recruit("triple_cannon").ok,"factory queue")
	host.get_player(0).complete_upgrade(BalanceCatalog.upgrade("cannon_range_1"))
	target.receive_hit(DamageResolver.snapshot(cannon._stats,0,0,0),cannon)
	host.elapsed = 2.0
	cannon.battery.last_fired = PackedFloat64Array([1.4,-1,1.9])
	var snapshot := wire(sender.build_snapshot(0))
	var stamps: Array = state_for(snapshot,cannon.entity_id).barrels
	check(NetworkProtocol.VERSION == 14 and is_equal_approx(stamps[0],1.4) and stamps[1] == -1.0 and is_equal_approx(stamps[2],1.9),"protocol carries individual release timestamps")
	check(state_for(snapshot,target.entity_id).hp == 345 and state_for(snapshot,hidden.entity_id).is_empty(),"host damage and fog filtering")
	var client: Node3D = FIXTURE.instantiate()
	root.add_child(client)
	var client_relay: RelayClient = RELAY.instantiate()
	client.add_child(client_relay)
	var receiver: MatchReplication = client.get_node("MatchReplication")
	receiver.configure(client,client_relay)
	receiver.receive_snapshot(snapshot)
	check(receiver.last_received_tick == 0,"client accepts new protocol snapshot")
	var replica: BattleUnit = client.entities_by_id[cannon.entity_id]
	receiver._playback_time = 2.0
	var state := state_for(snapshot,cannon.entity_id)
	receiver._present_unit(replica,state,state,0,0)
	var visual: BatteryVisual = replica._model
	check(visual._sampled_phases[0] > .59 and visual._sampled_phases[2] < .101 and visual._sampled_phases[1] == -1,"different recoil phases and unfired middle barrel")
	check(replica.attack_range == 7 and not replica.is_physics_processing(),"replica never starts attacks or applies range tech")
	var a := state.duplicate(true)
	var b := state.duplicate(true)
	a.barrels = [1.4,-1,-1]
	b.barrels = [1.4,-1,1.9]
	for at: float in [1.6,1.899,1.9,2.0]:
		receiver._playback_time = at
		receiver._present_unit(replica,a,b,0,0)
		check((visual._sampled_phases[2] >= 0) == (at >= 1.9),"interpolation never predicts an unfired barrel: "+str(at))
		check(is_equal_approx(visual._sampled_phases[0],at-1.4),"other recoil never restarts across a shot")
	var invalids: Array[Dictionary] = [{"barrels":[1,-1]},{"barrels":[1,-1,2.1]},{"barrels":[NAN,-1,-1]},{"barrels":[-2,-1,-1]},{"barrels":["x",-1,-1]},{"barrels":[true,-1,-1]},{"anim":"volley_5"},{"anim":"strike"},{"kind":"cannon","attack_range":13},{"attack_range":8}]
	for invalid: Dictionary in invalids:
		var bad := snapshot.duplicate(true)
		bad.tick = 1
		state_for(bad,cannon.entity_id).merge(invalid,true)
		receiver.receive_snapshot(bad)
		check(receiver.last_received_tick == 0,"reject invalid battery snapshot "+str(invalid))
	var missing := snapshot.duplicate(true)
	missing.tick = 1
	state_for(missing,cannon.entity_id).erase("barrels")
	receiver.receive_snapshot(missing)
	check(receiver.last_received_tick == 0,"reject absent independent state")
	# Full late/reconnect snapshot restores each gun without replaying damage.
	host.simulation_tick = 2
	host.elapsed = 4
	cannon.battery.last_fired = PackedFloat64Array([3.8,3.1,1.9])
	receiver.receive_snapshot(wire(sender.build_snapshot(0)))
	receiver.render(.1)
	check(receiver.last_received_tick == 2 and client.entities_by_id[target.entity_id].hp == 345,"reconnect only samples state, no repeated damage")
	client.queue_free()
	host.queue_free()
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute("res://.local/triple-independent")
	FileAccess.open("res://.local/triple-independent/network.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("TRIPLE_CANNON_NETWORK ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
