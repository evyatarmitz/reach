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
# RATE lowered again (0.01 -> 0.004): the first center was ballooning far faster
# than you could gather resources or expand, so it never paid to found a second
# system (and the neighbor bonus, which needs colonies in OTHER systems, stayed 0
# all game). Slower growth keeps pop in step with development.
const GROWTH_RATE := 0.004
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

# Mining: one structure, but each DEPOSIT has its own fixed richness (output/day,
# constant over time, varies by deposit) so later mine upgrades have a reason to
# prefer some deposits. The exact richness is hidden until a mine is built — the
# planet view shows only an ESTIMATE_BAND-wide bracket before building.
const MINE_RICHNESS_MIN := 25.0
const MINE_RICHNESS_MAX := 65.0
const ESTIMATE_BAND := 15.0

# How often an AI empire re-evaluates (sim days). Gradual, deterministic; not
# tied to framerate or the speed dial.
const AI_ACTION_INTERVAL_DAYS := 8.0

# Ships. Two roles x 5 tiers, built above the empire's most-populated city and
# paid for in that tier's national military resource. Fighters win fleet combat
# and barely bombard; bombers barely fight but bombard hard. Stats per tier (1-5).
enum Role { FIGHTER, BOMBER }
const SHIP_NAT_COST := 15.0     # cost in the tier's military resource, per ship
const FIGHTER_ATK := [10.0, 18.0, 28.0, 40.0, 55.0]
const FIGHTER_BOMB := [1.0, 1.5, 2.0, 2.5, 3.0]
const FIGHTER_HP := [10.0, 16.0, 24.0, 34.0, 46.0]
const BOMBER_ATK := [2.0, 3.0, 4.0, 5.0, 6.0]
const BOMBER_BOMB := [8.0, 14.0, 22.0, 32.0, 44.0]
const BOMBER_HP := [12.0, 18.0, 26.0, 36.0, 48.0]

# Fleets travel lanes at FLEET_SPEED map-units/day. In a system with an enemy
# fleet they auto-fight, losing hull proportional to enemy combat power (no single
# decisive fight). Otherwise a fleet bombards enemy colonies weakest-first; a
# colony under BOMBARD_DESTROY_POP left when bombed is destroyed.
const FLEET_SPEED := 60.0
const COMBAT_RATE := 0.02       # hull lost per enemy-combat-power per day
const BOMBARD_DESTROY_POP := 100.0

# Established-city conversion: capacity/day = COEF * pop^EXP for each chain
# (water->food, minerals->alloys). Actual output is capped by the available T0
# input — partial is fine (20W wanted but only 5W left -> 5F made). As pop rises,
# capacity grows sublinearly while food demand grows linearly, so a food ceiling
# emerges on its own.
const CONV_EXP := 0.8
const FOOD_CONV_COEF := 0.05
const ALLOY_CONV_COEF := 0.05

# National MILITARY resources, one per ship tier (1-5). A refining chain: tier 1
# is made from alloys, each higher tier from the one below it, and each tier is
# gated by a city population cutoff (higher tiers need bigger cities — "more
# resources for higher-tier production"). Ships of tier T cost the tier-T resource.
const MIL_CUTOFF := [100.0, 400.0, 900.0, 1600.0, 2500.0]
const MIL_COEF := 0.02
const MIL_EXP := 0.8

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
