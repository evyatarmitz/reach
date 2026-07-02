class_name StarSystem
extends RefCounted

# Topology node. Lanes (edges between systems) live on Sim; a system knows its
# own planets only. Single-system slice for now, but the shape is the real one.

var id: int = -1
var name: String = ""
var planet_ids: Array[int] = []

# Position on the galaxy map. Layout AND the distance metric for the
# influence/neighbor-bonus math — systems are points, distance is euclidean.
var map_pos: Vector2 = Vector2.ZERO
