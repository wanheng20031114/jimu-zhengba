extends Node
## Saved-scene priority markers bracket actual SceneTree physics work, not tick spacing.
@export_enum("Collector", "Begin", "End") var marker: int = 0
var collecting: bool = false
var physics_ms: Array[float] = []
var path_query_ms: Array[float] = []
var path_query_count: Array[float] = []
var _begin_usec: int = 0

func _ready() -> void:
	if marker == 0: set_physics_process(false)

func _physics_process(_delta: float) -> void:
	var collector: Node = get_parent()
	if marker == 1:
		collector._begin_usec = Time.get_ticks_usec()
	elif collector.collecting:
		collector.physics_ms.append((Time.get_ticks_usec() - collector._begin_usec) / 1000.0)
		var budget: PathBudget = collector.get_parent().get_node("PathBudget")
		collector.path_query_ms.append(budget.query_usec_this_tick / 1000.0)
		collector.path_query_count.append(float(budget.queries_this_tick))

func begin_sample() -> void:
	physics_ms.clear()
	path_query_ms.clear()
	path_query_count.clear()
	collecting = true

func end_sample() -> Array[float]:
	collecting = false
	return physics_ms.duplicate()
