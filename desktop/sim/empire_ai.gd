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
	_move_fleets(sim)


# Build the highest tier it can afford (alternating fighter/bomber), for defence.
func _build_ships(sim: Sim) -> void:
	for tier in [5, 4, 3, 2, 1]:
		if sim.can_build_ship(empire_id, tier):
			var role: int = SimConstants.Role.FIGHTER if _build_count % 2 == 0 \
				else SimConstants.Role.BOMBER
			sim.build_ship(empire_id, role, tier)
			_build_count += 1
			return


# Send a stationary fleet to the nearest enemy-owned adjacent system (attack), or
# hold. Only commits a fleet that actually has ships. Deterministic (sorted).
func _move_fleets(sim: Sim) -> void:
	for f in sim.fleets:
		if f.empire_id != empire_id or f.is_moving() or f.ship_count() == 0:
			continue
		var targets: Array = sim.lane_neighbors(f.system_id)
		targets.sort()
		for nb in targets:
			if sim._has_enemy_colony(empire_id, nb):
				sim.order_fleet(f.id, nb)
				break
		return   # one fleet order per interval


func _build_one_mine(sim: Sim) -> void:
	# Income first. Lowest planet id wins for determinism.
	var best := -1
	for pid in _sorted_planet_ids(sim):
		if sim.can_build_mine(empire_id, pid):
			best = pid
			break
	if best != -1:
		sim.build_mine(empire_id, best)


func _found_one_colony(sim: Sim) -> void:
	# Prefer an empty planet in a system where we have no colony yet — spreading
	# into new systems is what grows influence and unlocks the neighbor bonus.
	# Fall back to any colonizable planet. Lowest id breaks ties (deterministic).
	var expansion := -1
	var fallback := -1
	for pid in _sorted_planet_ids(sim):
		if not sim.can_found_colony(empire_id, pid):
			continue
		if fallback == -1:
			fallback = pid
		var sys_id: int = sim.planets[pid].system_id
		if not _has_colony_in_system(sim, sys_id):
			expansion = pid
			break
	var target := expansion if expansion != -1 else fallback
	if target != -1:
		sim.found_colony(empire_id, target)


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
