class_name Planet
extends RefCounted

var id: int = -1
var system_id: int = -1
var name: String = ""
var colony: Colony = null
var deposit_type: int = SimConstants.Deposit.NONE  # NONE / WATER / MINERAL
var mine_empire_id: int = -1  # -1 = no mine; otherwise the owning empire
var mine_level: int = 0        # upgrade level; each adds MINE_UPGRADE_STEP output

# Layout data for rendering — the sim itself never does physics with these.
var orbit_radius: float = 0.0
var orbit_angle: float = 0.0


func has_deposit() -> bool:
	return deposit_type != SimConstants.Deposit.NONE


func has_mine() -> bool:
	return mine_empire_id != -1


# This deposit's true output/day — deterministic per planet (no RNG), constant
# over time, varying between deposits.
func mine_output() -> float:
	var n: float = abs(sin(id * 12.9898 + 78.233))
	var base: float = SimConstants.MINE_RICHNESS_MIN \
		+ n * (SimConstants.MINE_RICHNESS_MAX - SimConstants.MINE_RICHNESS_MIN)
	return base * (1.0 + mine_level * SimConstants.MINE_UPGRADE_STEP)


# The pre-build estimate: the ESTIMATE_BAND-wide bracket the true output falls in
# (e.g. 30-45). Returns [low, high].
func output_estimate() -> Vector2:
	var band: float = SimConstants.ESTIMATE_BAND
	var low: float = floor(mine_output() / band) * band
	return Vector2(low, low + band)
