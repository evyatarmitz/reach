class_name Colony
extends RefCounted

# Pure state + local math. Orchestration (paying construction from stockpiles,
# converting resources, spreading food across the empire) lives in Sim so state
# classes stay cycle-free.

var planet_id: int = -1
var empire_id: int = -1
var population: float = 0.0
var established: bool = false
var emigrating: bool = false   # while on, sheds pop to the empire's other colonies


static func growth_per_day(pop: float) -> float:
	return SimConstants.GROWTH_RATE * pop \
		/ (1.0 + pow(pop / SimConstants.GROWTH_SOFTCAP, SimConstants.GROWTH_EXP))


# Per-day conversion capacity of an established city (T0 -> T1); actual output is
# capped by available input in Sim.tick.
func food_capacity() -> float:
	if not established:
		return 0.0
	return SimConstants.FOOD_CONV_COEF * pow(population, SimConstants.CONV_EXP)


func alloy_capacity() -> float:
	if not established:
		return 0.0
	return SimConstants.ALLOY_CONV_COEF * pow(population, SimConstants.CONV_EXP)


func activation_progress() -> float:
	return clampf(population / SimConstants.ACTIVATION_POP, 0.0, 1.0)
