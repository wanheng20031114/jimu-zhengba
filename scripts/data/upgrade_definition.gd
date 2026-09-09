class_name UpgradeDefinition
extends Resource

@export var id: StringName
@export var name: String
@export var track: StringName
@export_range(1, 3) var level: int = 1
@export var cost: int = 100
@export var research_seconds: float = 20.0
@export var total_bonus: int = 1

