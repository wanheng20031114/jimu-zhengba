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
const SNAPSHOT_INTERVAL_USEC: int = 66667
const MAX_BUFFERED_SNAPSHOTS: int = 12
# Eight expanded armies can contain 896 units; leave room for production lines,
# defenses and rebuilding sites without rejecting an otherwise valid snapshot.
const MAX_VISIBLE_ENTITIES: int = 1536
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
var _next_publish_usec: int = 0
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
var _pending_snapshot_json: Dictionary[int, String] = {}
var _deferred_visual: Dictionary[int, bool] = {}
var _recipient_cursor: int = 0
var _last_drain_frame: int = -1
var _snapshot_job: SnapshotJsonBatchJob
var _outbound_epoch: int = 0
var last_json_encode_usec: int = 0
var last_json_queue_usec: int = 0

func configure(match_game: Node3D, transport: RelayClient) -> void:
	reset()
	game = match_game
	relay = transport
	_fog = game.get_node("FogOfWar")
	relay.snapshot_received.connect(receive_snapshot)
	relay.event_received.connect(_relay_event)
	relay.outbound_invalidated.connect(_discard_outbound)

func reset() -> void:
	_outbound_epoch += 1
	_join_snapshot_job()
	if is_instance_valid(relay) and relay.snapshot_received.is_connected(receive_snapshot):
		relay.snapshot_received.disconnect(receive_snapshot)
	if is_instance_valid(relay) and relay.event_received.is_connected(_relay_event):
		relay.event_received.disconnect(_relay_event)
	if is_instance_valid(relay) and relay.outbound_invalidated.is_connected(_discard_outbound):
		relay.outbound_invalidated.disconnect(_discard_outbound)
	_frames.clear()
	for id: int in _replicas.keys():
		_remove_replica(id)
	last_received_tick = -1
	last_applied_tick = -1
	_last_sent_tick = -1
	_next_publish_usec = 0
	_playback_time = 0.0
	_last_arrival_msec = 0
	_send_errors.clear()
	_outbound_visual.clear()
	_cosmetic_times.clear()
	_last_visual_tick.clear()
	_visual_queue.clear()
	_pending_snapshot_json.clear()
	_deferred_visual.clear()
	_recipient_cursor = 0
	_last_drain_frame = -1
	game = null
	relay = null
	_fog = null

func publish_latest() -> void:
	# Network publication follows wall time after the native physics frame. A
	# render hitch may execute several authority steps, but intermediate states
	# are already obsolete: build/encode only the latest complete state once.
	if game == null or not game.is_authority or game.finished or get_tree().paused or relay.connection_state != "match":
		_discard_outbound()
		_collect_snapshot_job()
		return
	_collect_snapshot_job()
	var current_tick: int = game.simulation_tick
	var now: int = Time.get_ticks_usec()
	if _snapshot_job == null and current_tick > _last_sent_tick and now >= _next_publish_usec:
		if _next_publish_usec == 0:
			_next_publish_usec = now + SNAPSHOT_INTERVAL_USEC
		else:
			# Skip expired deadlines arithmetically, never by sending catch-up packets.
			_next_publish_usec += (int((now - _next_publish_usec) / SNAPSHOT_INTERVAL_USEC) + 1) * SNAPSHOT_INTERVAL_USEC
		_next_publish_usec = maxi(_next_publish_usec, now + 50000)
		_last_sent_tick = current_tick
		var recipients: Array[int] = []
		for player: PlayerState in game.players:
			if player.owner_id != game.local_owner_id and player.controller == "human":
				recipients.append(player.owner_id)
		# Sampling Nodes and visibility stays on the main thread. The resulting
		# primitive tree is detached from game state and transferred to one job.
		# While it runs, drain existing payloads without building a queued history.
		if not recipients.is_empty():
			_snapshot_job = SnapshotJsonBatchJob.new()
			var error: Error = _snapshot_job.submit(build_snapshots(recipients), _outbound_epoch, current_tick)
			assert(error == OK, "A fresh snapshot JSON job must accept its single batch")
		var submitted: int = Time.get_ticks_usec()
		if _next_publish_usec <= submitted:
			_next_publish_usec += (int((submitted - _next_publish_usec) / SNAPSHOT_INTERVAL_USEC) + 1) * SNAPSHOT_INTERVAL_USEC
	_drain_pending()

