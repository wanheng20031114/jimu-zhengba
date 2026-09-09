class_name MatchReplication
extends Node
## Host-owned state, recipient-filtered snapshots, and a delayed client presentation.
## Gameplay never runs from a replicated pose or an animation callback.

signal snapshot_applied(tick: int)
signal snapshot_rejected(reason: String)
signal replication_error(owner: int, code: int)
signal visual_event_due(event: Dictionary)

const INTERPOLATION_SECONDS: float = 0.12
const SNAPSHOT_TICKS: int = 2
const MAX_BUFFERED_SNAPSHOTS: int = 12
const MAX_VISIBLE_ENTITIES: int = 768
const MAX_CONTINUOUS_GAP: float = 0.5
const MAX_VISUAL_EVENTS: int = 256
const MAX_BATCH_EVENTS: int = 96
const MAX_COSMETIC_BATCH: int = 16
const COSMETIC_INTERVAL: float = 0.2
const COSMETIC_CELL_SIZE: float = 4.0

var game: Node3D
var relay: RelayClient
var last_received_tick: int = -1
var last_applied_tick: int = -1
var _last_sent_tick: int = -1
var _frames: Array[Dictionary] = []
var _replicas: Dictionary = {}
var _playback_time: float = 0.0
var _last_arrival_msec: int = 0
var _fog: Node
var _send_errors: Dictionary = {}
var _outbound_visual: Dictionary = {}
var _cosmetic_times: Dictionary = {}
var _last_visual_tick: Dictionary = {}
var _visual_queue: Array[Dictionary] = []

func configure(match_game: Node3D, transport: RelayClient) -> void:
	reset()
	game = match_game
	relay = transport
	_fog = game.get_node("FogOfWar")
	relay.snapshot_received.connect(receive_snapshot)
	relay.event_received.connect(_relay_event)

func reset() -> void:
	if is_instance_valid(relay) and relay.snapshot_received.is_connected(receive_snapshot):
		relay.snapshot_received.disconnect(receive_snapshot)
	if is_instance_valid(relay) and relay.event_received.is_connected(_relay_event):
		relay.event_received.disconnect(_relay_event)
	_frames.clear()
	for id: int in _replicas.keys():
		_remove_replica(id)
	last_received_tick = -1
	last_applied_tick = -1
	_last_sent_tick = -1
	_playback_time = 0.0
	_last_arrival_msec = 0
	_send_errors.clear()
	_outbound_visual.clear()
	_cosmetic_times.clear()
	_last_visual_tick.clear()
	_visual_queue.clear()
	game = null
	relay = null
	_fog = null

func tick(_delta: float) -> void:
	if game == null or not game.is_authority or relay.connection_state != "match":
		return
	var current_tick: int = game.simulation_tick
	if current_tick <= _last_sent_tick:
		return
	_last_sent_tick = current_tick
	for player: PlayerState in game.players:
		if player.owner_id != game.local_owner_id and player.controller == "human":
			# Every recipient still gets 15 Hz; offset the two phases so a full
			# four-human match never serializes three large snapshots in one tick.
			if current_tick % SNAPSHOT_TICKS != (player.owner_id - 1) % SNAPSHOT_TICKS:
				continue
			_flush_visual(player.owner_id)
			var error := relay.snapshot_to(player.owner_id, build_snapshot(player.owner_id))
			if error == OK:
				_send_errors.erase(player.owner_id)
			elif error not in [ERR_BUSY, ERR_UNAVAILABLE] and _send_errors.get(player.owner_id) != error:
				_send_errors[player.owner_id] = error
				replication_error.emit(player.owner_id, error)

