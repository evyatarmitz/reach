class_name StarSystem
extends RefCounted

# Topology node. Lanes (edges between systems) live on Sim; a system knows its
# own planets only. Single-system slice for now, but the shape is the real one.

var id: int = -1
var name: String = ""
var planet_ids: Array[int] = []

# Position on the galaxy map. Layout AND the distance metric for the
# influence/neighbor-bonus math — systems are points, distance is euclidean.
var map_pos: Vector2 = Vector2.ZERO
var depot_empire_id: int = -1     # supply depot owner (-1 = none)
var obs_post_empire_id: int = -1  # observation post owner: doubles influence reach
                                  # here + extends visibility (early warning)
var imperial_empire_id: int = -1  # imperial center owner: amplifies this system's colony
                                  # influence for extra water (see IMPERIAL_BONUS)
var imperial_level: int = 0       # 0 = none; 1..IMPERIAL_MAX_LEVEL once built/upgraded
var imperial_charge: float = 0.0  # 0..1 spin-up of the center: the effective influence bonus
                                  # is base(level) * this. Winds UP while the level's tier alloy
                                  # is affordably fed, DOWN while starved — symmetric ramp over
                                  # IMPERIAL_RAMP_DAYS, so dialing a level you can't feed grants
                                  # nothing (no instant bonus), and a fed center fades in slowly.
var citadel_empire_id: int = -1   # citadel owner (-1 = none): a massive-HP chokepoint that
                                  # blocks enemy fleets from passing until it's bombarded down
var citadel_hp: float = 0.0       # remaining citadel hull; standing while > 0
