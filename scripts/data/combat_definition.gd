class_name CombatDefinition
extends Resource
## Shared, editor-visible combat data. Catalog resources are never mutated at runtime.

enum DamageChannel { MELEE, RANGED }

@export var id: StringName
@export var name: String
@export_multiline var description: String
@export var hp: float = 1.0
@export var damage: float = 0.0
@export var melee_armor: float = 0.0
@export var ranged_armor: float = 0.0
## Siege engines remain vulnerable to melee even after military defense research.
@export var melee_defense_upgrades: bool = true
@export var damage_channel: DamageChannel = DamageChannel.MELEE
@export var combat_class: StringName
@export var bonuses: Dictionary = {}
@export var range: float = 0.0
@export var cooldown: float = 1.0