func build_snapshot(recipient: int) -> Dictionary:
	var states: Array = []
	var mines: Array = []
	var observer: PlayerState = game.get_player(recipient)
	for entity: Node3D in game.entities_by_id.values():
		if not is_instance_valid(entity) or not entity.alive:
			continue
		if entity is ResourceVein:
			if game.can_see_position(recipient, entity.global_position):
				mines.append({"id": entity.entity_id, "workers": entity.occupied_slots()})
			continue
		if entity.alliance_id != observer.alliance_id and not game.can_see_entity(recipient, entity):
			continue
		states.append(_entity_state(entity, recipient))
	var player_states: Array = []
	for player: PlayerState in game.players:
		var state := player.public_state()
		if player.owner_id == recipient:
			state["private"] = player.private_state()
			var active: Dictionary = {}
			for track: StringName in player.active_research:
				active[String(track)] = player.active_research[track]
			state["private"]["active_research"] = active
		player_states.append(state)
	return {"tick": game.simulation_tick, "time": game.elapsed, "entities": states, "mines": mines,
		"players": player_states, "fog": _fog.snapshot_for(recipient)}

func _entity_state(entity: Node3D, recipient: int) -> Dictionary:
	var state := {"id": entity.entity_id, "owner": entity.owner_id,
		# Quantize only presentation transforms, directly into GDScript float64
		# arrays. Passing the rounded values through Vector3 would restore float32
		# tails and inflate native JSON/ENet fragmentation without visual benefit.
		"p": presentation_position(entity.global_position), "yaw": roundf(float(entity.model_pivot.rotation.y) * 1000.0) / 1000.0,
		"hp": entity.hp, "max_hp": entity.max_hp}
	if entity is BattleUnit:
		var unit := entity as BattleUnit
		var animation: AnimationPlayer = unit._attack_animation
		state.merge({"category": "unit", "kind": unit.unit_type, "moving": unit._moving,
			"working": unit._working, "work": unit.work_progress,
			"anim": String(animation.current_animation) if animation.is_playing() else "",
			"phase": animation.current_animation_position if animation.is_playing() else 0.0})
		if unit.owner_id == recipient:
			state["order"] = int(unit.order)
			state["order_name"] = unit.order_name
			state["queued_count"] = unit.waypoint_queue.size()
			state["plan"] = UnitOrderPlan.build(unit, game)
	else:
		var building := entity as BattleBuilding
		state.merge({"category": "building", "kind": building.building_type,
			"construction": building.under_construction, "progress": building.construction_progress,
			"rotation": vector_data(building.rotation)})
		if building.owner_id == recipient:
			state["production"] = building.production.snapshot()
			state["rally"] = vector_data(building.rally_point)
			state["rally_mine"] = building.production.rally_mine.entity_id if is_instance_valid(building.production.rally_mine) else 0
			state["order_name"] = building.order_name
	return state

static func presentation_position(at: Vector3) -> Array:
	return [roundf(float(at.x) * 100.0) / 100.0, roundf(float(at.y) * 100.0) / 100.0, roundf(float(at.z) * 100.0) / 100.0]

func receive_snapshot(snapshot: Dictionary) -> void:
	if game == null or game.is_authority:
		return
	if not _valid_snapshot(snapshot):
		snapshot_rejected.emit("invalid_schema")
		return
	var snapshot_tick := int(snapshot.tick)
	if snapshot_tick <= last_received_tick:
		return
	if not _frames.is_empty() and float(snapshot.time) < float(_frames.back().time):
		snapshot_rejected.emit("time_reversed")
		return
	if not _frames.is_empty() and float(snapshot.time) - float(_frames.back().time) > MAX_CONTINUOUS_GAP:
		# After a long outage, resume at current authority time. Retain replicas
		# themselves; spending seconds interpolating the missing history is wrong.
		_frames.clear()
	last_received_tick = snapshot_tick
	_last_arrival_msec = Time.get_ticks_msec()
	var by_id: Dictionary = {}
	for state: Dictionary in snapshot.entities:
		by_id[int(state.id)] = state
	_frames.append({"time": float(snapshot.time), "data": snapshot, "index": by_id})
	if _frames.size() == 1:
		_playback_time = float(snapshot.time) - INTERPOLATION_SECONDS
		_apply_frame(_frames[0])
	while _frames.size() > MAX_BUFFERED_SNAPSHOTS:
		_frames.pop_front()

