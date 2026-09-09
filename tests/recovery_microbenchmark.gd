extends SceneTree
## Isolated callback cost, not a full-match FPS benchmark. 896 authored mobile units.
const FIXTURE = preload("res://tests/network_game_fixture.tscn")
const SAMPLES: int = 600
var actors: Array[BattleUnit] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var game = FIXTURE.instantiate()
	game.is_authority = true
	for owner in range(4, 8):
		game.players.append(PlayerState.new(owner, owner / 4))
	root.add_child(game)
	var kinds: Array = BalanceCatalog.UNITS.keys()
	for owner in range(8):
		for index in range(112):
			actors.append(game.spawn_unit(kinds[index % kinds.size()], owner, Vector3(index, 0, owner * 4)))
	var off := sample(game, false)
	var on := sample(game, true)
	var mean_delta: float = float(on.mean_usec) - float(off.mean_usec)
	var health_correct: bool = actors.all(func(actor): return is_equal_approx(actor.hp, actor.max_hp - 10.0))
	print("RECOVERY_MICROBENCHMARK_RESULTS " + JSON.stringify({"units": actors.size(), "owners": 8, "tps": 30,
		"samples_per_case": SAMPLES, "unresearched": off, "researched": on, "mean_increment_usec": mean_delta,
		"all_units_healed_twenty": health_correct, "scope": "896 authored damaged mobile units; existing recovery callback only, no render/pathfinding/network; not match FPS"}))
	actors.clear()
	game.queue_free()
	current_scene = null
	await process_frame
	await process_frame
	quit(0 if health_correct else 1)

func sample(game: Node3D, enabled: bool) -> Dictionary:
	for player: PlayerState in game.players:
		player.recovery_level = 1 if enabled else 0
	for actor: BattleUnit in actors:
		actor.hp = actor.max_hp - 30.0
		actor._recovery_quiet_seconds = 10.0
		actor._recovery_progress = 0.0
	var durations: Array[int] = []
	var total: int = 0
	for tick in range(SAMPLES):
		var before: int = Time.get_ticks_usec()
		for actor: BattleUnit in actors:
			actor._tick_recovery(1.0 / 30.0)
		var elapsed: int = Time.get_ticks_usec() - before
		durations.append(elapsed)
		total += elapsed
	durations.sort()
	return {"mean_usec": float(total) / SAMPLES, "p95_usec": durations[int(SAMPLES * 0.95) - 1],
		"p99_usec": durations[int(SAMPLES * 0.99) - 1], "max_usec": durations[-1]}
