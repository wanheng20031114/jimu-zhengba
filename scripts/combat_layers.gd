class_name CombatLayers
extends RefCounted
## Native physics filters for eight alliances. Common picking/obstacle bits stay
## unchanged (terrain 1, buildings 2, units 4, mines 128).
const UNIT_LAYERS: Array[int] = [16, 8, 256, 512, 1024, 2048, 65536, 131072]
const BUILDING_LAYERS: Array[int] = [32, 64, 4096, 8192, 16384, 32768, 262144, 524288]
const ALL_UNITS: int = 16 | 8 | 256 | 512 | 1024 | 2048 | 65536 | 131072
const ALL_BUILDINGS: int = 32 | 64 | 4096 | 8192 | 16384 | 32768 | 262144 | 524288

static func hostile_units(alliance: int) -> int:
	return ALL_UNITS & ~UNIT_LAYERS[alliance]

static func hostile_entities(alliance: int) -> int:
	return hostile_units(alliance) | (ALL_BUILDINGS & ~BUILDING_LAYERS[alliance])
