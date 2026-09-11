class_name CombatLayers
extends RefCounted
## Eight match alliances plus eight unit-only sandbox factions. Common bits stay
## unchanged (terrain 1, buildings 2, units 4, mines 128).
const UNIT_LAYERS: Array[int] = [16, 8, 256, 512, 1024, 2048, 65536, 131072, 1048576, 2097152, 4194304, 8388608, 16777216, 33554432, 67108864, 134217728]
const BUILDING_LAYERS: Array[int] = [32, 64, 4096, 8192, 16384, 32768, 262144, 524288]
const ALL_UNITS: int = 16 | 8 | 256 | 512 | 1024 | 2048 | 65536 | 131072 | 267386880
const ALL_BUILDINGS: int = 32 | 64 | 4096 | 8192 | 16384 | 32768 | 262144 | 524288

static func hostile_units(alliance: int) -> int:
	return ALL_UNITS & ~UNIT_LAYERS[alliance]

static func hostile_entities(alliance: int) -> int:
	var own_buildings: int = BUILDING_LAYERS[alliance] if alliance < BUILDING_LAYERS.size() else 0
	return hostile_units(alliance) | (ALL_BUILDINGS & ~own_buildings)