func render(delta: float) -> void:
	if game == null or game.is_authority or _frames.is_empty():
		return
	var newest_time: float = _frames.back().time
	var since_arrival: float = (Time.get_ticks_msec() - _last_arrival_msec) / 1000.0
	var desired: float = newest_time + minf(since_arrival, INTERPOLATION_SECONDS) - INTERPOLATION_SECONDS
	# Correct jitter gradually. A stall freezes at the last authoritative position;
	# the renderer never invents movement beyond the received simulation.
	var rate: float = clampf(1.0 + (desired - _playback_time) * 2.0, 0.85, 1.15)
	_playback_time = minf(_playback_time + maxf(delta, 0.0) * rate, newest_time)
	while _frames.size() >= 2 and float(_frames[1].time) <= _playback_time:
		_frames.pop_front()
	var older: Dictionary = _frames[0]
	if int(older.data.tick) != last_applied_tick:
		_apply_frame(older)
	var newer: Dictionary = _frames[1] if _frames.size() >= 2 else older
	var span: float = float(newer.time) - float(older.time)
	var weight: float = clampf((_playback_time - float(older.time)) / span, 0.0, 1.0) if span > 0.00001 else 0.0
	for id: int in _replicas:
		var entity: Node3D = _replicas[id]
		if not is_instance_valid(entity):
			continue
		var a: Dictionary = older.index[id]
		var b: Dictionary = newer.index.get(id, a)
		entity.global_position = vector(a.p).lerp(vector(b.p), weight)
		entity.model_pivot.rotation.y = lerp_angle(float(a.yaw), float(b.yaw), weight)
		if entity is BattleUnit:
			_present_unit(entity, a, b, weight, delta)
	game.elapsed = maxf(0.0, _playback_time)
	while not _visual_queue.is_empty() and float(_visual_queue[0].time) <= _playback_time + 0.000001:
		var event: Dictionary = _visual_queue.pop_front()
		if _playback_time - float(event.time) <= MAX_CONTINUOUS_GAP:
			visual_event_due.emit(event)

func queue_host_visual(recipient: int, event: Dictionary) -> void:
	if game == null or not game.is_authority or relay.connection_state != "match" or recipient == game.local_owner_id:
		return
	if recipient < 0 or recipient >= game.players.size() or game.get_player(recipient).controller != "human":
		return
	if not _outbound_visual.has(recipient):
		_outbound_visual[recipient] = []
	var pending: Array = _outbound_visual[recipient]
	var cosmetic: bool = _is_cosmetic(event)
	if cosmetic:
		var times: Dictionary = _cosmetic_times.get(recipient, {})
		var at: Array = event.at
		var kind: int = ["footstep_dirt", "horse_hoof", "cart_wheel"].find(event.get("sound", "")) + 1
		var key := Vector3i(floori(float(at[0]) / COSMETIC_CELL_SIZE), floori(float(at[2]) / COSMETIC_CELL_SIZE), kind)
		if game.elapsed - float(times.get(key, -1.0)) < COSMETIC_INTERVAL:
			return
		times[key] = game.elapsed
		_cosmetic_times[recipient] = times
	if pending.size() >= MAX_VISUAL_EVENTS:
		if cosmetic:
			return
		# Battle presentation may replace footsteps; room/gameplay events use
		# send_event/finish_match directly and never enter this cosmetic backlog.
		var replacement := -1
		for index in range(pending.size()):
			if _is_cosmetic(pending[index]):
				replacement = index
				break
		if replacement < 0:
			return
		pending.remove_at(replacement)
	var stamped := event.duplicate(true)
	stamped["time"] = game.elapsed
	pending.append(stamped)

func flush_visual() -> void:
	for recipient: int in _outbound_visual.keys():
		_flush_visual(recipient)

