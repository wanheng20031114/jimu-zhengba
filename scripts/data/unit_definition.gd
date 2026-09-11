class_name UnitDefinition
extends CombatDefinition

## Seconds from attack start to melee contact or projectile release.
@export var attack_windup_seconds: float = 0.22
@export var health_bar_height: float = 2.45
@export var cost: int = 0
@export var supply: int = 1
@export var speed: float = 3.5
@export var radius: float = 0.5
@export var sight: float = 10.0
@export var min_range: float = 0.0
@export var splash_radius: float = 0.0
@export var projectile: String = ""
@export var production_building: StringName
@export var training_seconds: float = 0.0
@export var military: bool = true
