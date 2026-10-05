class_name EmpireAI
extends RefCounted

# A rival empire's brain. Critically, it acts ONLY through the same public
# command methods and gating the player uses (found_colony / build_mine) — there
# are no AI-only shortcuts. It is a pure, deterministic function of sim state:
# no RNG, fixed iteration order, so identical runs stay bit-identical.

var empire_id: int = -1
var personality: int = SimConstants.Personality.BALANCED
var cadence: float = 1.0    # difficulty-derived think-interval multiplier (>1 = slower)
var _next_action_day: float = 0.0
var _build_count: int = 0   # alternates fighter/bomber deterministically


func _init(id: int, persona: int = SimConstants.Personality.BALANCED,
		think_cadence: float = 1.0) -> void:
	empire_id = id
	personality = persona
	cadence = think_cadence


func _persona() -> Dictionary:
	return SimConstants.AI_PERSONA[personality]


func maybe_act(sim: Sim) -> void:
	if sim.day < _next_action_day:
		return
	# Think interval = base x difficulty cadence x personality cadence. A lower-
	# difficulty rival (bigger cadence) acts less often, so it can't micro everything
	# at once -- it reads as a distracted human, not just a poorer one.
	_next_action_day = sim.day + SimConstants.AI_ACTION_INTERVAL_DAYS \
		* cadence * float(_persona()["cadence"])
	_act(sim)


func _act(sim: Sim) -> void:
	# One mine + the personality's expansion quota per interval, keeping growth gradual.
	_build_one_mine(sim)
	_found_colonies(sim)
	_build_ships(sim)
	_build_support(sim)
	_move_fleets(sim)


# Dispatch this personality's colony quota this interval (expansionists push two).
# Each call re-scans, so the second skips the planet the first just targeted.
func _found_colonies(sim: Sim) -> void:
	for _i in int(_persona()["colonies"]):
		_found_one_colony(sim)


# Support structures, same options the player has (built instantly in own influence).
# Priority: an imperial center at the capital (and its upgrades — buys influence by
# burning alloy), then an observation post on a frontier system (early warning + border
# push). One per interval, only with spare alloys — expansion/defence come first.
func _build_support(sim: Sim) -> void:
	var cap := sim.most_populated_system(empire_id)
	# An imperial center at the capital, upgraded only while the NEXT tier's alloy is
	# comfortably stocked and debt-free — so the AI buys influence it can actually feed
	# instead of over-dialing the level and starving its own fleet of high-tier alloy.
	if cap != -1:
		if sim.systems[cap].imperial_empire_id == -1 \
				and sim.can_build_imperial(empire_id, cap):
			sim.build_imperial(empire_id, cap)
			return
		if sim.can_upgrade_imperial(empire_id, cap):
			var e: Empire = sim.empires[empire_id]
			var next_tier: int = sim.systems[cap].imperial_level   # level L -> next tier index L
			if next_tier < 5 and e.nat[next_tier] >= SimConstants.IMPERIAL_ALLOY_DRAIN \
					* SimConstants.AI_IMPERIAL_STOCK_DAYS:
				sim.upgrade_imperial(empire_id, cap)
				return
	for sid in _owned_systems_sorted(sim):
		if sim.systems[sid].obs_post_empire_id != -1:
			continue
		var frontier := false
		for nb in sim.lane_neighbors(sid):
			if sim._has_enemy_colony(empire_id, nb):
				frontier = true
				break
		if frontier and sim.can_build_obs_post(empire_id, sid):
			sim.build_obs_post(empire_id, sid)
			return


func _owned_systems_sorted(sim: Sim) -> Array:
	var ids: Array = []
	for sid in sim.systems:
		if _has_colony_in_system(sim, sid):
			ids.append(sid)
	ids.sort()
	return ids


# Build the highest tier it can afford (alternating fighter/bomber), for defence.
func _build_ships(sim: Sim) -> void:
	for tier in [5, 4, 3, 2, 1]:
		if sim.can_build_ship(empire_id, tier):
			var role: int = SimConstants.Role.FIGHTER if _build_count % 2 == 0 \
				else SimConstants.Role.BOMBER
			sim.build_ship(empire_id, role, tier)
			_build_count += 1
			return


