extends SceneTree
## Visibility-filtered target selection and wire snapshots for independent gun recoil.
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
		if int(state.id)==id: return state
	return {}
func wire(snapshot: Dictionary) -> Dictionary:
	return NetworkProtocol.decode(NetworkProtocol.encode({"op":"snapshot","payload":snapshot})).payload
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
	var hidden_cell: Vector2i = fog._cell_unclamped(hidden.position)
	fog._cells[0][hidden_cell.y*fog.grid_size.x+hidden_cell.x] = 0
	for angle: float in [-45.1,-45.0,0,45.0,45.1,180]:
		candidate.position = Vector3(sin(deg_to_rad(angle))*6,0,-cos(deg_to_rad(angle))*6)
		await physics_frame
		await physics_frame
		cannon.volley.begin(target)
		check(cannon.volley.targets.has(candidate)==(absf(angle)<=45),"90 degree cone boundary "+str(angle))
		check(not cannon.volley.targets.has(ally) and not cannon.volley.targets.has(hidden),"allies and invisible infantry excluded")
		cannon.volley.cancel()
	candidate.position = Vector3(0,0,-1.0-cannon.radius-candidate.radius+.01)
	await physics_frame
	await physics_frame
	cannon.volley.begin(target)
	check(cannon.volley.targets.is_empty(),"minimum-range infantry and extra buildings excluded")
	cannon.volley.cancel()
	candidate.position = Vector3(0,0,-7.0-cannon.radius-candidate.radius+.01)
	await physics_frame
	await physics_frame
	cannon.volley.begin(structure)
	check(cannon.volley.primary==structure and cannon.volley.targets.has(candidate),"primary building allowed; unit at outer edge remains queryable")
	cannon.volley.cancel()
	var factory: BattleBuilding = host.spawn_building("factory",0,Vector3(12,0,12))
	check(factory.production.recruit("triple_cannon").ok,"host factory accepts triple cannon")
	host.get_player(0).complete_upgrade(BalanceCatalog.upgrade("cannon_range_1"))
	target.receive_hit(DamageResolver.snapshot(cannon._stats,0,0,0),cannon)
	cannon.model_pivot.rotation.y = .4
	cannon._model.strike(5)
	cannon._model.attack.seek(.58,true)
	var snapshot := wire(sender.build_snapshot(0))
	check(NetworkProtocol.VERSION==13 and state_for(snapshot,cannon.entity_id).anim=="volley_5","protocol 13 carries successful-barrel mask")
	check(state_for(snapshot,target.entity_id).hp==345 and state_for(snapshot,hidden.entity_id).is_empty(),"host damage and hidden-target omission")
	check(state_for(snapshot,factory.entity_id).production.training[0].kind=="triple_cannon","production queue encodes new identifier")
	var client: Node3D = FIXTURE.instantiate()
	root.add_child(client)
	var client_relay: RelayClient = RELAY.instantiate()
	client.add_child(client_relay)
	var receiver: MatchReplication = client.get_node("MatchReplication")
	receiver.configure(client,client_relay)
	receiver.receive_snapshot(snapshot)
	check(receiver.last_received_tick==0 and client.entities_by_id.has(cannon.entity_id),"client accepts new snapshot")
	var replica: BattleUnit = client.entities_by_id[cannon.entity_id]
	receiver.render(.1)
	check(replica.attack_range==7 and client.get_player(0).get_cannon_range_bonus()==1,"range remains seven on researched client")
	check(replica._model.attack.current_animation=="volley_5" and is_equal_approx(replica._model.attack.current_animation_position,.58),"replica samples cancelled middle barrel correctly")
	for i: int in 3:
		check(replica.get_projectile_origin(i).distance_to(cannon.get_projectile_origin(i))<.0001,"indexed muzzle transform on replica "+str(i))
		var flight := ProjectileFlight.new()
		flight.initialize_visual(client,cannon.get_projectile_origin(i),target.position+Vector3.UP,"cannon",.4,.13,client.entities_by_id[target.entity_id])
		flight.advance(.4)
		flight.reset()
	check(not replica.is_physics_processing() and client.entities_by_id[target.entity_id].hp==345,"client projectile arrivals never duplicate damage")
	var a := state_for(snapshot,cannon.entity_id).duplicate(true)
	var b := a.duplicate(true)
	a.anim = "volley_0"
	a.phase = .2
	b.anim = "volley_5"
	b.phase = .5
	for entry: Array in [[0.0,"volley_0"],[.4,"volley_1"],[.7,"volley_1"],[1.0,"volley_5"]]:
		receiver._present_unit(replica,a,b,entry[0],0)
		check(replica._model.attack.current_animation==entry[1],"interpolation releases only confirmed barrels "+str(entry[0]))
	for invalid: Dictionary in [{"attack_range":8},{"anim":"volley_8"},{"anim":"heal"},{"phase":2.5},{"kind":"cannon","attack_range":13},{"phase":NAN}]:
		var bad := snapshot.duplicate(true)
		bad.tick = 1
		state_for(bad,cannon.entity_id).merge(invalid,true)
		receiver.receive_snapshot(bad)
		check(receiver.last_received_tick==0,"reject invalid triple state "+str(invalid))
	current_scene = host
	var fresh: BattleUnit = host.spawn_unit("triple_cannon",0,Vector3(-5,0,0))
	host.simulation_tick = 2
	host.elapsed = 1
	current_scene = client
	receiver.receive_snapshot(wire(sender.build_snapshot(0)))
	receiver.render(1)
	check(receiver.last_received_tick==2 and client.entities_by_id[fresh.entity_id].attack_range==7,"reconnect snapshot builds new model without range bonus")
	client.queue_free()
	host.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/triple-cannon-20260913/network.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("TRIPLE_CANNON_NETWORK ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
