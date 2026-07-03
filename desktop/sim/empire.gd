class_name Empire
extends RefCounted

# An empire is any population-driving actor — human or AI, same rules, same
# code paths (multiplayer-shaped by design; no player-only special cases).
#
# Four stockpiles: two T0 raw (water, minerals) filled by mines, two T1 goods
# (food, alloys) refined by established cities. Food drives population; alloys
# pay for construction.

var id: int = -1
var name: String = ""
var color: Color = Color.WHITE

var water: float = SimConstants.START_WATER
var minerals: float = SimConstants.START_MINERALS
var food: float = SimConstants.START_FOOD
var alloys: float = SimConstants.START_ALLOYS
# National military resources, tiers 1-5 (index 0-4), refined in cities.
var nat: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
# Production multiplier — 1.0 for the player; AI empires scale by difficulty.
var efficiency: float = 1.0
