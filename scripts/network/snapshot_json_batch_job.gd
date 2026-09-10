class_name SnapshotJsonBatchJob
extends RefCounted
## One independently owned snapshot batch, encoded without touching the scene tree.
## The caller transfers the complete primitive tree at submit(), then must neither
## read nor mutate it. The builder already detaches every leaf from live game state.
## Only the worker reads input/writes output until the main thread joins the task.

var epoch: int = 0
var captured_tick: int = -1
var encode_usec: int = 0
var queue_usec: int = 0

var _task_id: int = -1
var _submitted: bool = false
var _submitted_usec: int = 0
var _snapshots: Dictionary[int, Dictionary] = {}
var _result: Dictionary[int, String] = {}

func submit(snapshots: Dictionary[int, Dictionary], generation: int, tick: int) -> Error:
	# A job is deliberately single-use. MatchReplication owns at most one job;
	# a busy worker never queues another batch or asks the builder for more data.
	if _submitted:
		return ERR_ALREADY_IN_USE
	_submitted = true
	epoch = generation
	captured_tick = tick
	_snapshots = snapshots
	_submitted_usec = Time.get_ticks_usec()
	_task_id = WorkerThreadPool.add_task(_encode, false, "RTS snapshot JSON")
	return OK

func has_task() -> bool:
	return _task_id >= 0

func is_completed() -> bool:
	return _task_id >= 0 and WorkerThreadPool.is_task_completed(_task_id)

func take_result() -> Dictionary[int, String]:
	# Normal publication never waits for unfinished work. The wait below also
	# releases WorkerThreadPool's task resources and completes result ownership.
	var completed: bool = is_completed()
	assert(completed, "Snapshot JSON result requested before completion")
	if not completed:
		return {}
	var error: Error = WorkerThreadPool.wait_for_task_completion(_task_id)
	assert(error == OK, "Snapshot JSON task could not be joined")
	_task_id = -1
	var result: Dictionary[int, String] = _result
	_result = {}
	_snapshots = {}
	return result

func join_and_discard() -> void:
	# Scene teardown must join even an unfinished task. Invalidation during play
	# only changes the caller's epoch; it must not clear the worker-owned input.
	if _task_id >= 0:
		var error: Error = WorkerThreadPool.wait_for_task_completion(_task_id)
		assert(error == OK, "Snapshot JSON task could not be joined at teardown")
		_task_id = -1
	_result = {}
	_snapshots = {}

func _encode() -> void:
	var started: int = Time.get_ticks_usec()
	queue_usec = started - _submitted_usec
	_result = stringify_batch(_snapshots)
	# Release the transferred graph here too; its many short-lived containers
	# must not become another main-thread deallocation burst after encoding.
	_snapshots = {}
	encode_usec = Time.get_ticks_usec() - started

static func stringify_batch(snapshots: Dictionary[int, Dictionary]) -> Dictionary[int, String]:
	# All caches and containers belong to this invocation. Public state can be
	# reused across recipients; an owner's private state never enters that cache.
	var public_entities: Dictionary[int, String] = {}
	var public_players: Dictionary[int, String] = {}
	var public_mines: Dictionary[int, String] = {}
	var result: Dictionary[int, String] = {}
	for recipient: int in snapshots:
		var snapshot: Dictionary = snapshots[recipient]
		var fields := PackedStringArray()
		for key: String in snapshot:
			var value_json: String
			if key in ["entities", "players", "mines"]:
				var items := PackedStringArray()
				for state: Dictionary in snapshot[key]:
					var id: int = int(state.owner_id) if key == "players" else int(state.id)
					var owner: int = int(state.owner_id) if key == "players" else int(state.get("owner", -1))
					if owner == recipient:
						items.append(JSON.stringify(state, "", false))
						continue
					var cache: Dictionary[int, String] = public_entities
					if key == "players": cache = public_players
					elif key == "mines": cache = public_mines
					if not cache.has(id): cache[id] = JSON.stringify(state, "", false)
					items.append(cache[id])
				value_json = "[" + ",".join(items) + "]"
			else:
				value_json = JSON.stringify(snapshot[key], "", false)
			fields.append(JSON.stringify(key) + ":" + value_json)
		result[recipient] = "{" + ",".join(fields) + "}"
	return result
