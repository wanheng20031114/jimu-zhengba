class_name DamageResolver
extends RefCounted
## Pure damage arithmetic: ownership, presentation and death handling stay in entities.

static func snapshot(definition: CombatDefinition, attack_bonus: float, owner_id: int, alliance_id: int) -> DamagePayload:
	var payload := DamagePayload.new()
	payload.base_damage = definition.damage
	payload.attack_bonus = attack_bonus
	payload.bonuses = definition.bonuses.duplicate()
	payload.channel = definition.damage_channel
	payload.owner_id = owner_id
	payload.alliance_id = alliance_id
	return payload

static func resolve(payload: DamagePayload, defender: CombatDefinition, defense_bonus: float = 0.0, falloff: float = 1.0) -> float:
	var armor: float = armor_for_channel(defender, payload.channel, defense_bonus)
	var bonus: float = float(payload.bonuses.get(defender.combat_class, 0.0))
	return maxf(1.0, (payload.base_damage + payload.attack_bonus + bonus) * falloff - armor)

static func armor_for_channel(definition: CombatDefinition, channel: CombatDefinition.DamageChannel, defense_bonus: float = 0.0) -> float:
	if channel == CombatDefinition.DamageChannel.MELEE:
		return definition.melee_armor + (defense_bonus if definition.melee_defense_upgrades else 0.0)
	return definition.ranged_armor + defense_bonus

static func stone_falloff(distance: float) -> float:
	# The inner disk is full damage; the outer annulus fades to half damage.
	return lerpf(1.0, 0.5, clampf((distance - 1.2) / 1.8, 0.0, 1.0))