# Consolidate scattered fleets into single stacks, then act — DEFENCE FIRST (pull a
# stack home to relieve a colony under attack), and only if nothing's threatened,
# attack an adjacent enemy colony it can win (undefended, or it out-powers the
# defenders), or march a decisive massed force to the nearest enemy colony. One order
# per interval, so a live home threat always pre-empts an offensive move.
func _move_fleets(sim: Sim) -> void:
	_consolidate(sim)
	if _defend(sim):
		return
	var p := _persona()
	var aggressive: bool = bool(p["aggressive"])
	# How much massed power a stack needs before it marches out to the nearest enemy.
	# Raiders commit at ~a third of a ceiling stack; a turtle (march = INF) never leaves.
	var march_at: float = SimConstants.POWER_CEILING * float(p["march"])
	for f in sim.fleets:
		if f.empire_id != empire_id or f.is_moving() or f.ship_count() == 0:
			continue
		var target := _best_attack_target(sim, f, aggressive)
		if target != -1:
			sim.order_fleet(f.id, target)
		elif f.combat_power() >= march_at:
			# No easy adjacent target, but the stack has massed to this personality's
			# commit threshold — march it to the nearest enemy colony (it fights its way
			# there). This is what gets the AI's fleets into the war, as committed strikes
			# rather than a trickle that gets worn down.
			var dest := _nearest_enemy_colony(sim, f.system_id)
			if dest != -1:
				sim.order_fleet(f.id, dest)
		return   # one fleet order per interval


# Relieve a colony under attack. A colony system is "threatened" when an enemy fleet
# with ships is sitting on it (active siege) or is inbound (its move ends there) AND we
# have no stationary fleet there already contesting it. We relieve the highest-stakes
# threatened system (most of our population at risk) with our nearest idle stack that
# can actually route there. Returns true if it issued a defensive order.
#
# This is what stops a rival's colonies falling for free: before, the AI only ever
# pushed outward and let its own worlds be bombarded unanswered. It never gives the AI
# a shortcut — it still moves through order_fleet like the player, so the FTL-inhibitor
# pin, lane routing and border rules all apply.
func _defend(sim: Sim) -> bool:
	var best_sys := -1
	var best_pop := -1.0
	for sid in _owned_systems_sorted(sim):   # ascending id -> deterministic tie-break
		if _friendly_fleet_in(sim, sid):
			continue   # a defender is already contesting this system
		if not _system_under_threat(sim, sid):
			continue
		var pop := _own_population_in(sim, sid)
		if pop > best_pop:
			best_pop = pop
			best_sys = sid
	if best_sys == -1:
		return false
	# Our nearest idle stack by lane hops (topology distance); ties break on fleet id.
	# Unreachable fleets are dropped. Dispatch the first whose order is accepted (a
	# nearer stack may be blocked by enemy territory, so fall through to the next).
	var candidates: Array = []
	for f in sim.fleets:
		if f.empire_id != empire_id or f.is_moving() or f.ship_count() == 0:
			continue
		if f.system_id == best_sys:
			continue
		var h := _hops(sim, f.system_id, best_sys)
		if h < 0:
			continue
		candidates.append({"id": f.id, "hops": h})
	candidates.sort_custom(func(a, b):
		if a["hops"] != b["hops"]:
			return a["hops"] < b["hops"]
		return a["id"] < b["id"])
	for c in candidates:
		if sim.order_fleet(c["id"], best_sys):
			return true
	return false


func _friendly_fleet_in(sim: Sim, system_id: int) -> bool:
	for f in sim.fleets:
		if f.empire_id == empire_id and not f.is_moving() \
				and f.system_id == system_id and f.ship_count() > 0:
			return true
	return false


# An enemy stack sitting on this system (siege) or inbound to it (its path ends here).
func _system_under_threat(sim: Sim, system_id: int) -> bool:
	for f in sim.fleets:
		if f.empire_id == empire_id or f.ship_count() == 0:
			continue
		if not f.is_moving() and f.system_id == system_id:
			return true
		if f.is_moving() and not f.path.is_empty() \
				and f.path[f.path.size() - 1] == system_id:
			return true
	return false


func _own_population_in(sim: Sim, system_id: int) -> float:
	var total := 0.0
	for pid in sim.systems[system_id].planet_ids:
		var c: Colony = sim.planets[pid].colony
		if c != null and c.empire_id == empire_id:
			total += c.population
	return total


# Lane-topology hop distance a->b (BFS, ignores enemy blocking — a routing heuristic
# for ranking; order_fleet does the real reachability check). -1 if disconnected.
func _hops(sim: Sim, from_sys: int, to_sys: int) -> int:
	if from_sys == to_sys:
		return 0
	var dist := {from_sys: 0}
	var queue: Array = [from_sys]
	while not queue.is_empty():
		var s: int = queue.pop_front()
		var nbs: Array = sim.lane_neighbors(s)
		nbs.sort()
		for nb in nbs:
			if dist.has(nb):
				continue
			dist[nb] = dist[s] + 1
			if nb == to_sys:
				return dist[nb]
			queue.append(nb)
	return -1


