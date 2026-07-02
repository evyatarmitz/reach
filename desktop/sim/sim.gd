class_name Sim
extends RefCounted

# The simulation core. Engine-agnostic on purpose: no Node, no rendering, no
# input — plain data advanced by tick(). Godot (or any future engine) reads
# state and calls the command methods. Keep it that way; the engine is
# provisional, this module is not.
#
# There is deliberately no "player" concept in here — every empire, human or
# AI, acts through the same command methods under the same gating.

var day: float = 0.0

var empires: Dictionary = {}   # id -> Empire
var systems: Dictionary = {}   # id -> StarSystem
var planets: Dictionary = {}   # id -> Planet
var lanes: Array = []          # [system_id, system_id] pairs
var colonies: Array[Colony] = []

var _next_id := 1


static func new_demo() -> Sim:
	var sim := Sim.new()
	# [name, map position, planet count]. Hand-authored, deterministic.
	var defs := [
		["Meridian", Vector2(250, 360), 4],
		["Harrow", Vector2(450, 220), 3],
		["Cinder", Vector2(470, 500), 2],
		["Vale", Vector2(660, 340), 3],
		["Tessa", Vector2(850, 200), 3],
		["Oro", Vector2(880, 480), 2],
		["Locke", Vector2(1080, 350), 4],
	]
	var numerals := ["I", "II", "III", "IV"]
	var radii := [70.0, 115.0, 165.0, 220.0]
	for si in defs.size():
		var sys := sim.add_system(defs[si][0])
		sys.map_pos = defs[si][1]
		for pi in int(defs[si][2]):
			var p := sim.add_planet(sys.id, "%s %s" % [sys.name, numerals[pi]])
			p.orbit_radius = radii[pi]
			p.orbit_angle = fmod(0.9 + pi * 1.9 + si * 1.3, TAU)
			# Scattered deterministically; guarantees the home system's first
			# planet has one.
			p.has_deposit = (si + pi) % 3 == 0
	var sys_ids: Array = sim.systems.keys()
	for l in [[0, 1], [0, 2], [1, 3], [2, 3], [1, 4], [3, 4], [3, 5], [2, 5],
			[4, 6], [5, 6]]:
		sim.add_lane(sys_ids[l[0]], sys_ids[l[1]])
	# By convention the demo's first empire is the one the UI controls.
	var player := sim.add_empire("Meridian Compact", Color(0.35, 0.8, 1.0))
	var home := sim.inject_colony(player.id,
		sim.systems[sys_ids[0]].planet_ids[0], 150.0, true)
	home.days_since_established = 60.0
	return sim


# --- construction -----------------------------------------------------------

func add_empire(empire_name: String, color: Color) -> Empire:
	var e := Empire.new()
	e.id = _next_id
	_next_id += 1
	e.name = empire_name
	e.color = color
	empires[e.id] = e
	return e


func add_system(system_name: String) -> StarSystem:
	var sys := StarSystem.new()
	sys.id = _next_id
	_next_id += 1
	sys.name = system_name
	systems[sys.id] = sys
	return sys


func add_planet(system_id: int, planet_name: String) -> Planet:
	var p := Planet.new()
	p.id = _next_id
	_next_id += 1
	p.system_id = system_id
	p.name = planet_name
	planets[p.id] = p
	systems[system_id].planet_ids.append(p.id)
	return p


func add_lane(a_system_id: int, b_system_id: int) -> void:
	lanes.append([a_system_id, b_system_id])


# Scenario/test loader — bypasses cost and influence gating deliberately.
# Game flow must use found_colony instead.
func inject_colony(empire_id: int, planet_id: int, pop: float,
		established: bool) -> Colony:
	var c := Colony.new()
	c.empire_id = empire_id
	c.planet_id = planet_id
	c.population = pop
	c.established = established
	planets[planet_id].colony = c
	colonies.append(c)
	return c


# --- topology ----------------------------------------------------------------

func lane_neighbors(system_id: int) -> Array[int]:
	var out: Array[int] = []
	for l in lanes:
		if l[0] == system_id:
			out.append(l[1])
		elif l[1] == system_id:
			out.append(l[0])
	return out


func system_distance(a_system_id: int, b_system_id: int) -> float:
	return systems[a_system_id].map_pos.distance_to(systems[b_system_id].map_pos)


# --- influence (vision.md core formulas) -------------------------------------

