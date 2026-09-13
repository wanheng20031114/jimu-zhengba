class_name UnitDefinition
extends CombatDefinition

## Seconds from attack start to melee contact or projectile release.
@export var attack_windup_seconds: float = 0.22
@export var health_bar_height: float = 2.45
## Full capsule height; keep the legacy diameter floor for large footprints.
@export var collision_height: float = 1.8
@export var death_rest_height: float = 0.15
@export var cost: int = 0
@export var supply: int = 1
@export var speed: float = 3.5
@export var radius: float = 0.5
@export var sight: float = 10.0
@export var min_range: float = 0.0
## Explicit eligibility for the academy barrel-length research.
@export var cannon_range_upgrades: bool = false
## Fixed distinct targets per cycle; the first release uses attack_windup_seconds.
@export_range(1, 3) var volley_targets: int = 1
@export var volley_interval: float = 0.0
@export var volley_arc_degrees: float = 0.0
@export var splash_radius: float = 0.0
@export var projectile: String = ""
@export var production_building: StringName
@export var training_seconds: float = 0.0
@export var military: bool = true
## Authored support capability; recovery uses a separate authority-only channel.
@export var support_kind: StringName
@export var support_range: float = 0.0
@export var support_amount: float = 0.0
@export var support_period: float = 1.0
@export var support_windup_seconds: float = 1.0
@export var support_discovery_range: float = 0.0
@export var support_auto_chase: bool = true
