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
var abandoning: bool = false   # while on, sheds at DOUBLE rate and receives 0 immigration
var spec: int = SimConstants.Spec.NONE   # FOOD / ALLOY specialization target
var spec_strength: float = 0.0           # 0..1 ramp toward the current spec's bonus


# Multiplier on a given output's capacity from specialization (1.0 if not this
# output's specialty). kind is a SimConstants.Spec value.
func spec_factor(kind: int) -> float:
	if spec == kind and kind != SimConstants.Spec.NONE:
		return 1.0 + SimConstants.SPEC_BONUS * spec_strength
	return 1.0


static func growth_per_day(pop: float) -> float:
	return SimConstants.GROWTH_RATE * pop \
		/ (1.0 + pow(pop / SimConstants.GROWTH_SOFTCAP, SimConstants.GROWTH_EXP))


# Total per-day refining budget of an established city, split across the alloy tiers
# it qualifies for (see Sim.tick). Actual output is capped by available input.
func refine_capacity() -> float:
	if not established:
		return 0.0
	return SimConstants.REFINE_COEF * pow(population, SimConstants.REFINE_EXP)


func activation_progress() -> float:
	return clampf(population / SimConstants.ACTIVATION_POP, 0.0, 1.0)