# Nearest enemy-colony system by lane hops (BFS). -1 if none reachable. Sorted
# neighbours keep it deterministic.
func _nearest_enemy_colony(sim: Sim, from_sys: int) -> int:
	var seen := {from_sys: true}
	var queue: Array = [from_sys]
	while not queue.is_empty():
		var s: int = queue.pop_front()
		if s != from_sys and sim._has_enemy_colony(empire_id, s):
			return s
		var nbs: Array = sim.lane_neighbors(s)
		nbs.sort()
		for nb in nbs:
			if not seen.has(nb):
				seen[nb] = true
				queue.append(nb)
	return -1


# Merge this empire's stationary fleets that share a system into one stack.
func _consolidate(sim: Sim) -> void:
	var keep_by_sys := {}
	for f in sim.fleets:
		if f.empire_id == empire_id and not f.is_moving() \
				and not keep_by_sys.has(f.system_id):
			keep_by_sys[f.system_id] = f.id
	for sid in keep_by_sys:
		sim.merge_fleets_into(keep_by_sys[sid])


# The WEAKEST adjacent enemy-colony system this fleet can take — undefended (bombard
# freely) or, when aggressive, where our combat power beats the defenders'. A cautious
# (turtle) stack only grabs UNDEFENDED neighbours and never trades blows for ground.
# Picking the softest target (least defending power) over the lowest id means the stack
# secures the fastest kill and keeps moving instead of grinding the first colony it
# happens to border. Ties break on lowest id (deterministic). -1 = hold and keep massing.
func _best_attack_target(sim: Sim, f: Fleet, aggressive: bool) -> int:
	var mine: float = f.combat_power()
	var targets: Array = sim.lane_neighbors(f.system_id)
	targets.sort()
	var best := -1
	var best_def := INF
	for nb in targets:
		if not sim._has_enemy_colony(empire_id, nb):
			continue
		var powers: Dictionary = sim.fleet_powers_in(nb)
		var def := 0.0
		for eid in powers:
			if eid != empire_id:
				def += powers[eid].combat
		if def <= 0.0 or (aggressive and mine > def):
			if def < best_def:   # strict < keeps the first (lowest-id) of equal-defence ties
				best_def = def
				best = nb
	return best


func _build_one_mine(sim: Sim) -> void:
	# Income first. Lowest planet id wins for determinism. Dispatch a construction
	# vessel (same path as the player); skip planets already targeted in transit.
	for pid in _sorted_planet_ids(sim):
		if not _targeted(sim, pid, SimConstants.Build.MINE) \
				and sim.can_order_construction(empire_id, SimConstants.Build.MINE, pid):
			sim.order_construction(empire_id, SimConstants.Build.MINE, pid)
			return


func _found_one_colony(sim: Sim) -> void:
	# Prefer an empty planet in a system where we have no colony yet — spreading
	# into new systems is what grows influence and unlocks the neighbor bonus.
	# Fall back to any colonizable planet. Lowest id breaks ties (deterministic).
	# Dispatched via a construction vessel; skip planets already in transit.
	var expansion := -1
	var fallback := -1
	for pid in _sorted_planet_ids(sim):
		if _targeted(sim, pid, SimConstants.Build.COLONY) \
				or not sim.can_order_construction(empire_id, SimConstants.Build.COLONY, pid):
			continue
		if fallback == -1:
			fallback = pid
		var sys_id: int = sim.planets[pid].system_id
		if not _has_colony_in_system(sim, sys_id):
			expansion = pid
			break
	var target := expansion if expansion != -1 else fallback
	if target != -1:
		sim.order_construction(empire_id, SimConstants.Build.COLONY, target)


# Is a planet already the destination of one of this empire's in-flight vessels of
# the given build type? (A colony and a mine vessel may target the same planet.)
func _targeted(sim: Sim, planet_id: int, build_type: int) -> bool:
	for b in sim.builders:
		if b.eid == empire_id and b.target == planet_id and b.type == build_type:
			return true
	return false


func _has_colony_in_system(sim: Sim, system_id: int) -> bool:
	for pid in sim.systems[system_id].planet_ids:
		var c: Colony = sim.planets[pid].colony
		if c != null and c.empire_id == empire_id:
			return true
	return false


func _sorted_planet_ids(sim: Sim) -> Array:
	var ids: Array = sim.planets.keys()
	ids.sort()
	return ids
