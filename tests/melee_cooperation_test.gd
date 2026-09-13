extends SceneTree
## Occupancy lifecycle, bounded retargeting and native RVO friendly passage.
const UNIT: PackedScene = preload("res://scenes/unit.tscn")
var host: Node3D
var checks: int = 0
var failures: Array[String] = []

class QueueProbe extends BattleUnit:
	var visits: int = 0
	func _resolve_combat_congestion() -> void: visits += 1

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func sync(frames: int = 3) -> void:
	for frame: int in frames:
		await physics_frame
		await process_frame

func spawn(at: Vector3, owner: int = 0, kind: String = "swordsman") -> BattleUnit:
	var unit: BattleUnit = UNIT.instantiate()
	unit.unit_type = kind
	unit.owner_id = owner
	unit.alliance_id = host.get_player(owner).alliance_id
	unit.position = at
	unit.prune_stationary_avoidance = true
	host.get_node("Units").add_child(unit)
	unit.hp = 100000.0
	unit.max_hp = unit.hp
	unit.set_physics_process(false)
	unit.navigation_agent.avoidance_enabled = false
	return unit

func clear() -> void:
	for unit: Node in host.get_node("Units").get_children(): unit.queue_free()
	await sync()

func _run() -> void:
	create_timer(100.0, true, false, true).timeout.connect(func(): quit(3))
	change_scene_to_file("res://tests/melee_cooperation_host.tscn")
	await scene_changed
	host = current_scene
	host.players.clear()
	for owner: int in NetworkProtocol.MAX_PLAYERS:
		host.players.append(PlayerState.new(owner, owner))
	host.combat_fog.configure(host, Vector2(80, 80))
	await sync(8)
	await allocation()
	await guards()
	await passage_guards()
	await walls_and_pockets()
	await native_passage()
	budget_fairness()
	print("MELEE_COOPERATION %d checks; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func allocation() -> void:
	var rear := spawn(Vector3(-6, 0, 0))
	var crowded := spawn(Vector3.ZERO, 1)
	var open := spawn(Vector3(0, 0, 3), 1)
	var friends: Array[BattleUnit] = []
	for i: int in 10:
		var friend := spawn(Vector3(-3.0 - i * 0.5, 0, 0), 0, "knight")
		friend.issue_attack(crowded)
		friends.append(friend)
	await sync()
	rear.issue_move(Vector3(12, 0, 0), true)
	rear._refresh_target()
	check(rear.target == open, "A-move chooses an open nearby engagement over a saturated approach")
	check(rear._melee_target_score(crowded, 36.0) > rear._melee_target_score(open, 45.0), "occupancy adds approach distance without extra scene queries")
	var ledger: MeleePressure = crowded.melee_pressure
	check(ledger.excess(0, 4, 0.0) > 0.0, "mounted melee reserves physical contact width")
	check(ledger.excess(2, 4, 0.0) == 0.0, "unrelated alliances do not consume our contact space")
	check(ledger.excess(0, 0, 0.0) == 0.0, "an opposite approach remains open")
	var before: float = ledger.excess(0, 4, 0.0)
	friends[0].issue_attack(crowded)
	check(is_equal_approx(ledger.excess(0, 4, 0.0), before), "repeated explicit attack never duplicates its reservation")
	friends[0].global_position = Vector3(4, 0, 0)
	friends[0]._refresh_target()
	check(ledger.excess(0, 4, 0.0) < before, "a moved attacker transfers its approach reservation")
	for i: int in 3: friends[i].stop()
	for i: int in range(3, 6): friends[i].issue_move(Vector3(-12, 0, 0))
	friends[6].receive_damage(100001)
	friends[7].queue_free()
	friends[8].target = null
	friends[9].hold()
	await sync()
	check(ledger.excess(0, 4, MeleePressure.APPROACH_ARC) < 0.00001, "stop, move, death, free, target clear and hold release all reservations")
	var ranged := spawn(Vector3(-4, 0, 0), 0, "archer")
	ranged.issue_attack(crowded)
	check(ledger.excess(0, 4, MeleePressure.APPROACH_ARC) < 0.00001, "ranged attacks never consume melee approach space")
	# Every sandbox alliance has independent capacity, including alliance 15.
	for owner: int in CombatLayers.UNIT_LAYERS.size():
		var pressure := MeleePressure.new()
		pressure.add(owner, 7, 3.0)
		check(pressure.excess(owner, 0, 0.0) > 0.0, "wrapped sector counts neighbour for alliance %d" % owner)
		check(pressure.excess((owner + 1) % 16, 0, 0.0) == 0.0, "separate capacity for alliance %d" % owner)
	await clear()
	check(ledger.excess(0, 4, MeleePressure.APPROACH_ARC) < 0.00001, "ledger can outlive a freed target without retaining actors")

func guards() -> void:
	var rear := spawn(Vector3(-6, 0, 0))
	var crowded := spawn(Vector3.ZERO, 1)
	var open := spawn(Vector3(0, 0, 3), 1)
	for i: int in 10:
		spawn(Vector3(-3 - i, 0, 0), 0, "knight").issue_attack(crowded)
	await sync()
	rear.issue_move(Vector3(12, 0, 0), true)
	rear.target = crowded
	rear._refresh_target()
	check(rear.target == crowded, "a progressing chase does not widen its contact scan")
	rear._congestion_seconds = BattleUnit.CONGESTION_SECONDS
	rear._resolve_combat_congestion()
	check(rear.target == open and rear.melee_rebalances == 1, "stalled A-move can replace a target before the replacement enters weapon reach")
	rear.target = crowded
	rear._resolve_combat_congestion()
	check(rear.target == crowded and rear.melee_rebalances == 1, "wide re-evaluation has an explicit rate limit")
	rear.issue_attack(crowded)
	rear._next_rebalance_frame = 0
	rear._congestion_seconds = BattleUnit.CONGESTION_SECONDS
	rear._resolve_combat_congestion()
	check(rear.target == crowded, "explicit focus fire is never redistributed")
	rear.issue_move(Vector3(12, 0, 0), true)
	rear.target = crowded
	rear.attack_windup.start(2.0)
	rear._congestion_seconds = BattleUnit.CONGESTION_SECONDS
	rear._refresh_target()
	rear._resolve_combat_congestion()
	check(rear.target == crowded, "windup retains its locked target")
	rear.attack_windup.stop()
	rear._next_rebalance_frame = 0
	open.position = Vector3(-5, 0, 0)
	await sync()
	rear._refresh_target()
	check(rear.target == open, "an enemy already in reach takes precedence over queue balancing")
	rear.hold()
	open.position = Vector3(0, 0, 4)
	await sync()
	rear._refresh_target()
	check(rear.target == null, "HOLD never acquires a distant unoccupied engagement")
	rear.issue_move(Vector3(12, 0, 0), true)
	rear.target = crowded
	rear._congestion_seconds = BattleUnit.CONGESTION_SECONDS
	var budget := CombatApproachBudget.new()
	budget.enqueue(rear)
	rear.issue_move(Vector3(-12, 0, 0))
	budget.tick()
	check(rear.order == BattleUnit.Order.MOVE and rear.target == null, "a queued decision cannot overwrite a newer player command")
	host.suspend_alliance_vision(0)
	check(rear._find_auto_target(false, true) == null, "occupancy scoring still rejects enemies hidden by fog")
	host.resume_vision()
	await clear()

func passage_guards() -> void:
	var mover := spawn(Vector3.ZERO)
	var blocker := spawn(Vector3(1.3, 0, 0), 0, "knight")
	var foe := spawn(Vector3(7, 0, 0), 1)
	mover.issue_move(Vector3(12, 0, 0), true)
	mover.target = foe
	mover._blocked_intent = Vector3.RIGHT * mover.speed
	await sync()
	for mode: int in [BattleUnit.Order.HOLD, BattleUnit.Order.GATHER, BattleUnit.Order.BUILD, BattleUnit.Order.SUPPORT, BattleUnit.Order.MOVE]:
		blocker.order = mode
		mover.passage.next_request_frame = 0
		check(not mover.passage.request(mover), "passage respects order %d" % mode)
	blocker.order = BattleUnit.Order.IDLE
	blocker.target = foe
	foe.position = Vector3(2.5, 0, 0)
	await sync()
	mover.passage.next_request_frame = 0
	check(not mover.passage.request(mover), "a front fighter in contact cannot be pushed off its attack")
	blocker.target = null
	blocker.attack_windup.start(1.0)
	mover.passage.next_request_frame = 0
	check(not mover.passage.request(mover), "an active swing cannot be displaced")
	blocker.attack_windup.stop()
	foe.position = Vector3(7, 0, 0)
	blocker.alliance_id = 1
	await sync()
	mover.passage.next_request_frame = 0
	check(not mover.passage.request(mover), "an enemy is never asked to yield")
	blocker.alliance_id = 0
	mover.passage.next_request_frame = 0
	check(mover.passage.request(mover), "idle friendly accepts one local sidestep")
	check(blocker.order == BattleUnit.Order.IDLE and blocker.target == null, "sidestep preserves orders and targets")
	blocker._set_avoidance_moving(true)
	check(blocker.navigation_agent.max_speed <= FriendlyPassage.STEP_SPEED, "native RVO bounds sidestep speed before solving")
	blocker.passage.cancel()
	blocker._set_avoidance_moving(true)
	check(is_equal_approx(blocker.navigation_agent.max_speed, blocker.speed), "normal movement recovers its speed even without a moving-state change")
	check(not mover.passage.request(mover), "requests are rate limited and never form recursive chains")
	blocker.hold()
	check(blocker.passage.remaining == 0.0, "new player order immediately cancels the sidestep")
	await clear()

func native_passage() -> void:
	var mover := spawn(Vector3(-3, 0, 0), 0, "knight")
	var blocker := spawn(Vector3(-1.2, 0, 0), 0, "knight")
	var foe := spawn(Vector3(7, 0, 0), 1)
	foe.hold()
	for unit: BattleUnit in [mover, blocker, foe]:
		unit.navigation_agent.avoidance_enabled = true
		unit.set_physics_process(true)
	blocker._scan_time = 100.0
	mover.issue_move(Vector3(12, 0, 0), true)
	mover.target = foe
	await sync()
	var blocker_start := blocker.global_position
	# Start from the production state after 0.6 seconds of blocked RVO probes;
	# the physics scan and shared FIFO must deliver the request themselves.
	mover._blocked_intent = Vector3.RIGHT * mover.speed
	mover._congestion_target = foe
	mover._congestion_seconds = BattleUnit.CONGESTION_SECONDS
	mover._congestion_wait = 0.5
	mover._scan_time = 0.0
	await sync(180)
	check(mover.passage.accepted > 0, "physics congestion scan dispatches a queued native sidestep")
	check(blocker.global_position.distance_to(blocker_start) > 0.4, "yielding friend actually moves with native RVO")
	check(mover.global_position.x > blocker_start.x + 1.0, "attacker passes its friend and resumes the original engagement")
	check(foe.hp < foe.max_hp, "passage produces real attacks, not only a path preview")
	check(mover.navigation_agent.avoidance_enabled and blocker.navigation_agent.avoidance_enabled, "native separation stays enabled")
	await clear()

func budget_fairness() -> void:
	var budget := CombatApproachBudget.new()
	var probes: Array[QueueProbe] = []
	for index: int in 37:
		var probe := QueueProbe.new()
		probes.append(probe)
		budget.enqueue(probe)
		budget.enqueue(probe)
	for tick: int in 10:
		budget.tick()
		check(budget.jobs_this_tick <= 4, "optional decisions stay within per-tick budget")
	check(probes.all(func(probe: QueueProbe): return probe.visits == 1 and not probe._approach_queued), "FIFO serves all units once without duplicates or starvation")
	budget.enqueue(probes[0])
	probes[0].free()
	budget.tick()
	check(budget.jobs_this_tick == 1, "a freed queued unit consumes bounded cleanup work")
	for index: int in range(1, probes.size()): probes[index].free()

func walls_and_pockets() -> void:
	var mover := spawn(Vector3(-20, 0, 0), 0, "knight")
	var blocker := spawn(Vector3(-18.2, 0, 0), 0, "knight")
	mover._blocked_intent = Vector3.RIGHT * mover.speed
	await sync()
	check(not mover.passage.request(mover), "both side walls reject a push before any displacement")
	check(blocker.passage.remaining == 0.0, "no fallback shove when a passage has no free pocket")
	mover.position = Vector3.ZERO
	blocker.position = Vector3(1.8, 0, 0)
	var guard := spawn(Vector3(1.8, 0, 1.85), 1, "knight")
	await sync()
	mover.passage.next_request_frame = 0
	check(mover.passage.request(mover), "a blocked side still allows the opposite free pocket")
	check(blocker.passage.destination.z < 0.0, "sidestep endpoint avoids nearby enemy bodies")
	blocker.stop()
	blocker.passage.next_yield_frame = 0
	guard.position.z = -1.85
	spawn(Vector3(1.8, 0, 1.85), 0, "knight")
	await sync()
	mover.passage.next_request_frame = 0
	check(not mover.passage.request(mover), "two occupied pockets do not propagate a push chain")
	await clear()
