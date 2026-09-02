class_name Empire
extends RefCounted

# An empire is any population-driving actor — human or AI, same rules, same
# code paths (multiplayer-shaped by design; no player-only special cases).
#
# Economy: MINERALS are the one banked raw resource (mined), refined up the single
# ALLOY tier chain nat[0..4] = T1..T5 (also banked; T1 is the construction currency).
# WATER is population's need and a FLOW — not banked: water_income vs water_demand
# each tick decides whether population grows or shrinks (see Sim.tick).

var id: int = -1
var name: String = ""
var color: Color = Color.WHITE

var minerals: float = SimConstants.START_MINERALS
# Alloy tiers 1-5 (index 0-4), refined in cities. nat[0] (T1) also pays for building.
var nat: Array[float] = [SimConstants.START_NAT0, 0.0, 0.0, 0.0, 0.0]
# Lifetime alloy paid out on purchases (ships/structures), per tier. Monotonic, never
# banked back — the HUD adds it to the stockpile so displayed income rates reflect
# PRODUCTION only (buying a ship must not read as negative income). Not serialized:
# only differences over a few days matter, and the rate window rebuilds after load.
var spent_nat: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
# Water flow this tick (recomputed every tick — display/growth only, never banked).
var water_income: float = 0.0    # water produced by this empire's mines this tick
var water_demand: float = 0.0    # water its whole population needs this tick
# Production multiplier — 1.0 for the player; AI empires scale by difficulty.
var efficiency: float = 1.0
