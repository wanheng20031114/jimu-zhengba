extends RefCounted
## Shared audio resources; no runtime directory scan or per-unit duplication.

const EVENTS: Dictionary = {
	"sword_swing": {"streams": [preload("res://assets/audio/sword_swing_01.wav"), preload("res://assets/audio/sword_swing_02.wav"), preload("res://assets/audio/sword_swing_03.wav")], "gain_db": -5.0, "bus": &"Combat", "priority": 2, "gap_ms": 85, "limit": 3},
	"sword_hit": {"streams": [preload("res://assets/audio/sword_hit_01.wav"), preload("res://assets/audio/sword_hit_02.wav"), preload("res://assets/audio/sword_hit_03.wav"), preload("res://assets/audio/sword_hit_04.wav")], "gain_db": -2.0, "bus": &"Combat", "priority": 3, "gap_ms": 75, "limit": 4},
	"bow_release": {"streams": [preload("res://assets/audio/bow_release_01.wav"), preload("res://assets/audio/bow_release_02.wav"), preload("res://assets/audio/bow_release_03.wav")], "gain_db": -3.0, "bus": &"Combat", "priority": 2, "gap_ms": 110, "limit": 3},
	"arrow_hit": {"streams": [preload("res://assets/audio/arrow_hit_01.wav"), preload("res://assets/audio/arrow_hit_02.wav"), preload("res://assets/audio/arrow_hit_03.wav")], "gain_db": -4.0, "bus": &"Combat", "priority": 2, "gap_ms": 90, "limit": 3},
	"wood_hit": {"streams": [preload("res://assets/audio/wood_hit_01.wav"), preload("res://assets/audio/wood_hit_02.wav"), preload("res://assets/audio/wood_hit_03.wav")], "gain_db": -3.0, "bus": &"Combat", "priority": 2, "gap_ms": 110, "limit": 3},
	"catapult_release": {"streams": [preload("res://assets/audio/catapult_release_01.wav"), preload("res://assets/audio/catapult_release_02.wav")], "gain_db": -1.0, "bus": &"Combat", "priority": 4, "gap_ms": 220, "limit": 2},
	"stone_hit": {"streams": [preload("res://assets/audio/stone_hit_01.wav"), preload("res://assets/audio/stone_hit_02.wav"), preload("res://assets/audio/stone_hit_03.wav")], "gain_db": -1.0, "bus": &"Combat", "priority": 4, "gap_ms": 150, "limit": 3},
	"stone_chip": {"streams": [preload("res://assets/audio/stone_hit_01.wav"), preload("res://assets/audio/stone_hit_02.wav"), preload("res://assets/audio/stone_hit_03.wav")], "gain_db": -9.0, "bus": &"Combat", "priority": 2, "gap_ms": 110, "limit": 3},
	"cannon_shot": {"streams": [preload("res://assets/audio/cannon_shot_01.wav"), preload("res://assets/audio/cannon_shot_02.wav")], "gain_db": -2.0, "bus": &"Combat", "priority": 5, "gap_ms": 160, "limit": 3},
	"explosion": {"streams": [preload("res://assets/audio/explosion_01.wav"), preload("res://assets/audio/explosion_02.wav")], "gain_db": -2.0, "bus": &"Combat", "priority": 5, "gap_ms": 180, "limit": 3},
	"collapse": {"streams": [preload("res://assets/audio/collapse_01.wav"), preload("res://assets/audio/collapse_02.wav")], "gain_db": -1.0, "bus": &"Combat", "priority": 6, "gap_ms": 350, "limit": 2},
	"death_fall": {"streams": [preload("res://assets/audio/death_fall_01.wav"), preload("res://assets/audio/death_fall_02.wav"), preload("res://assets/audio/death_fall_03.wav")], "gain_db": -5.0, "bus": &"Combat", "priority": 2, "gap_ms": 160, "limit": 3},
	"footstep_dirt": {"streams": [preload("res://assets/audio/footstep_dirt_01.wav"), preload("res://assets/audio/footstep_dirt_02.wav"), preload("res://assets/audio/footstep_dirt_03.wav"), preload("res://assets/audio/footstep_dirt_04.wav")], "gain_db": 1.0, "bus": &"Foley", "priority": 1, "gap_ms": 95, "limit": 3},
	"horse_hoof": {"streams": [preload("res://assets/audio/horse_hoof_01.wav"), preload("res://assets/audio/horse_hoof_02.wav"), preload("res://assets/audio/horse_hoof_03.wav"), preload("res://assets/audio/horse_hoof_04.wav")], "gain_db": 2.0, "bus": &"Foley", "priority": 2, "gap_ms": 120, "limit": 3},
	"cart_wheel": {"streams": [preload("res://assets/audio/cart_wheel_01.wav"), preload("res://assets/audio/cart_wheel_02.wav"), preload("res://assets/audio/cart_wheel_03.wav")], "gain_db": -7.0, "bus": &"Foley", "priority": 1, "gap_ms": 220, "limit": 2},
	"select": {"streams": [preload("res://assets/audio/ui_select_01.wav"), preload("res://assets/audio/ui_select_02.wav")], "gain_db": -1.0, "bus": &"UI", "priority": 2, "gap_ms": 130, "limit": 2},
	"order": {"streams": [preload("res://assets/audio/ui_order_01.wav"), preload("res://assets/audio/ui_order_02.wav")], "gain_db": -1.0, "bus": &"UI", "priority": 2, "gap_ms": 220, "limit": 2},
	"recruit": {"streams": [preload("res://assets/audio/ui_recruit_01.wav"), preload("res://assets/audio/ui_recruit_02.wav")], "gain_db": -1.0, "bus": &"UI", "priority": 3, "gap_ms": 160, "limit": 2},
	"denied": {"streams": [preload("res://assets/audio/ui_denied_01.wav"), preload("res://assets/audio/ui_denied_02.wav")], "gain_db": -2.0, "bus": &"UI", "priority": 3, "gap_ms": 450, "limit": 1},
	"coin": {"streams": [preload("res://assets/audio/coin_01.wav"), preload("res://assets/audio/coin_02.wav"), preload("res://assets/audio/coin_03.wav")], "gain_db": -2.0, "bus": &"UI", "priority": 2, "gap_ms": 180, "limit": 2},
	"victory": {"streams": [preload("res://assets/audio/victory.wav")], "gain_db": -1.0, "bus": &"UI", "priority": 5, "gap_ms": 1000, "limit": 1},
	"defeat": {"streams": [preload("res://assets/audio/defeat.wav")], "gain_db": -1.0, "bus": &"UI", "priority": 5, "gap_ms": 1000, "limit": 1},
}
