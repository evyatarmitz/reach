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
var fleets: Array[Fleet] = []
var ais: Array[EmpireAI] = []  # rival brains; step deterministically in tick()
var combat_at: Dictionary = {} # system_id -> sim day of last combat (transient, for
                               # the renderer's clash flash; not serialized)
var combat_kind: Dictionary = {} # system_id -> 0 battle / 1 bombardment, THIS tick's
                               # active combat (rebuilt each tick; drives the live
                               # combat indicator + readout; not serialized)
var anomalies: Array = []      # [{pos: Vector2, r: float}] — cosmic anomalies that
                               # block influence AND visibility (you route around them)
var builders: Array = []       # construction vessels in transit: [{id, eid, sys,
                               # path:[sys...], prog, type, target:planet_or_system}]

var _next_id := 1


# Name syllables — combined by index for readable, unique system names.
const _SYL_A := ["Ka", "Me", "Or", "Ve", "Ta", "Sy", "Lo", "Ne", "Ro", "Ai",
	"Zu", "Cy", "Da", "Fe", "Gi", "Ha"]
const _SYL_B := ["ron", "dis", "lex", "mos", "tia", "var", "nyx", "del", "sor",
	"pel"]
const _EMPIRE_SUFFIX := ["Compact", "Ascendancy", "Union", "Dominion", "League",
	"Accord", "Pact", "Reach"]
const _EMPIRE_COLORS := [
	Color(0.35, 0.8, 1.0), Color(1.0, 0.4, 0.35), Color(0.5, 1.0, 0.45),
	Color(1.0, 0.82, 0.3), Color(0.75, 0.5, 1.0), Color(1.0, 0.6, 0.25)]


static func _system_name(idx: int) -> String:
	return _SYL_A[idx % _SYL_A.size()] + _SYL_B[(idx / _SYL_A.size()) % _SYL_B.size()]


# All procedural-generation knobs live here so future game-settings can override
# them. Passed straight into generate_map.
static func default_map_config() -> Dictionary:
	return {
		"seed": 20260702,
		"system_count": 50,
		"size": Vector2(2000.0, 1120.0),
		"empire_count": 4,
		"density_blobs": 5,       # heatmap: number of high-density clusters
		"density_spread": 360.0,  # heatmap: blob radius (bigger = smoother)
		"min_separation": 95.0,   # min distance between systems
		"extra_lane_neighbors": 2,# lanes beyond the spanning tree (loops/chokepoints)
		"ai_efficiency": 1.0,     # difficulty: AI production multiplier
	}


static func new_demo() -> Sim:
	return generate_map(default_map_config())


# Merge a partial config over the defaults, so the menu can pass only the knobs it
# changes (map size / empire count / difficulty) and the rest stay sensible.
static func _merged_config(cfg: Dictionary) -> Dictionary:
	var c := default_map_config()
	for k in cfg:
		c[k] = cfg[k]
	return c


# Procedural map: systems scattered by a variable-density heatmap, connected by a
# minimum spanning tree (guarantees NO disconnected parts) plus a few nearest-
# neighbor lanes for loops/chokepoints, then N empires placed far apart. Seeded
# RNG only — same config -> identical map, so the sim stays deterministic.
static func generate_map(cfg_in: Dictionary) -> Sim:
	var cfg := _merged_config(cfg_in)
	var sim := Sim.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = cfg.seed
	var size: Vector2 = cfg.size
	var numerals := ["I", "II", "III", "IV"]
	var radii := [70.0, 115.0, 165.0, 220.0]

	# Density heatmap = sum of Gaussian blobs; systems are placed where it's high.
	var blobs: Array = []
	for i in int(cfg.density_blobs):
		blobs.append(Vector2(rng.randf_range(0.0, size.x),
			rng.randf_range(0.0, size.y)))
	var spread: float = cfg.density_spread
	var min_sep: float = cfg.min_separation

	var positions: Array = []
	var target: int = cfg.system_count
	var attempts := 0
	while positions.size() < target and attempts < target * 500:
		attempts += 1
		var p := Vector2(rng.randf_range(0.0, size.x), rng.randf_range(0.0, size.y))
		var dens := 0.0
		for b in blobs:
			var d: float = p.distance_to(b)
			dens += exp(-(d * d) / (spread * spread))
		if rng.randf() > clampf(dens, 0.0, 1.0):
			continue   # weight placement by local density
		var ok := true
		for q in positions:
			if p.distance_to(q) < min_sep:
				ok = false
				break
		if ok:
			positions.append(p)

	var sys_ids: Array = []
	for i in positions.size():
		var sys := sim.add_system(_system_name(i))
		sys.map_pos = positions[i]
		sys_ids.append(sys.id)
		var pc := 2 + rng.randi_range(0, 2)
		for pi in pc:
			var pl := sim.add_planet(sys.id, "%s %s" % [sys.name, numerals[pi]])
			pl.orbit_radius = radii[pi]
			pl.orbit_angle = rng.randf_range(0.0, TAU)
			if rng.randf() < 0.35:
				pl.deposit_type = SimConstants.Deposit.WATER if rng.randf() < 0.5 \
					else SimConstants.Deposit.MINERAL

	_connect_systems(sim, sys_ids, positions, int(cfg.extra_lane_neighbors))
	_place_anomalies(sim, positions, size, rng)
	_place_empires(sim, sys_ids, positions, int(cfg.empire_count),
		float(cfg.ai_efficiency))
	return sim


# Scatter a few anomalies in open space — clear of every system and every lane, so
# they block influence/visibility without ever cutting the map or a fleet's route.
static func _place_anomalies(sim: Sim, positions: Array, size: Vector2,
		rng: RandomNumberGenerator) -> void:
	var target: int = clampi(int(positions.size() / 12),
		SimConstants.ANOMALY_MIN, SimConstants.ANOMALY_MAX)
	var attempts := 0
	while sim.anomalies.size() < target and attempts < target * 400:
		attempts += 1
		var r := rng.randf_range(SimConstants.ANOMALY_RADIUS_MIN,
			SimConstants.ANOMALY_RADIUS_MAX)
		var p := Vector2(rng.randf_range(r, size.x - r), rng.randf_range(r, size.y - r))
		var clear := true
		for q in positions:   # keep off systems
			if p.distance_to(q) < r + SimConstants.ANOMALY_SYSTEM_CLEARANCE:
				clear = false
				break
		if clear:
			for l in sim.lanes:   # keep off lanes (movement never blocked)
				var a: Vector2 = sim.systems[l[0]].map_pos
				var b: Vector2 = sim.systems[l[1]].map_pos
				var ab := b - a
				var len2 := ab.length_squared()
				var t := 0.0 if len2 <= 0.0 else clampf((p - a).dot(ab) / len2, 0.0, 1.0)
				if p.distance_to(a + ab * t) < r:
					clear = false
					break
		if clear:
			sim.anomalies.append({"pos": p, "r": r})


