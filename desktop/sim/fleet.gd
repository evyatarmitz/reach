class_name Fleet
extends RefCounted

# A fleet moves only along lanes (vision: chokepoints are real) and, when parked
# over an enemy population centre, slowly bombards it — no single decisive battle.

var id: int = -1
var empire_id: int = -1
var system_id: int = -1        # current system (stationary, or the one being left)
var path: Array[int] = []      # remaining system ids to traverse, in order
var progress: float = 0.0      # 0..1 along the lane from system_id to path[0]
var strength: float = 0.0


func is_moving() -> bool:
	return not path.is_empty()
