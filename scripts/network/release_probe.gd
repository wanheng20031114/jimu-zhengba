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
var catalogue_only: bool = false
var room_mode: String = "2v2"
var room_empty_slots: Array[int] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	if "--network-smoke" not in OS.get_cmdline_user_args():
		check(false, "explicit_probe_flag_required")
		await finish()
		return
	catalogue_only = "--catalogue-only" in OS.get_cmdline_user_args()
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--room-mode="):
			room_mode = argument.trim_prefix("--room-mode=")
		if argument.begins_with("--room-empty-slots="):
			for raw: String in argument.trim_prefix("--room-empty-slots=").split(",", false):
				if not raw.is_valid_int():
					check(false, "invalid_empty_seat_argument")
				else:
					room_empty_slots.append(int(raw))
	check(room_mode in NetworkProtocol.MODES, "release_room_mode_exists")
	if not failures.is_empty():
		await finish()
		return
	var roster := Session.offline_config(room_mode)
	for owner: int in room_empty_slots:
		if owner <= 0 or owner >= roster.players.size():
			check(false, "invalid_empty_seat_index")
		else:
			roster.players[owner].controller = "open"
	check(NetworkProtocol.match_config_error(roster).is_empty(), "release_room_roster_valid")
	if not failures.is_empty():
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
	resource_value_checks += validate_special_upgrade_values()
	check(FileAccess.file_exists(RelayClient.CERTIFICATE_PATH), "packaged_public_trust_certificate_exists")
	var endpoint := read_dictionary(ENDPOINT_PATH)
	check(endpoint.get("address") is String and not endpoint.get("address", "").is_empty() and NetworkProtocol.integer(endpoint.get("port"), 1, 65535), "packaged_public_endpoint_exists")
	check(relay.content_hash.length() == 64 and relay.content_hash == FileAccess.get_sha256(MANIFEST_PATH), "packaged_manifest_fingerprint_loaded")
	if catalogue_only or not failures.is_empty():
		await finish()
		return
	var began := Time.get_ticks_msec()
	check(relay.connect_relay(endpoint.address, int(endpoint.port)) == OK, "native_verified_dtls_connection_started")
	check(await until(func(): return relay.connection_state == "connected", 30.0), "deployed_relay_accepts_certificate_and_content_fingerprint")
	handshake_msec = Time.get_ticks_msec() - began
	if not failures.is_empty():
		await finish()
		return
	relay.create_room(room_mode, "发布包联网自检")
	check(await until(func(): return relay.connection_state == "lobby" and not relay.room.is_empty(), 10.0), "temporary_room_created")
	if not failures.is_empty():
		await finish()
		return
	check(relay.owner_id == 0 and relay.is_host and relay.room.slots.size() == roster.players.size(), "server_assigns_requested_slots_and_host_identity")
	check(relay.room.mode == room_mode, "room_preserves_requested_mode")
	check(relay.room.match_id is String and relay.room.match_id.length() == 32, "server_assigns_independent_match_epoch")
	for owner in range(1, roster.players.size()):
		if owner not in room_empty_slots:
			relay.configure_slot(owner, "bot", NetworkProtocol.default_alliance(room_mode, owner))
	check(await until(func(): return relay.room.slots.slice(1).all(func(slot): return slot.kind == ("open" if int(slot.owner_id) in room_empty_slots else "bot")), 10.0), "server_accepts_bot_and_empty_slot_configuration")
	if failures.is_empty():
		# Only the room protocol starts, so the probe can confirm reliable finish
		# and capacity release. No main.tscn or gameplay simulation is instantiated.
		relay.start_match()
		check(await until(func(): return relay.connection_state == "match" and not received_config.is_empty(), 10.0), "start_configuration_reaches_packaged_client")
	if failures.is_empty():
		check(received_config.match_id == relay.room.match_id and received_config.players.size() == roster.players.size(), "start_configuration_preserves_epoch_and_roster")
		check(received_config.mode == room_mode and received_config.map_id == NetworkProtocol.MODES[room_mode].map_id, "start_configuration_preserves_requested_mode_and_map")
		check(received_config.players.all(func(slot): return int(slot.team_id) == NetworkProtocol.default_alliance(room_mode, int(slot.owner_id))), "start_configuration_preserves_alliances")
		check(received_config.players.all(func(slot): return slot.controller == ("open" if int(slot.owner_id) in room_empty_slots else ("human" if int(slot.owner_id) == 0 else "bot"))), "start_configuration_preserves_actual_participation")
		relay.finish_match({"winner": -1, "time": 0})
		check(await until(func(): return relay.connection_state == "finished" and received_finish, 10.0), "reliable_finish_confirms_room_release")
	check(errors.is_empty(), "no_transport_error_during_release_probe")
	await finish()

