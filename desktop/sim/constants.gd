class_name SimConstants
extends RefCounted

# Every value here is a "tune until it feels right" placeholder (see CLAUDE.md,
# "A note on numbers"). The SHAPES they parameterize — uncapped-but-self-limiting
# growth, food-balance-driven population, throughput-limited production — are the
# design and must be preserved.

# Deposit / T0 resource type. Same mine structure extracts whichever a deposit
# holds. Water -> Food (grows population); Minerals -> Alloys (builds things).
enum Deposit { NONE, WATER, MINERAL }

# A colony can specialize its refining toward FOOD or ALLOYS for a bonus, but
# switching has inertia: the bonus ramps 0->1 over SPEC_RAMP_DAYS and resets to 0
# when you change target (vision: "specialization with inertia on change").
enum Spec { NONE, FOOD, ALLOY }
const SPEC_BONUS := 0.6          # +60% to the specialized output at full strength
const SPEC_RAMP_DAYS := 60.0

# Mines can be upgraded when the same planet holds a big enough colony of the
# owning empire; each level multiplies output and needs a higher pop + alloys.
const MINE_UPGRADE_STEP := 0.5           # +50% output per level
const MINE_UPGRADE_POP := 400.0          # same-planet colony pop needed per level
const MINE_UPGRADE_COST_ALLOYS := 80.0
const MINE_MAX_LEVEL := 4

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
# Hard cap on the neighbor growth bonus (the multiplier tops out at 1 + this). The
# bonus scales with neighbour population, so a dense cluster could compound without
# bound; this keeps clusters strong-but-finite instead of runaway (a 2-system,
# 8-colony knot was reaching thousands-of-percent growth).
const NEIGHBOR_MAX_BONUS := 3.0
# Effective distance used for a neighbor in the SAME system (real distance there
# is ~0). Applying the bonus in-system means a big city also lifts its neighbours
# on other planets of its own system.
const IN_SYSTEM_DIST := 80.0

# Emigration: a colony with the toggle on sheds this fraction of its population
# per day to the empire's other colonies (0.1% per 0.1-day tick), letting you
# shift population — and thus influence — toward where it matters.
const IMMIGRATION_RATE := 0.01

# Mining: one structure, but each DEPOSIT has its own fixed richness (output/day,
# constant over time, varies by deposit) so later mine upgrades have a reason to
# prefer some deposits. The exact richness is hidden until a mine is built — the
# planet view shows only an ESTIMATE_BAND-wide bracket before building.
# Tuned down from 25-65: at the old rate mines out-produced city refining several
# times over, so raw water/minerals ballooned into the millions (a meaningless
# buffer that never drained — see tests/balance_report.gd). Lower richness keeps
# raw supply near refining demand, so mines/deposits stay a real constraint.
const MINE_RICHNESS_MIN := 12.0
const MINE_RICHNESS_MAX := 30.0
const ESTIMATE_BAND := 8.0

# How often an AI empire re-evaluates (sim days). Gradual, deterministic; not
# tied to framerate or the speed dial.
const AI_ACTION_INTERVAL_DAYS := 8.0

# Ships. Two roles x 5 tiers, built above the empire's most-populated city and
# paid for in that tier's national military resource. Fighters win fleet combat
# and barely bombard; bombers barely fight but bombard hard. Stats per tier (1-5).
enum Role { FIGHTER, BOMBER }

# Construction vessels deliver expansion structures (colonies, mines): they travel
# lanes from your capital to the target and CANNOT path through another empire's
# territory (vision). The structure is placed on arrival; cost is paid at dispatch.
enum Build { COLONY, MINE }
const BUILDER_SPEED := 70.0   # map-units/day along lanes (a touch faster than fleets)
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
# Hard ship-power ceiling (vision): an empire's combat DAMAGE in one battle can't
# exceed this, no matter how big the stack — extra ships become durability, not
# punch, so a bigger fleet wins by outlasting, never by one decisive blow.
const POWER_CEILING := 200.0
# Overstay attrition: a fleet parked in space it doesn't own (and out of supply)
# bleeds this fraction of its own hull per day after a grace period — so bigger
# fleets bleed more in absolute terms and can't camp enemy territory forever.
const ATTRITION_GRACE_DAYS := 20.0
const ATTRITION_FRAC := 0.01
# Supply depot: a structure that negates attrition for friendly fleets in its
# system or one lane-jump away (doesn't stack).
const DEPOT_COST_ALLOYS := 60.0
# Observation post: doubles the influence REACH of its system (border pushes twice
# as far, and — since VR rides influence reach — grants early warning well past the
# border). Vision: "doubles influence range, adds a separate visibility range."
const OBS_POST_COST_ALLOYS := 90.0
const OBS_POST_REACH_MULT := 2.0
# Transportation infrastructure: multiplies the neighbor/proximity growth bonus for
# colonies in its system (vision: "strengthens the proximity bonus between
# established centers"), so a well-connected cluster climbs higher.
const TRANSPORT_COST_ALLOYS := 90.0
const TRANSPORT_BONUS_MULT := 1.6