func _flush_visual(recipient: int) -> void:
	var times: Dictionary = _cosmetic_times.get(recipient, {})
	for key: Vector3i in times.keys():
		if game.elapsed - float(times[key]) >= COSMETIC_INTERVAL:
			times.erase(key)
	if times.is_empty():
		_cosmetic_times.erase(recipient)
	var pending: Array = _outbound_visual.get(recipient, [])
	if pending.is_empty():
		return
	if game.simulation_tick - int(_last_visual_tick.get(recipient, -SNAPSHOT_TICKS)) < SNAPSHOT_TICKS:
		return
	var battle: Array = []
	var cosmetic: Array = []
	for item: Dictionary in pending:
		var age: float = game.elapsed - float(item.time)
		if _is_cosmetic(item):
			if age <= COSMETIC_INTERVAL and cosmetic.size() < MAX_COSMETIC_BATCH:
				cosmetic.append(item)
		elif age <= MAX_CONTINUOUS_GAP:
			battle.append(item)
	pending = battle
	pending.append_array(cosmetic)
	_outbound_visual[recipient] = pending
	if pending.is_empty():
		return
	var batch: Array = pending.slice(0, mini(pending.size(), MAX_BATCH_EVENTS))
	# Reserve room for the transport envelope. Binary size is enforced again by
	# RelayClient; a large effect burst stays one reliable packet per 15 Hz phase.
	while JSON.stringify(batch, "", false).to_utf8_buffer().size() > NetworkProtocol.MAX_EVENT_BYTES - 256:
		if batch.size() == 1:
			pending.pop_front()
			replication_error.emit(recipient, ERR_INVALID_DATA)
			return
		batch = batch.slice(0, maxi(1, batch.size() / 2))
	var error := relay.send_event(recipient, {"kind": "visual_batch", "events": batch})
	if error == OK:
		_last_visual_tick[recipient] = game.simulation_tick
		_outbound_visual[recipient] = pending.slice(batch.size())
	elif error in [ERR_INVALID_DATA, ERR_OUT_OF_MEMORY]:
		_outbound_visual[recipient] = pending.slice(batch.size())
		replication_error.emit(recipient, error)

static func _is_cosmetic(event: Dictionary) -> bool:
	return (event.get("kind") == "sound" and event.get("sound") in ["footstep_dirt", "horse_hoof", "cart_wheel"]) or (event.get("kind") == "effect" and event.get("effect") == "dust")

func _relay_event(event: Dictionary) -> void:
	if game == null or game.is_authority or event.get("kind") != "visual_batch":
		return
	if not event.get("events") is Array or event.events.size() > MAX_BATCH_EVENTS:
		snapshot_rejected.emit("invalid_visual_batch")
		return
	for item: Variant in event.events:
		if not item is Dictionary or not item.get("kind") is String or not _number(item.get("time"), 0, 10000000):
			snapshot_rejected.emit("invalid_visual_event")
			return
	for item: Dictionary in event.events:
		if _visual_queue.size() >= MAX_VISUAL_EVENTS:
			_visual_queue.pop_front()
		_visual_queue.append(item)
	_visual_queue.sort_custom(func(a: Dictionary, b: Dictionary): return float(a.time) < float(b.time))

func _apply_frame(frame: Dictionary) -> void:
	var visible: Dictionary = frame.index
	for id: int in _replicas.keys():
		if not visible.has(id):
			_remove_replica(id)
	for id: int in visible:
		var state: Dictionary = visible[id]
		var entity: Node3D = _replicas.get(id)
		if not is_instance_valid(entity):
			entity = _create_replica(state)
			_replicas[id] = entity
		_apply_entity(entity, state)
	_apply_players(frame.data.players)
	for mine: Dictionary in frame.data.mines:
		var vein: ResourceVein = game.entities_by_id[int(mine.id)]
		vein.set_remote_occupancy(int(mine.workers))
	_fog.apply_snapshot(frame.data.fog)
	_fog.apply_visibility(game.local_owner_id)
	game.simulation_tick = int(frame.data.tick)
	last_applied_tick = int(frame.data.tick)
	snapshot_applied.emit(last_applied_tick)

func _create_replica(state: Dictionary) -> Node3D:
	var entity: Node3D
	if state.category == "unit":
		var unit: BattleUnit = game.spawn_unit(state.kind, int(state.owner), vector(state.p), int(state.id))
		unit.set_physics_process(false)
		unit.navigation_agent.avoidance_enabled = false
		unit.attack_windup.stop()
		unit._attack_animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		unit._model.locomotion.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		entity = unit
	else:
		var building: BattleBuilding = game.spawn_building(state.kind, int(state.owner), vector(state.p), bool(state.construction), int(state.id))
		building.set_physics_process(false)
		building.production.set_physics_process(false)
		entity = building
	# Picking collision remains enabled; remote motion never enters RVO or physics.
	entity.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	entity.reset_physics_interpolation()
	return entity

