class_name StarSystem
extends RefCounted

# Topology node. Lanes (edges between systems) live on Sim; a system knows its
# own planets only. Single-system slice for now, but the shape is the real one.

var id: int = -1
var name: String = ""
var planet_ids: Array[int] = []
