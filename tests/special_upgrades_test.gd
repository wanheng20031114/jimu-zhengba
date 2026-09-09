extends SceneTree
## Real academy queues, native combat units, HUD and recipient-filtered replication.
const FIXTURE = preload("res://tests/network_game_fixture.tscn")
const RELAY = preload("res://scripts/network/relay_client.tscn")
const CODEX = preload("res://scenes/unit_codex.tscn")
var game: Node3D
var checks: int = 0
var failures: Array[String] = []
var snapshot_bytes: int = 0

func _initialize() -> void:
	Engine.max_fps = 60
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)

func building(kind: String, owner: int = 0) -> BattleBuilding:
	var at: Vector3 = game.find_build_location(owner, kind, game.owned_entities(owner, "buildings")[0].position)
	check(at.is_finite(), "legal " + kind + " for owner " + str(owner))
	var result: BattleBuilding = game.spawn_building(kind, owner, at)
	result.set_physics_process(false)
	result.production.set_physics_process(false)
	return result

func unit(kind: String, owner: int = 0) -> BattleUnit:
	var result: BattleUnit = game.spawn_unit(kind, owner, Vector3.ZERO)
	result.set_physics_process(false)
	result.navigation_agent.avoidance_enabled = false
	return result

func _run() -> void:
	create_timer(55.0, true, false, true).timeout.connect(func(): quit(3))
	root.get_node("Session").start_offline("2v2")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.set_physics_process(false)
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for existing: BattleUnit in get_nodes_in_group("units"):
		existing.stop()
		existing.set_physics_process(false)
		existing.navigation_agent.avoidance_enabled = false
	for existing: BattleBuilding in get_nodes_in_group("buildings"):
		existing.set_physics_process(false)
		existing.production.set_physics_process(false)
	var player: PlayerState = game.get_player(0)
	player.gold = 10000
	building("barracks")
	building("barracks", 1)
	var academy := building("academy")
	var second := building("academy")
	var ally_academy := building("academy", 1)
	var cannon := unit("cannon")
	var ally_cannon := unit("cannon", 1)
	var enemy_cannon := unit("cannon", 2)
	var target := unit("swordsman", 2)
	target.position = Vector3(13.5 + cannon.radius + target.radius, 0, 0)
	check(cannon.attack_range == 13.0 and not cannon._within_attack_range(target), "base cannon cannot hit a target at thirteen and a half surface distance")
	check(player.get_cannon_range_bonus() == 0.0 and player.get_recovery_per_second() == 0.0, "fresh owner has no special upgrade benefit")
	check(BalanceCatalog.UPGRADE_TRACKS.size() == 7 and BalanceCatalog.UPGRADES.size() == 14, "seven independent tracks include both special upgrades")
	_ui(academy)
	for id: String in ["cannon_range_1", "recovery_1"]:
		var before := player.gold
		check(not game.command_bus.execute({"kind": "research", "target": ally_academy.entity_id, "upgrade": id}, 0).ok and player.gold == before, id + " rejects allied asset purchase")
		var command := {"kind": "research", "target": academy.entity_id, "upgrade": id, "seq": 100 + checks,
			"cost": 0, "cannon_range_level": 1, "recovery_level": 1, "hp": 99999, "attack_range": 999}
		check(game.command_bus.submit(command, 0).ok and not game.command_bus.submit(command, 0).ok, id + " duplicate sequence is accepted once")
		game.command_bus.tick()
		check(player.gold == before - BalanceCatalog.upgrade(id).cost and player.get_upgrade_level(BalanceCatalog.upgrade(id).track) == 0, id + " charges real catalog cost and ignores forged completion")
		check(not second.production.research(id).ok, id + " cannot duplicate across academies")
		check(academy.production.cancel_research().ok and player.gold == before and player.queued_research.is_empty(), id + " cancellation refunds one payment and releases reservation")
		check(not academy.production.cancel_research().ok and player.gold == before, id + " second cancellation cannot duplicate refund")
	check(academy.production.research("cannon_range_1").ok and second.production.research("recovery_1").ok, "special tracks can research in parallel academies")
	academy.production._physics_process(29.99)
	check(cannon.attack_range == 13.0, "range research requires all thirty seconds")
	academy.production._physics_process(0.01)
	check(cannon.attack_range == 14.0 and cannon._within_attack_range(target), "completion immediately changes existing cannon native range gate")
	check(ally_cannon.attack_range == 13.0 and enemy_cannon.attack_range == 13.0, "range technology remains independent between owners and allies")
	var future := unit("cannon")
	check(future.attack_range == 14.0 and future.min_attack_range == BalanceCatalog.unit("cannon").min_range, "new cannon inherits range without changing minimum range")
	check(target.attack_range == BalanceCatalog.unit("swordsman").range, "range upgrade cannot affect other unit kinds")
	second.production._physics_process(19.99)
	check(player.recovery_level == 0, "recovery research requires all twenty seconds")
	second.production._physics_process(0.01)
	check(player.recovery_level == 1 and player.get_recovery_per_second() == 1.0, "recovery completes through native academy queue")
	await _pause_case(cannon)
	check(not academy.production.research("cannon_range_1").ok and not second.production.research("recovery_1").ok, "completed one-level tracks cannot be repurchased")
	for kind: String in BalanceCatalog.UNITS:
		_healing(unit(kind))
	_healing(cannon)
	var outsider := unit("farmer", 1)
	outsider.receive_damage(12.0)
	outsider._tick_recovery(50.0)
	check(outsider.hp == outsider.max_hp - 12.0, "unresearched ally cannot recover even after fifty seconds")
	game.get_player(1).complete_upgrade(BalanceCatalog.upgrade("recovery_1"))
	outsider._tick_recovery(0.99)
	check(outsider.hp == outsider.max_hp - 12.0, "pre-research quiet time does not bank instant healing")
	outsider._tick_recovery(0.01)
	check(outsider.hp == outsider.max_hp - 11.0, "already resting unit starts its next one-second heal after research")
	var tower: BattleBuilding = game.owned_entities(0, "buildings").filter(func(b): return b.building_type == "defense_tower")[0]
	tower.receive_damage(10.0)
	tower._physics_process(60.0)
	check(tower.hp == tower.max_hp - 10.0, "recovery never restores buildings")
	var dead := unit("farmer")
	dead.receive_damage(dead.max_hp)
	dead._tick_recovery(100.0)
	check(not dead.alive and dead.hp == 0.0, "dead movable unit cannot be resurrected by recovery")
	var doomed := building("academy", 1)
	check(doomed.production.research("cannon_range_1").ok, "unresearched ally can start its own range research")
	var before_destroy: int = game.get_player(1).gold
	doomed.receive_damage(doomed.max_hp)
	check(game.get_player(1).gold == before_destroy and game.get_player(1).cannon_range_level == 0 and game.get_player(1).queued_research.is_empty(), "academy destruction loses pending payment and clears reservation")
	academy.receive_damage(academy.max_hp)
	second.receive_damage(second.max_hp)
	check(cannon.attack_range == 14.0 and player.recovery_level == 1, "completed effects survive destruction of all own academies")
	await _network(cannon, ally_cannon, enemy_cannon)
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	print("SPECIAL_UPGRADES_RESULTS " + JSON.stringify({"checks": checks, "failures": failures, "snapshot_bytes": snapshot_bytes, "tps": 30, "first_heal_seconds": 11}))
	quit(0 if failures.is_empty() else 1)

