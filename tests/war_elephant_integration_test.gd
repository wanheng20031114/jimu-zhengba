extends SceneTree
## Approved balance, recruitment, native windup, AI recognition and wire snapshots.
const KIND := "war_elephant"
const OUTPUT := "res://artifacts/model-previews/war_elephant/"
var checks: int = 0
var failures: Array[String] = []
var game: Node3D

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		printerr("FAIL ",label)

func _run() -> void:
	create_timer(80.0,true,false,true).timeout.connect(func(): quit(3))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var stats := BalanceCatalog.unit(KIND)
	check(stats.hp == 360 and stats.damage == 26 and stats.speed == 3.2, "latest user health, damage and movement")
	check(stats.melee_armor == 2 and stats.ranged_armor == 3 and stats.bonuses.is_empty(), "fixed armor without extra damage or directional blocking")
	check(stats.cost == 300 and stats.supply == 5 and stats.training_seconds == 30, "approved cost, population and training")
	check(stats.range == 1.5 and stats.min_range == 0 and stats.cooldown == 2.4 and stats.attack_windup_seconds == .55, "melee reach and full attack cycle")
	check(stats.radius == 1.15 and stats.sight == 15 and stats.combat_class == &"cavalry" and stats.projectile.is_empty(), "approved native footprint, vision and class")
	check(stats.military and stats.production_building == &"barracks", "war elephant belongs to barracks and military selection")
	check(DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit("archer"),0,0,0),stats) == 8, "archer causes eight damage")
	check(DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit("spearman"),0,0,0),stats)==24,"spearman deals its full anti-cavalry bonus")
	check(DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit("swordsman"),0,0,0),stats)==12,"swordsman deals its full anti-cavalry bonus")
	check(stats.splash_radius==0 and stats.projectile.is_empty(),"elephant has no splash or rider projectile")
	for future: String in ["engineer","priest","heavy_cannon","triple_cannon"]:
		check(not BalanceCatalog.UNITS.has(future),"unapproved later unit remains unimplemented: "+future)
	var old_windups := {"swordsman":.22,"spearman":.22,"archer":.27,"knight":.2,"catapult":.48,"cannon":.25,"farmer":.22}
	for kind: String in old_windups:
		check(is_equal_approx(BalanceCatalog.unit(kind).attack_windup_seconds, old_windups[kind]), "preserve old attack release "+kind)
	change_scene_to_file("res://scenes/main.tscn")
	await scene_changed
	game = current_scene
	while not game._match_ready:
		await process_frame
	game.tests_running = true
	game.bots.clear()
	game.get_node("IncomeTimer").stop()
	game.get_node("EnemyTimer").stop()
	for unit: BattleUnit in get_nodes_in_group("units"):
		unit.stop()
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	for building: BattleBuilding in get_nodes_in_group("buildings"):
		building.set_physics_process(false)
		building.production.set_physics_process(false)
	var player: PlayerState = game.get_player(0)
	player.gold = 10000
	var barracks: BattleBuilding = game.spawn_building("barracks",0,game.find_build_location(0,"barracks",game.headquarters.position))
	barracks.set_physics_process(false)
	barracks.production.set_physics_process(false)
	game.get_node("ConstructionNavigation").refresh()
	await physics_frame
	await physics_frame
	await create_timer(.4).timeout
	var supply_before: int = player.military_supply
	player.gold = 299
	check(not barracks.production.recruit(KIND).ok and player.gold == 299, "insufficient gold does not reserve or charge")
	player.gold = 10000
	var command := {"kind":"recruit","target":barracks.entity_id,"unit_type":KIND}
	check(game.command_bus.execute(command,0).ok, "validated human command recruits a war elephant")
	check(player.gold == 9700 and player.reserved_military_supply == 5, "recruitment charges three hundred and reserves five population")
	barracks.production._physics_process(29.9)
	check(barracks.production.training.size() == 1 and player.military_supply == supply_before, "training cannot complete early")
	barracks.production._physics_process(.11)
	check(barracks.production.training.is_empty() and player.military_supply == supply_before+5 and player.reserved_military_supply == 0, "thirty-second training spawns once and converts reserved population")
	var trained: BattleUnit
	for unit: BattleUnit in game.owned_entities(0,"units"):
		if unit.unit_type == KIND:
			trained = unit
	check(trained != null and trained._model.batch_parts.size() == 14 and trained.hp == 360, "recruit spawns the correct batched model with full health")
	trained.stop()
	trained.set_physics_process(false)
	check(is_equal_approx(trained.get_node("CollisionShape3D").shape.height,3.6),"actual capsule encloses the mounted rider")
	var ray:=PhysicsRayQueryParameters3D.create(trained.global_position+Vector3(0,3.0,-4),trained.global_position+Vector3(0,3.0,4),4)
	var picked: Dictionary=game.get_world_3d().direct_space_state.intersect_ray(ray)
	check(picked.get("collider")==trained,"ray selection reaches the elevated rider and upper body")
	await _blocked_exit(barracks,player)
	game.select_entities([barracks])
	game.hud._refresh_actions()
	check(game.hud._actions.any(func(action: Dictionary): return action.kind == "recruit" and action.id == KIND), "barracks exposes its actual recruitment button")
	check(game.command_bus.execute(command,0).ok, "war elephant can be queued again")
	var refund_before: int = player.gold
	check(barracks.production.cancel_training(0).ok and player.gold == refund_before+300 and player.reserved_military_supply == 0, "cancellation refunds its exact cost and population")
	var military_before: int = player.military_supply
	player.military_supply = player.get_supply_limit()
	var gold_before: int = player.gold
	check(not barracks.production.recruit(KIND).ok and player.gold == gold_before, "population cap rejects war elephant without charging")
	player.military_supply = military_before
	check(not game.headquarters.production.recruit(KIND).ok, "wrong production building refuses war elephant")
	check(not game.command_bus.execute(command,1).ok, "another player cannot use the owner's barracks")
	check(barracks.production.recruit(KIND).ok, "queue elephant before producer destruction")
	barracks.production.destroyed()
	check(barracks.production.training.is_empty() and player.reserved_military_supply == 0, "producer destruction releases war elephant reservation")
	game.select_entities([trained])
	check(game.own_selected_units() == [trained] and game.own_selected_workers().is_empty(), "war elephant selection never becomes a farmer selection")
	var target: BattleUnit = game.spawn_unit("farmer",1,Vector3(0,0,-1.5))
	var bystander: BattleUnit = game.spawn_unit("farmer",1,Vector3(.7,0,-1.5))
	var second_bystander: BattleUnit=game.spawn_unit("farmer",1,Vector3(-.7,0,-1.5))
	var elephant: BattleUnit = game.spawn_unit(KIND,0,Vector3.ZERO)
	for unit: BattleUnit in [target,bystander,second_bystander,elephant]:
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	game.get_node("FogOfWar")._recompute()
	elephant.target = target
	elephant._start_attack()
	await create_timer(.45).timeout
	check(target.hp == 150, "damage does not precede the authored .55-second contact")
	await create_timer(.15).timeout
	check(target.hp == 124 and bystander.hp == 150 and second_bystander.hp==150, "one melee strike damages only its locked target")
	check(is_equal_approx(elephant._attack_cooldown,2.4), "attack start consumes the complete cooldown")
	elephant.issue_attack(target)
	check(is_equal_approx(elephant._attack_cooldown,2.4), "repeated focus fire cannot reset cooldown")
	elephant.stop()
	check(is_equal_approx(elephant._attack_cooldown,2.4), "stop does not refund attack recovery")
	elephant._charge_time=2.0
	elephant._charge_cooldown=0.0
	elephant.target=target
	elephant._start_attack()
	check(elephant._charge_cooldown==0.0,"elephant does not inherit knight charge")
	elephant.stop()
	var target_after: float=target.hp
	await create_timer(.65).timeout
	check(target.hp==target_after,"stop cancels pending elephant damage")
	elephant.receive_hit(DamageResolver.snapshot(BalanceCatalog.unit("spearman"),0,1,1),bystander)
	check(elephant.hp==336,"native receiving endpoint applies 24 anti-cavalry damage")
	elephant.receive_hit(DamageResolver.snapshot(BalanceCatalog.unit("swordsman"),0,1,1),bystander)
	check(elephant.hp==324,"native receiving endpoint applies 12 swordsman damage")
	var bot := SkirmishBot.new(game,0)
	bot._memory = {1:{"building":false,"kind":KIND,"seen_at":0.0},2:{"building":false,"kind":"archer","seen_at":0.0}}
	check(bot._composition().knight == 1 and bot._composition().archer == 1, "AI counts elephants as cavalry without unknown-kind errors")
	bot._army = [elephant]
	bot._buildings = [barracks]
	bot._budget = 10000
	bot._recruit_army(0)
	check(game.command_bus.pending.all(func(item: Dictionary): return item.get("unit_type","") != KIND), "AI takeover recognizes existing elephants but never recruits new ones")
	game.command_bus.pending.clear()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	await _network()
	FileAccess.open(OUTPUT+"integration-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("ELEPHANT_INTEGRATION ",checks," checks; ",failures.size()," failures")
	quit(0 if failures.is_empty() else 1)

func _blocked_exit(barracks: BattleBuilding,player: PlayerState) -> void:
	var blockers: Array[BattleUnit]=[]
	for attempt: int in 128:
		var at: Vector3=game.find_recruit_position(KIND,barracks)
		if not at.is_finite():
			break
		var blocker: BattleUnit=game.spawn_unit("farmer",0,at)
		blocker.set_physics_process(false)
		blocker.navigation_agent.avoidance_enabled=false
		blockers.append(blocker)
		await physics_frame
	check(not blockers.is_empty() and not game.find_recruit_position(KIND,barracks).is_finite(),"real units block all elephant-sized exit candidates")
	check(barracks.production.recruit(KIND).ok,"elephant can train with temporarily blocked exits")
	var before: int=player.military_supply
	barracks.production._physics_process(30)
	check(barracks.production.training.size()==1 and player.reserved_military_supply==5 and player.military_supply==before,"blocked completion retains its single reservation")
	for blocker: BattleUnit in blockers:
		blocker.queue_free()
	await physics_frame
	await physics_frame
	check(game.find_recruit_position(KIND,barracks).is_finite(),"clearing blockers restores an exit")
	barracks.production._physics_process(.3)
	check(barracks.production.training.is_empty() and player.reserved_military_supply==0 and player.military_supply==before+5,"unblocked retry spawns exactly one elephant")
	for unit: BattleUnit in game.owned_entities(0,"units"):
		unit.stop()
		unit.set_physics_process(false)

func _network() -> void:
	var fixture: PackedScene = load("res://tests/network_game_fixture.tscn")
	var relay_scene: PackedScene = load("res://scripts/network/relay_client.tscn")
	var host: Node3D = fixture.instantiate()
	root.add_child(host)
	var host_relay: RelayClient = relay_scene.instantiate()
	host.add_child(host_relay)
	var sender: MatchReplication = host.get_node("MatchReplication")
	sender.configure(host,host_relay)
	var own: BattleUnit = host.spawn_unit(KIND,0,Vector3.ZERO)
	var enemy: BattleUnit = host.spawn_unit(KIND,2,Vector3(3,0,0))
	var hidden: BattleUnit = host.spawn_unit(KIND,3,Vector3(50,0,50))
	host.visible_ids.assign([enemy.entity_id])
	own.hp = 99
	own._model.strike()
	own._attack_animation.seek(.55,true,true)
	var snapshot: Dictionary = sender.build_snapshot(0)
	check(snapshot.entities.size() == 2 and not snapshot.entities.any(func(item: Dictionary): return item.id == hidden.entity_id), "war elephant snapshots obey fog visibility")
	var wire: Dictionary = NetworkProtocol.decode(NetworkProtocol.encode({"op":"snapshot","payload":snapshot})).payload
	var client: Node3D = fixture.instantiate()
	root.add_child(client)
	var client_relay: RelayClient = relay_scene.instantiate()
	client.add_child(client_relay)
	var receiver: MatchReplication = client.get_node("MatchReplication")
	receiver.configure(client,client_relay)
	receiver.receive_snapshot(wire)
	check(receiver.last_received_tick == 0, "network validator accepts new unit with ordinary strike animation")
	check(client.entities_by_id.has(own.entity_id), "replica instantiates the war elephant")
	if client.entities_by_id.has(own.entity_id):
		var replica: BattleUnit = client.entities_by_id[own.entity_id]
		check(replica.unit_type == KIND and replica.hp == 99 and replica.max_hp == 360, "replica preserves authoritative kind and health")
		check(not replica.is_physics_processing(), "client cannot apply duplicate damage")
	client.queue_free()
	host.queue_free()
	current_scene = null
	await process_frame
	await process_frame
