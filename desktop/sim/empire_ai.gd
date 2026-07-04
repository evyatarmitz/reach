class_name EmpireAI
extends RefCounted

# A rival empire's brain. Critically, it acts ONLY through the same public
# command methods and gating the player uses (found_colony / build_mine) — there
# are no AI-only shortcuts. It is a pure, deterministic function of sim state:
# no RNG, fixed iteration order, so identical runs stay bit-identical.

var empire_id: int = -1
var _next_action_day: float = 0.0
var _build_count: int = 0   # alternates fighter/bomber deterministically


func _init(id: int) -> void:
	empire_id = id


func maybe_act(sim: Sim) -> void:
	if sim.day < _next_action_day:
		return
	_next_action_day = sim.day + SimConstants.AI_ACTION_INTERVAL_DAYS
	_act(sim)


func _act(sim: Sim) -> void:
	# One mine and one colony per interval, keeping expansion gradual.
	_build_one_mine(sim)
	_found_one_colony(sim)
	_build_ships(sim)
	_build_support(sim)
	_move_fleets(sim)


# Support structures, same options the player has (built instantly in own influence).
# Priority: a transport hub at the capital (lifts the core cluster's growth), then
# an observation post on a frontier system (early warning + border push). One per
# interval, only with spare alloys — expansion/defence come first (called after them).
func _build_support(sim: Sim) -> void:
	var cap := sim.most_populated_system(empire_id)
	if cap != -1 and sim.systems[cap].transport_empire_id == -1 \
			and sim.can_build_transport(empire_id, cap):
		sim.build_transport(empire_id, cap)
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


# Consolidate scattered fleets into single stacks, then send a stack to attack an
# adjacent enemy colony ONLY when it can win (undefended, or it out-powers the
# defenders) — so the AI fights as a massed force and stops throwing ships away.
func _move_fleets(sim: Sim) -> void:
	_consolidate(sim)
	for f in sim.fleets:
		if f.empire_id != empire_id or f.is_moving() or f.ship_count() == 0:
			continue
		var target := _best_attack_target(sim, f)
		if target != -1:
			sim.order_fleet(f.id, target)
		return   # one fleet order per interval


# Merge this empire's stationary fleets that share a system into one stack.
func _consolidate(sim: Sim) -> void:
	var keep_by_sys := {}
	for f in sim.fleets:
		if f.empire_id == empire_id and not f.is_moving() \
				and not keep_by_sys.has(f.system_id):
			keep_by_sys[f.system_id] = f.id
	for sid in keep_by_sys:
		sim.merge_fleets_into(keep_by_sys[sid])


# Lowest-id adjacent enemy-colony system this fleet can take: undefended (bombard
# freely) or where our combat power beats the defenders'. -1 = hold and keep massing.
func _best_attack_target(sim: Sim, f: Fleet) -> int:
	var mine: float = f.combat_power()
	var targets: Array = sim.lane_neighbors(f.system_id)
	targets.sort()
	for nb in targets:
		if not sim._has_enemy_colony(empire_id, nb):
			continue
		var powers: Dictionary = sim.fleet_powers_in(nb)
		var def := 0.0
		for eid in powers:
			if eid != empire_id:
				def += powers[eid].combat
		if def <= 0.0 or mine > def:
			return nb
	return -1


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
