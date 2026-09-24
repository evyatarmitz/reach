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

# Calendar epoch: sim day 0 is 1 Jan of this year. 2291 is a shout-out — the year
# humanity first tested the Shaw-Fujikawa Translight Engine (slipspace) in Halo lore,
# i.e. the year we cracked FTL. Purely cosmetic; change freely.
const START_YEAR := 2291

# Starting empire stockpiles. Water is a FLOW now (not banked — see the tick), so
# there's no starting water; a little starting T1 alloy + minerals so the opening
# isn't dead while the home mines spin up.
const START_MINERALS := 0.0      # none — mines provide minerals from tick 1
const START_NAT0 := 300.0        # starting tier-1 alloy (the construction currency)

const START_POP := 10.0

# Construction is paid in TIER-1 alloy (nat[0]) — the base refined good. (These keep
# the _ALLOYS suffix for continuity; there is no separate untiered "alloys" resource.)
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
# Raised 0.004 -> 0.014 now that the neighbor bonus is OFF (it used to supply much of a
# clustered colony's growth) and water is the real ceiling: faster growth just lets a
# colony climb to the level its water income supports (income / WATER_PER_POP), where it
# holds — no bank to over-shoot, so no boom-bust. Water, not this rate, is the limiter.
const GROWTH_RATE := 0.014
const GROWTH_SOFTCAP := 2000.0
const GROWTH_EXP := 2.0
# Population decline per day while the empire is in food deficit, floored so a
# colony persists (can regrow) rather than vanishing.
const SHRINK_RATE := 0.03
const MIN_POP := 1.0

# Neighbor bonus MASTER SWITCH. OFF for now: the flat planet-mesh map has no real
# clusters, and whatever the values, the bonus compounds into a late-game population
# explosion. Kept (not deleted) so a future game mode can switch it back on. When false,
# neighbor_growth_multiplier() returns 1.0 and none of the tuning below matters.
const NEIGHBOR_BONUS_ENABLED := false

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
const COMBAT_RATE := 0.06       # hull lost per enemy-combat-power per day (each side's
                                # kill rate scales with the OTHER side's full power, so
                                # a bigger fleet kills faster and force ratio decides how
                                # fast — a curbstomp ends near-instantly, an even fight
                                # grinds). Tune for feel.
const BOMBARD_DESTROY_POP := 100.0
# Fraction of raw bomb power that actually converts to population killed per day.
# Low, so bombardment is a SLOW grind (vision: "killing population is slow — no war
# won by one decisive fight"), not an instant wipe.
const BOMBARD_RATE := 0.15
# The vision's "hard ship-power ceiling" lives PER SHIP (each tier's ATK is capped, so
# there are no god-ships — investing past the top tier buys more ships, i.e. capacity,
# not stronger ones). Fleet-vs-fleet damage is NOT capped: total punch scales with the
# stack, so a 100:1 advantage curbstomps and a 10:1 does not — force ratio matters (a
# flat per-battle cap used to flatten every ratio to the same tiny kill rate). This
# constant is now just the AI's "I've massed a decisive strike force" threshold.
const POWER_CEILING := 200.0
# Border attrition: a fleet outside its own borders bleeds this fraction of its
# own hull per day — immediately, no grace. Bigger fleets bleed more in absolute
# terms, so no one can project force into hostile space indefinitely. The counter-
# play is a supply depot (below), which extends a safe supply radius forward.
const ATTRITION_FRAC := 0.02
# Supply depot: negates border attrition for friendly fleets within this many lane
# jumps of the depot's system (0 = same system). This is what lets you campaign in
# foreign space — plant a depot, and everything DEPOT_SUPPLY_JUMPS hops out is safe.
const DEPOT_SUPPLY_JUMPS := 3
const DEPOT_COST_ALLOYS := 60.0
# Observation post: doubles the influence REACH of its system (border pushes twice
# as far, and — since VR rides influence reach — grants early warning well past the
# border). Vision: "doubles influence range, adds a separate visibility range."
const OBS_POST_COST_ALLOYS := 90.0
const OBS_POST_REACH_MULT := 2.0
# Citadel: an expensive fortress on one of your systems. It walls the system off — enemy
# fleets cannot pass THROUGH it (they must make it their destination and bombard it down
# to advance past). Its hull is enormous, so a citadel on a chokepoint lane buys many
# ticks of siege before it falls; while it stands it fully absorbs bombardment (the
# colony behind it is untouched). Deliberately costly — a strategic wall, not routine.
const CITADEL_COST_ALLOYS := 300.0
const CITADEL_MAX_HP := 6000.0
# Imperial center: an administrative seat built on one of your systems. It amplifies the
# influence its colony projects (bigger borders, longer reach/VR) in exchange for extra
# water — the colony has to be supplied to run the bureaucracy. The trade is symmetric and
# upgrades as the colony grows: +10% influence for +10% water at level 1, then +30/+30 at
# level 2, capped at +50/+50 at level 3. So influence is something you can BUY with water
# territory, not only grow — but it deepens your water dependence, keeping the water
# economy the master constraint. (Was the transport hub, whose water-relief job is gone.)
const IMPERIAL_COST_ALLOYS := 90.0
const IMPERIAL_UPGRADE_COST_ALLOYS := 60.0
const IMPERIAL_MAX_LEVEL := 3
# Influence bonus AND matching water surcharge per level (index = level-1). Same number for
# both: you pay in water exactly the fraction of influence you gain.
const IMPERIAL_BONUS := [0.10, 0.30, 0.50]
# The system's strongest colony must reach this pop to build/upgrade to each level
# (index = level-1). Level 1 just needs the colony; higher levels need it to have grown.
const IMPERIAL_UPGRADE_POP := [0.0, 400.0, 900.0]

