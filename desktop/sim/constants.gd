class_name SimConstants
extends RefCounted

# Every value here is a "tune until it feels right" placeholder (see CLAUDE.md,
# "A note on numbers"). The SHAPES they parameterize — uncapped-but-self-limiting
# growth, food-balance-driven population, throughput-limited production — are the
# design and must be preserved.

# Deposit / T0 resource type. Same mine structure extracts whichever a deposit
# holds. Water -> Food (grows population); Minerals -> Alloys (builds things).
enum Deposit { NONE, WATER, MINERAL }

# One sim tick advances this many in-game days. Fixed tick size keeps the sim
# deterministic; the speed dial changes how many ticks run per real second.
const TICK_DAYS := 0.1

# Starting empire stockpiles. A buffer of food + alloys so the opening isn't
# instant starvation; the homeworld also starts with free mines (see new_demo).
const START_FOOD := 1500.0
const START_ALLOYS := 400.0
const START_WATER := 0.0
const START_MINERALS := 0.0

const START_POP := 10.0

# Construction is paid in alloys (a T1 good refined from minerals).
const FOUND_COST_ALLOYS := 100.0
const MINE_COST_ALLOYS := 50.0

# A colony activates (becomes an established city, starts converting) at this pop.
const ACTIVATION_POP := 100.0

# Growth curve: relative growth/day = RATE / (1 + (pop/SOFTCAP)^EXP), times the
# neighbor multiplier, applied only when the empire has a food surplus. Base ~1%,
# and SOFTCAP tuned so a LONE colony flattens around ~2k pop but never stops (the
# neighbor bonus is what lets a clustered colony keep climbing past that).
# Never a hard cap; the ceiling emerges from food throughput + diminishing returns.
const GROWTH_RATE := 0.01
const GROWTH_SOFTCAP := 2000.0
const GROWTH_EXP := 2.0
# Population decline per day while the empire is in food deficit, floored so a
# colony persists (can regrow) rather than vanishing.
const SHRINK_RATE := 0.03
const MIN_POP := 1.0

# Neighbor bonus: a colony's growth bonus = Σ over OTHER systems of
# NEIGHBOR_COEF * that system's influence / distance. It's the reward for being
# near a MAJOR CENTER (big influence pushes a big bonus onto nearby colonies),
# while a major center gains almost nothing from a small neighbor (that neighbor's
# influence is tiny). Same-system gives nothing (they compete for influence). The
# bonus multiplies growth (a 20% bonus makes 1% -> 1.2%), offsetting diminishing
# returns so clustered colonies climb past the lone-colony flattening.
const NEIGHBOR_COEF := 0.1

# Emigration: a colony with the toggle on sheds this fraction of its population
# per day to the empire's other colonies (0.1% per 0.1-day tick), letting you
# shift population — and thus influence — toward where it matters.
const IMMIGRATION_RATE := 0.01

# Mining: one structure, extracts MINE_RATE/day of the deposit's T0 resource.
const MINE_RATE := 5.0

# How often an AI empire re-evaluates (sim days). Gradual, deterministic; not
# tied to framerate or the speed dial.
const AI_ACTION_INTERVAL_DAYS := 8.0

# Established-city conversion: capacity/day = COEF * pop^EXP for each chain
# (water->food, minerals->alloys). Actual output is capped by the available T0
# input — partial is fine (20W wanted but only 5W left -> 5F made). As pop rises,
# capacity grows sublinearly while food demand grows linearly, so a food ceiling
# emerges on its own.
const CONV_EXP := 0.8
const FOOD_CONV_COEF := 0.05
const ALLOY_CONV_COEF := 0.05

# Food demand: each pop eats this per day. The sign of the empire's end-of-tick
# food balance decides population direction: surplus -> grow, exactly zero ->
# steady, deficit -> shrink.
const FOOD_PER_POP := 0.01

# Fog of war: an empire sees this multiple of a colony's influence reach around
# it (1.2-2x; separate from influence itself). Mines have no influence, so they
# grant a small flat sensor range instead.
const SIGHT_INFLUENCE_FACTOR := 1.5
const SIGHT_MINE_RANGE := 260.0

# Influence (vision.md core formulas): influence = A1 * pop of the strongest
# center in a system (non-stacking); uncontested reach = A2 * influence;
# contested border sits where influence1/influence2 = r1/r2.
const INFLUENCE_A1 := 1.0
const BORDER_A2 := 1.8
