extends SceneTree
## Real saved BattleUnits and command bus; fixed work ticks isolate exact rate tests.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool,label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func spawn(kind: String,at: Vector3,owner: int=0) -> BattleUnit:
	var unit: BattleUnit = game.spawn_unit(kind,owner,at)
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	return unit
func work(engineers: Array[BattleUnit],targets: Array[BattleUnit],ticks: int) -> void:
	for step: int in ticks:
		game.elapsed += .02
		for target: BattleUnit in targets: target.support.advance_clock(.02)
		for unit: BattleUnit in engineers:
			unit.support.advance_clock(.02)
			if unit.support.select_job(): unit.support.velocity_for_job(.02)
func _run() -> void:
	create_timer(90,true,false,true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	var e := spawn("engineer",Vector3(0,0,-2))
	var c := spawn("cannon",Vector3.ZERO)
	c.hp = c.max_hp-100
	var initial := c.hp
	check(e.issue_support(c),"manual repair accepted")
	work([e],[c],49)
	check(c.hp == initial,"first recovery waits one effective second")
	work([e],[c],1)
	check(c.hp == initial+5,"first recovery exactly five")
	work([e],[c],950)
	check(c.hp == c.max_hp and e.order == BattleUnit.Order.IDLE,"100 HP takes twenty work seconds then completes order")
	check(game.get_player(0).gold == 0,"repair is free at zero gold")
	var peers: Array[BattleUnit] = [e]
	for i: int in 4: peers.append(spawn("engineer",Vector3(0,0,-2)))
	c.hp = initial
	c.support.recovery_gap = 0
	for p: BattleUnit in peers: p.issue_support(c)
	work(peers,[c],250)
	check(c.hp == initial+25,"five simultaneous repairers remain five HP per second")
	check(peers.filter(func(p: BattleUnit): return p.support.recipient==c).size()==1,"one exclusive owner")
	var elapsed_work := e.support.work_seconds
	e.stop()
	check(c.support.provider == null and e.support.work_seconds == elapsed_work,"stop releases claim without refunding rate limit")
	work(peers,[c],1)
	check(c.hp == initial+25,"replacement cannot heal immediately")
	for p: BattleUnit in peers: p.stop()
	# Repeated stop/click preserves earned work and cannot exceed time spent.
	c.hp = initial
	c.support.recovery_gap = 0
	e.support.work_seconds = 0
	for i: int in 50:
		e.issue_support(c)
		work([e],[c],1)
		e.stop()
	check(c.hp == initial+5,"fifty repeated commands cannot accelerate or starve work")
	var c2 := spawn("catapult",Vector3(1,0,0))
	c2.hp = c2.max_hp-50
	c.hp = initial
	c.support.recovery_gap = 0
	e.issue_support(c)
	peers[1].issue_support(c)
	work([e,peers[1]],[c,c2],1)
	check(e.support.recipient == c and peers[1].support.recipient == c2,"busy repairer picks another damaged siege")
	for p: BattleUnit in peers: p.stop()
	var elephant := spawn("war_elephant",Vector3(10,0,0))
	elephant.hp -= 100
	check(not e.issue_support(elephant),"cannot repair cavalry elephant")
	var enemy := spawn("cannon",Vector3(10,0,3),1)
	enemy.hp -= 20
	check(not e.issue_support(enemy),"cannot repair hostile siege")
	var factory: BattleBuilding = game.spawn_building("factory",0,Vector3(20,0,0))
	factory.hp -= 100
	check(not e.issue_support(factory),"cannot repair buildings")
	game.get_player(2).alliance_id=0
	var ally := spawn("cannon",Vector3(-1,0,0),2)
	ally.hp -= 20
	check(e.issue_support(ally),"another owner's allied siege accepted")
	e.stop()
	var soldier := spawn("swordsman",Vector3(-4,0,0))
	soldier.issue_move(Vector3(-8,0,0))
	var result: Dictionary=game.command_bus.execute({"kind":"support","units":[e.entity_id,soldier.entity_id],"target":c.entity_id},0)
	check(result.ok and e.order==BattleUnit.Order.SUPPORT and soldier.order==BattleUnit.Order.MOVE,"mixed selection only redirects capable engineer")
	check(not game.command_bus.execute({"kind":"support","units":[e.entity_id],"target":enemy.entity_id},0).ok,"command bus rejects hostile repair")
	e.issue_move(Vector3(0,0,-4))
	e.issue_support(c,true)
	e.queue_move(Vector3(0,0,-7))
	check(e.waypoint_queue.size()==2 and e.waypoint_queue[0].kind=="support","Shift appends support and move")
	e._complete_waypoint()
	c.hp=c.max_hp-1
	c.support.recovery_gap=0
	work([e],[c],50)
	check(e.order==BattleUnit.Order.MOVE and e.destination==Vector3(0,0,-7),"full target continues queued movement")
	# Active restoration does not modify passive recovery's injury clock.
	c.hp -= 20
	c._recovery_quiet_seconds=4.0
	check(c.restore_health(5)==5 and c._recovery_quiet_seconds==4.0,"restore uses independent capped health API")
	check(c.restore_health(1000)==15 and c.hp==c.max_hp,"health clamps to maximum")
	check(c.restore_health(NAN)==0 and c.restore_health(-5)==0,"invalid recovery rejected")
	e.issue_support(ally)
	work([e],[ally],1)
	e.receive_damage(100)
	check(ally.support.provider==null,"provider death releases claim")
	check(e.restore_health(5)==0,"dead units cannot recover")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	current_scene=null
	await network()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.local/engineer-20260912"))
	FileAccess.open("res://.local/engineer-20260912/support-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("ENGINEER_SUPPORT ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
func network() -> void:
	var fixture: PackedScene = load("res://tests/network_game_fixture.tscn")
	var relay: PackedScene = load("res://scripts/network/relay_client.tscn")
	var host: Node3D = fixture.instantiate()
	root.add_child(host)
	var host_relay: RelayClient = relay.instantiate()
	host.add_child(host_relay)
	var sender: MatchReplication = host.get_node("MatchReplication")
	sender.configure(host,host_relay)
	var own: BattleUnit = host.spawn_unit("engineer",0,Vector3.ZERO)
	var machine: BattleUnit = host.spawn_unit("cannon",0,Vector3(0,0,-2))
	machine.hp=80
	own.order=BattleUnit.Order.SUPPORT
	own.work_target=machine
	own._set_working(true)
	own._model.attack.seek(.4,true)
	var snapshot: Dictionary = sender.build_snapshot(0)
	var client: Node3D = fixture.instantiate()
	root.add_child(client)
	var client_relay: RelayClient = relay.instantiate()
	client.add_child(client_relay)
	var receiver: MatchReplication = client.get_node("MatchReplication")
	receiver.configure(client,client_relay)
	var wire: Dictionary=NetworkProtocol.decode(NetworkProtocol.encode({"op":"snapshot","payload":snapshot})).payload
	receiver.receive_snapshot(wire)
	check(receiver.last_received_tick==0 and client.entities_by_id.has(own.entity_id),"protocol accepts support order and repair animation")
	if client.entities_by_id.has(own.entity_id):
		var replica: BattleUnit=client.entities_by_id[own.entity_id]
		receiver.render(.1)
		check(replica._model.attack.current_animation=="repair","client plays actual repair clip")
		check(not replica.is_physics_processing() and replica.restore_health(5)==0,"client cannot duplicate authoritative recovery")
		check(client.entities_by_id[machine.entity_id].hp==80,"client receives machine HP")
	var bad: Dictionary=wire.duplicate(true)
	bad.tick=1
	for state: Dictionary in bad.entities:
		if state.id==machine.entity_id: state.anim="repair"
	receiver.receive_snapshot(bad)
	check(receiver.last_received_tick==0,"repair animation rejected for unsupported unit")
	client.queue_free()
	host.queue_free()
	current_scene=null
	await process_frame
	await process_frame