# Minimum spanning tree (Prim) so the whole map is one connected component, plus
# each system's nearest few extra lanes for loops and chokepoints.
static func _connect_systems(sim: Sim, sys_ids: Array, positions: Array,
		extra: int) -> void:
	var n := sys_ids.size()
	if n < 2:
		return
	var added := {0: true}
	while added.size() < n:
		var best_i := -1
		var best_j := -1
		var best_d := INF
		for i in added:
			for j in n:
				if added.has(j):
					continue
				var d: float = positions[i].distance_to(positions[j])
				if d < best_d:
					best_d = d
					best_i = i
					best_j = j
		sim.add_lane(sys_ids[best_i], sys_ids[best_j])
		added[best_j] = true

	var laneset := {}
	for l in sim.lanes:
		var ia: int = sys_ids.find(l[0])
		var ib: int = sys_ids.find(l[1])
		laneset["%d-%d" % [mini(ia, ib), maxi(ia, ib)]] = true
	for i in n:
		var order: Array = []
		for j in n:
			if j != i:
				order.append([positions[i].distance_to(positions[j]), j])
		order.sort()
		for k in mini(extra, order.size()):
			var j: int = order[k][1]
			var key := "%d-%d" % [mini(i, j), maxi(i, j)]
			if not laneset.has(key):
				laneset[key] = true
				sim.add_lane(sys_ids[i], sys_ids[j])


# Place empires at maximally-separated systems (greedy farthest-point). First
# empire is the player; the rest get an AI. Each homeworld gets a mineral mine +
# water mine (free) so its capital is self-sustaining from tick 1.
static func _place_empires(sim: Sim, sys_ids: Array, positions: Array,
		count: int, ai_efficiency: float) -> void:
	var n := sys_ids.size()
	var chosen: Array = [0]
	while chosen.size() < count and chosen.size() < n:
		var best := -1
		var best_d := -1.0
		for j in n:
			if chosen.has(j):
				continue
			var mind := INF
			for c in chosen:
				mind = minf(mind, positions[j].distance_to(positions[c]))
			if mind > best_d:
				best_d = mind
				best = j
		if best == -1:
			break
		chosen.append(best)

	for e_i in chosen.size():
		var sid: int = sys_ids[chosen[e_i]]
		var ename := "%s %s" % [sim.systems[sid].name,
			_EMPIRE_SUFFIX[e_i % _EMPIRE_SUFFIX.size()]]
		var emp := sim.add_empire(ename, _EMPIRE_COLORS[e_i % _EMPIRE_COLORS.size()])
		if e_i > 0:   # AI empires scale with difficulty; the player stays at 1.0
			emp.efficiency = ai_efficiency
		var pids: Array = sim.systems[sid].planet_ids
		var mineral_p: Planet = sim.planets[pids[0]]
		var water_p: Planet = sim.planets[pids[1]]
		mineral_p.deposit_type = SimConstants.Deposit.MINERAL
		mineral_p.mine_empire_id = emp.id
		water_p.deposit_type = SimConstants.Deposit.WATER
		water_p.mine_empire_id = emp.id
		sim.inject_colony(emp.id, pids[0], 150.0, true)
		if e_i > 0:   # first empire is the human player
			sim.add_ai(emp.id)


func add_ai(empire_id: int) -> void:
	ais.append(EmpireAI.new(empire_id))


# --- save / load -------------------------------------------------------------
# Serialize the whole sim to a plain Dictionary (JSON-safe). deserialize() is the
# inverse. JSON turns every number into a float, so deserialize int()s all ids.

func serialize() -> Dictionary:
	var es: Array = []
	for e in empires.values():
		es.append({"id": e.id, "name": e.name,
			"color": [e.color.r, e.color.g, e.color.b, e.color.a],
			"water": e.water, "minerals": e.minerals, "food": e.food,
			"alloys": e.alloys, "nat": e.nat.duplicate(), "eff": e.efficiency})
	var ss: Array = []
	for s in systems.values():
		ss.append({"id": s.id, "name": s.name, "x": s.map_pos.x, "y": s.map_pos.y,
			"depot": s.depot_empire_id, "obs": s.obs_post_empire_id,
			"trans": s.transport_empire_id, "planets": s.planet_ids.duplicate()})
	var ps: Array = []
	for p in planets.values():
		ps.append({"id": p.id, "sys": p.system_id, "name": p.name,
			"dep": p.deposit_type, "mine": p.mine_empire_id, "mlvl": p.mine_level,
			"orad": p.orbit_radius, "oang": p.orbit_angle})
	var cs: Array = []
	for c in colonies:
		cs.append({"pid": c.planet_id, "eid": c.empire_id, "pop": c.population,
			"est": c.established, "emi": c.emigrating, "spec": c.spec,
			"sstr": c.spec_strength})
	var fs: Array = []
	for f in fleets:
		fs.append({"id": f.id, "eid": f.empire_id, "sys": f.system_id,
			"path": f.path.duplicate(), "prog": f.progress,
			"fi": f.fighters.duplicate(), "bo": f.bombers.duplicate(),
			"dmg": f.damage, "fd": f.foreign_days})
	var ai: Array = []
	for a in ais:
		ai.append({"eid": a.empire_id, "bc": a._build_count,
			"nad": a._next_action_day})
	var ans: Array = []
	for an in anomalies:
		ans.append({"x": an.pos.x, "y": an.pos.y, "r": an.r})
	var bs: Array = []
	for b in builders:
		bs.append({"id": b.id, "eid": b.eid, "sys": b.sys, "path": b.path.duplicate(),
			"prog": b.prog, "type": b.type, "target": b.target})
	return {"day": day, "next_id": _next_id, "empires": es, "systems": ss,
		"planets": ps, "colonies": cs, "fleets": fs, "lanes": lanes.duplicate(true),
		"ais": ai, "anomalies": ans, "builders": bs}