# --- refining: the single tiered ALLOY chain (minerals -> T1 -> T2 -> ... -> T5) ---
# One chain now, no separate "alloys" resource: minerals refine into tier-1 alloy,
# each higher tier from the one below. An established colony has a total refining
# budget = REFINE_COEF * pop^REFINE_EXP, split EQUALLY across the tiers it qualifies
# for (by MIL_CUTOFF pop gates), and each step yields TIER_YIELD^(tier) per unit of
# budget — so higher tiers are progressively harder and a natural PYRAMID emerges
# (lots of minerals -> many T1 -> fewer T2 -> ...). If a tier's input runs out, its
# unused budget flows UP to the next tier (minerals gone -> that budget makes T2 from
# T1, etc.). Kept modest so an empire doesn't drown in alloys it can't spend.
const REFINE_COEF := 0.06
const REFINE_EXP := 0.8
const TIER_YIELD := 0.3           # each tier produces at this fraction of the one below
const CONV_EXP := 0.8             # (kept for any external refs; refining uses REFINE_EXP)

# Raw MINERAL stockpile ceiling, as days of the empire's current refining budget
# (floored so a young empire can buffer a little). Mine output past this is wasted —
# a throughput limit so minerals stay a real constraint. Water is NOT banked (flow).
const RAW_STOCK_DAYS := 20.0
const RAW_STOCK_MIN := 500.0

# Per-tier city population gate: a colony refines tier T only once it passes this pop
# (higher tiers need bigger cities). Small cities make T1-2; big cities reach T3-5.
const MIL_CUTOFF := [50.0, 150.0, 350.0, 700.0, 1200.0]
# Variety: tiers at this index and above (0-based; 2 = tiers 3-5) require the empire
# to mine BOTH water and minerals — "higher tiers need a wider variety of territory."
const VARIETY_MIN_TIER := 2

# WATER is population's only need, and it's a FLOW, not a bank: each tick a pop needs
# WATER_PER_POP of water; if the empire's water income (from water mines) that tick
# covers total demand -> population grows, else it shrinks. Surplus is NOT stored, so
# an empire can't bank water, over-grow, and then crash — pop settles where water
# income supports it (income / WATER_PER_POP), a ceiling set by how much water
# territory you hold (map geometry).
const WATER_PER_POP := 0.01

# Per-colony water OVERHEAD (a flow, like the per-pop need): every colony draws a fixed
# baseline of water beyond what its people drink — a settlement has to be supplied at all,
# not just fed. So the same total population spread across many colonies costs MORE water
# than concentrated in a few: 200 pop in one place needs 200*WATER_PER_POP + 1 overhead;
# 100+100 in two places needs the same 200*WATER_PER_POP + 2 overhead. Sprawl is punished
# (concentration is more water-efficient), but expansion is never forbidden — it's a
# marginal cost that lowers your pop ceiling a little per colony, self-limiting, no hard
# cap. Kept small relative to a mature colony's per-pop draw so it's "close, but not the
# same," not a cliff. Tune for feel.
const WATER_PER_COLONY := 0.5
# (The transport hub's water-relief effect was removed — that building is now the imperial
# center, which spends water to buy influence instead of saving it. Sprawl's per-colony
# overhead above therefore has no dedicated counter-play now: concentration is simply more
# water-efficient, full stop.)

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

# Flat planet-mesh map sizing. The map area scales with the planet count at this
# fixed density, so more planets = a bigger map (not a denser one). Separation is
# the minimum gap between planets.
const MAP_AREA_PER_PLANET := 30000.0
const MAP_MIN_SEPARATION := 90.0

# Cosmic anomalies ("storms"): snaking bands that block influence and visibility but
# NOT movement — fleets fly straight through them, and they're allowed to lie across
# hyperlanes. That makes a storm a tactical object (a blind, un-defended corridor)
# rather than a wall. Each is a capsule-chain: a spine polyline of ANOMALY_STEPS
# points, thickened by ANOMALY_RADIUS. Count scales a little with map size.
const ANOMALY_MIN := 2
const ANOMALY_MAX := 6
const ANOMALY_RADIUS_MIN := 30.0         # band half-width — tighter so the sight-block
const ANOMALY_RADIUS_MAX := 54.0         # footprint (the dark halo) stays a slim corridor
const ANOMALY_STEPS_MIN := 5             # spine points — more = longer snake
const ANOMALY_STEPS_MAX := 7             # was 9 — shorter snakes so one storm can't span the map
const ANOMALY_STEP_LEN := 130.0          # spine segment length
const ANOMALY_TURN := 0.9                # max radians a snake turns per step (wiggle)
const ANOMALY_SYSTEM_CLEARANCE := 30.0   # keep the band this far off any system
const ANOMALY_CORRIDOR := 190.0          # guaranteed clear gap between any two storm BODIES,
                                         # so storms can never chain into a wall that splits the
                                         # map — there's always a corridor to route influence/
                                         # fleets through (storms are tactical, not barriers)