func _collect_snapshot_job() -> void:
	if _snapshot_job == null or not _snapshot_job.is_completed():
		return
	var job: SnapshotJsonBatchJob = _snapshot_job
	var encoded: Dictionary[int, String] = job.take_result()
	_snapshot_job = null
	last_json_encode_usec = job.encode_usec
	last_json_queue_usec = job.queue_usec
	if job.epoch == _outbound_epoch:
		# Completion does not change the captured tick/time. A newly encoded
		# batch replaces unsent state, while recipient rotation stays independent.
		_pending_snapshot_json = encoded

func _join_snapshot_job() -> void:
	if _snapshot_job != null:
		_snapshot_job.join_and_discard()
		_snapshot_job = null

func _exit_tree() -> void:
	_join_snapshot_job()

func _discard_outbound() -> void:
	# Do not mutate or discard worker-owned containers while encoding runs.
	# Completed work from before a pause, reset or reconnect cannot be published.
	_outbound_epoch += 1
	_pending_snapshot_json.clear()
	_deferred_visual.clear()
	_outbound_visual.clear()
	_cosmetic_times.clear()
	_last_visual_tick.clear()
	_last_sent_tick = -1
	_next_publish_usec = 0
	# Do not reset the display-frame gate: pause/reconnect in this same frame
	# must not mint another native burst. The next process opportunity can drain.

func _drain_pending() -> void:
	var frame: int = Engine.get_process_frames()
	if frame == _last_drain_frame:
		return
	_last_drain_frame = frame
	var attempted := 0
	for _index in range(game.players.size()):
		var recipient: int = _recipient_cursor % game.players.size()
		_recipient_cursor = (_recipient_cursor + 1) % game.players.size()
		if not _pending_snapshot_json.has(recipient) and _outbound_visual.get(recipient, []).is_empty():
			continue
		if game.get_player(recipient).controller != "human":
			_pending_snapshot_json.erase(recipient)
			_outbound_visual.erase(recipient)
			_deferred_visual.erase(recipient)
			continue
		attempted += 1
		var blocked := false
		var visual_first: bool = _deferred_visual.has(recipient)
		if visual_first:
			var visual_error: Error = _flush_visual(recipient)
			blocked = visual_error == ERR_BUSY and relay.presentation_budget_blocked
			if visual_error == OK:
				_deferred_visual.erase(recipient)
		if not blocked and _pending_snapshot_json.has(recipient):
			var error := relay.snapshot_json_to(recipient, _pending_snapshot_json[recipient])
			if error == OK:
				_pending_snapshot_json.erase(recipient)
				_send_errors.erase(recipient)
			elif error not in [ERR_BUSY, ERR_UNAVAILABLE] and _send_errors.get(recipient) != error:
				_send_errors[recipient] = error
				replication_error.emit(recipient, error)
			blocked = error == ERR_BUSY and relay.presentation_budget_blocked
		if not blocked and not visual_first:
			var visual_error: Error = _flush_visual(recipient)
			blocked = visual_error == ERR_BUSY and relay.presentation_budget_blocked
			if blocked:
				_deferred_visual[recipient] = true
		# Effects are scheduled independently after their snapshot leaves the
		# pending map. A budget-blocked effect gets the next empty opportunity
		# before a newer snapshot; wall-time throttling still lets others proceed.
		# Flush each owner separately, including a visual-only retry.
		relay.flush_outbound()
		if blocked:
			_recipient_cursor = recipient
			break
		if attempted >= RelayClient.PRESENTATION_OWNERS_PER_FRAME:
			break

func build_snapshot(recipient: int) -> Dictionary:
	# Standalone reads are fresh even if callers change orders or destroy an
	# entity inside the same tick. Only one synchronous send batch shares data.
	return build_snapshots([recipient])[recipient]