static func deserialize(d: Dictionary) -> Sim:
	var sim := Sim.new()
	sim.day = d.day
	sim._next_id = int(d.next_id)
	for e in d.empires:
		var emp := Empire.new()
		emp.id = int(e.id)
		emp.name = e.name
		var col: Array = e.color
		emp.color = Color(col[0], col[1], col[2], col[3])
		emp.water = e.water
		emp.minerals = e.minerals
		emp.food = e.food
		emp.alloys = e.alloys
		emp.efficiency = e.eff
		var nat: Array[float] = []
		for v in e.nat:
			nat.append(float(v))
		emp.nat = nat
		sim.empires[emp.id] = emp
	for s in d.systems:
		var sys := StarSystem.new()
		sys.id = int(s.id)
		sys.name = s.name
		sys.map_pos = Vector2(s.x, s.y)
		sys.depot_empire_id = int(s.depot)
		sys.obs_post_empire_id = int(s.get("obs", -1))
		sys.transport_empire_id = int(s.get("trans", -1))
		var pl: Array[int] = []
		for pid in s.planets:
			pl.append(int(pid))
		sys.planet_ids = pl
		sim.systems[sys.id] = sys
	for p in d.planets:
		var pp := Planet.new()
		pp.id = int(p.id)
		pp.system_id = int(p.sys)
		pp.name = p.name
		pp.deposit_type = int(p.dep)
		pp.mine_empire_id = int(p.mine)
		pp.mine_level = int(p.mlvl)
		pp.orbit_radius = p.orad
		pp.orbit_angle = p.oang
		sim.planets[pp.id] = pp
	for c in d.colonies:
		var col2 := Colony.new()
		col2.planet_id = int(c.pid)
		col2.empire_id = int(c.eid)
		col2.population = c.pop
		col2.established = c.est
		col2.emigrating = c.emi
		col2.spec = int(c.spec)
		col2.spec_strength = c.sstr
		sim.planets[col2.planet_id].colony = col2
		sim.colonies.append(col2)
	for f in d.fleets:
		var fl := Fleet.new()
		fl.id = int(f.id)
		fl.empire_id = int(f.eid)
		fl.system_id = int(f.sys)
		fl.progress = f.prog
		fl.damage = f.dmg
		fl.foreign_days = f.fd
		var pth: Array[int] = []
		for x in f.path:
			pth.append(int(x))
		fl.path = pth
		var fi: Array[int] = []
		for v in f.fi:
			fi.append(int(v))
		fl.fighters = fi
		var bo: Array[int] = []
		for v in f.bo:
			bo.append(int(v))
		fl.bombers = bo
		sim.fleets.append(fl)
	for l in d.lanes:
		sim.lanes.append([int(l[0]), int(l[1])])
	for an in d.get("anomalies", []):
		sim.anomalies.append({"pos": Vector2(an.x, an.y), "r": float(an.r)})
	for b in d.get("builders", []):
		var bpath: Array[int] = []
		for x in b.path:
			bpath.append(int(x))
		sim.builders.append({"id": int(b.id), "eid": int(b.eid), "sys": int(b.sys),
			"path": bpath, "prog": float(b.prog), "type": int(b.type),
			"target": int(b.target)})
	for a in d.ais:
		var ai := EmpireAI.new(int(a.eid))
		ai._build_count = int(a.bc)
		ai._next_action_day = a.nad
		sim.ais.append(ai)
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


# --- cosmic anomalies ---------------------------------------------------------
# Anomalies block both influence and visibility: no claim/sight inside one, and
# neither influence nor sight crosses one (a source can't project past it).

func point_in_anomaly(p: Vector2) -> bool:
	for an in anomalies:
		if p.distance_to(an.pos) < an.r:
			return true
	return false


# True if the segment a→b passes through any anomaly (blocking influence/sight).
func segment_hits_anomaly(a: Vector2, b: Vector2) -> bool:
	for an in anomalies:
		var c: Vector2 = an.pos
		var ab := b - a
		var len2 := ab.length_squared()
		var t := 0.0 if len2 <= 0.0 else clampf((c - a).dot(ab) / len2, 0.0, 1.0)
		if c.distance_to(a + ab * t) < an.r:
			return true
	return false


# Influence from source system to a point is blocked if the point is inside an
# anomaly or the line to it crosses one. Used by both the logic claim and the field.
func influence_blocked(src: Vector2, dst: Vector2) -> bool:
	return point_in_anomaly(dst) or segment_hits_anomaly(src, dst)


func influence_reach(system_id: int, empire_id: int) -> float:
	var r := SimConstants.BORDER_A2 * system_influence(system_id, empire_id)
	# An observation post owned by this empire here doubles how far influence reaches.
	if systems[system_id].obs_post_empire_id == empire_id:
		r *= SimConstants.OBS_POST_REACH_MULT
	return r


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
		if d <= influence_reach(sys.id, empire_id) \
				and not influence_blocked(sys.map_pos, systems[target_system_id].map_pos):
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

# Growth multiplier for a colony: the bonus it gets for being near other centers
# of the same empire, = Σ A * (A1 * neighbor_pop) / R, 1/R falloff, summed over
# every other established same-empire colony. Applies BOTH across systems (real
# distance) and within a system (a fixed in-system distance), so a big city lifts
# its neighbours on other planets too. Multiplies growth.
func neighbor_growth_multiplier(colony: Colony) -> float:
	var sys_id: int = planets[colony.planet_id].system_id
	var bonus := 0.0
	for other in colonies:
		if other == colony or other.empire_id != colony.empire_id \
				or not other.established:
			continue
		var other_sys: int = planets[other.planet_id].system_id
		# Same-system colonies COMPETE for the one influence area (vision) — they do
		# NOT boost each other's growth. Only OTHER systems boost, at 1/R. (Without
		# this, several colonies in one system compounded into runaway growth.)
		if other_sys == sys_id:
			continue
		var r := system_distance(sys_id, other_sys)
		if r > 0.0:
			bonus += SimConstants.NEIGHBOR_COEF \
				* (SimConstants.INFLUENCE_A1 * other.population) / r
	# Transportation infrastructure in this colony's system amplifies the proximity
	# bonus it receives (vision: strengthens the bonus between established centers).
	if systems[sys_id].transport_empire_id == colony.empire_id:
		bonus *= SimConstants.TRANSPORT_BONUS_MULT
	# Cap the multiplier: the bonus scales with neighbour population, so a tight,
	# populous cluster could otherwise compound without bound. Clusters still climb
	# well past the lone-colony softcap, just not into runaway.
	return 1.0 + minf(bonus, SimConstants.NEIGHBOR_MAX_BONUS)