# Non-stacking: the strongest single center defines a system's influence —
# a second colony in the same system adds nothing here. That is the designed
# pressure to spread across systems.
func system_influence(system_id: int, empire_id: int) -> float:
	var best := 0.0
	for pid in systems[system_id].planet_ids:
		var c: Colony = planets[pid].colony
		if c != null and c.empire_id == empire_id:
			best = maxf(best, SimConstants.INFLUENCE_A1 * c.population)
	return best


func influence_reach(system_id: int, empire_id: int) -> float:
	return SimConstants.BORDER_A2 * system_influence(system_id, empire_id)


# Claim on a target system: max over own influence sources of influence/distance,
# counting only sources whose reach actually covers the target. Own presence in
# the target system is an absolute claim. The influence/distance form makes
# contested borders sit exactly where border1/border2 = influence1/influence2.
func claim_strength(target_system_id: int, empire_id: int) -> float:
	var best := 0.0
	for sys in systems.values():
		var inf := system_influence(sys.id, empire_id)
		if inf <= 0.0:
			continue
		if sys.id == target_system_id:
			return INF
		var d := system_distance(sys.id, target_system_id)
		if d <= influence_reach(sys.id, empire_id):
			best = maxf(best, inf / d)
	return best


# The live border contest: whoever holds the strongest claim owns the system
# right now. -1 = unclaimed. Ties go to the earliest-created empire
# (deterministic; proper shared-system contests come with combat).
func system_owner(system_id: int) -> int:
	var best_empire := -1
	var best := 0.0
	for e in empires.values():
		var s := claim_strength(system_id, e.id)
		if s > best:
			best = s
			best_empire = e.id
	return best_empire


func is_under_influence(system_id: int, empire_id: int) -> bool:
	return system_owner(system_id) == empire_id


# --- commands (same gating for every empire) ----------------------------------

func can_found_colony(empire_id: int, planet_id: int) -> bool:
	var p: Planet = planets.get(planet_id)
	var e: Empire = empires.get(empire_id)
	return p != null and e != null and p.colony == null \
		and e.raw >= SimConstants.FOUND_COST \
		and is_under_influence(p.system_id, empire_id)


func found_colony(empire_id: int, planet_id: int) -> bool:
	if not can_found_colony(empire_id, planet_id):
		return false
	empires[empire_id].raw -= SimConstants.FOUND_COST
	var c := inject_colony(empire_id, planet_id, SimConstants.START_POP, false)
	return c != null


func can_build_mine(empire_id: int, planet_id: int) -> bool:
	var p: Planet = planets.get(planet_id)
	var e: Empire = empires.get(empire_id)
	# "Wherever deposits exist within reach" — influence-gated, a colony in the
	# system is not required.
	return p != null and e != null and p.has_deposit and not p.has_mine() \
		and e.raw >= SimConstants.MINE_COST \
		and is_under_influence(p.system_id, empire_id)


func build_mine(empire_id: int, planet_id: int) -> bool:
	if not can_build_mine(empire_id, planet_id):
		return false
	empires[empire_id].raw -= SimConstants.MINE_COST
	planets[planet_id].mine_empire_id = empire_id
	return true


# --- tick ---------------------------------------------------------------------

func tick(dt_days: float) -> void:
	day += dt_days
	# Income first, so a tick's own mining output can feed its upkeep/production.
	for p in planets.values():
		if p.has_mine():
			empires[p.mine_empire_id].raw += SimConstants.MINE_RAW_PER_DAY * dt_days
	for c in colonies:
		var e: Empire = empires[c.empire_id]
		# Drain first: growth is throttled by how much of the upkeep was
		# actually covered, so an empty stockpile stalls colonies instead of
		# going negative.
		var need := c.upkeep_per_day() * dt_days
		var paid: float = minf(need, e.raw)
		e.raw -= paid
		var supplied := 1.0 if need <= 0.0 else paid / need

		c.population += Colony.growth_per_day(c.population) * supplied * dt_days

		if not c.established and c.population >= SimConstants.ACTIVATION_POP:
			c.established = true

		if c.established:
			c.days_since_established += dt_days
			# Production is capped by actual raw input, not by capacity.
			var raw_wanted := c.production_per_day() * dt_days \
				* SimConstants.GOODS_RAW_PER_GOOD
			var raw_used: float = minf(raw_wanted, e.raw)
			e.raw -= raw_used
			e.goods += raw_used / SimConstants.GOODS_RAW_PER_GOOD
