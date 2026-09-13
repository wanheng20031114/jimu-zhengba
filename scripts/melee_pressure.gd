class_name MeleePressure
extends RefCounted
## Incremental angular occupancy around one enemy. No actor references or scans.
## Each attacker owns one reservation and releases it on target/order/death changes.
const SECTORS: int = 8
const SECTOR_ARC: float = TAU / SECTORS
const APPROACH_ARC: float = SECTOR_ARC * 3.0

var _arcs := PackedFloat32Array()

func _init() -> void:
	_arcs.resize(CombatLayers.UNIT_LAYERS.size() * SECTORS)

static func sector(offset: Vector3) -> int:
	return posmod(roundi(atan2(offset.z, offset.x) / SECTOR_ARC), SECTORS)

static func footprint(attacker_radius: float, contact_radius: float) -> float:
	return 2.0 * asin(minf(1.0, (attacker_radius + 0.1) / contact_radius))

func add(alliance: int, approach: int, arc: float) -> void:
	var index: int = alliance * SECTORS + approach
	_arcs[index] = maxf(0.0, _arcs[index] + arc)

func excess(alliance: int, approach: int, incoming_arc: float) -> float:
	var start: int = alliance * SECTORS
	var occupied: float = _arcs[start + approach] + _arcs[start + posmod(approach - 1, SECTORS)] + _arcs[start + (approach + 1) % SECTORS]
	return maxf(0.0, occupied + incoming_arc - APPROACH_ARC)