# --- visibility (fog of war) --------------------------------------------------
# An empire sees within a sight radius of each point of presence. A colony sees
# SIGHT_INFLUENCE_FACTOR × its influence reach (scales with its strength); a mine
# has no influence, so it grants a flat SIGHT_MINE_RANGE. Separate from influence
# — you can hold ground you can't see. AI empires are full-info; fog is
# player-facing. Returns [ [Vector2 pos, float radius], ... ].
func sight_sources(empire_id: int) -> Array:
	var out: Array = []
	for c in colonies:
		if c.empire_id == empire_id:
			var sys_id: int = planets[c.planet_id].system_id
			var r := SimConstants.SIGHT_INFLUENCE_FACTOR \
				* influence_reach(sys_id, empire_id)
			out.append([systems[sys_id].map_pos, r])
	for p in planets.values():
		if p.has_mine() and p.mine_empire_id == empire_id:
			out.append([systems[p.system_id].map_pos, SimConstants.SIGHT_MINE_RANGE])
	return out


func is_point_visible(pos: Vector2, empire_id: int) -> bool:
	for src in sight_sources(empire_id):
		if pos.distance_to(src[0]) <= src[1]:
			return true
	return false


# --- commands (same gating for every empire) ----------------------------------
# Construction is paid in alloys (T1 refined from minerals).

# Target validity (no cost check) — the physical requirements to place the
# structure. Split out so a construction vessel can re-check it on ARRIVAL (cost was
# already paid at dispatch).
func _colony_target_ok(empire_id: int, planet_id: int) -> bool:
	var p: Planet = planets.get(planet_id)
	return p != null and p.colony == null and is_under_influence(p.system_id, empire_id)


func _mine_target_ok(empire_id: int, planet_id: int) -> bool:
	var p: Planet = planets.get(planet_id)
	return p != null and p.has_deposit() and not p.has_mine() \
		and is_under_influence(p.system_id, empire_id)


func can_found_colony(empire_id: int, planet_id: int) -> bool:
	var e: Empire = empires.get(empire_id)
	return e != null and e.alloys >= SimConstants.FOUND_COST_ALLOYS \
		and _colony_target_ok(empire_id, planet_id)


func found_colony(empire_id: int, planet_id: int) -> bool:
	if not can_found_colony(empire_id, planet_id):
		return false
	empires[empire_id].alloys -= SimConstants.FOUND_COST_ALLOYS
	var c := inject_colony(empire_id, planet_id, SimConstants.START_POP, false)
	return c != null


func can_build_mine(empire_id: int, planet_id: int) -> bool:
	# "Wherever deposits exist within reach" — influence-gated, a colony in the
	# system is not required.
	var e: Empire = empires.get(empire_id)
	return e != null and e.alloys >= SimConstants.MINE_COST_ALLOYS \
		and _mine_target_ok(empire_id, planet_id)


func build_mine(empire_id: int, planet_id: int) -> bool:
	if not can_build_mine(empire_id, planet_id):
		return false
	empires[empire_id].alloys -= SimConstants.MINE_COST_ALLOYS
	planets[planet_id].mine_empire_id = empire_id
	return true


# --- construction vessels -----------------------------------------------------
# Expansion structures (colonies, mines) are delivered by a construction vessel:
# it travels lanes from the empire's capital to the target and cannot pass through
# another empire's territory. Cost is paid at dispatch; the structure is placed on
# arrival (refunded if the target went invalid in the meantime).

func _construction_cost(build_type: int) -> float:
	return SimConstants.FOUND_COST_ALLOYS if build_type == SimConstants.Build.COLONY \
		else SimConstants.MINE_COST_ALLOYS


func _construction_target_ok(empire_id: int, build_type: int, target_id: int) -> bool:
	if build_type == SimConstants.Build.COLONY:
		return _colony_target_ok(empire_id, target_id)
	return _mine_target_ok(empire_id, target_id)


# BFS lane path that never ENTERS a system owned by a different empire (own/neutral
# are traversable, and the destination itself is always allowed). [] if unreachable.
func lane_path_friendly(from_sys: int, to_sys: int, empire_id: int) -> Array[int]:
	var out: Array[int] = []
	if from_sys == to_sys or not systems.has(from_sys) or not systems.has(to_sys):
		return out
	var prev := {from_sys: from_sys}
	var queue: Array[int] = [from_sys]
	while not queue.is_empty():
		var s: int = queue.pop_front()
		if s == to_sys:
			break
		for nb in lane_neighbors(s):
			if prev.has(nb):
				continue
			var o := system_owner(nb)
			if nb == to_sys or o == -1 or o == empire_id:
				prev[nb] = s
				queue.append(nb)
	if not prev.has(to_sys):
		return out
	var cur := to_sys
	while cur != from_sys:
		out.push_front(cur)
		cur = prev[cur]
	return out


func _target_system_of(build_type: int, target_id: int) -> int:
	# Both colony and mine target a planet; the vessel travels to its system.
	var p: Planet = planets.get(target_id)
	return p.system_id if p != null else -1


func can_order_construction(empire_id: int, build_type: int, target_id: int) -> bool:
	var e: Empire = empires.get(empire_id)
	if e == null or e.alloys < _construction_cost(build_type):
		return false
	if not _construction_target_ok(empire_id, build_type, target_id):
		return false
	var cap := most_populated_system(empire_id)
	var tsys := _target_system_of(build_type, target_id)
	if cap == -1 or tsys == -1:
		return false
	if cap == tsys:
		return true   # build in the capital's own system, no travel
	return not lane_path_friendly(cap, tsys, empire_id).is_empty()


