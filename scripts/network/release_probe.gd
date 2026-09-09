extends Node
## Explicit --network-smoke release diagnostics. This scene never loads Game,
## creates units, grants resources, or reads private deployment configuration.

const MANIFEST_PATH := "res://data/content_manifest.json"
const ENDPOINT_PATH := "res://data/relay_endpoint.json"

@onready var relay: RelayClient = $RelayClient
var checks: int = 0
var failures: Array[String] = []
var errors: Array[String] = []
var received_config: Dictionary = {}
var received_finish: bool = false
var catalog_files: int = 0
var resource_value_checks: int = 0
var handshake_msec: int = -1

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if "--network-smoke" not in OS.get_cmdline_user_args():
		check(false, "explicit_probe_flag_required")
		await finish()
		return
	relay.error_received.connect(func(code: String, _message: String): errors.append(code))
	relay.match_started.connect(func(config: Dictionary): received_config = config)
	relay.event_received.connect(func(event: Dictionary):
		if event.get("kind") == "match_finished": received_finish = true)
	var manifest := read_dictionary(MANIFEST_PATH)
	check(manifest.get("build") == NetworkProtocol.BUILD_ID and manifest.get("protocol") == NetworkProtocol.VERSION, "packaged_manifest_matches_protocol_and_build")
	check(manifest.get("files") is Dictionary and not manifest.get("files", {}).is_empty(), "packaged_catalogue_is_present")
	if manifest.get("files") is Dictionary:
		catalog_files = manifest.files.size()
		for relative: String in manifest.files:
			var path := "res://" + relative
			# Native export may convert scenes/resources to binary and remap them.
			check(FileAccess.file_exists(path) if relative.ends_with(".json") else ResourceLoader.exists(path), "catalogue_resource_" + relative)
	validate_resource_values()
	check(FileAccess.file_exists(RelayClient.CERTIFICATE_PATH), "packaged_public_trust_certificate_exists")
	var endpoint := read_dictionary(ENDPOINT_PATH)
	check(endpoint.get("address") is String and not endpoint.get("address", "").is_empty() and NetworkProtocol.integer(endpoint.get("port"), 1, 65535), "packaged_public_endpoint_exists")
	check(relay.content_hash.length() == 64 and relay.content_hash == FileAccess.get_sha256(MANIFEST_PATH), "packaged_manifest_fingerprint_loaded")
	if not failures.is_empty():
		await finish()
		return
	var began := Time.get_ticks_msec()
	check(relay.connect_relay(endpoint.address, int(endpoint.port)) == OK, "native_verified_dtls_connection_started")
	check(await until(func(): return relay.connection_state == "connected", 30.0), "deployed_relay_accepts_certificate_and_content_fingerprint")
	handshake_msec = Time.get_ticks_msec() - began
	if not failures.is_empty():
		await finish()
		return
	relay.create_room("2v2", "发布包联网自检")
	check(await until(func(): return relay.connection_state == "lobby" and not relay.room.is_empty(), 10.0), "temporary_room_created")
	if not failures.is_empty():
		await finish()
		return
	check(relay.owner_id == 0 and relay.is_host and relay.room.slots.size() == 4, "server_assigns_four_slot_room_and_host_identity")
	check(relay.room.match_id is String and relay.room.match_id.length() == 32, "server_assigns_independent_match_epoch")
	for owner in range(1, 4):
		relay.configure_slot(owner, "bot", 0 if owner < 2 else 1)
	check(await until(func(): return relay.room.slots.slice(1).all(func(slot): return slot.kind == "bot"), 10.0), "server_accepts_native_bot_slot_configuration")
	if failures.is_empty():
		# Only the room protocol starts, so the probe can confirm reliable finish
		# and capacity release. No main.tscn or gameplay simulation is instantiated.
		relay.start_match()
		check(await until(func(): return relay.connection_state == "match" and not received_config.is_empty(), 10.0), "start_configuration_reaches_packaged_client")
	if failures.is_empty():
		check(received_config.match_id == relay.room.match_id and received_config.players.size() == 4, "start_configuration_preserves_epoch_and_roster")
		relay.finish_match({"winner": -1, "time": 0})
		check(await until(func(): return relay.connection_state == "finished" and received_finish, 10.0), "reliable_finish_confirms_room_release")
	check(errors.is_empty(), "no_transport_error_during_release_probe")
	await finish()