func build_snapshots(recipients: Array[int]) -> Dictionary[int, Dictionary]:
	var snapshots: Dictionary[int, Dictionary] = {}
	if recipients.is_empty():
		return snapshots
	# Public dictionaries are shared only inside this batch; callers transfer the
	# immutable primitive tree to the encoder. Each owner's private state uses a
	# separate dictionary. No live Node, Resource or mutable game-state container
	# escapes, so later ticks cannot mutate a batch still being encoded.
	var public_players: Array = []
	for player: PlayerState in game.players:
		public_players.append(player.public_state())
	var alliances: PackedInt32Array = PackedInt32Array()
	for recipient: int in recipients:
		var observer: PlayerState = game.get_player(recipient)
		alliances.append(observer.alliance_id)
		var player_states: Array = public_players.duplicate()
		var own_state: Dictionary = public_players[recipient].duplicate()
		own_state["private"] = observer.private_state()
		var active: Dictionary = {}
		for track: StringName in observer.active_research:
			active[String(track)] = observer.active_research[track]
		own_state["private"]["active_research"] = active
		player_states[recipient] = own_state
		snapshots[recipient] = {"tick": game.simulation_tick, "time": game.elapsed,
			"entities": [], "mines": [], "players": player_states,
			"fog": _fog.snapshot_for(recipient)}
	# Traverse the authoritative registry once. Visibility stays recipient-
	# specific, including mines. Sample a common pose only if someone can see it;
	# an off-screen attack animation is never repeatedly advanced for teammates.
	for entity: Node3D in game.entities_by_id.values():
		if not is_instance_valid(entity) or not entity.alive:
			continue
		var common: Dictionary = {}
		if entity is ResourceVein:
			for recipient: int in recipients:
				if game.can_see_position(recipient, entity.global_position):
					if common.is_empty():
						common = {"id": entity.entity_id, "workers": entity.occupied_slots()}
					snapshots[recipient].mines.append(common)
			continue
		for index in range(recipients.size()):
			var recipient: int = recipients[index]
			if entity.alliance_id != alliances[index] and not game.can_see_entity(recipient, entity):
				continue
			if common.is_empty():
				common = _entity_public_state(entity)
			var state: Dictionary = common
			if entity.owner_id == recipient:
				state = common.duplicate()
				_append_entity_private_state(state, entity)
			snapshots[recipient].entities.append(state)
	return snapshots

static func snapshot_batch_json(snapshots: Dictionary[int, Dictionary]) -> Dictionary[int, String]:
	return SnapshotJsonBatchJob.stringify_batch(snapshots)

func _entity_public_state(entity: Node3D) -> Dictionary:
	var state := {"id": entity.entity_id, "owner": entity.owner_id,
		# Quantize directly into float64 arrays, without float32 Vector3 tails.
		"p": presentation_position(entity.global_position), "yaw": roundf(float(entity.model_pivot.rotation.y) * 1000.0) / 1000.0,
		"hp": entity.hp, "max_hp": entity.max_hp}
	if entity is BattleUnit:
		var unit := entity as BattleUnit
		unit._model.synchronize_animation()
		var animation: AnimationPlayer = unit._attack_animation
		state.merge({"category": "unit", "kind": unit.unit_type, "moving": unit._moving, "attack_range": unit.attack_range,
			"working": unit._working, "work": unit.work_progress,
			"anim": String(animation.current_animation) if animation.is_playing() else "",
			"phase": animation.current_animation_position if animation.is_playing() else 0.0})
	else:
		var building := entity as BattleBuilding
		state.merge({"category": "building", "kind": building.building_type,
			"construction": building.under_construction, "progress": building.construction_progress,
			"rotation": vector_data(building.rotation)})
	return state

func _entity_state(entity: Node3D, recipient: int) -> Dictionary:
	var state: Dictionary = _entity_public_state(entity)
	if entity.owner_id == recipient:
		_append_entity_private_state(state, entity)
	return state

func _append_entity_private_state(state: Dictionary, entity: Node3D) -> void:
	if entity is BattleUnit:
		var unit := entity as BattleUnit
		state["order"] = int(unit.order)
		state["order_name"] = unit.order_name
		state["queued_count"] = unit.waypoint_queue.size()
		state["plan"] = UnitOrderPlan.build(unit, game)
	else:
		var building := entity as BattleBuilding
		state["actual_paid_gold"] = building.actual_paid_gold
		state["production"] = building.production.snapshot()
		state["rally"] = vector_data(building.rally_point)
		state["rally_mine"] = building.production.rally_mine.entity_id if is_instance_valid(building.production.rally_mine) else 0
		state["order_name"] = building.order_name