func _remove_replica(id: int) -> void:
	var entity: Node3D = _replicas[id]
	_replicas.erase(id)
	game.entities_by_id.erase(id)
	if not is_instance_valid(entity):
		return
	# Leaving visibility is not dying. No resource refund, score, rubble, death
	# sound or authoritative on_entity_died callback is permitted here.
	game.forget_entity_selection(entity)
	entity.alive = false
	entity.set_selected(false)
	entity.hide()
	entity.collision_layer = 0
	entity.collision_mask = 0
	for group: StringName in entity.get_groups():
		entity.remove_from_group(group)
	entity.queue_free()

func _apply_entity(entity: Node3D, state: Dictionary) -> void:
	entity.global_position = vector(state.p)
	entity.model_pivot.rotation.y = float(state.yaw)
	entity.hp = float(state.hp)
	entity.max_hp = float(state.max_hp)
	entity.health_bar.set_instance_shader_parameter("health", entity.hp / entity.max_hp)
	entity.health_bar.visible = entity.selected or entity.hp < entity.max_hp
	if entity.owner_id == game.local_owner_id:
		entity.order_name = state.order_name
	if entity is BattleUnit:
		if entity.owner_id == game.local_owner_id:
			entity.order = int(state.order)
			entity.set_meta("replica_queue_count", int(state.queued_count))
			entity.set_meta("replica_order_plan", state.plan.duplicate(true))
		entity.work_progress = float(state.work)
		entity.work_bar.visible = bool(state.working)
		entity.work_bar.set_instance_shader_parameter("health", float(state.work))
		entity.work_bar.set_instance_shader_parameter("bar_color", Color("e9bf5c") if state.anim == "gather" else Color("72c6d8"))
	else:
		entity.rotation = vector(state.rotation)
		var construction_changed: bool = entity.under_construction != bool(state.construction) or not is_equal_approx(entity.construction_progress, float(state.progress))
		entity.under_construction = bool(state.construction)
		entity.construction_progress = float(state.progress)
		if construction_changed:
			entity._update_construction_visuals()
		entity.get_node("DamageSmoke").emitting = entity.hp < entity.max_hp * 0.55
		if entity.owner_id == game.local_owner_id:
			entity.rally_point = vector(state.rally)
			entity.production.training.assign(state.production.training)
			entity.production.research_queue.assign(state.production.research_queue)
			entity.production.rally_mine = game.entities_by_id.get(int(state.rally_mine))

func _present_unit(unit: BattleUnit, a: Dictionary, b: Dictionary, weight: float, delta: float) -> void:
	unit._model.set_motion(bool(a.moving))
	unit._model.set_working(bool(a.working), "gather" if a.anim == "gather" else "build")
	unit._model.locomotion.advance(delta)
	var player: AnimationPlayer = unit._attack_animation
	var animation: String = a.anim
	if animation.is_empty():
		if player.is_playing():
			player.stop()
		return
	if player.current_animation != animation:
		player.play(animation)
	var phase: float = float(a.phase)
	if b.anim == animation:
		var end: float = float(b.phase)
		var clip: Animation = player.get_animation(animation)
		if end < phase and clip.loop_mode != Animation.LOOP_NONE:
			end += clip.length
		if end >= phase:
			phase = lerpf(phase, end, weight)
		if clip.loop_mode != Animation.LOOP_NONE:
			phase = fposmod(phase, clip.length)
	# update_only excludes animation method/audio tracks. The host sends gameplay
	# and spatial sound effects separately on the reliable visibility-filtered path.
	player.seek(phase, true, true)

