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
var ais: Array[EmpireAI] = []  # rival brains; step deterministically in tick()

var _next_id := 1


# Deterministic COLS x ROWS grid map — a big testbed (50 systems) so influence
# and border behavior has room to show. NOT the eventual procedural generator
# (that comes later); just a larger hand-parameterized map. No RNG: jitter is
# index-based sin so runs stay bit-identical.
const MAP_COLS := 10
const MAP_ROWS := 5
const _SYL_A := ["Ka", "Me", "Or", "Ve", "Ta", "Sy", "Lo", "Ne", "Ro", "Ai"]
const _SYL_B := ["ron", "dis", "lex", "mos", "tia", "var", "nyx", "del"]


static func _system_name(idx: int) -> String:
	# Unique for idx 0..79: prefix cycles every 10, suffix every 80.
	return _SYL_A[idx % _SYL_A.size()] + _SYL_B[(idx / _SYL_A.size()) % _SYL_B.size()]


static func new_demo() -> Sim:
	var sim := Sim.new()
	var numerals := ["I", "II", "III", "IV"]
	var radii := [70.0, 115.0, 165.0, 220.0]
	var grid: Array[int] = []  # system id per grid index, row-major
	for row in MAP_ROWS:
		for col in MAP_COLS:
			var idx := row * MAP_COLS + col
			var sys := sim.add_system(_system_name(idx))
			sys.map_pos = Vector2(160.0 + col * 200.0, 150.0 + row * 190.0) \
				+ Vector2(sin(idx * 12.9898) * 30.0, sin(idx * 4.1414) * 24.0)
			grid.append(sys.id)
			var planet_count := 2 + idx % 3
			for pi in planet_count:
				var p := sim.add_planet(sys.id, "%s %s" % [sys.name, numerals[pi]])
				p.orbit_radius = radii[pi]
				p.orbit_angle = fmod(0.9 + pi * 1.9 + idx * 1.3, TAU)
				p.has_deposit = (idx + pi) % 3 == 0
	# Lanes: grid adjacency (right, down) + a down-right diagonal for chokepoint
	# variety. Right/down adjacency guarantees a fully connected graph.
	for row in MAP_ROWS:
		for col in MAP_COLS:
			var here: int = grid[row * MAP_COLS + col]
			if col + 1 < MAP_COLS:
				sim.add_lane(here, grid[row * MAP_COLS + col + 1])
			if row + 1 < MAP_ROWS:
				sim.add_lane(here, grid[(row + 1) * MAP_COLS + col])
			if col + 1 < MAP_COLS and row + 1 < MAP_ROWS and idx_even(col, row):
				sim.add_lane(here, grid[(row + 1) * MAP_COLS + col + 1])
	# Two empires at opposite corners; both homeworlds get a deposit so each can
	# mine at home. By convention the first empire is the one the UI controls.
	var player_home_sys: int = grid[0]                      # top-left
	var rival_home_sys: int = grid[grid.size() - 1]         # bottom-right
	var player := sim.add_empire(
		"%s Compact" % sim.systems[player_home_sys].name, Color(0.35, 0.8, 1.0))
	var rival := sim.add_empire(
		"%s Ascendancy" % sim.systems[rival_home_sys].name, Color(1.0, 0.4, 0.35))
	for sys_id in [player_home_sys, rival_home_sys]:
		sim.planets[sim.systems[sys_id].planet_ids[0]].has_deposit = true
	var home := sim.inject_colony(player.id,
		sim.systems[player_home_sys].planet_ids[0], 150.0, true)
	home.days_since_established = 60.0
	var rival_home := sim.inject_colony(rival.id,
		sim.systems[rival_home_sys].planet_ids[0], 150.0, true)
	rival_home.days_since_established = 60.0
	# Rival plays under the same rules; the border between them is a live
	# contest, not scripted.
	sim.add_ai(rival.id)
	return sim


static func idx_even(col: int, row: int) -> bool:
	return (col + row) % 2 == 0


func add_ai(empire_id: int) -> void:
	ais.append(EmpireAI.new(empire_id))


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


# --- influence field (deformed borders) --------------------------------------
# The border between empires is the boundary of a scalar field, sampled by the
# renderer. At any world point, an empire's claim combines its sources that
# REACH the point: influences ADD (friction/gang-up across systems) while the
# effective distance is their influence-weighted mean. Range never adds — a
# source only contributes within its own reach A2*i, so non-overlapping bubbles
# leave neutral space between them and only overlapping ones form a border.
# Within a system, sources are already collapsed to the max (system_influence),
# so same-system colonies don't stack; only different systems add.
func empire_claim_at(pos: Vector2, empire_id: int) -> float:
	var sum_i := 0.0
	var sum_ri := 0.0
	for sys in systems.values():
		var inf := system_influence(sys.id, empire_id)
		if inf <= 0.0:
			continue
		var d := pos.distance_to(sys.map_pos)
		if d > SimConstants.BORDER_A2 * inf:   # reach-gated: bubble radius
			continue
		sum_i += inf
		sum_ri += d * inf
	if sum_i <= 0.0:
		return 0.0
	var r_comb := sum_ri / sum_i
	if r_comb <= 0.0:
		return INF   # exactly on a source
	return sum_i / r_comb


# Which empire holds a world point (-1 if none reaches it). Free space in reach
# of a single empire is claimed; where two overlap, the stronger combined claim
# wins and the boundary sits at r1/r2 = i1/i2.
func point_owner(pos: Vector2) -> int:
	var best := -1
	var best_claim := 0.0
	for e in empires.values():
		var c := empire_claim_at(pos, e.id)
		if c > best_claim:
			best_claim = c
			best = e.id
	return best


# --- neighbor bonus (vision.md: cluster-across-systems) ----------------------

# Growth multiplier for a colony from same-empire established centers in OTHER
# systems, 1/R falloff, summed (compounding). Same-system centers give nothing —
# they compete via influence instead. This is what lets a clustered colony grow
# past the diminishing-returns wall an isolated one hits.
func neighbor_growth_multiplier(colony: Colony) -> float:
	var sys_id: int = planets[colony.planet_id].system_id
	var bonus := 0.0
	for other in colonies:
		if other == colony or other.empire_id != colony.empire_id \
				or not other.established:
			continue
		var other_sys: int = planets[other.planet_id].system_id
		if other_sys == sys_id:
			continue
		var r := system_distance(sys_id, other_sys)
		if r > 0.0:
			bonus += other.population / r
	return 1.0 + SimConstants.NEIGHBOR_COEF * bonus


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
	# Rival decisions run on their own day-cadence, before the economy advances.
	for ai in ais:
		ai.maybe_act(self)
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

		c.population += Colony.growth_per_day(c.population) * supplied \
			* neighbor_growth_multiplier(c) * dt_days

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
