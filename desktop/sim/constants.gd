class_name SimConstants
extends RefCounted

# Every value here is a "tune until it feels right" placeholder (see CLAUDE.md,
# "A note on numbers"). The SHAPES they parameterize — uncapped-but-self-limiting
# growth, drain-that-tapers activation — are the design and must be preserved.

# One sim tick advances this many in-game days. Fixed tick size keeps the sim
# deterministic; the speed dial changes how many ticks run per real second.
const TICK_DAYS := 0.1

# National stockpile at game start (tier-0 "raw").
const START_RAW := 500.0

# Colony founding: flat, repeatable cost (vision.md).
const FOUND_COST := 100.0
const START_POP := 10.0

# Unestablished colonies drain this much raw per day; after activation the same
# base decays exponentially with this half-life-ish taper (drain-that-tapers).
const COLONY_UPKEEP_BASE := 2.0
const UPKEEP_TAPER_DAYS := 30.0

# A colony activates (established, starts producing) at this population.
const ACTIVATION_POP := 100.0

# Growth: dpop/day = GROWTH_RATE * pop / (1 + (pop/GROWTH_SOFTCAP)^GROWTH_EXP).
# Never a hard cap — growth only asymptotically flattens. The neighbor bonus
# (later) multiplies the rate, which is the designed way past the flattening.
const GROWTH_RATE := 0.08
const GROWTH_SOFTCAP := 500.0
const GROWTH_EXP := 2.0

# Mining: the only raw income. A mine sits on a deposit planet within reach.
const MINE_COST := 50.0
const MINE_RAW_PER_DAY := 5.0

# Tier-1 production of an established colony: goods/day = PROD_COEF * pop^PROD_EXP,
# but every good consumes GOODS_RAW_PER_GOOD raw — production is throughput-limited
# by real resource input (anti-snowball pillar), never by theoretical maximums.
const PROD_COEF := 0.05
const PROD_EXP := 0.8
const GOODS_RAW_PER_GOOD := 2.0

# Influence (vision.md core formulas — not used by this slice yet, pinned here so
# the constants exist next to their siblings): influence = A1 * pop_count,
# uncontested border_length = A2 * influence.
const INFLUENCE_A1 := 1.0
const BORDER_A2 := 1.0