func _apply_players(states: Array) -> void:
	for state: Dictionary in states:
		var player: PlayerState = game.get_player(int(state.owner_id))
		player.display_name = state.name
		player.controller = state.controller
		if player.owner_id != game.local_owner_id:
			continue
		var own: Dictionary = state.private
		player.gold = int(own.gold)
		player.military_supply = int(own.supply)
		player.reserved_military_supply = int(own.reserved_supply)
		player.farmers = int(own.farmers)
		player.reserved_farmers = int(own.reserved_farmers)
		player.attack_level = int(own.attack_level)
		player.defense_level = int(own.defense_level)
		player.workforce_level = int(own.workforce_level)
		player.queued_research = own.queued_research.duplicate()
		player.active_research.clear()
		for track: String in own.active_research:
			player.active_research[StringName(track)] = int(own.active_research[track])

func _valid_snapshot(snapshot: Dictionary) -> bool:
	if not NetworkProtocol.integer(snapshot.get("tick"), 0, 2147483647) or not _number(snapshot.get("time"), 0, 10000000):
		return false
	if not snapshot.get("entities") is Array or snapshot.entities.size() > MAX_VISIBLE_ENTITIES:
		return false
	if not snapshot.get("players") is Array or snapshot.players.size() != game.players.size() or not snapshot.get("fog") is Dictionary:
		return false
	if not snapshot.get("mines") is Array or snapshot.mines.size() > 64:
		return false
	var mine_ids: Dictionary = {}
	for mine: Variant in snapshot.mines:
		if not mine is Dictionary or not NetworkProtocol.integer(mine.get("id"), 1, 2147483647) or not NetworkProtocol.integer(mine.get("workers"), 0, ResourceVein.CAPACITY):
			return false
		if mine_ids.has(int(mine.id)) or not game.entities_by_id.get(int(mine.id)) is ResourceVein:
			return false
		mine_ids[int(mine.id)] = true
	var ids: Dictionary = {}
	for value: Variant in snapshot.entities:
		if not value is Dictionary:
			return false
		var state: Dictionary = value
		if not NetworkProtocol.integer(state.get("id"), 1, 2147483647) or ids.has(int(state.id)):
			return false
		ids[int(state.id)] = true
		if not NetworkProtocol.integer(state.get("owner"), 0, game.players.size() - 1):
			return false
		var existing: Node3D = game.entities_by_id.get(int(state.id))
		if is_instance_valid(existing) and existing is ResourceVein:
			return false
		if is_instance_valid(existing) and _replicas.has(int(state.id)):
			if existing.owner_id != int(state.get("owner", -1)):
				return false
			if existing is BattleUnit and (state.get("category") != "unit" or state.get("kind") != existing.unit_type):
				return false
			if existing is BattleBuilding and (state.get("category") != "building" or state.get("kind") != existing.building_type):
				return false
		if not _vector(state.get("p")) or not _number(state.get("yaw"), -1000000, 1000000):
			return false
		if not _number(state.get("hp"), 0, 10000000) or not _number(state.get("max_hp"), 1, 10000000):
			return false
		if float(state.hp) > float(state.max_hp):
			return false
		if state.has("plan") and (state.get("category") != "unit" or int(state.owner) != game.local_owner_id):
			return false
		if state.get("category") == "unit":
			if not state.get("kind") in BalanceCatalog.UNITS or not state.get("moving") is bool or not state.get("working") is bool:
				return false
			if not state.get("anim") in ["", "strike", "gather", "build"] or not _number(state.get("phase"), 0, 100) or not _number(state.get("work"), 0, 1):
				return false
			if state.anim in ["gather", "build"] and state.kind != "farmer":
				return false
			if int(state.owner) == game.local_owner_id and not NetworkProtocol.integer(state.get("order"), 0, 6):
				return false
			if int(state.owner) == game.local_owner_id and not NetworkProtocol.integer(state.get("queued_count"), 0, 2147483647):
				return false
			if int(state.owner) == game.local_owner_id:
				if not UnitOrderPlan.valid(state.get("plan")):
					return false
		elif state.get("category") == "building":
			if not state.get("kind") in BalanceCatalog.BUILDINGS or not state.get("construction") is bool or not _number(state.get("progress"), 0, 1) or not _vector(state.get("rotation")):
				return false
			if int(state.owner) == game.local_owner_id and not _valid_production(state):
				return false
		else:
			return false
		if int(state.owner) == game.local_owner_id and not state.get("order_name") is String:
			return false
	var owners: Dictionary = {}
	for state: Variant in snapshot.players:
		if not state is Dictionary or not NetworkProtocol.integer(state.get("owner_id"), 0, 3) or owners.has(int(state.owner_id)):
			return false
		var owner := int(state.owner_id)
		owners[owner] = true
		if owner >= game.players.size() or not state.get("name") is String or not state.get("controller") in ["human", "bot"]:
			return false
		if owner == game.local_owner_id:
			if not _valid_private(state.get("private")):
				return false
		elif state.has("private"):
			return false
	return true

