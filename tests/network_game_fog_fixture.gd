extends Node

var last_applied: Dictionary = {}

func snapshot_for(owner: int) -> Dictionary:
	return {"owner": owner, "visible": "AQID", "explored": "AQIDBA==", "memories": [{"id": 500, "kind": "tower", "p": [22, 0, 11]}]}

func apply_snapshot(data: Dictionary) -> void:
	last_applied = data.duplicate(true)

func apply_visibility(_owner: int) -> void:
	pass
