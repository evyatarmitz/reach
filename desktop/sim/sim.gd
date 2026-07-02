class_name Sim
extends RefCounted

# The simulation core. Engine-agnostic on purpose: no Node, no rendering, no
# input — plain data advanced by tick(). Godot (or any future engine) reads
# state and calls the command methods. Keep it that way; the engine is
# provisional, this module is not.

var day: float = 0.0
var raw: float = SimConstants.START_RAW
var goods: float = 0.0

var systems: Dictionary = {}   # id -> StarSystem
var planets: Dictionary = {}   # id -> Planet
var lanes: Array = []          # [system_id, system_id] pairs; empty in one-system slice
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
	return sim


func add_lane(a_system_id: int, b_system_id: int) -> void:
	lanes.append([a_system_id, b_system_id])


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


func can_found_colony(planet_id: int) -> bool:
	var p: Planet = planets.get(planet_id)
	return p != null and p.colony == null and raw >= SimConstants.FOUND_COST


func found_colony(planet_id: int) -> bool:
	if not can_found_colony(planet_id):
		return false
	var p: Planet = planets[planet_id]
	raw -= SimConstants.FOUND_COST
	var c := Colony.new()
	c.planet_id = planet_id
	c.population = SimConstants.START_POP
	p.colony = c
	colonies.append(c)
	return true


func system_has_colony(system_id: int) -> bool:
	for c in colonies:
		if planets[c.planet_id].system_id == system_id:
			return true
	return false


func can_build_mine(planet_id: int) -> bool:
	var p: Planet = planets.get(planet_id)
	# "Within reach" is a colony in the same system for now; becomes
	# influence-gated once influence bubbles exist.
	return p != null and p.has_deposit and not p.has_mine \
		and raw >= SimConstants.MINE_COST and system_has_colony(p.system_id)


func build_mine(planet_id: int) -> bool:
	if not can_build_mine(planet_id):
		return false
	raw -= SimConstants.MINE_COST
	planets[planet_id].has_mine = true
	return true


func tick(dt_days: float) -> void:
	day += dt_days
	# Income first, so a tick's own mining output can feed its upkeep/production.
	for p in planets.values():
		if p.has_mine:
			raw += SimConstants.MINE_RAW_PER_DAY * dt_days
	for c in colonies:
		# Drain first: growth is throttled by how much of the upkeep was
		# actually covered, so an empty stockpile stalls colonies instead of
		# going negative.
		var need := c.upkeep_per_day() * dt_days
		var paid: float = minf(need, raw)
		raw -= paid
		var supplied := 1.0 if need <= 0.0 else paid / need

		c.population += Colony.growth_per_day(c.population) * supplied * dt_days

		if not c.established and c.population >= SimConstants.ACTIVATION_POP:
			c.established = true

		if c.established:
			c.days_since_established += dt_days
			# Production is capped by actual raw input, not by capacity.
			var raw_wanted := c.production_per_day() * dt_days \
				* SimConstants.GOODS_RAW_PER_GOOD
			var raw_used: float = minf(raw_wanted, raw)
			raw -= raw_used
			goods += raw_used / SimConstants.GOODS_RAW_PER_GOOD