func validate_resource_values() -> void:
	# File existence and a source manifest cannot detect a converter dropping a
	# saved exported property. Exercise the actual ResourceLoader values in PCK.
	var began := checks
	var production := {"headquarters": ["farmer"], "barracks": ["swordsman", "archer", "knight"],
		"factory": ["catapult", "cannon"], "academy": [], "defense_tower": [], "enemy_keep": ["farmer"], "tower": [], "house": []}
	for kind: String in production:
		var building := BalanceCatalog.building(kind)
		check(Array(building.produces) == production[kind], "packaged_production_members_" + kind)
		check(building.id == StringName(kind) and building.hp >= 1000.0 and building.melee_armor == 10.0 and building.ranged_armor == 10.0,
			"packaged_building_combat_values_" + kind)
	for kind: String in BalanceCatalog.UNITS:
		var unit := BalanceCatalog.unit(kind)
		check(unit.id == StringName(kind) and unit.hp > 0.0 and is_finite(unit.hp) and unit.cost > 0 and unit.speed > 0.0
			and String(unit.production_building) in production and kind in production[String(unit.production_building)], "packaged_unit_production_owner_" + kind)
	var farmer := BalanceCatalog.unit("farmer")
	check(not farmer.military and farmer.cost == 50 and farmer.training_seconds == 10.0 and farmer.supply == 0, "packaged_farmer_training_contract")
	var training_seconds := {"swordsman": 6.0, "archer": 8.0, "knight": 10.0, "catapult": 20.0, "cannon": 20.0, "farmer": 10.0}
	for kind: String in training_seconds:
		check(BalanceCatalog.unit(kind).training_seconds == training_seconds[kind], "packaged_training_seconds_" + kind)
	for pair: Array in [["knight", "archer", 2], ["knight", "swordsman", 6], ["swordsman", "knight", 3],
		["swordsman", "archer", 3], ["archer", "knight", 15], ["archer", "swordsman", 10]]:
		var defender := BalanceCatalog.unit(pair[1])
		var damage := DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit(pair[0]), 0.0, 0, 0), defender)
		check(ceili(defender.hp / damage) == pair[2], "packaged_combat_hits_" + pair[0] + "_" + pair[1])
	var archer := BalanceCatalog.unit("archer")
	var swordsman := BalanceCatalog.unit("swordsman")
	check(archer.damage == 12 and archer.bonuses.is_empty() and archer.sight == 13
		and swordsman.ranged_armor == 1 and swordsman.melee_armor == 2 and swordsman.cost == 45 and swordsman.hp == 100
		and swordsman.damage == 20 and swordsman.bonuses == {&"cavalry": 40},
		"packaged_archer_values_and_swordsman_anti_cavalry_bonus")
	check(BalanceCatalog.unit("knight").sight == 15 and BalanceCatalog.unit("knight").sight > archer.sight, "packaged_knight_scouting_sight")
	var knight := BalanceCatalog.unit("knight")
	check(knight.cost == 80 and knight.ranged_armor == 4 and knight.melee_armor == 2 and knight.damage == 19
		and knight.bonuses == {&"archer": 11, &"siege": 31}, "packaged_knight_price_ranged_armor_and_class_bonuses")
	var catapult := BalanceCatalog.unit("catapult")
	check(catapult.range == 13 and catapult.damage == 35 and catapult.bonuses == {&"building": 50}
		and catapult.cost == 200 and catapult.hp == 160 and catapult.cooldown == 3 and catapult.min_range == 3,
		"packaged_catapult_reach_damage_and_class_bonuses")
	var cannon := BalanceCatalog.unit("cannon")
	check(cannon.damage == 86 and cannon.bonuses == {&"building": 150}, "packaged_cannon_base_damage_and_building_only_bonus")
	var cannon_damage := DamageResolver.resolve(DamageResolver.snapshot(cannon, 0, 0, 0), cannon)
	check(cannon_damage == 80 and is_equal_approx((cannon.hp - 2 * cannon_damage) / cannon.hp, 0.2), "packaged_cannon_two_mirror_hits_leave_twenty_percent")
	check(cannon.hp == 200 and cannon.cost == 250 and cannon.range == 14 and cannon.min_range == 2.5
		and is_equal_approx(cannon.cooldown, 3.2), "packaged_cannon_health_price_and_reach")
	var defense_tower := BalanceCatalog.building("defense_tower")
	check(defense_tower.cost == 150 and defense_tower.hp == 1000 and defense_tower.build_seconds == 20
		and defense_tower.range == cannon.range and catapult.range == cannon.range - 1,
		"packaged_tower_price_health_time_and_siege_reach_relationship")
	for siege: UnitDefinition in [catapult, cannon]:
		check(siege.melee_armor == 0 and not siege.melee_defense_upgrades
			and DamageResolver.armor_for_channel(siege, CombatDefinition.DamageChannel.MELEE, 4) == 0
			and DamageResolver.armor_for_channel(siege, CombatDefinition.DamageChannel.RANGED, 4) == siege.ranged_armor + 4,
			"packaged_" + String(siege.id) + "_zero_melee_armor_after_defense_research")
		var knight_damage := DamageResolver.resolve(DamageResolver.snapshot(knight, 0, 0, 0), siege)
		check(knight_damage == 50 and ceili(siege.hp / knight_damage) == 4,
			"packaged_knight_four_hits_against_" + String(siege.id))
	for track: String in ["attack", "defense"]:
		for level in range(1, 4):
			var upgrade := BalanceCatalog.upgrade(track + "_" + str(level))
			check(upgrade.track == StringName(track) and upgrade.level == level and upgrade.total_bonus == [1, 2, 4][level - 1],
				"packaged_upgrade_values_" + track + "_" + str(level))
	var workforce := BalanceCatalog.upgrade("workforce_1")
	check(workforce.track == &"workforce" and workforce.level == 1 and workforce.cost == 125
		and workforce.research_seconds == 24 and workforce.total_bonus == 2, "packaged_workforce_research_price_duration_and_bonus")
	var player := PlayerState.new()
	check(player.get_worker_limit() == 10, "packaged_default_worker_limit_is_ten")
	player.complete_upgrade(workforce)
	check(player.get_worker_limit() == 12 and player.attack_level == 0 and player.defense_level == 0, "packaged_workforce_research_expands_only_worker_limit_to_twelve")
	resource_value_checks = checks - began

func until(predicate: Callable, duration: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(duration * 1000)
	while Time.get_ticks_msec() < deadline and relay.connection_state != "error":
		if predicate.call(): return true
		await get_tree().process_frame
	return bool(predicate.call())

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition: failures.append(label)

func read_dictionary(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK or not parser.data is Dictionary: return {}
	return parser.data

func finish() -> void:
	if relay.connection_state != "finished" and not relay.room.is_empty():
		relay.leave_room()
		# Allow reliable leave to flush before destroying this test connection.
		await get_tree().create_timer(0.5).timeout
	relay.disconnect_relay()
	print("NETWORK_RELEASE_PROBE " + JSON.stringify({"checks": checks, "failures": failures,
		"error_codes": errors, "build": NetworkProtocol.BUILD_ID, "protocol": NetworkProtocol.VERSION,
		"content_hash": NetworkProtocol.content_hash(), "catalogue_files": catalog_files, "resource_value_checks": resource_value_checks,
		"exported_template": not OS.has_feature("editor"), "handshake_msec": handshake_msec}))
	get_tree().quit(0 if failures.is_empty() else 1)