# Established-city conversion: capacity/day = COEF * pop^EXP for each chain
# (water->food, minerals->alloys). Actual output is capped by the available T0
# input — partial is fine (20W wanted but only 5W left -> 5F made). As pop rises,
# capacity grows sublinearly while food demand grows linearly, so a food ceiling
# emerges on its own.
const CONV_EXP := 0.8
const FOOD_CONV_COEF := 0.05
const ALLOY_CONV_COEF := 0.05

# Raw (T0) stockpile ceiling, as days of the empire's current refining capacity
# (floored so a young empire can still buffer a little). Mine output beyond this is
# wasted — a throughput limit that keeps raw a real constraint and removes the giant
# buffer that fuelled the population boom-then-famine. See tests/balance_report.gd.
const RAW_STOCK_DAYS := 20.0
const RAW_STOCK_MIN := 500.0

# National MILITARY resources, one per ship tier (1-5). A refining chain: tier 1
# is made from alloys, each higher tier from the one below it, and each tier is
# gated by a city population cutoff (higher tiers need bigger cities — "more
# resources for higher-tier production"). Ships of tier T cost the tier-T resource.
# Lowered from [100,400,900,1600,2500]: cities in a real game top out around a few
# hundred to ~1500 pop, so the old high cutoffs left ship tiers 3-5 permanently
# unbuildable (dead content — every game showed Mil T3-5 stuck at 0). These map the
# five tiers onto achievable city sizes: small cities make T1-2, big cities T3-5.
const MIL_CUTOFF := [50.0, 150.0, 350.0, 700.0, 1200.0]
# National/civilian resource split: military tiers at this index and above (0-based;
# 2 = tiers 3-5) require the empire to mine BOTH deposit types — the vision's
# "higher production tiers need a wider variety of resource types, rewarding diverse
# territory over hoarding one kind."
const VARIETY_MIN_TIER := 2
const MIL_COEF := 0.02
const MIL_EXP := 0.8

# Food demand: each pop eats this per day. The sign of the empire's end-of-tick
# food balance decides population direction: surplus -> grow, exactly zero ->
# steady, deficit -> shrink.
const FOOD_PER_POP := 0.01

# Fog of war: how far VR reaches past your influence. It's the claim-ratio margin
# in the field VR test (visible where player_claim * this >= rival_claim). At 1.5
# the margin was ~10% of the inter-system distance — visually flush with the
# border; 3.0 puts the VR edge ~1.5x the border distance from your source, i.e.
# clearly IN FRONT of the border (early warning). Tunable.
const SIGHT_INFLUENCE_FACTOR := 3.0
const SIGHT_MINE_RANGE := 260.0

# Influence (vision.md core formulas): influence = A1 * pop of the strongest
# center in a system (non-stacking); uncontested reach = A2 * influence;
# contested border sits where influence1/influence2 = r1/r2.
const INFLUENCE_A1 := 1.0
const BORDER_A2 := 1.8

# Cosmic anomalies: circular regions that block influence and visibility. Placed in
# open space (clear of systems and lanes) so they never break connectivity or
# movement — they force influence/sight to route around them. Count scales a little
# with map size (see generate_map).
const ANOMALY_MIN := 2
const ANOMALY_MAX := 6
const ANOMALY_RADIUS_MIN := 110.0
const ANOMALY_RADIUS_MAX := 190.0
const ANOMALY_SYSTEM_CLEARANCE := 30.0   # keep this far off any system