static func presentation_position(at: Vector3) -> Array:
	return [roundf(float(at.x) * 100.0) / 100.0, roundf(float(at.y) * 100.0) / 100.0, roundf(float(at.z) * 100.0) / 100.0]

func receive_snapshot(snapshot: Dictionary) -> void:
	if game == null or game.is_authority or game.finished:
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
	# Visibility and removal use the newest complete authority set immediately.
	# Interpolation is only for live poses: an older buffered frame must never
	# resurrect a dead enemy or leave a frozen silhouette after losing sight.
	for id: int in _replicas.keys():
		if not by_id.has(id):
			_remove_replica(id)
	for buffered: Dictionary in _frames:
		for id: int in buffered.index.keys():
			if not by_id.has(id):
				buffered.index.erase(id)
	_frames.append({"time": float(snapshot.time), "data": snapshot, "index": by_id})
	if _frames.size() == 1:
		_playback_time = float(snapshot.time) - INTERPOLATION_SECONDS
		_apply_frame(_frames[0])
	while _frames.size() > MAX_BUFFERED_SNAPSHOTS:
		_frames.pop_front()

func render(delta: float) -> void:
	if game == null or game.is_authority or game.finished or _frames.is_empty():
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
	# Final presentation is best-effort; the common transport quota still caps
	# it, and finish_match clears all remaining bulk before queuing the result.
	for recipient: int in _outbound_visual.keys():
		_flush_visual(recipient)
		relay.flush_outbound()

func _flush_visual(recipient: int) -> Error:
	var times: Dictionary = _cosmetic_times.get(recipient, {})
	for key: Vector3i in times.keys():
		if game.elapsed - float(times[key]) >= COSMETIC_INTERVAL:
			times.erase(key)
	if times.is_empty():
		_cosmetic_times.erase(recipient)
	var pending: Array = _outbound_visual.get(recipient, [])
	if pending.is_empty():
		return OK
	if game.simulation_tick - int(_last_visual_tick.get(recipient, -SNAPSHOT_TICKS)) < SNAPSHOT_TICKS:
		return ERR_SKIP
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
		return OK
	var batch: Array = pending.slice(0, mini(pending.size(), MAX_BATCH_EVENTS))
	# Encode the normal batch only once. RelayClient checks the actual envelope
	# size before native submission; only that size failure may shrink a batch.
	# BUSY keeps the complete queue for the next fair process opportunity.
	var error := relay.send_event(recipient, {"kind": "visual_batch", "events": batch})
	while error == ERR_OUT_OF_MEMORY and batch.size() > 1:
		batch = batch.slice(0, maxi(1, batch.size() / 2))
		error = relay.send_event(recipient, {"kind": "visual_batch", "events": batch})
	if error == ERR_OUT_OF_MEMORY:
		pending.pop_front()
		replication_error.emit(recipient, ERR_INVALID_DATA)
		return ERR_INVALID_DATA
	if error == OK:
		_last_visual_tick[recipient] = game.simulation_tick
		_outbound_visual[recipient] = pending.slice(batch.size())
	elif error in [ERR_INVALID_DATA, ERR_OUT_OF_MEMORY]:
		_outbound_visual[recipient] = pending.slice(batch.size())
		replication_error.emit(recipient, error)
	return error

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
		entity.attack_range = float(state.attack_range)
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
			entity.actual_paid_gold = int(state.actual_paid_gold)
			entity.rally_point = vector(state.rally)
			entity.production.training.assign(state.production.training)
			entity.production.research_queue.assign(state.production.research_queue)
			entity.production.rally_mine = game.entities_by_id.get(int(state.rally_mine))

