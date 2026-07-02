class_name Planet
extends RefCounted

var id: int = -1
var system_id: int = -1
var name: String = ""
var colony: Colony = null
var has_deposit: bool = false
var mine_empire_id: int = -1  # -1 = no mine; otherwise the owning empire


func has_mine() -> bool:
	return mine_empire_id != -1

# Layout data for rendering — the sim itself never does physics with these.
var orbit_radius: float = 0.0
var orbit_angle: float = 0.0