func validate_resource_values() -> void:
	# File existence and a source manifest cannot detect a converter dropping a
	# saved exported property. Exercise the actual ResourceLoader values in PCK.
	var began := checks
	var production := {"headquarters": ["farmer"], "barracks": ["swordsman", "spearman", "archer", "knight"],
		"factory": ["catapult", "cannon"], "academy": [], "defense_tower": [], "enemy_keep": ["farmer"], "tower": [], "house": []}
	var defensive_damage := {"headquarters": 40, "enemy_keep": 40, "defense_tower": 16, "tower": 17}
	for kind: String in production:
		var building := BalanceCatalog.building(kind)
		check(Array(building.produces) == production[kind], "packaged_production_members_" + kind)
		check(building.id == StringName(kind) and building.hp >= 1000.0 and building.melee_armor == 10.0 and building.ranged_armor == 10.0 and building.damage == defensive_damage.get(kind, 0),
			"packaged_building_combat_values_" + kind)
	for kind: String in BalanceCatalog.UNITS:
		var unit := BalanceCatalog.unit(kind)
		check(unit.id == StringName(kind) and unit.hp > 0.0 and is_finite(unit.hp) and unit.cost > 0 and unit.speed > 0.0
			and String(unit.production_building) in production and kind in production[String(unit.production_building)], "packaged_unit_production_owner_" + kind)
	var farmer := BalanceCatalog.unit("farmer")
	check(not farmer.military and farmer.hp == 150 and farmer.damage == 5 and farmer.cost == 50 and farmer.training_seconds == 10.0 and farmer.supply == 0 and farmer.sight == 9, "packaged_farmer_health_and_training_contract")
	var training_seconds := {"spearman": 6.0, "swordsman": 6.0, "archer": 7.0, "knight": 8.0, "catapult": 20.0, "cannon": 20.0, "farmer": 10.0}
	for kind: String in training_seconds:
		check(BalanceCatalog.unit(kind).training_seconds == training_seconds[kind], "packaged_training_seconds_" + kind)
	for pair: Array in [["knight", "archer", 5], ["knight", "swordsman", 16], ["swordsman", "knight", 10],
		["swordsman", "archer", 7], ["archer", "knight", 30], ["archer", "swordsman", 13], ["spearman", "knight", 5]]:
		var defender := BalanceCatalog.unit(pair[1])
		var damage := DamageResolver.resolve(DamageResolver.snapshot(BalanceCatalog.unit(pair[0]), 0.0, 0, 0), defender)
		check(ceili(defender.hp / damage) == pair[2], "packaged_combat_hits_" + pair[0] + "_" + pair[1])
	var archer := BalanceCatalog.unit("archer")
	var swordsman := BalanceCatalog.unit("swordsman")
	var spearman := BalanceCatalog.unit("spearman")
	check(spearman.hp == 75 and spearman.damage == 6 and spearman.melee_armor == 1 and spearman.ranged_armor == 1
		and spearman.bonuses == {&"cavalry": 20} and spearman.cost == 40 and spearman.training_seconds == 6
		and spearman.speed == swordsman.speed and spearman.supply == 1 and spearman.combat_class == &"infantry",
		"packaged_spearman_combat_and_production_values")
	check(archer.damage == 11 and archer.hp == 60 and archer.ranged_armor == 5 and archer.bonuses.is_empty() and archer.sight == 14
		and swordsman.ranged_armor == 2 and swordsman.melee_armor == 2 and swordsman.cost == 60 and swordsman.hp == 110
		and swordsman.damage == 9 and swordsman.bonuses == {&"cavalry": 5} and swordsman.sight == 14,
		"packaged_archer_values_and_swordsman_anti_cavalry_bonus")
	check(BalanceCatalog.unit("knight").sight == 16 and BalanceCatalog.unit("knight").sight > archer.sight, "packaged_knight_scouting_sight")
	var knight := BalanceCatalog.unit("knight")
	check(knight.cost == 80 and knight.hp == 120 and knight.ranged_armor == 7 and knight.melee_armor == 2 and knight.damage == 9
		and knight.bonuses == {&"archer": 3, &"siege": 11} and knight.supply == 1, "packaged_knight_price_ranged_armor_and_class_bonuses")
	var catapult := BalanceCatalog.unit("catapult")
	check(catapult.range == 13 and catapult.damage == 26 and catapult.speed == 2 and catapult.splash_radius == 2.7
		and catapult.bonuses == {&"building": 50, &"siege": 20}
		and catapult.cost == 240 and catapult.hp == 140 and catapult.ranged_armor == 2 and catapult.cooldown == 3 and catapult.min_range == 3 and catapult.sight == 14,
		"packaged_catapult_reach_damage_and_class_bonuses")
	var stone := DamageResolver.snapshot(catapult, 0, 0, 0)
	check(DamageResolver.resolve(stone, swordsman) == 24 and DamageResolver.resolve(stone, archer) == 21
		and ceili(swordsman.hp / 24.0) == 5 and ceili(archer.hp / 21.0) == 3,
		"packaged_catapult_needs_five_sword_and_three_archer_hits")
	var cannon := BalanceCatalog.unit("cannon")
	check(DamageResolver.resolve(stone, catapult) == 44 and DamageResolver.resolve(stone, cannon) == 44,
		"packaged_catapult_adds_twenty_damage_against_siege")
	check(cannon.damage == 40 and cannon.bonuses == {&"building": 100} and cannon.ranged_armor == 2, "packaged_cannon_base_damage_and_building_only_bonus")
	var cannon_damage := DamageResolver.resolve(DamageResolver.snapshot(cannon, 0, 0, 0), cannon)
	check(cannon_damage == 38 and ceili(cannon.hp / cannon_damage) == 5
		and is_equal_approx(cannon.hp - 4 * cannon_damage, 28.0), "packaged_cannon_five_mirror_hits_to_destroy")
	check(cannon.hp == 180 and cannon.cost == 255 and cannon.speed == 2 and cannon.range == 13 and cannon.min_range == 2.5 and cannon.sight == 14
		and is_equal_approx(cannon.cooldown, 3.2), "packaged_cannon_health_price_and_reach")
	var defense_tower := BalanceCatalog.building("defense_tower")
	check(defense_tower.cost == 150 and defense_tower.hp == 1000 and defense_tower.build_seconds == 20
		and defense_tower.range == cannon.range and catapult.range == cannon.range
		and defense_tower.bonuses == {&"infantry": 3, &"cavalry": 9}
		and Array(defense_tower.cost_progression) == [150, 185, 225, 255, 280, 270],
		"packaged_tower_price_health_time_and_siege_reach_relationship")
	for siege: UnitDefinition in [catapult, cannon]:
		check(siege.melee_armor == 0 and not siege.melee_defense_upgrades
			and DamageResolver.armor_for_channel(siege, CombatDefinition.DamageChannel.MELEE, 3) == 0
			and DamageResolver.armor_for_channel(siege, CombatDefinition.DamageChannel.RANGED, 3) == siege.ranged_armor + 3,
			"packaged_" + String(siege.id) + "_zero_melee_armor_after_defense_research")
		var knight_damage := DamageResolver.resolve(DamageResolver.snapshot(knight, 0, 0, 0), siege)
		check(knight_damage == 20 and ceili(siege.hp / knight_damage) == (7 if siege.id == &"catapult" else 9),
			"packaged_knight_extended_hits_against_" + String(siege.id))
	var technology_bonuses := {"attack": [1, 2, 4], "defense": [1, 2, 3]}
	for track: String in ["attack", "defense"]:
		for level in range(1, 4):
			var upgrade := BalanceCatalog.upgrade(track + "_" + str(level))
			check(upgrade.track == StringName(track) and upgrade.level == level and upgrade.total_bonus == technology_bonuses[track][level - 1],
				"packaged_upgrade_values_" + track + "_" + str(level))
	var workforce := BalanceCatalog.upgrade("workforce_1")
	check(workforce.track == &"workforce" and workforce.level == 1 and workforce.cost == 125
		and workforce.research_seconds == 24 and workforce.total_bonus == 2, "packaged_workforce_research_price_duration_and_bonus")
	var player := PlayerState.new()
	check(player.get_worker_limit() == 10, "packaged_default_worker_limit_is_ten")
	player.complete_upgrade(workforce)
	check(player.get_worker_limit() == 12 and player.attack_level == 0 and player.defense_level == 0, "packaged_workforce_research_expands_only_worker_limit_to_twelve")
	check(player.get_supply_limit() == 50 and player.get_mining_rate_multiplier() == 1.0, "packaged_default_army_and_mining_limits")
	for level in range(1, 3):
		var upgrade := BalanceCatalog.upgrade("army_capacity_%d" % level)
		check(upgrade.track == &"army_capacity" and upgrade.level == level and upgrade.cost == 500
			and upgrade.research_seconds == 30 and upgrade.total_bonus == 25 * level, "packaged_army_capacity_resource_%d" % level)
		player.complete_upgrade(upgrade)
		check(player.get_supply_limit() == 50 + level * 25 and player.get_worker_limit() == 12
			and player.get_attack_bonus() == 0 and player.get_defense_bonus() == 0, "packaged_army_capacity_state_%d" % level)
	for level in range(1, 4):
		var upgrade := BalanceCatalog.upgrade("mining_%d" % level)
		check(upgrade.track == &"mining" and upgrade.level == level and upgrade.cost == [50, 150, 300][level - 1]
			and upgrade.research_seconds == [15, 25, 35][level - 1] and upgrade.total_bonus == level * 10, "packaged_mining_resource_%d" % level)
		player.complete_upgrade(upgrade)
		check(is_equal_approx(player.get_mining_rate_multiplier(), 1.0 + level * 0.1) and player.get_supply_limit() == 100
			and player.get_worker_limit() == 12 and player.get_attack_bonus() == 0 and player.get_defense_bonus() == 0, "packaged_mining_state_%d" % level)
	resource_value_checks = checks - began

