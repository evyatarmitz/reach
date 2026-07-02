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
	var sys := sim.add_system("Meridian")
	var radii := [70.0, 115.0, 165.0, 220.0]
	var angles := [0.7, 2.4, 4.1, 5.5]
	for i in radii.size():
		var p := sim.add_planet(sys.id, "Meridian %s" % ["I", "II", "III", "IV"][i])
		p.orbit_radius = radii[i]
		p.orbit_angle = angles[i]
	return sim


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


func tick(dt_days: float) -> void:
	day += dt_days
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
			goods += c.production_per_day() * dt_days
