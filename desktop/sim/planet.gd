class_name Planet
extends RefCounted

var id: int = -1
var system_id: int = -1
var name: String = ""
var colony: Colony = null
var deposit_type: int = SimConstants.Deposit.NONE  # NONE / WATER / MINERAL
var mine_empire_id: int = -1  # -1 = no mine; otherwise the owning empire

# Layout data for rendering — the sim itself never does physics with these.
var orbit_radius: float = 0.0
var orbit_angle: float = 0.0


func has_deposit() -> bool:
	return deposit_type != SimConstants.Deposit.NONE


func has_mine() -> bool:
	return mine_empire_id != -1
