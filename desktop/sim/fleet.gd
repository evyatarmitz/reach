class_name Fleet
extends RefCounted

# A fleet is a bag of ships — fighters (strong in fleet combat, poor at
# bombardment) and bombers (the reverse) — in tiers 1-5. It moves only along
# lanes; in a system with an enemy fleet it auto-fights, otherwise it bombards
# enemy colonies. Counts are per tier (index 0-4 = tier 1-5).

var id: int = -1
var empire_id: int = -1
var system_id: int = -1        # current system (stationary, or the one being left)
var prev_system: int = -1      # system this fleet arrived FROM (its one legal retreat)
var path: Array[int] = []      # remaining system ids to traverse, in order
var progress: float = 0.0      # 0..1 along the lane from system_id to path[0]
var fighters: Array[int] = [0, 0, 0, 0, 0]
var bombers: Array[int] = [0, 0, 0, 0, 0]
var damage: float = 0.0        # accumulated combat damage; destroys ships as it mounts
var foreign_days: float = 0.0  # days parked in unsupplied foreign space (attrition)


func is_moving() -> bool:
	return not path.is_empty()


func ship_count() -> int:
	var n := 0
	for t in 5:
		n += fighters[t] + bombers[t]
	return n


func combat_power() -> float:
	var p := 0.0
	for t in 5:
		p += fighters[t] * SimConstants.FIGHTER_ATK[t] \
			+ bombers[t] * SimConstants.BOMBER_ATK[t]
	return p


func bomb_power() -> float:
	var p := 0.0
	for t in 5:
		p += bombers[t] * SimConstants.BOMBER_BOMB[t] \
			+ fighters[t] * SimConstants.FIGHTER_BOMB[t]
	return p


# Total ship "hit points" — used for percentage-of-strength combat attrition.
func hull() -> float:
	var h := 0.0
	for t in 5:
		h += fighters[t] * SimConstants.FIGHTER_HP[t] \
			+ bombers[t] * SimConstants.BOMBER_HP[t]
	return h