func _healing(subject: BattleUnit) -> void:
	var label: String = subject.unit_type + "#" + str(subject.entity_id)
	var children: int = subject.get_child_count()
	subject.receive_damage(20.0)
	var baseline: float = subject.hp
	for tick in range(300):
		subject._tick_recovery(1.0 / 30.0)
	check(subject.hp == baseline, label + " has no heal during 300 quiet simulation ticks")
	for tick in range(29):
		subject._tick_recovery(1.0 / 30.0)
	check(subject.hp == baseline, label + " waits the full first healing interval")
	subject._tick_recovery(1.0 / 30.0)
	check(subject.hp == baseline + 1.0, label + " first point lands on quiet tick 330")
	for tick in range(300):
		subject._tick_recovery(1.0 / 30.0)
	check(subject.hp == baseline + 11.0, label + " continues at exactly one health per simulation second")
	subject._tick_recovery(0.6)
	subject.receive_damage(1.0)
	baseline = subject.hp
	subject._tick_recovery(10.99)
	check(subject.hp == baseline, label + " real damage resets quiet window and fractional healing")
	subject._tick_recovery(0.01)
	check(subject.hp == baseline + 1.0, label + " restarts exactly one full cycle after damage")
	subject._tick_recovery(0.5)
	subject.receive_damage(0.0)
	subject._tick_recovery(0.5)
	check(subject.hp == baseline + 2.0, label + " zero damage cannot reset an otherwise complete interval")
	subject._tick_recovery(100.0)
	check(subject.hp == subject.max_hp and subject._recovery_progress == 0.0, label + " recovery clamps at max health and stops banking")
	check(subject.get_child_count() == children, label + " uses existing simulation callback without new timers or nodes")