func _valid_private(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	for key: String in ["gold", "supply", "reserved_supply", "farmers", "reserved_farmers"]:
		if not NetworkProtocol.integer(value.get(key), 0, 2147483647):
			return false
	for track: String in BalanceCatalog.UPGRADE_TRACKS:
		if not NetworkProtocol.integer(value.get(track + "_level"), 0, BalanceCatalog.UPGRADE_TRACKS[track]):
			return false
	if not value.get("active_research") is Dictionary:
		return false
	for track: Variant in value.active_research:
		if not track in BalanceCatalog.UPGRADE_TRACKS or not NetworkProtocol.integer(value.active_research[track], 1, 2147483647):
			return false
	if not value.get("queued_research") is Dictionary or value.queued_research.size() > BalanceCatalog.UPGRADES.size():
		return false
	for id: Variant in value.queued_research:
		if not id in BalanceCatalog.UPGRADES or not NetworkProtocol.integer(value.queued_research[id], 1, 2147483647):
			return false
	return true

func _valid_production(state: Dictionary) -> bool:
	if not _vector(state.get("rally")) or not NetworkProtocol.integer(state.get("rally_mine"), 0, 2147483647):
		return false
	if not state.get("production") is Dictionary:
		return false
	var production: Dictionary = state.production
	if not production.get("training") is Array or production.training.size() > BuildingProduction.TRAINING_LIMIT:
		return false
	var job_ids: Dictionary = {}
	for item: Variant in production.training:
		if not item is Dictionary or not item.get("kind") in BalanceCatalog.UNITS or not _number(item.get("elapsed"), 0, 1000) or not NetworkProtocol.integer(item.get("cost"), 0, 1000000):
			return false
		if not NetworkProtocol.integer(item.get("job_id"), 1, 2147483647) or job_ids.has(int(item.job_id)):
			return false
		job_ids[int(item.job_id)] = true
	if not production.get("research_id") is String or not _number(production.get("research_elapsed"), 0, 10000):
		return false
	if not production.get("research_queue") is Array or production.research_queue.size() > BuildingProduction.RESEARCH_LIMIT:
		return false
	var research_ids: Dictionary = {}
	var research_jobs: Dictionary = {}
	for job: Variant in production.research_queue:
		if not job is Dictionary or not job.get("id") in BalanceCatalog.UPGRADES:
			return false
		if not _number(job.get("elapsed"), 0, BalanceCatalog.upgrade(job.id).research_seconds) or not NetworkProtocol.integer(job.get("cost"), 0, 1000000):
			return false
		if not NetworkProtocol.integer(job.get("job_id"), 1, 2147483647) or research_jobs.has(int(job.job_id)) or research_ids.has(job.id):
			return false
		research_jobs[int(job.job_id)] = true
		research_ids[job.id] = true
	if production.research_queue.is_empty():
		return production.research_id.is_empty() and is_zero_approx(float(production.research_elapsed))
	return production.research_id == production.research_queue[0].id and is_equal_approx(float(production.research_elapsed), float(production.research_queue[0].elapsed))

static func _number(value: Variant, minimum: float, maximum: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) >= minimum and float(value) <= maximum

static func _vector(value: Variant) -> bool:
	return value is Array and value.size() == 3 and _number(value[0], -4096, 4096) and _number(value[1], -4096, 4096) and _number(value[2], -4096, 4096)

static func vector_data(at: Vector3) -> Array:
	return [at.x, at.y, at.z]

static func vector(data: Array) -> Vector3:
	return Vector3(float(data[0]), float(data[1]), float(data[2]))
