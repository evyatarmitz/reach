class_name Planet
extends RefCounted

var id: int = -1
var system_id: int = -1
var name: String = ""
var colony: Colony = null

# Layout data for rendering — the sim itself never does physics with these.
var orbit_radius: float = 0.0
var orbit_angle: float = 0.0