func _pause_case(subject: BattleUnit) -> void:
	subject.receive_damage(3.0)
	subject._recovery_quiet_seconds = 10.0
	subject._recovery_progress = 0.98
	var health: float = subject.hp
	subject.set_physics_process(true)
	paused = true
	check(not subject.can_process(), "native scene pause suspends recovery physics callbacks")
	await create_timer(0.15, true, false, true).timeout
	check(subject.hp == health and subject._recovery_progress == 0.98, "wall-clock time while paused accrues no healing")
	subject.set_physics_process(false)
	paused = false
	subject._tick_recovery(0.02)
	check(subject.hp == health + 1.0, "resuming simulation preserves the pre-pause partial interval")
	subject.hp = subject.max_hp

func _ui(academy: BattleBuilding) -> void:
	game.select_entities([academy])
	var hud: Control = game.hud
	check(hud._actions.size() == 6 and hud._actions[-1].kind == "research_page", "seven academy tracks fit six slots with an explicit more button")
	hud.trigger_action_slot(5)
	check(hud._actions.size() == 3 and hud._actions[0].id == &"cannon_range_1" and hud._actions[1].id == &"recovery_1", "more hotkey exposes both special research actions")
	check(hud.buttons[0].get_node("Hotkey").text == game.settings.hotkey_text("rts_slot_1") and not hud.buttons[1].disabled, "new research cards display active slot hotkeys and paid availability")
	var before: int = game.get_player(0).gold
	hud.trigger_action_slot(1)
	game.command_bus.tick()
	check(academy.production.research_id == "recovery_1" and game.get_player(0).gold == before - 100, "research slot hotkey submits real paid recovery job")
	hud.refresh()
	check(hud._queue_actions.any(func(action): return action.get("upgrade") == "recovery_1"), "new research appears in the visible cancellable queue")
	game.cancel_selected_queue()
	game.command_bus.tick()
	check(academy.production.research_queue.is_empty() and game.get_player(0).gold == before, "Esc queue action cancels the special research with full refund")
	game.select_entities([])
	game.select_entities([academy])
	check(hud._research_page == 0 and hud._actions[-1].kind == "research_page", "changing academy selection resets action page")
	var codex: Control = CODEX.instantiate()
	root.add_child(codex)
	for id: String in ["cannon_range_1", "recovery_1"]:
		codex.select_entry(2, id)
		var definition := BalanceCatalog.upgrade(id)
		check(codex.get_node("%EntryTitle").text == definition.name and codex.get_node("%Stats").get_parsed_text().contains(str(definition.cost)), id + " codex reads real name and research cost")
		check(is_instance_valid(codex._model) and codex.get_node("%ModelAnchor").get_child_count() == 1, id + " codex displays a single native model")
	check(codex.get_node("%Description").text.contains("阵亡") and codex.get_node("%Stats").get_parsed_text().contains("农民"), "recovery codex states death and farmer applicability")
	codex.free()