func order_construction(empire_id: int, build_type: int, target_id: int) -> bool:
	if not can_order_construction(empire_id, build_type, target_id):
		return false
	var cap := most_populated_system(empire_id)
	var tsys := _target_system_of(build_type, target_id)
	empires[empire_id].alloys -= _construction_cost(build_type)
	builders.append({"id": _next_id, "eid": empire_id, "sys": cap,
		"path": lane_path_friendly(cap, tsys, empire_id), "prog": 0.0,
		"type": build_type, "target": target_id})
	_next_id += 1
	return true


func builder_position(b: Dictionary) -> Vector2:
	if b.path.is_empty():
		return systems[b.sys].map_pos
	return systems[b.sys].map_pos.lerp(systems[b.path[0]].map_pos, b.prog)


# Move vessels a tick; when one reaches its target system, place the structure (or
# refund if the target is no longer valid). Called from tick().
func _advance_builders(dt_days: float) -> void:
	var done: Array = []
	for b in builders:
		if not b.path.is_empty():
			var length: float = maxf(system_distance(b.sys, b.path[0]), 1.0)
			b.prog += SimConstants.BUILDER_SPEED * dt_days / length
			if b.prog >= 1.0:
				b.sys = b.path.pop_front()
				b.prog = 0.0
		if b.path.is_empty():   # arrived at the target system
			done.append(b)
	for b in done:
		builders.erase(b)
		var eid: int = b.eid
		if _construction_target_ok(eid, b.type, b.target):
			if b.type == SimConstants.Build.COLONY:
				inject_colony(eid, b.target, SimConstants.START_POP, false)
			else:
				planets[b.target].mine_empire_id = eid
		else:   # target spoiled in transit — refund what was paid at dispatch
			empires[eid].alloys += _construction_cost(b.type)


func toggle_emigration(empire_id: int, planet_id: int) -> void:
	var p: Planet = planets.get(planet_id)
	if p != null and p.colony != null and p.colony.empire_id == empire_id:
		p.colony.emigrating = not p.colony.emigrating


# Set a colony's specialization target. Switching resets its ramp (inertia).
func set_specialization(empire_id: int, planet_id: int, kind: int) -> void:
	var p: Planet = planets.get(planet_id)
	if p != null and p.colony != null and p.colony.empire_id == empire_id:
		if p.colony.spec != kind:
			p.colony.spec_strength = 0.0
		p.colony.spec = kind


# A mine can be upgraded when the same planet holds a big enough colony of the
# owning empire (and there are alloys to pay for it).
func can_upgrade_mine(empire_id: int, planet_id: int) -> bool:
	var p: Planet = planets.get(planet_id)
	var e: Empire = empires.get(empire_id)
	if p == null or e == null or not p.has_mine() or p.mine_empire_id != empire_id:
		return false
	if p.mine_level >= SimConstants.MINE_MAX_LEVEL:
		return false
	if e.alloys < SimConstants.MINE_UPGRADE_COST_ALLOYS:
		return false
	var c: Colony = p.colony
	return c != null and c.empire_id == empire_id \
		and c.population >= (p.mine_level + 1) * SimConstants.MINE_UPGRADE_POP


func upgrade_mine(empire_id: int, planet_id: int) -> bool:
	if not can_upgrade_mine(empire_id, planet_id):
		return false
	empires[empire_id].alloys -= SimConstants.MINE_UPGRADE_COST_ALLOYS
	planets[planet_id].mine_level += 1
	return true


# Supply depot: one per system, built in your influence for alloys.
func can_build_depot(empire_id: int, system_id: int) -> bool:
	var e: Empire = empires.get(empire_id)
	return e != null and systems.has(system_id) \
		and systems[system_id].depot_empire_id == -1 \
		and e.alloys >= SimConstants.DEPOT_COST_ALLOYS \
		and is_under_influence(system_id, empire_id)


func build_depot(empire_id: int, system_id: int) -> bool:
	if not can_build_depot(empire_id, system_id):
		return false
	empires[empire_id].alloys -= SimConstants.DEPOT_COST_ALLOYS
	systems[system_id].depot_empire_id = empire_id
	return true


# Observation post: one per system, built in your influence for alloys. Doubles the
# system's influence reach (see influence_reach).
func can_build_obs_post(empire_id: int, system_id: int) -> bool:
	var e: Empire = empires.get(empire_id)
	return e != null and systems.has(system_id) \
		and systems[system_id].obs_post_empire_id == -1 \
		and e.alloys >= SimConstants.OBS_POST_COST_ALLOYS \
		and is_under_influence(system_id, empire_id)


func build_obs_post(empire_id: int, system_id: int) -> bool:
	if not can_build_obs_post(empire_id, system_id):
		return false
	empires[empire_id].alloys -= SimConstants.OBS_POST_COST_ALLOYS
	systems[system_id].obs_post_empire_id = empire_id
	return true


# Transportation hub: one per system, built in your influence for alloys.
# Strengthens the neighbor bonus for its colonies (see neighbor_growth_multiplier).
func can_build_transport(empire_id: int, system_id: int) -> bool:
	var e: Empire = empires.get(empire_id)
	return e != null and systems.has(system_id) \
		and systems[system_id].transport_empire_id == -1 \
		and e.alloys >= SimConstants.TRANSPORT_COST_ALLOYS \
		and is_under_influence(system_id, empire_id)


func build_transport(empire_id: int, system_id: int) -> bool:
	if not can_build_transport(empire_id, system_id):
		return false
	empires[empire_id].alloys -= SimConstants.TRANSPORT_COST_ALLOYS
	systems[system_id].transport_empire_id = empire_id
	return true


# A fleet is in supply if a friendly depot sits in its system or a lane-neighbor.
func _fleet_supplied(f: Fleet) -> bool:
	if systems[f.system_id].depot_empire_id == f.empire_id:
		return true
	for nb in lane_neighbors(f.system_id):
		if systems[nb].depot_empire_id == f.empire_id:
			return true
	return false


# --- fleets -------------------------------------------------------------------

func _empire_has_colony_in(empire_id: int, system_id: int) -> bool:
	for pid in systems[system_id].planet_ids:
		var c: Colony = planets[pid].colony
		if c != null and c.empire_id == empire_id:
			return true
	return false


