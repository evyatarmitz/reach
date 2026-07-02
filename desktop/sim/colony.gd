class_name Colony
extends RefCounted

# Pure state + local math. Orchestration (paying upkeep from the national
# stockpile, banking production) lives in Sim so state classes stay cycle-free.

var planet_id: int = -1
var empire_id: int = -1
var population: float = 0.0
var established: bool = false
var days_since_established: float = 0.0


static func growth_per_day(pop: float) -> float:
	return SimConstants.GROWTH_RATE * pop \
		/ (1.0 + pow(pop / SimConstants.GROWTH_SOFTCAP, SimConstants.GROWTH_EXP))


func upkeep_per_day() -> float:
	if not established:
		return SimConstants.COLONY_UPKEEP_BASE
	return SimConstants.COLONY_UPKEEP_BASE \
		* exp(-days_since_established / SimConstants.UPKEEP_TAPER_DAYS)


func production_per_day() -> float:
	if not established:
		return 0.0
	return SimConstants.PROD_COEF * pow(population, SimConstants.PROD_EXP)


func activation_progress() -> float:
	return clampf(population / SimConstants.ACTIVATION_POP, 0.0, 1.0)