func _present_unit(unit: BattleUnit, a: Dictionary, b: Dictionary, weight: float, delta: float) -> void:
	unit._model.set_motion(bool(a.moving))
	unit._model.set_working(bool(a.working), String(a.anim) if a.anim in ["gather", "build", "repair", "heal"] else "gather")
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
		var newly_eliminated: bool = bool(state.eliminated) and not player.eliminated
		player.eliminated = bool(state.eliminated)
		if newly_eliminated and player.owner_id == game.local_owner_id:
			game.notify_owner(player.owner_id, "你的阵营已出局 · 比赛继续，可返回大厅")
		if player.owner_id != game.local_owner_id:
			continue
		var own: Dictionary = state.private
		player.gold = int(own.gold)
		# Protocol 10's earlier hosts did not include this additive statistic.
		if own.has("kills"):
			player.kills = int(own.kills)
		player.military_supply = int(own.supply)
		player.reserved_military_supply = int(own.reserved_supply)
		player.farmers = int(own.farmers)
		player.reserved_farmers = int(own.reserved_farmers)
		player.paid_tower_count = int(own.paid_tower_count)
		player.attack_level = int(own.attack_level)
		player.defense_level = int(own.defense_level)
		player.workforce_level = int(own.workforce_level)
		player.army_capacity_level = int(own.army_capacity_level)
		player.mining_level = int(own.mining_level)
		player.cannon_range_level = int(own.cannon_range_level)
		player.recovery_level = int(own.recovery_level)
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
		if not NetworkProtocol.integer(state.get("owner"), 0, game.players.size() - 1) or not game.get_player(int(state.owner)).is_participating():
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
		if state.has("actual_paid_gold") and (state.get("category") != "building" or int(state.owner) != game.local_owner_id):
			return false
		if state.get("category") == "unit":
			if not state.get("kind") in BalanceCatalog.UNITS or not state.get("moving") is bool or not state.get("working") is bool:
				return false
			var base_range: float = BalanceCatalog.unit(state.kind).range
			var range_bonus: float = BalanceCatalog.upgrade(&"cannon_range_1").total_bonus if BalanceCatalog.unit(state.kind).cannon_range_upgrades else 0.0
			if not _number(state.get("attack_range"), base_range, base_range + range_bonus):
				return false
			if not state.get("anim") in ["", "strike", "gather", "build", "repair", "heal"] or not _number(state.get("phase"), 0, 100) or not _number(state.get("work"), 0, 1):
				return false
			if state.anim in ["repair", "heal"] and BalanceCatalog.unit(state.kind).support_kind != StringName(state.anim):
				return false
			if state.anim in ["repair", "heal"] and (not state.working or state.moving):
				return false
			if state.anim in ["gather", "build"] and state.kind != "farmer":
				return false
			if int(state.owner) == game.local_owner_id and not NetworkProtocol.integer(state.get("order"), 0, 7):
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
			if int(state.owner) == game.local_owner_id and not NetworkProtocol.integer(state.get("actual_paid_gold"), 0, 1000000):
				return false
		else:
			return false
		if int(state.owner) == game.local_owner_id and not state.get("order_name") is String:
			return false
	var owners: Dictionary = {}
	for state: Variant in snapshot.players:
		if not state is Dictionary or not NetworkProtocol.integer(state.get("owner_id"), 0, game.players.size() - 1) or owners.has(int(state.owner_id)):
			return false
		var owner := int(state.owner_id)
		owners[owner] = true
		if owner >= game.players.size() or not state.get("name") is String or not state.get("controller") in ["human", "bot", "open"] or not state.get("eliminated") is bool:
			return false
		# Empty seats are immutable for this match. Disconnect takeovers may only
		# switch a participating player between human and Bot.
		if (state.controller == "open") != (not game.get_player(owner).is_participating()):
			return false
		if state.controller == "open" and state.eliminated:
			return false
		if not NetworkProtocol.integer(state.get("alliance_id"), 0, NetworkProtocol.MAX_PLAYERS - 1) or int(state.alliance_id) != game.get_player(owner).alliance_id:
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
	if value.has("kills") and not NetworkProtocol.integer(value.kills, 0, 2147483647):
		return false
	for key: String in ["gold", "supply", "reserved_supply", "farmers", "reserved_farmers", "paid_tower_count"]:
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
