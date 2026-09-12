extends SceneTree
## Approved balance, recruitment, native windup, AI recognition and wire snapshots.
const KIND := "light_cavalry"
const OUTPUT := "res://artifacts/model-previews/light_cavalry/"
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
	check(stats.hp == 90 and stats.damage == 7 and stats.speed == 6.8, "latest user health, damage and movement")
	check(stats.melee_armor == 1 and stats.ranged_armor == 3 and stats.bonuses == {&"archer": 2}, "fixed armor without extra damage or directional blocking")
	check(stats.cost == 70 and stats.supply == 1 and stats.training_seconds == 7, "approved cost, population and training")
	check(stats.range == 1.1 and stats.min_range == 0 and stats.cooldown == 1.1 and stats.attack_windup_seconds == .2, "melee reach and full attack cycle")
	check(stats.radius == .75 and stats.sight == 20 and stats.combat_class == &"cavalry" and stats.projectile.is_empty(), "approved native footprint, vision and class")
	check(stats.military and stats.production_building == &"barracks", "light cavalry belongs to barracks and military selection")
	check(DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit("archer"),0,0,0),stats) == 8, "archer causes eight damage")
	check(DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit("spearman"),0,0,0),stats)==25,"spearman deals its full anti-cavalry bonus")
	check(DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit("swordsman"),0,0,0),stats)==13,"swordsman deals its full anti-cavalry bonus")
	check(stats.splash_radius==0 and stats.projectile.is_empty(),"cavalry has no splash or rider projectile")
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
	player.gold = 69
	check(not barracks.production.recruit(KIND).ok and player.gold == 69, "insufficient gold does not reserve or charge")
	player.gold = 10000
	var command := {"kind":"recruit","target":barracks.entity_id,"unit_type":KIND}
	check(game.command_bus.execute(command,0).ok, "validated human command recruits a light cavalry")
	check(player.gold == 9930 and player.reserved_military_supply == 1, "recruitment charges seventy and reserves one population")
	barracks.production._physics_process(6.9)
	check(barracks.production.training.size() == 1 and player.military_supply == supply_before, "training cannot complete early")
	barracks.production._physics_process(.11)
	check(barracks.production.training.is_empty() and player.military_supply == supply_before+1 and player.reserved_military_supply == 0, "seven-second training spawns once and converts reserved population")
	var trained: BattleUnit
	for unit: BattleUnit in game.owned_entities(0,"units"):
		if unit.unit_type == KIND:
			trained = unit
	check(trained != null and trained._model.batch_parts.size() == 19 and trained.hp == 90, "recruit spawns the correct batched model with full health")
	trained.stop()
	trained.set_physics_process(false)
	check(is_equal_approx(trained.get_node("CollisionShape3D").shape.height,2.7),"actual capsule encloses the mounted rider")
	var ray:=PhysicsRayQueryParameters3D.create(trained.global_position+Vector3(0,2.2,-4),trained.global_position+Vector3(0,2.2,4),4)
	var picked: Dictionary=game.get_world_3d().direct_space_state.intersect_ray(ray)
	check(picked.get("collider")==trained,"ray selection reaches the elevated rider and upper body")
	await _blocked_exit(barracks,player)
	game.select_entities([barracks])
	game.hud._refresh_actions()
	game.hud.trigger_action_slot(5)
	check(game.hud._actions.any(func(action: Dictionary): return action.kind == "recruit" and action.id == KIND), "barracks exposes its actual recruitment button")
	check(game.command_bus.execute(command,0).ok, "light cavalry can be queued again")
	var refund_before: int = player.gold
	check(barracks.production.cancel_training(0).ok and player.gold == refund_before+70 and player.reserved_military_supply == 0, "cancellation refunds its exact cost and population")
	var military_before: int = player.military_supply
	player.military_supply = player.get_supply_limit()
	var gold_before: int = player.gold
	check(not barracks.production.recruit(KIND).ok and player.gold == gold_before, "population cap rejects light cavalry without charging")
	player.military_supply = military_before
	check(not game.headquarters.production.recruit(KIND).ok, "wrong production building refuses light cavalry")
	check(not game.command_bus.execute(command,1).ok, "another player cannot use the owner's barracks")
	check(barracks.production.recruit(KIND).ok, "queue cavalry before producer destruction")
	barracks.production.destroyed()
	check(barracks.production.training.is_empty() and player.reserved_military_supply == 0, "producer destruction releases light cavalry reservation")
	game.select_entities([trained])
	check(game.own_selected_units() == [trained] and game.own_selected_workers().is_empty(), "light cavalry selection never becomes a farmer selection")
	var target: BattleUnit = game.spawn_unit("farmer",1,Vector3(0,0,-1.5))
	var bystander: BattleUnit = game.spawn_unit("farmer",1,Vector3(.7,0,-1.5))
	var second_bystander: BattleUnit=game.spawn_unit("farmer",1,Vector3(-.7,0,-1.5))
	var cavalry: BattleUnit = game.spawn_unit(KIND,0,Vector3.ZERO)
	for unit: BattleUnit in [target,bystander,second_bystander,cavalry]:
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
	game.get_node("FogOfWar")._recompute()
	cavalry.target = target
	cavalry._start_attack()
	await create_timer(.13).timeout
	check(target.hp == 150, "damage does not precede the authored .20-second contact")
	await create_timer(.10).timeout
	check(target.hp == 143 and bystander.hp == 150 and second_bystander.hp==150, "one melee strike damages only its locked target")
	check(is_equal_approx(cavalry._attack_cooldown,1.1), "attack start consumes the complete cooldown")
	cavalry.issue_attack(target)
	check(is_equal_approx(cavalry._attack_cooldown,1.1), "repeated focus fire cannot reset cooldown")
	cavalry.stop()
	check(is_equal_approx(cavalry._attack_cooldown,1.1), "stop does not refund attack recovery")
	cavalry._charge_time=2.0
	cavalry._charge_cooldown=0.0
	cavalry.target=target
	cavalry._start_attack()
	check(cavalry._charge_cooldown==0.0,"cavalry does not inherit knight charge")
	cavalry.stop()
	var target_after: float=target.hp
	await create_timer(.65).timeout
	check(target.hp==target_after,"stop cancels pending cavalry damage")
	cavalry.receive_hit(DamageResolver.snapshot(BalanceCatalog.unit("spearman"),0,1,1),bystander)
	check(cavalry.hp==65,"native receiving endpoint applies 25 anti-cavalry damage")
	cavalry.receive_hit(DamageResolver.snapshot(BalanceCatalog.unit("swordsman"),0,1,1),bystander)
	check(cavalry.hp==52,"native receiving endpoint applies 13 swordsman damage")
	var bot := SkirmishBot.new(game,0)
	bot._memory = {1:{"building":false,"kind":KIND,"seen_at":0.0},2:{"building":false,"kind":"archer","seen_at":0.0}}
	check(bot._composition().knight == 1 and bot._composition().archer == 1, "AI counts cavalry as cavalry without unknown-kind errors")
	bot._army = [cavalry]
	bot._buildings = [barracks]
	bot._budget = 10000
	bot._recruit_army(0)
	check(game.command_bus.pending.all(func(item: Dictionary): return item.get("unit_type","") != KIND), "AI takeover recognizes existing cavalry but never recruits new ones")
	game.command_bus.pending.clear()
	await game.prepare_shutdown()
	game.queue_free()
	await process_frame
	await process_frame
	await _network()
	FileAccess.open(OUTPUT+"integration-results.json",FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	print("LIGHT_CAVALRY_INTEGRATION ",checks," checks; ",failures.size()," failures")
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
	check(not blockers.is_empty() and not game.find_recruit_position(KIND,barracks).is_finite(),"real units block all cavalry-sized exit candidates")
	check(barracks.production.recruit(KIND).ok,"cavalry can train with temporarily blocked exits")
	var before: int=player.military_supply
	barracks.production._physics_process(7)
	check(barracks.production.training.size()==1 and player.reserved_military_supply==1 and player.military_supply==before,"blocked completion retains its single reservation")
	for blocker: BattleUnit in blockers:
		blocker.queue_free()
	await physics_frame
	await physics_frame
	check(game.find_recruit_position(KIND,barracks).is_finite(),"clearing blockers restores an exit")
	barracks.production._physics_process(.3)
	check(barracks.production.training.is_empty() and player.reserved_military_supply==0 and player.military_supply==before+1,"unblocked retry spawns exactly one cavalry")
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
	own.hp = 59
	own._model.strike()
	own._attack_animation.seek(.2,true,true)
	var snapshot: Dictionary = sender.build_snapshot(0)
	check(snapshot.entities.size() == 2 and not snapshot.entities.any(func(item: Dictionary): return item.id == hidden.entity_id), "light cavalry snapshots obey fog visibility")
	var wire: Dictionary = NetworkProtocol.decode(NetworkProtocol.encode({"op":"snapshot","payload":snapshot})).payload
	var client: Node3D = fixture.instantiate()
	root.add_child(client)
	var client_relay: RelayClient = relay_scene.instantiate()
	client.add_child(client_relay)
	var receiver: MatchReplication = client.get_node("MatchReplication")
	receiver.configure(client,client_relay)
	receiver.receive_snapshot(wire)
	check(receiver.last_received_tick == 0, "network validator accepts new unit with ordinary strike animation")
	check(client.entities_by_id.has(own.entity_id), "replica instantiates the light cavalry")
	if client.entities_by_id.has(own.entity_id):
		var replica: BattleUnit = client.entities_by_id[own.entity_id]
		check(replica.unit_type == KIND and replica.hp == 59 and replica.max_hp == 90, "replica preserves authoritative kind and health")
		check(not replica.is_physics_processing(), "client cannot apply duplicate damage")
	client.queue_free()
	host.queue_free()
	current_scene = null
	await process_frame
	await process_frame
