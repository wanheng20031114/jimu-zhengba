extends Node3D
## Three bounded native MultiMeshes, updated at 10 Hz only when plans change.
const MAX_FLAGS := 128
const MAX_LINES := 192
const COLORS := {"move": Color("6aaed4"), "attack": Color("e96b52"), "gather": Color("e9bf5c"),
	"build": Color("71c9bf"), "hold": Color("c5bd9d")}
@onready var game: Node3D = get_parent()
@onready var poles: MultiMesh = $Poles.multimesh
@onready var flags: MultiMesh = $Flags.multimesh
@onready var lines: MultiMesh = $Lines.multimesh
var _elapsed := 0.0
var _signature := 0
var flag_count := 0
var line_count := 0

func _ready() -> void:
	poles.instance_count = MAX_FLAGS
	flags.instance_count = MAX_FLAGS
	lines.instance_count = MAX_LINES
	_clear()

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.1:
		return
	_elapsed = 0.0
	refresh()

func refresh() -> void:
	var routes: Array = []
	if not game.finished:
		for unit: BattleUnit in game.own_selected_units():
			var plan: Array = UnitOrderPlan.build(unit, game) if game.is_authority else unit.get_meta("replica_order_plan", [])
			if plan.is_empty():
				continue
			var start := unit.global_position.snapped(Vector3(0.5, 0.5, 0.5))
			routes.append({"start": start, "plan": plan})
	var signature := hash(routes)
	if signature == _signature:
		return
	_signature = signature
	_clear()
	var placed: Dictionary = {}
	var segments: Dictionary = {}
	for route: Dictionary in routes:
		var previous: Vector3 = route.start
		var connected := true
		for step: Dictionary in route.plan:
			if not step.has("at"):
				# Never draw a speculative route through a target lost in fog.
				connected = false
				continue
			var at := Vector3(float(step.at[0]), 0.10, float(step.at[2]))
			var key := "%s:%d:%d" % [step.kind, roundi(at.x), roundi(at.z)]
			var color: Color = COLORS[step.kind]
			if not placed.has(key) and flag_count < MAX_FLAGS:
				placed[key] = true
				_flag(at, color)
			if connected and line_count < MAX_LINES and previous.distance_squared_to(at) > 0.3:
				var segment := "%d:%d:%d:%d:%s" % [roundi(previous.x), roundi(previous.z), roundi(at.x), roundi(at.z), step.kind]
				if not segments.has(segment):
					segments[segment] = true
					_line(previous, at, color)
			previous = at
			connected = true
	poles.visible_instance_count = flag_count
	flags.visible_instance_count = flag_count
	lines.visible_instance_count = line_count

func _clear() -> void:
	flag_count = 0
	line_count = 0
	poles.visible_instance_count = 0
	flags.visible_instance_count = 0
	lines.visible_instance_count = 0

func _flag(at: Vector3, color: Color) -> void:
	poles.set_instance_transform(flag_count, Transform3D(Basis.IDENTITY, at + Vector3(0, 0.49, 0)))
	flags.set_instance_transform(flag_count, Transform3D(Basis.IDENTITY, at + Vector3(0.31, 0.82, 0)))
	flags.set_instance_color(flag_count, color)
	flag_count += 1

func _line(start: Vector3, finish: Vector3, color: Color) -> void:
	start.y = 0.10
	finish.y = 0.10
	var length := start.distance_to(finish)
	var basis := Basis.looking_at((finish - start).normalized(), Vector3.UP)
	# Scale the mesh's local longitudinal axis after orientation. World-axis
	# scaling would skew diagonal segments away from their actual waypoints.
	basis.z *= length
	lines.set_instance_transform(line_count, Transform3D(basis, (start + finish) * 0.5))
	lines.set_instance_color(line_count, color.darkened(0.12))
	line_count += 1