func _network(cannon: BattleUnit, ally: BattleUnit, enemy: BattleUnit) -> void:
	var sender := MatchReplication.new()
	sender.game = game
	sender._fog = game.get_node("FogOfWar")
	var snapshot := sender.build_snapshot(0)
	snapshot.entities = [sender._entity_state(cannon, 0), sender._entity_state(ally, 0), sender._entity_state(enemy, 0)]
	snapshot.mines = []
	check(snapshot.players[0].private.cannon_range_level == 1 and snapshot.players[0].private.recovery_level == 1, "owner receives completed private technology state")
	check(not snapshot.players[1].has("private") and not snapshot.players[2].has("private"), "ally and enemy technology levels remain private")
	check(snapshot.entities[0].attack_range == 14.0 and snapshot.entities[1].attack_range == 13.0, "visible unit states carry their effective authority range independently")
	var bytes := NetworkProtocol.encode({"op": "snapshot", "payload": snapshot})
	snapshot_bytes = bytes.size()
	check(not bytes.is_empty(), "native JSON codec accepts special upgrade snapshot")
	snapshot = NetworkProtocol.decode(bytes).payload
	var client = FIXTURE.instantiate()
	root.add_child(client)
	var relay: RelayClient = RELAY.instantiate()
	client.add_child(relay)
	var receiver: MatchReplication = client.get_node("MatchReplication")
	receiver.configure(client, relay)
	check(receiver._valid_snapshot(snapshot), "decoded special upgrade state passes complete client schema")
	for track: String in ["cannon_range", "recovery"]:
		for malformed: Variant in [-1, 2, 0.5, null, {}, "1"]:
			var invalid := snapshot.duplicate(true)
			invalid.players[0].private[track + "_level"] = malformed
			check(not receiver._valid_snapshot(invalid), track + " rejects malformed private level " + str(malformed))
	for malformed: Variant in [12, 15, INF, NAN, null, "14"]:
		var invalid := snapshot.duplicate(true)
		invalid.entities[0].attack_range = malformed
		check(not receiver._valid_snapshot(invalid), "range schema rejects impossible value " + str(malformed))
	receiver.receive_snapshot(snapshot)
	check(receiver.last_received_tick == int(snapshot.tick), "client installs upgrade snapshot")
	var replica: BattleUnit = client.entities_by_id[cannon.entity_id]
	check(replica.attack_range == 14.0 and client.get_player(0).get_cannon_range_bonus() == 1.0, "client displays effective range without adding the owner bonus twice")
	check(client.get_player(0).recovery_level == 1 and client.get_player(1).recovery_level == 0, "only local private recovery level is restored")
	var health_before: float = replica.hp
	replica.hp -= 10.0
	replica._tick_recovery(100.0)
	check(replica.hp == health_before - 10.0 and not replica.is_physics_processing(), "client cannot run independent healing")
	client.get_player(0).cannon_range_level = 0
	client.get_player(0).recovery_level = 0
	snapshot.tick += 30
	snapshot.time += 1.0
	receiver.receive_snapshot(snapshot)
	check(replica.hp == health_before and replica.attack_range == 14.0 and client.get_player(0).recovery_level == 1, "authoritative rejoin snapshot restores health and technology after a long gap")
	receiver.reset()
	client.queue_free()
	sender.free()
	await process_frame
	current_scene = game