func empire_fleet_in_system(empire_id: int, system_id: int) -> bool:
	for f in fleets:
		if f.empire_id == empire_id and not f.is_moving() and f.system_id == system_id:
			return true
	return false


# Per-empire combat power of stationary fleets in a system (for the combat readout).
# empire_id -> {"combat": x, "bomb": y}. Empty if no stationary fleets.
func fleet_powers_in(system_id: int) -> Dictionary:
	var out := {}
	for f in fleets:
		if f.is_moving() or f.system_id != system_id or f.ship_count() == 0:
			continue
		var r: Dictionary = out.get(f.empire_id, {"combat": 0.0, "bomb": 0.0})
		r.combat += f.combat_power()
		r.bomb += f.bomb_power()
		out[f.empire_id] = r
	return out


func _has_enemy_colony(empire_id: int, system_id: int) -> bool:
	for pid in systems[system_id].planet_ids:
		var c: Colony = planets[pid].colony
		if c != null and c.empire_id != empire_id:
			return true
	return false


# The empire's most-populated colony's system — its de-facto shipyard, where new
# ships appear. -1 if the empire has no colonies.
func most_populated_system(empire_id: int) -> int:
	var best := -1
	var best_pop := -1.0
	for c in colonies:
		if c.empire_id == empire_id and c.population > best_pop:
			best_pop = c.population
			best = planets[c.planet_id].system_id
	return best


func can_build_ship(empire_id: int, tier: int) -> bool:   # tier 1-5
	var e: Empire = empires.get(empire_id)
	return e != null and tier >= 1 and tier <= 5 \
		and e.nat[tier - 1] >= SimConstants.SHIP_NAT_COST \
		and most_populated_system(empire_id) != -1


# Build one ship (role, tier) above the empire's most-populated city, paid in the
# tier's national military resource. It joins (or forms) a stationary fleet there.
func build_ship(empire_id: int, role: int, tier: int) -> bool:
	if not can_build_ship(empire_id, tier):
		return false
	var sys := most_populated_system(empire_id)
	empires[empire_id].nat[tier - 1] -= SimConstants.SHIP_NAT_COST
	var f := _fleet_at(empire_id, sys)
	if role == SimConstants.Role.FIGHTER:
		f.fighters[tier - 1] += 1
	else:
		f.bombers[tier - 1] += 1
	return true


func _fleet_at(empire_id: int, system_id: int) -> Fleet:
	for f in fleets:
		if f.empire_id == empire_id and not f.is_moving() and f.system_id == system_id:
			return f
	var f := Fleet.new()
	f.id = _next_id
	_next_id += 1
	f.empire_id = empire_id
	f.system_id = system_id
	fleets.append(f)
	return f


func get_fleet(fleet_id: int) -> Fleet:
	for f in fleets:
		if f.id == fleet_id:
			return f
	return null


# Shortest lane path (BFS) from one system to another: the system ids to visit in
# order, excluding the start, including the destination. [] if same or unreachable.
func lane_path(from_sys: int, to_sys: int) -> Array[int]:
	var out: Array[int] = []
	if from_sys == to_sys or not systems.has(from_sys) or not systems.has(to_sys):
		return out
	var prev := {from_sys: from_sys}
	var queue: Array[int] = [from_sys]
	while not queue.is_empty():
		var s: int = queue.pop_front()
		if s == to_sys:
			break
		for nb in lane_neighbors(s):
			if not prev.has(nb):
				prev[nb] = s
				queue.append(nb)
	if not prev.has(to_sys):
		return out
	var cur := to_sys
	while cur != from_sys:
		out.push_front(cur)
		cur = prev[cur]
	return out


func order_fleet(fleet_id: int, dest_system: int) -> void:
	var f := get_fleet(fleet_id)
	if f != null:
		f.path = lane_path(f.system_id, dest_system)
		f.progress = 0.0


func fleet_position(f: Fleet) -> Vector2:
	if f.path.is_empty():
		return systems[f.system_id].map_pos
	return systems[f.system_id].map_pos.lerp(systems[f.path[0]].map_pos, f.progress)


# Automatic combat, per stationary-fleet cluster in each system:
#  - if two+ empires are present, they fight: every fleet takes damage in
#    proportion to the enemy's combat power (fighter-heavy fleets deal more, so
#    they win) — accumulated, no single decisive blow;
#  - otherwise a lone empire's fleets bombard enemy colonies weakest-first, and a
#    colony left under BOMBARD_DESTROY_POP is destroyed.
func _resolve_combat(dt_days: float) -> void:
	var by_sys := {}   # system_id -> { empire_id -> [fleets] }
	for f in fleets:
		if f.is_moving():
			continue
		var emap: Dictionary = by_sys.get(f.system_id, {})
		var list: Array = emap.get(f.empire_id, [])
		list.append(f)
		emap[f.empire_id] = list
		by_sys[f.system_id] = emap

	var destroyed_colonies: Array[Colony] = []
	combat_kind.clear()   # rebuilt each tick — reflects combat happening right now
	for sid in by_sys:
		var emap: Dictionary = by_sys[sid]
		if emap.size() >= 2:
			_fight(emap, dt_days)
			combat_at[sid] = day     # fleet battle here — flag for the clash flash
			combat_kind[sid] = 0     # 0 = fleet battle
		else:
			var eid: int = emap.keys()[0]
			_bombard(eid, emap[eid], sid, dt_days, destroyed_colonies)
			if _has_enemy_colony(eid, sid):
				combat_at[sid] = day
				combat_kind[sid] = 1   # 1 = bombardment
	for c in destroyed_colonies:
		planets[c.planet_id].colony = null
		colonies.erase(c)

	# Overstay attrition: a stationary fleet in space it doesn't own and isn't
	# supplied bleeds hull ∝ its own size after a grace period.
	for f in fleets:
		if f.is_moving():
			f.foreign_days = 0.0
			continue
		if system_owner(f.system_id) == f.empire_id or _fleet_supplied(f):
			f.foreign_days = 0.0
			continue
		f.foreign_days += dt_days
		if f.foreign_days > SimConstants.ATTRITION_GRACE_DAYS:
			_damage_fleet(f, SimConstants.ATTRITION_FRAC * f.hull() * dt_days)

	# Cull emptied fleets.
	var empty: Array[Fleet] = []
	for f in fleets:
		if f.ship_count() == 0:
			empty.append(f)
	for f in empty:
		fleets.erase(f)


