class_name EconomyDefinition
extends Resource
## Shared economy rules for simulation, HUD and multiplayer content validation.
@export_range(0, 100) var passive_gold_per_second: int = 1
@export_range(0.1, 60.0, 0.1) var mining_seconds: float = 3.0
@export_range(1, 100) var mining_gold: int = 4