func validate_special_upgrade_values() -> int:
	var began: int = checks
	check(BalanceCatalog.UPGRADE_TRACKS.get(&"cannon_range") == 1 and BalanceCatalog.UPGRADE_TRACKS.get(&"recovery") == 1, "packaged_two_special_upgrade_tracks")
	var cannon_range := BalanceCatalog.upgrade(&"cannon_range_1")
	var recovery := BalanceCatalog.upgrade(&"recovery_1")
	check(cannon_range.track == &"cannon_range" and cannon_range.level == 1 and cannon_range.cost == 240 and cannon_range.research_seconds == 30.0 and cannon_range.total_bonus == 1, "packaged_cannon_range_research_contract")
	check(recovery.track == &"recovery" and recovery.level == 1 and recovery.cost == 100 and recovery.research_seconds == 20.0 and recovery.total_bonus == 1 and BattleUnit.RECOVERY_DELAY == 10.0, "packaged_recovery_research_contract")
	var player := PlayerState.new()
	check(player.get_cannon_range_bonus() == 0.0 and player.get_recovery_per_second() == 0.0, "packaged_special_research_initially_disabled")
	player.complete_upgrade(cannon_range)
	check(player.get_cannon_range_bonus() == 1.0 and player.get_recovery_per_second() == 0.0 and BalanceCatalog.unit(&"cannon").range + player.get_cannon_range_bonus() == 14.0, "packaged_cannon_range_upgrade_reaches_fourteen")
	player.complete_upgrade(recovery)
	check(player.get_recovery_per_second() == 1.0 and player.get_cannon_range_bonus() == 1.0, "packaged_recovery_is_independent_of_range")
	var private_state := player.private_state()
	check(private_state.cannon_range_level == 1 and private_state.recovery_level == 1 and not player.public_state().has("recovery_level"), "packaged_special_tech_state_is_private")
	return checks - began

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
		"exported_template": not OS.has_feature("editor"), "catalogue_only": catalogue_only, "handshake_msec": handshake_msec}))
	get_tree().quit(0 if failures.is_empty() else 1)