func _fight(emap: Dictionary, dt_days: float) -> void:
	var power := {}
	for eid in emap:
		var p := 0.0
		for f in emap[eid]:
			p += (f as Fleet).combat_power()
		# Hard ceiling: damage output can't exceed the cap regardless of stack
		# size, so mass buys survival (hull), not a one-shot.
		power[eid] = minf(p, SimConstants.POWER_CEILING)
	for eid in emap:
		var enemy := 0.0
		for oid in power:
			if oid != eid:
				enemy += power[oid]
		var dmg: float = enemy * SimConstants.COMBAT_RATE * dt_days
		# Spread this empire's incoming damage across its fleets by hull share.
		var total_hull := 0.0
		for f in emap[eid]:
			total_hull += (f as Fleet).hull()
		if total_hull <= 0.0:
			continue
		for f in emap[eid]:
			_damage_fleet(f, dmg * (f.hull() / total_hull))


# Accumulate damage and destroy whole ships (lowest tier / weakest first) as it
# covers their hit points.
func _damage_fleet(f: Fleet, dmg: float) -> void:
	f.damage += dmg
	while true:
		var removed := false
		for t in 5:
			if f.fighters[t] > 0 and f.damage >= SimConstants.FIGHTER_HP[t]:
				f.damage -= SimConstants.FIGHTER_HP[t]
				f.fighters[t] -= 1
				removed = true
				break
			if f.bombers[t] > 0 and f.damage >= SimConstants.BOMBER_HP[t]:
				f.damage -= SimConstants.BOMBER_HP[t]
				f.bombers[t] -= 1
				removed = true
				break
		if not removed:
			break


func _bombard(empire_id: int, fleet_list: Array, system_id: int, dt_days: float,
		destroyed: Array[Colony]) -> void:
	var budget := 0.0
	for f in fleet_list:
		budget += (f as Fleet).bomb_power()
	budget *= dt_days
	if budget <= 0.0:
		return
	var targets: Array[Colony] = []
	for pid in systems[system_id].planet_ids:
		var c: Colony = planets[pid].colony
		if c != null and c.empire_id != empire_id:
			targets.append(c)
	targets.sort_custom(func(a, b): return a.population < b.population)  # weakest first
	for c in targets:
		if budget <= 0.0:
			break
		var applied: float = minf(budget, c.population)
		c.population -= applied
		budget -= applied
		if c.population < SimConstants.BOMBARD_DESTROY_POP and not destroyed.has(c):
			destroyed.append(c)


# Merge every other stationary same-empire fleet in this fleet's system into it
# (strengths add). Returns how many were absorbed.
func merge_fleets_into(fleet_id: int) -> int:
	var keep := get_fleet(fleet_id)
	if keep == null or keep.is_moving():
		return 0
	var absorbed: Array[Fleet] = []
	for f in fleets:
		if f != keep and f.empire_id == keep.empire_id and not f.is_moving() \
				and f.system_id == keep.system_id:
			for t in 5:
				keep.fighters[t] += f.fighters[t]
				keep.bombers[t] += f.bombers[t]
			absorbed.append(f)
	for f in absorbed:
		fleets.erase(f)
	return absorbed.size()


# Split a stationary fleet in two (half of each ship type). Returns the new fleet
# (null if it has nothing to split).
func split_fleet(fleet_id: int) -> Fleet:
	var f := get_fleet(fleet_id)
	if f == null or f.is_moving() or f.ship_count() < 2:
		return null
	var g := Fleet.new()
	g.id = _next_id
	_next_id += 1
	g.empire_id = f.empire_id
	g.system_id = f.system_id
	var moved := 0
	for t in 5:
		var hf: int = f.fighters[t] / 2
		g.fighters[t] = hf
		f.fighters[t] -= hf
		var hb: int = f.bombers[t] / 2
		g.bombers[t] = hb
		f.bombers[t] -= hb
		moved += hf + hb
	if moved == 0:
		return null
	fleets.append(g)
	return g


# --- tick ---------------------------------------------------------------------

