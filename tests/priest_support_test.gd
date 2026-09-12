extends SceneTree
## Exercise the real support component against authored units at a fixed match clock.
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)
func spawn(kind: String, at: Vector3, owner: int = 0) -> BattleUnit:
	var unit: BattleUnit = game.spawn_unit(kind,owner,at)
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	return unit
func work(priests: Array[BattleUnit], ticks: int, delta: float = .02) -> void:
	for step: int in ticks:
		game.elapsed += delta
		for priest: BattleUnit in priests:
			priest.support.advance_clock(delta)
			if priest.support.select_job(): priest.support.velocity_for_job(delta)
func reset() -> void:
	game.clear_units()
	await process_frame
	await physics_frame
func _run() -> void:
	create_timer(90,true,false,true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://scenes/sandbox.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready: await process_frame
	game.set_placing(false)
	var p := spawn("priest",Vector3.ZERO)
	var target := spawn("swordsman",Vector3(0,0,-3))
	target.hp = 10
	check(p.issue_support(target),"manual heal accepts injured infantry")
	work([p],29)
	check(target.hp == 10,"no recovery before .6 seconds")
	work([p],1)
	check(target.hp == 20,"opening cast recovers ten at .6 seconds")
	work([p],49)
	check(target.hp == 20,"second heal waits a full second")
	work([p],1)
	check(target.hp == 30,"second recovery at 1.6 seconds")
	work([p],400)
	check(target.hp == 110 and p.order == BattleUnit.Order.IDLE and target.support.provider == null,"100 HP restored in 9.6 seconds then releases and completes")
	check(game.get_player(0).gold == 0,"healing is free with zero gold")
	for kind: String in ["swordsman","spearman","shield_guard","archer","knight","light_cavalry","war_elephant","farmer","engineer","priest"]:
		var candidate := spawn(kind,Vector3(8,0,8))
		candidate.hp -= 10
		check(p.support.valid_target(candidate),"organic target accepted: "+kind)
	p.hp -= 10
	check(not p.issue_support(p),"active self healing rejected")
	for kind: String in ["catapult","cannon"]:
		var candidate := spawn(kind,Vector3(8,0,-8))
		candidate.hp -= 10
		check(not p.issue_support(candidate),"siege healing rejected: "+kind)
	var enemy := spawn("swordsman",Vector3(8,0,0),1)
	enemy.hp -= 10
	check(not p.issue_support(enemy),"enemy healing rejected")
	var building: BattleBuilding = game.spawn_building("academy",0,Vector3(20,0,0))
	building.hp -= 10
	check(not p.issue_support(building),"building healing rejected")
	building.queue_free()
	game.get_player(2).alliance_id = 0
	var ally := spawn("priest",Vector3(3,0,0),2)
	ally.hp -= 30
	check(p.issue_support(ally),"allied player and another priest accepted")
	p.stop()
	await reset()
	# The same recipient's cap holds across arbitrary provider update order.
	target = spawn("war_elephant",Vector3(0,0,-3))
	target.hp = 10
	var priests: Array[BattleUnit] = []
	for index: int in 5:
		var healer := spawn("priest",Vector3.ZERO)
		priests.append(healer)
		healer.issue_support(target)
	work(priests,230)
	check(target.hp == 60,"five priests remain ten HP per second after opening")
	check(priests.filter(func(healer: BattleUnit): return healer.support.recipient == target).size() == 1,"one exclusive healing provider")
	for healer: BattleUnit in priests: healer.stop()
	for index: int in 100:
		var healer: BattleUnit = priests[index % priests.size()]
		healer.issue_support(target)
		work([healer],1)
		healer.stop()
	check(target.hp == 60,"rotating providers cannot turn incomplete casts into recovery")
	p = priests[0]
	p.issue_support(target)
	work([p],29)
	check(target.hp == 60,"fresh channel must still complete .6 seconds")
	work([p],1)
	check(target.hp == 70,"fresh channel can resume normally")
	p.stop()
	priests[1].issue_support(target)
	work([priests[1]],49)
	check(target.hp == 70,"handoff cannot bypass recipient's one second deadline")
	work([priests[1]],1)
	check(target.hp == 80,"handoff recovers at the earliest valid deadline")
	for healer: BattleUnit in priests: healer.stop()
	# One provider cannot alternate patients to bypass its own delivery deadline.
	var second := spawn("swordsman",Vector3(2,0,-3))
	second.hp = 10
	p.issue_support(second)
	work([p],30)
	check(second.hp == 20,"different provider starts a valid new channel")
	p.issue_support(target)
	work([p],49)
	check(target.hp == 80,"retargeting retains provider recovery frequency")
	work([p],1)
	check(target.hp == 90,"retargeted heal waits a full second")
	p.stop()
	# A repeated click on an unchanged order preserves the original cast.
	p.issue_support(second)
	for tick: int in 50:
		p.issue_support(second)
		work([p],1)
	check(second.hp == 30,"repeated identical clicks neither reset nor accelerate healing")
	p.stop()
	# Movement cancels incomplete work, even before a model reports locomotion.
	work([],50)
	p.issue_support(second)
	work([p],20)
	p.issue_move(Vector3(-5,0,0))
	check(not p._working and second.support.provider == null and p.support.work_seconds == 0,"movement immediately cancels unfinished cast and releases claim")
	p.issue_support(second)
	work([p],29)
	check(second.hp == 30,"returning after movement cannot reuse unfinished cast")
	work([p],1)
	check(second.hp == 40,"returning channel heals after its full windup")
	p.stop()
	await reset()
	p = spawn("priest",Vector3.ZERO)
	target = spawn("swordsman",Vector3(0,0,-3))
	target.hp = 10
	p.issue_support(target)
	work([p],20)
	target.position = Vector3(0,0,-12)
	work([p],50)
	check(target.hp == 10 and not p._working and p.support.work_seconds == 0,"out of range blocks recovery and resets channel")
	target.position = Vector3(0,0,-3)
	work([p],30)
	check(target.hp == 20,"manual target returning in range begins fresh cast")
	p.stop()
	work([],50)
	game.get_player(0).complete_upgrade(BalanceCatalog.upgrade("attack_1"))
	game.get_player(0).complete_upgrade(BalanceCatalog.upgrade("defense_1"))
	target._recovery_quiet_seconds = 4.0
	p.issue_support(target)
	work([p],30)
	check(target.hp == 30 and target._recovery_quiet_seconds == 4.0,"attack technology does not boost healing or reset passive recovery quiet clock")
	var attack: DamagePayload = DamageResolver.snapshot(p._stats,game.get_player(0).get_attack_bonus(),0,0)
	check(DamageResolver.resolve(attack,BalanceCatalog.unit("farmer")) == 4,"attack technology increases punch damage")
	var arrow: DamagePayload = DamageResolver.snapshot(BalanceCatalog.unit("archer"),0,1,1)
	check(DamageResolver.resolve(arrow,p._stats,game.get_player(0).get_defense_bonus()) == 9,"defense technology increases priest armor")
	p.stop()
	work([],50)
	target.hp = target.max_hp - 1
	p.issue_move(Vector3(-1,0,0))
	p.issue_support(target,true)
	p.queue_move(Vector3(-5,0,0))
	check(p.waypoint_queue.size() == 2 and p.waypoint_queue[0].kind == "support","Shift support and subsequent move queue correctly")
	p._complete_waypoint()
	work([p],30)
	check(target.hp == target.max_hp and p.order == BattleUnit.Order.MOVE and p.destination == Vector3(-5,0,0),"full target clamps recovery and resumes next order")
	target.hp -= 20
	p.issue_support(target)
	work([p],1)
	target.receive_damage(999)
	work([p],1)
	check(target.support.provider == null and not is_instance_valid(p.support.recipient) and p.order == BattleUnit.Order.IDLE,"target death clears owner and finishes support order")
	check(not p.issue_support(target),"dead target cannot be selected")
	await reset()
	p = spawn("priest",Vector3.ZERO)
	target = spawn("swordsman",Vector3(0,0,-3))
	target.hp = 10
	p.issue_support(target)
	work([p],1)
	p.receive_damage(999)
	check(target.support.provider == null,"provider death releases target immediately")
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	FileAccess.open("res://.local/priest-20260913/support-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("PRIEST_SUPPORT ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)