func tick(dt_days: float) -> void:
	day += dt_days
	# Rival decisions run on their own day-cadence, before the economy advances.
	for ai in ais:
		ai.maybe_act(self)

	# 1. Mines extract their deposit's T0 resource (at the deposit's own richness)
	#    into the empire stockpile.
	for p in planets.values():
		if p.has_mine():
			var e: Empire = empires[p.mine_empire_id]
			var out: float = p.mine_output() * dt_days * e.efficiency
			if p.deposit_type == SimConstants.Deposit.WATER:
				e.water += out
			elif p.deposit_type == SimConstants.Deposit.MINERAL:
				e.minerals += out

	# 1b. Cap raw stockpiles: you can't hoard T0 beyond what your cities could soon
	#     refine. A throughput limit — mine output past the cap is wasted, so raw
	#     stays a real constraint (build more cities) AND there's no giant buffer to
	#     fuel a population boom-then-famine. Cap scales with current refining
	#     capacity so it never starves refining.
	var food_cap := {}   # empire -> total water/day it can refine into food
	var alloy_cap := {}  # empire -> total minerals/day it can refine into alloys
	for c in colonies:
		if c.established:
			food_cap[c.empire_id] = food_cap.get(c.empire_id, 0.0) + c.food_capacity()
			alloy_cap[c.empire_id] = alloy_cap.get(c.empire_id, 0.0) + c.alloy_capacity()
	for e in empires.values():
		e.water = minf(e.water, maxf(SimConstants.RAW_STOCK_MIN,
			food_cap.get(e.id, 0.0) * SimConstants.RAW_STOCK_DAYS))
		e.minerals = minf(e.minerals, maxf(SimConstants.RAW_STOCK_MIN,
			alloy_cap.get(e.id, 0.0) * SimConstants.RAW_STOCK_DAYS))

	# National vs civilian variety: higher-tier military production needs a wider
	# variety of resource types, rewarding diverse territory over hoarding one kind
	# (vision). Concretely, an empire must mine BOTH water and minerals to refine the
	# top military tiers (VARIETY_MIN_TIER+) — the civilian (water→food) economy and
	# the industrial (mineral→alloy) economy both feed a modern war machine.
	var mines_both := {}
	var has_water := {}
	var has_mineral := {}
	for p in planets.values():
		if p.has_mine():
			if p.deposit_type == SimConstants.Deposit.WATER:
				has_water[p.mine_empire_id] = true
			elif p.deposit_type == SimConstants.Deposit.MINERAL:
				has_mineral[p.mine_empire_id] = true
	for eid in has_water:
		if has_mineral.has(eid):
			mines_both[eid] = true

	# 2. Established cities refine T0 -> T1, capped by available input (partial
	#    is fine). Earlier colonies draw first — deterministic by colony order.
	for c in colonies:
		if not c.established:
			continue
		var e: Empire = empires[c.empire_id]
		# Specialization ramps in over time (inertia); it multiplies its output.
		if c.spec != SimConstants.Spec.NONE and c.spec_strength < 1.0:
			c.spec_strength = minf(1.0,
				c.spec_strength + dt_days / SimConstants.SPEC_RAMP_DAYS)
		var food_made: float = minf(
			c.food_capacity() * c.spec_factor(SimConstants.Spec.FOOD) \
			* e.efficiency * dt_days, e.water)
		e.water -= food_made
		e.food += food_made
		var alloy_made: float = minf(
			c.alloy_capacity() * c.spec_factor(SimConstants.Spec.ALLOY) \
			* e.efficiency * dt_days, e.minerals)
		e.minerals -= alloy_made
		e.alloys += alloy_made
		# Military refining chain: tier 1 from alloys, each higher tier from the
		# one below, each gated by a city pop cutoff (cutoffs increase, so a
		# too-small city stops the chain early).
		var mil_cap := SimConstants.MIL_COEF \
			* pow(c.population, SimConstants.MIL_EXP) * dt_days
		for t in 5:
			if c.population < SimConstants.MIL_CUTOFF[t]:
				break
			# Variety gate: the top tiers need diverse territory (both deposit types
			# mined), not just a big single-resource stockpile.
			if t >= SimConstants.VARIETY_MIN_TIER and not mines_both.has(e.id):
				break
			var avail: float = e.alloys if t == 0 else e.nat[t - 1]
			var made: float = minf(mil_cap, avail)
			if t == 0:
				e.alloys -= made
			else:
				e.nat[t - 1] -= made
			e.nat[t] += made

	# 3. Food is empire-wide: the sign of the end-of-tick balance (food produced
	#    this tick minus what the whole population eats) sets growth direction.
	var grow_sign := {}
	for e in empires.values():
		var total_pop := 0.0
		for c in colonies:
			if c.empire_id == e.id:
				total_pop += c.population
		var consumption := total_pop * SimConstants.FOOD_PER_POP * dt_days
		var balance: float = e.food - consumption
		if balance > 0.0:
			e.food = balance
			grow_sign[e.id] = 1
		else:
			e.food = 0.0
			grow_sign[e.id] = 0 if balance == 0.0 else -1

	# 4. Apply population change. Surplus -> grow by the diminishing-returns curve
	#    × neighbor bonus; deficit -> shrink (pops CAN decrease now); zero -> hold.
	for c in colonies:
		var sign: int = grow_sign.get(c.empire_id, 0)
		if sign > 0:
			c.population += Colony.growth_per_day(c.population) \
				* neighbor_growth_multiplier(c) * dt_days
			if not c.established and c.population >= SimConstants.ACTIVATION_POP:
				c.established = true
		elif sign < 0:
			c.population = maxf(SimConstants.MIN_POP,
				c.population - SimConstants.SHRINK_RATE * c.population * dt_days)

	# 5. Emigration: colonies with the toggle shed population to the empire's
	#    other colonies, letting the player shift population (and influence).
	for c in colonies:
		if not c.emigrating:
			continue
		var others: Array[Colony] = []
		for o in colonies:
			if o != c and o.empire_id == c.empire_id:
				others.append(o)
		if others.is_empty():
			continue
		var shed: float = minf(
			c.population * SimConstants.IMMIGRATION_RATE * dt_days,
			c.population - SimConstants.MIN_POP)
		if shed <= 0.0:
			continue
		c.population -= shed
		var each := shed / others.size()
		for o in others:
			o.population += each

	# 6. Fleets move along lanes (one hop per tick at most).
	for f in fleets:
		if f.path.is_empty():
			continue
		var length: float = maxf(system_distance(f.system_id, f.path[0]), 1.0)
		f.progress += SimConstants.FLEET_SPEED * dt_days / length
		if f.progress >= 1.0:
			f.system_id = f.path.pop_front()
			f.progress = 0.0

	# 6b. Construction vessels advance and place their structure on arrival.
	_advance_builders(dt_days)

	# 7. Combat: fleets auto-fight where enemies meet, else bombard (see 0.25.0).
	_resolve_combat(dt_days)

	# 8. Structures follow the border: a mine or supply depot changes hands to
	#    whoever now controls its system. Colonies do NOT flip (a colony holds its
	#    own system — it must be bombarded to be taken).
	var struct_systems := {}
	for p in planets.values():
		if p.has_mine():
			struct_systems[p.system_id] = true
	for sys in systems.values():
		if sys.depot_empire_id != -1 or sys.obs_post_empire_id != -1 \
				or sys.transport_empire_id != -1:
			struct_systems[sys.id] = true
	var owner_of := {}
	for sid in struct_systems:
		owner_of[sid] = system_owner(sid)
	for p in planets.values():
		if p.has_mine():
			var o: int = owner_of[p.system_id]
			if o != -1 and o != p.mine_empire_id:
				p.mine_empire_id = o
	for sys in systems.values():
		var o: int = owner_of.get(sys.id, -1)
		if o == -1:
			continue
		if sys.depot_empire_id != -1 and o != sys.depot_empire_id:
			sys.depot_empire_id = o
		if sys.obs_post_empire_id != -1 and o != sys.obs_post_empire_id:
			sys.obs_post_empire_id = o
		if sys.transport_empire_id != -1 and o != sys.transport_empire_id:
			sys.transport_empire_id = o
