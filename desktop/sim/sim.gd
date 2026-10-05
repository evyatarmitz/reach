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
var anomalies: Array = []      # [{pts: PackedVector2Array (spine), r: float, bb: Rect2}]
                               # — cosmic storm bands that block influence AND visibility
                               # (route sight around them; fleets fly through). bb is the
                               # spine's bounding box grown by r, for a cheap reject.
var builders: Array = []       # construction vessels in transit: [{id, eid, sys,
                               # path:[sys...], prog, type, target:planet_or_system}]

var _next_id := 1
var _adj: Dictionary = {}          # system_id -> [neighbor ids], cached adjacency
var _owner_cache: Dictionary = {}  # system_id -> owner, rebuilt once per tick (day)
var _owner_cache_day: float = -1.0
var _src_cache: Dictionary = {}    # empire_id -> [influence sources], per-tick (day)
var _src_cache_day: float = -1.0
var _blocked_pair: Dictionary = {} # (src_id,dst_id) -> bool anomaly-blocked. Anomalies
                                   # and system positions are immutable after map-gen, so
                                   # this is a permanent constant — never invalidated.
# Supply-line connectivity: planet_id -> is this colony connected to its capital by a
# friendly/neutral lane path. Recomputed once per tick (recompute_connectivity), read
# by _is_colony_active. A disconnected colony drops out of influence, refining and the
# water pool — it's cut off (see the tick). One-tick-lagged snapshot: the pass that
# builds it needs ownership, and ownership needs influence, so it evaluates over an
# ALL-active view (guarded by _computing_connectivity) to break the cycle.
var _connected: Dictionary = {}
var _conn_computed: bool = false
var _computing_connectivity: bool = false
# planet_id -> consecutive in-game days a colony has been unreachable. A colony only
# counts as truly disconnected (dropped from influence/refining/water AND shown with the
# cut-off pocket border) once this crosses CONNECT_GRACE_DAYS. This absorbs single-tick
# border wobble at a claim threshold and storms briefly cutting an influence line, so an
# interior colony doesn't flicker disconnected when the frontier twitches. Not
# serialized: a reload just re-earns the (tiny) grace, which is harmless.
var _disc_days: Dictionary = {}


# Name syllables — combined by index for readable, unique system names.
const _SYL_A := ["Ka", "Me", "Or", "Ve", "Ta", "Sy", "Lo", "Ne", "Ro", "Ai",
	"Zu", "Cy", "Da", "Fe", "Gi", "Ha"]
const _SYL_B := ["ron", "dis", "lex", "mos", "tia", "var", "nyx", "del", "sor",
	"pel"]
const _EMPIRE_SUFFIX := ["Compact", "Ascendancy", "Union", "Dominion", "League",
	"Accord", "Pact", "Reach"]
# Softer, slightly desaturated empire hues — distinct on the dark map without the
# fluorescent/neon glare of fully-saturated primaries.
const _EMPIRE_COLORS := [
	Color(0.44, 0.68, 0.90), Color(0.88, 0.46, 0.42), Color(0.53, 0.78, 0.50),
	Color(0.87, 0.76, 0.44), Color(0.66, 0.55, 0.85), Color(0.87, 0.62, 0.40)]


static func _system_name(idx: int) -> String:
	return _SYL_A[idx % _SYL_A.size()] + _SYL_B[(idx / _SYL_A.size()) % _SYL_B.size()]


# All procedural-generation knobs live here so future game-settings can override
# them. Passed straight into generate_map.
static func default_map_config() -> Dictionary:
	return {
		"seed": 20260702,
		"system_count": 120,      # planets now (one per node); size derives from this
		"empire_count": 4,
		"lane_density": 0.35,     # 0 = spanning tree only (one connected wire); 1 = every
		                          # planar near-neighbour lane (Delaunay), no crossings
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
# Delaunay lane graph (planar — NO crossing lanes) whose density the player sets: a
# spanning tree at minimum (one connected wire, guaranteeing NO islands) up to every
# near-neighbour lane at maximum. Then N empires placed far apart. Seeded RNG only —
# same config -> identical map, so the sim stays deterministic.
static func generate_map(cfg_in: Dictionary) -> Sim:
	var cfg := _merged_config(cfg_in)
	var sim := Sim.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = cfg.seed
	var count: int = maxi(2, int(cfg.system_count))
	# The map is now a flat MESH OF PLANETS (one planet per node, no star systems).
	# Size scales with the planet count at a fixed density, so a bigger map simply
	# means more room — and influence reach, unchanged, becomes the real limiter on
	# how fast you can expand across it (which is what lengthens a big game).
	var area: float = count * SimConstants.MAP_AREA_PER_PLANET
	var size := Vector2(sqrt(area * 16.0 / 9.0), sqrt(area * 9.0 / 16.0))
	var spread: float = size.x * 0.16
	var min_sep: float = SimConstants.MAP_MIN_SEPARATION
	var blobs_n: int = clampi(count / 18, 3, 14)

	# Density heatmap = sum of Gaussian blobs; planets cluster where it's high.
	var blobs: Array = []
	for i in blobs_n:
		blobs.append(Vector2(rng.randf_range(0.0, size.x),
			rng.randf_range(0.0, size.y)))

	var positions: Array = []
	var attempts := 0
	while positions.size() < count and attempts < count * 500:
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
		# One node = one planet. We keep the StarSystem struct as the map node (its
		# position, lanes, structures) and hang a single planet on it — that's the
		# whole "system" now, presented to the player as just a planet.
		var sys := sim.add_system(_system_name(i))
		sys.map_pos = positions[i]
		sys_ids.append(sys.id)
		var pl := sim.add_planet(sys.id, sys.name)
		if rng.randf() < 0.35:
			pl.deposit_type = SimConstants.Deposit.WATER if rng.randf() < 0.5 \
				else SimConstants.Deposit.MINERAL

	_connect_systems(sim, sys_ids, positions, float(cfg.lane_density))
	_place_anomalies(sim, positions, size, rng)
	_place_empires(sim, sys_ids, positions, int(cfg.empire_count),
		float(cfg.ai_efficiency), int(cfg.get("player_color_idx", 0)),
		cfg.get("ai_personalities", []), rng)
	sim.recompute_connectivity()   # prime the supply-line snapshot before the first tick
	return sim


# Grow a few snaking storm-bands in open space. They may cross lanes (movement is
# never blocked) but are kept clear of systems, so no colony is ever born blind inside
# one. Each band is a spine polyline thickened by its radius (a capsule chain).
static func _place_anomalies(sim: Sim, positions: Array, size: Vector2,
		rng: RandomNumberGenerator) -> void:
	var target: int = clampi(int(positions.size() / 12),
		SimConstants.ANOMALY_MIN, SimConstants.ANOMALY_MAX)
	# Spread bands across the map instead of letting them clump: reject a candidate whose
	# head starts too near an existing band's head. ~the spacing of `target` points on a
	# grid over the map.
	var min_apart: float = sqrt(size.x * size.y / maxf(1.0, float(target))) * 0.62
	var attempts := 0
	while sim.anomalies.size() < target and attempts < target * 800:
		attempts += 1
		var r := rng.randf_range(SimConstants.ANOMALY_RADIUS_MIN,
			SimConstants.ANOMALY_RADIUS_MAX)
		var steps: int = rng.randi_range(SimConstants.ANOMALY_STEPS_MIN,
			SimConstants.ANOMALY_STEPS_MAX)
		# Grow the spine from a random head along a wandering heading. Reject the whole
		# band if any spine point strays off-map or too near a system.
		var head := Vector2(rng.randf_range(r, size.x - r), rng.randf_range(r, size.y - r))
		var clear := true
		for an in sim.anomalies:   # keep band heads spread apart
			if head.distance_to(an.pts[0]) < min_apart:
				clear = false
				break
		if not clear:
			continue
		var pts := PackedVector2Array([head])
		var heading := rng.randf_range(0.0, TAU)
		var p := head
		for s in steps - 1:
			heading += rng.randf_range(-SimConstants.ANOMALY_TURN, SimConstants.ANOMALY_TURN)
			p = p + Vector2.from_angle(heading) * SimConstants.ANOMALY_STEP_LEN
			if p.x < r or p.y < r or p.x > size.x - r or p.y > size.y - r:
				clear = false
				break
			pts.append(p)
		if clear:
			for q in positions:   # keep the whole band off systems
				if _dist_point_to_polyline(q, pts) < r + SimConstants.ANOMALY_SYSTEM_CLEARANCE:
					clear = false
					break
		if clear:
			# Keep a clear corridor between whole storm BODIES (not just heads), so two
			# storms can never lie end-to-end / cross into a continuous wall that cuts the
			# map. There's always a gap wide enough to route influence and fleets through.
			for an in sim.anomalies:
				if _polyline_min_dist(pts, an.pts) < r + an.r + SimConstants.ANOMALY_CORRIDOR:
					clear = false
					break
		if clear:
			sim.add_anomaly(pts, r)


# Minimum spanning tree (Prim) so the whole map is one connected component, plus
# each system's nearest few extra lanes for loops and chokepoints.
# Lanes from a Delaunay triangulation of the node positions: its edges are exactly the
# near-neighbour connections, and being a triangulation they NEVER cross. Kruskal picks a
# minimum spanning tree out of those edges (always kept — one connected mesh, no islands).
# `density` in [0,1] then fills in the remaining Delaunay edges shortest-first, up to a
# radius cap, so min = a single wire and max = every planar near-neighbour lane.
static func _connect_systems(sim: Sim, sys_ids: Array, positions: Array,
		density: float) -> void:
	var n := sys_ids.size()
	if n < 2:
		return
	if n == 2:
		sim.add_lane(sys_ids[0], sys_ids[1])
		return
	var pts := PackedVector2Array()
	for p in positions:
		pts.append(p)
	# Unique undirected Delaunay edges as [dist, i, j], shortest first. Degenerate inputs
	# (all-collinear) yield no triangles — fall back to a nearest-neighbour candidate set.
	var tris := Geometry2D.triangulate_delaunay(pts)
	var seen := {}
	var edges: Array = []
	if tris.size() >= 3:
		for t in range(0, tris.size(), 3):
			var tri: Array = [tris[t], tris[t + 1], tris[t + 2]]
			for e in [[tri[0], tri[1]], [tri[1], tri[2]], [tri[2], tri[0]]]:
				var i: int = mini(e[0], e[1])
				var j: int = maxi(e[0], e[1])
				var key: int = i * n + j
				if not seen.has(key):
					seen[key] = true
					edges.append([positions[i].distance_to(positions[j]), i, j])
	else:
		for i in n:
			for j in range(i + 1, n):
				edges.append([positions[i].distance_to(positions[j]), i, j])
	edges.sort()   # by distance, then i, then j -> deterministic

	# Kruskal MST over the candidate edges: always connects the whole map (no islands).
	var parent: Array = []
	for i in n:
		parent.append(i)
	var in_mst := {}
	var mst_edges := 0
	for e in edges:
		if mst_edges >= n - 1:
			break
		var ri: int = _uf_find(parent, e[1])
		var rj: int = _uf_find(parent, e[2])
		if ri != rj:
			parent[ri] = rj
			in_mst[e[1] * n + e[2]] = true
			mst_edges += 1

	# Non-MST candidates, shortest first, capped to a "not too big" radius (a multiple of
	# the median candidate length) so max density is dense-but-local, never map-spanning.
	var extras: Array = []
	for e in edges:
		if not in_mst.has(e[1] * n + e[2]):
			extras.append(e)
	var cap := INF
	if not edges.is_empty():
		cap = float(edges[edges.size() / 2][0]) * 2.2
	var eligible: Array = []
	for e in extras:
		if e[0] <= cap:
			eligible.append(e)
	var take: int = int(round(clampf(density, 0.0, 1.0) * float(eligible.size())))

	for key in in_mst:
		# key = i*n + j -> recover endpoints
		sim.add_lane(sys_ids[key / n], sys_ids[key % n])
	for k in take:
		var e: Array = eligible[k]
		sim.add_lane(sys_ids[e[1]], sys_ids[e[2]])


# Union-find with path compression (iterative — GDScript has no tail-call).
static func _uf_find(parent: Array, x: int) -> int:
	var root := x
	while parent[root] != root:
		root = parent[root]
	while parent[x] != root:
		var nxt: int = parent[x]
		parent[x] = root
		x = nxt
	return root


# Place empires at maximally-separated planets (greedy farthest-point). First
# empire is the player; the rest get an AI. Each home planet is a water world with a
# colony + water mine; its nearest planet is given a mineral mine — so a new empire
# has both resource streams from tick 1 (one planet per node, so the two mines can't
# share a node like they used to).
static func _place_empires(sim: Sim, sys_ids: Array, positions: Array,
		count: int, ai_efficiency: float, player_color_idx: int = 0,
		personalities: Array = [], rng: RandomNumberGenerator = null) -> void:
	# Easier rivals also think slower (not just gather less) -- see ai_cadence_for.
	var ai_cadence: float = SimConstants.ai_cadence_for(ai_efficiency)
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

	# Colour assignment: the player (empire 0) takes their chosen hue; the AI empires
	# take the remaining palette entries in order, skipping the player's pick so no two
	# share a colour.
	var pc := posmod(player_color_idx, _EMPIRE_COLORS.size())
	var ai_colors: Array = []
	for i in _EMPIRE_COLORS.size():
		if i != pc:
			ai_colors.append(_EMPIRE_COLORS[i])
	for e_i in chosen.size():
		var sid: int = sys_ids[chosen[e_i]]
		var ename := "%s %s" % [sim.systems[sid].name,
			_EMPIRE_SUFFIX[e_i % _EMPIRE_SUFFIX.size()]]
		var col: Color = _EMPIRE_COLORS[pc] if e_i == 0 \
			else ai_colors[(e_i - 1) % ai_colors.size()]
		var emp := sim.add_empire(ename, col)
		if e_i > 0:   # AI empires scale with difficulty; the player stays at 1.0
			emp.efficiency = ai_efficiency
		# Home planet: water world + water mine + the seed colony.
		var home_p: Planet = sim.planets[sim.systems[sid].planet_ids[0]]
		home_p.deposit_type = SimConstants.Deposit.WATER
		home_p.mine_empire_id = emp.id
		sim.inject_colony(emp.id, home_p.id, 150.0, true)
		# Nearest other planet: a starting mineral mine (so alloys flow from tick 1).
		var hi: int = chosen[e_i]
		var best_j := -1
		var best_d := INF
		for j in n:
			if chosen.has(j):
				continue
			var d: float = positions[hi].distance_to(positions[j])
			if d < best_d:
				best_d = d
				best_j = j
		if best_j != -1:
			var mp: Planet = sim.planets[sim.systems[sys_ids[best_j]].planet_ids[0]]
			mp.deposit_type = SimConstants.Deposit.MINERAL
			mp.mine_empire_id = emp.id
		if e_i > 0:   # first empire is the human player
			# Personality per rival: config entry if given, else Balanced. A -1 entry
			# means "random", resolved here from the map seed so it stays deterministic.
			var persona: int = SimConstants.Personality.BALANCED
			var ai_idx: int = e_i - 1
			if ai_idx < personalities.size():
				persona = int(personalities[ai_idx])
			if persona < 0:
				persona = (rng.randi_range(0, SimConstants.PERSONALITY_NAMES.size() - 1)
					if rng != null else SimConstants.Personality.BALANCED)
			sim.add_ai(emp.id, persona, ai_cadence)


func add_ai(empire_id: int, persona: int = SimConstants.Personality.BALANCED,
		cadence: float = 1.0) -> void:
	ais.append(EmpireAI.new(empire_id, persona, cadence))


# --- save / load -------------------------------------------------------------
# Serialize the whole sim to a plain Dictionary (JSON-safe). deserialize() is the
# inverse. JSON turns every number into a float, so deserialize int()s all ids.

func serialize() -> Dictionary:
	var es: Array = []
	for e in empires.values():
		es.append({"id": e.id, "name": e.name,
			"color": [e.color.r, e.color.g, e.color.b, e.color.a],
			"minerals": e.minerals, "nat": e.nat.duplicate(), "eff": e.efficiency,
			"cap": e.capital_planet_id})
	var ss: Array = []
	for s in systems.values():
		ss.append({"id": s.id, "name": s.name, "x": s.map_pos.x, "y": s.map_pos.y,
			"depot": s.depot_empire_id, "obs": s.obs_post_empire_id,
			"imp": s.imperial_empire_id, "implvl": s.imperial_level,
			"impchg": s.imperial_charge,
			"cit": s.citadel_empire_id, "cithp": s.citadel_hp,
			"planets": s.planet_ids.duplicate()})
	var ps: Array = []
	for p in planets.values():
		ps.append({"id": p.id, "sys": p.system_id, "name": p.name,
			"dep": p.deposit_type, "mine": p.mine_empire_id, "mlvl": p.mine_level,
			"orad": p.orbit_radius, "oang": p.orbit_angle})
	var cs: Array = []
	for c in colonies:
		cs.append({"pid": c.planet_id, "eid": c.empire_id, "pop": c.population,
			"est": c.established, "emi": c.emigrating, "aban": c.abandoning})
	var fs: Array = []
	for f in fleets:
		fs.append({"id": f.id, "eid": f.empire_id, "sys": f.system_id,
			"path": f.path.duplicate(), "prog": f.progress,
			"fi": f.fighters.duplicate(), "bo": f.bombers.duplicate(),
			"dmg": f.damage, "sr": f.supply_reserve})
	var ai: Array = []
	for a in ais:
		ai.append({"eid": a.empire_id, "bc": a._build_count,
			"nad": a._next_action_day, "pers": a.personality, "cad": a.cadence})
	var ans: Array = []
	for an in anomalies:
		var xs: Array = []
		var ys: Array = []
		for pt in an.pts:
			xs.append(pt.x)
			ys.append(pt.y)
		ans.append({"xs": xs, "ys": ys, "r": an.r})
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
		emp.minerals = e.minerals
		emp.efficiency = e.eff
		var nat: Array[float] = []
		for v in e.nat:
			nat.append(float(v))
		emp.nat = nat
		emp.capital_planet_id = int(e.get("cap", -1))
		sim.empires[emp.id] = emp
	for s in d.systems:
		var sys := StarSystem.new()
		sys.id = int(s.id)
		sys.name = s.name
		sys.map_pos = Vector2(s.x, s.y)
		sys.depot_empire_id = int(s.depot)
		sys.obs_post_empire_id = int(s.get("obs", -1))
		sys.imperial_empire_id = int(s.get("imp", -1))
		sys.imperial_level = int(s.get("implvl", 0))
		sys.imperial_charge = float(s.get("impchg", 0.0))
		sys.citadel_empire_id = int(s.get("cit", -1))
		sys.citadel_hp = float(s.get("cithp", 0.0))
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
		col2.abandoning = c.get("aban", false)
		sim.planets[col2.planet_id].colony = col2
		sim.colonies.append(col2)
	for f in d.fleets:
		var fl := Fleet.new()
		fl.id = int(f.id)
		fl.empire_id = int(f.eid)
		fl.system_id = int(f.sys)
		fl.progress = f.prog
		fl.damage = f.dmg
		fl.supply_reserve = float(f.get("sr", SimConstants.SUPPLY_RESERVE_DAYS))
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
		var pts := PackedVector2Array()
		var xs: Array = an.get("xs", [])
		var ys: Array = an.get("ys", [])
		for i in xs.size():
			pts.append(Vector2(float(xs[i]), float(ys[i])))
		sim.add_anomaly(pts, float(an.r))
	for b in d.get("builders", []):
		var bpath: Array[int] = []
		for x in b.path:
			bpath.append(int(x))
		sim.builders.append({"id": int(b.id), "eid": int(b.eid), "sys": int(b.sys),
			"path": bpath, "prog": float(b.prog), "type": int(b.type),
			"target": int(b.target)})
	for a in d.ais:
		var ai := EmpireAI.new(int(a.eid),
			int(a.get("pers", SimConstants.Personality.BALANCED)), float(a.get("cad", 1.0)))
		ai._build_count = int(a.bc)
		ai._next_action_day = a.nad
		sim.ais.append(ai)
	# Back-compat: a save from before explicit capitals has none — seat each empire at
	# its largest colony. Then prime the connectivity snapshot so nothing reads stale.
	for e in sim.empires.values():
		if e.capital_planet_id == -1 or sim.planets.get(e.capital_planet_id) == null \
				or sim.planets[e.capital_planet_id].colony == null:
			e.capital_planet_id = sim._largest_colony_planet(e.id)
	sim.recompute_connectivity()
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
	_invalidate_influence_caches()   # a new system can be a claim target
	return sys


func add_planet(system_id: int, planet_name: String) -> Planet:
	var p := Planet.new()
	p.id = _next_id
	_next_id += 1
	p.system_id = system_id
	p.name = planet_name
	planets[p.id] = p
	systems[system_id].planet_ids.append(p.id)
	_invalidate_influence_caches()   # deposits/colonies here can change influence
	return p


func add_lane(a_system_id: int, b_system_id: int) -> void:
	lanes.append([a_system_id, b_system_id])
	_adj.clear()   # invalidate cached adjacency


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
	# The empire's first colony becomes its capital (the seat everything supplies from).
	var e: Empire = empires.get(empire_id)
	if e != null and e.capital_planet_id == -1:
		e.capital_planet_id = planet_id
	_invalidate_influence_caches()
	return c


# Force the per-tick owner/source caches to rebuild on the next query. Called when
# the set of influence sources changes mid-tick (colony founded/destroyed/split) so
# `day`-keyed caching can't hand back a stale ownership picture within the same tick.
func _invalidate_influence_caches() -> void:
	_owner_cache_day = -1.0
	_src_cache_day = -1.0


# --- capital & supply-line connectivity --------------------------------------

# The system the empire's capital sits in, or -1 (no capital, or its colony is gone).
func capital_system(empire_id: int) -> int:
	var e: Empire = empires.get(empire_id)
	if e == null or e.capital_planet_id == -1:
		return -1
	var p: Planet = planets.get(e.capital_planet_id)
	if p == null or p.colony == null or p.colony.empire_id != empire_id:
		return -1
	return p.system_id


# Is this colony connected to its capital (and thus alive economically)? A
# disconnected colony projects no influence, refines nothing and is off the water
# pool. Defaults to true before the first connectivity pass and for brand-new
# colonies (not yet in the snapshot), so nothing dies on the tick it's founded.
func _is_colony_active(c: Colony) -> bool:
	if _computing_connectivity:
		return true   # the pass itself evaluates over an all-active view
	if not _conn_computed:
		return true
	return _connected.get(c.planet_id, true)


# Rebuild the connected snapshot: from each empire's capital, BFS across lanes
# through systems it owns or that are neutral (never through enemy territory), over
# an ALL-active influence view. A colony is connected iff its system is reached.
# This is what disconnects an overrun colony (its own system flipped to the enemy)
# AND a colony an enemy salient has cut off from the capital. Called once per tick.
func recompute_connectivity(dt_days: float = 0.0) -> void:
	_computing_connectivity = true
	_invalidate_influence_caches()   # rebuild caches under the all-active view
	var raw_owner := {}
	for sid in systems:
		raw_owner[sid] = system_owner(sid)
	_computing_connectivity = false
	_invalidate_influence_caches()   # and back to the active-only view for the tick
	var nc := {}
	var live_pids := {}
	for e in empires.values():
		var cap_sys := capital_system(e.id)
		var reached := {}
		if cap_sys != -1:
			reached[cap_sys] = true
			var q: Array[int] = [cap_sys]
			while not q.is_empty():
				var s: int = q.pop_front()
				for nb in lane_neighbors(s):
					if reached.has(nb):
						continue
					var o: int = raw_owner.get(nb, -1)
					if o == -1 or o == e.id:
						reached[nb] = true
						q.append(nb)
		for c in colonies:
			if c.empire_id == e.id:
				var pid: int = c.planet_id
				live_pids[pid] = true
				# Grace debounce: a reachable colony is instantly active and its timer
				# resets; an unreachable one is still treated as active until it has been
				# cut off for CONNECT_GRACE_DAYS straight, so a one-tick frontier twitch
				# doesn't disconnect it.
				if reached.has(planets[pid].system_id):
					_disc_days[pid] = 0.0
					nc[pid] = true
				else:
					var d: float = _disc_days.get(pid, 0.0) + dt_days
					_disc_days[pid] = d
					nc[pid] = d < SimConstants.CONNECT_GRACE_DAYS
	# Drop timers for colonies that no longer exist so the dict can't grow unbounded.
	for pid in _disc_days.keys():
		if not live_pids.has(pid):
			_disc_days.erase(pid)
	_connected = nc
	_conn_computed = true


# Move the empire's capital to one of its own colonies. Only a CONNECTED (supplied)
# colony is a valid seat — you cannot relocate to a colony cut off from the current
# capital, nor to a disconnected/overrun one. Returns false if the move is illegal.
func move_capital(empire_id: int, planet_id: int) -> bool:
	var e: Empire = empires.get(empire_id)
	if e == null:
		return false
	var p: Planet = planets.get(planet_id)
	if p == null or p.colony == null or p.colony.empire_id != empire_id:
		return false
	if not _is_colony_active(p.colony):
		return false   # not connected to the current capital
	e.capital_planet_id = planet_id
	return true


# Remove a colony from the map (0-pop, abandoned-out, or wiped). If it was the
# empire's capital and other colonies remain, the seat falls back to the largest;
# combat destruction of a capital is handled separately (it eliminates the empire).
func _remove_colony(c: Colony) -> void:
	var eid := c.empire_id
	_clear_imperial_on(c.planet_id, eid)
	planets[c.planet_id].colony = null
	colonies.erase(c)
	var e: Empire = empires.get(eid)
	if e != null and e.capital_planet_id == c.planet_id:
		e.capital_planet_id = _largest_colony_planet(eid)
	_invalidate_influence_caches()


# The imperial centre is PART of its colony — it stands and falls with the colony and is
# never captured by a conqueror. Clear it the moment the anchoring colony is removed so it
# can't outlive it (mine/depot/obs/citadel still resolve on the next border pass).
func _clear_imperial_on(planet_id: int, empire_id: int) -> void:
	var sid: int = planets[planet_id].system_id
	var s: StarSystem = systems.get(sid)
	if s != null and s.imperial_empire_id == empire_id:
		s.imperial_empire_id = -1
		s.imperial_level = 0
		s.imperial_charge = 0.0


# The planet of an empire's most-populated colony, or -1 if it has none.
func _largest_colony_planet(empire_id: int) -> int:
	var best := -1
	var best_pop := -1.0
	for c in colonies:
		if c.empire_id == empire_id and c.population > best_pop:
			best_pop = c.population
			best = c.planet_id
	return best


# The capital fell: the empire collapses. Every one of its colonies is deleted at
# once (even ones with enough local water to survive) — a split-off remnant does not
# carry on without its seat. Structures revert on the next border pass.
func _eliminate_empire(empire_id: int) -> void:
	var doomed: Array[Colony] = []
	for c in colonies:
		if c.empire_id == empire_id:
			doomed.append(c)
	for c in doomed:
		_clear_imperial_on(c.planet_id, empire_id)
		planets[c.planet_id].colony = null
		colonies.erase(c)
	var e: Empire = empires.get(empire_id)
	if e != null:
		e.capital_planet_id = -1
	_invalidate_influence_caches()


# --- topology ----------------------------------------------------------------

func lane_neighbors(system_id: int) -> Array[int]:
	# Cached adjacency (rebuilt lazily; invalidated on add_lane). Returns a COPY so
	# callers that sort/mutate the list don't corrupt the cache. Was O(lanes) per
	# call — a killer inside BFS/AI loops on big maps.
	if _adj.is_empty() and not lanes.is_empty():
		_build_adjacency()
	var out: Array[int] = []
	for nb in _adj.get(system_id, []):
		out.append(nb)
	return out


func _build_adjacency() -> void:
	_adj.clear()
	for l in lanes:
		if not _adj.has(l[0]):
			_adj[l[0]] = []
		if not _adj.has(l[1]):
			_adj[l[1]] = []
		_adj[l[0]].append(l[1])
		_adj[l[1]].append(l[0])


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
		if c != null and c.empire_id == empire_id and _is_colony_active(c):
			best = maxf(best, SimConstants.INFLUENCE_A1 * c.population)
	# An imperial center here amplifies the influence its colony projects (for extra water,
	# charged in the demand loop). Bigger borders/reach/VR — influence you buy, not grow.
	if best > 0.0 and systems[system_id].imperial_empire_id == empire_id:
		best *= 1.0 + _imperial_bonus(system_id)
	# An observation post projects its own sensor influence even with no colony here, so a
	# forward watchtower still reaches outward (influence_reach then doubles it). On a real
	# colony the colony's influence is larger, so maxf leaves established borders untouched.
	if systems[system_id].obs_post_empire_id == empire_id:
		best = maxf(best, SimConstants.OBS_POST_INFLUENCE)
	return best


# Influence bonus fraction of the imperial center in a system (0 if none). Level L gives
# +L*10% at full charge; the per-center imperial_charge (0..1) scales it, winding up when the
# level's tier alloy is fed and down when starved — so a just-dialed or starved center's bonus
# is partial, not instant (see StarSystem.imperial_charge, tick step 2b).
func _imperial_bonus(system_id: int) -> float:
	var s: StarSystem = systems[system_id]
	var lvl: int = s.imperial_level
	if lvl <= 0:
		return 0.0
	lvl = mini(lvl, SimConstants.IMPERIAL_MAX_LEVEL)
	var base: float = lvl * SimConstants.IMPERIAL_BONUS_PER_LEVEL
	return base * clampf(s.imperial_charge, 0.0, 1.0)


# Highest imperial level this system can host right now, gated by colony SIZE: level L needs
# the owning empire's top colony here past MIL_CUTOFF[L-1] (the same pop that unlocks refining
# tier L). 0 = no eligible colony, so nothing can be built/kept. Keeps a tiny border outpost
# from mounting a high-level center as a cheap frontline influence weapon.
func max_imperial_level(system_id: int) -> int:
	var owner: int = systems[system_id].imperial_empire_id
	var top := 0.0
	for pid in systems[system_id].planet_ids:
		var c: Colony = planets[pid].colony
		if c != null and (owner == -1 or c.empire_id == owner):
			top = maxf(top, c.population)
	var lvl := 0
	for t in SimConstants.IMPERIAL_MAX_LEVEL:
		if top >= SimConstants.MIL_CUTOFF[t]:
			lvl = t + 1
		else:
			break
	return lvl


# Public alias (UI reads this to show the current effective bonus).
func imperial_bonus_at(system_id: int) -> float:
	return _imperial_bonus(system_id)


# Charge fraction (1.0 full, <1.0 spinning up / starved) of the center in a system — 1.0 if
# none. UI only (shows how far wound-up the bonus is).
func imperial_feed_at(system_id: int) -> float:
	var s: StarSystem = systems[system_id]
	if s.imperial_level <= 0 or s.imperial_empire_id == -1:
		return 1.0
	return clampf(s.imperial_charge, 0.0, 1.0)


# --- cosmic anomalies ---------------------------------------------------------
# Anomalies block both influence and visibility: no claim/sight inside one, and
# neither influence nor sight crosses one (a source can't project past it).

func point_in_anomaly(p: Vector2) -> bool:
	for an in anomalies:
		if not an.bb.has_point(p):   # cheap AABB reject before the polyline distance
			continue
		if _dist_point_to_polyline(p, an.pts) < an.r:
			return true
	return false


# True if the segment a→b passes through any anomaly (blocking influence/sight).
func segment_hits_anomaly(a: Vector2, b: Vector2) -> bool:
	for an in anomalies:
		# Cheap AABB reject: skip the storm if the segment's box misses its grown box.
		if not an.bb.intersects(Rect2(a, Vector2.ZERO).expand(b)):
			continue
		var pts: PackedVector2Array = an.pts
		for i in pts.size() - 1:
			if _seg_seg_dist(a, b, pts[i], pts[i + 1]) < an.r:
				return true
		# A single-point (degenerate) spine has no segment to test above.
		if pts.size() == 1 and _dist_point_to_segment(pts[0], a, b) < an.r:
			return true
	return false


# Shortest distance from point p to the polyline `pts` (a storm's spine).
static func _dist_point_to_polyline(p: Vector2, pts: PackedVector2Array) -> float:
	if pts.is_empty():
		return INF
	if pts.size() == 1:
		return p.distance_to(pts[0])
	var best := INF
	for i in pts.size() - 1:
		best = minf(best, _dist_point_to_segment(p, pts[i], pts[i + 1]))
	return best


static func _dist_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	var t := 0.0 if len2 <= 0.0 else clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


# Shortest distance between two segments (p1p2 and p3p4). 0 if they cross.
static func _seg_seg_dist(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> float:
	if Geometry2D.segment_intersects_segment(p1, p2, p3, p4) != null:
		return 0.0
	return minf(
		minf(_dist_point_to_segment(p1, p3, p4), _dist_point_to_segment(p2, p3, p4)),
		minf(_dist_point_to_segment(p3, p1, p2), _dist_point_to_segment(p4, p1, p2)))


# Shortest distance between two polylines (storm spines). Used at map-gen to enforce a
# clear corridor between storms so they can't chain into a map-splitting wall.
static func _polyline_min_dist(a: PackedVector2Array, b: PackedVector2Array) -> float:
	if a.is_empty() or b.is_empty():
		return INF
	if a.size() == 1 and b.size() == 1:
		return a[0].distance_to(b[0])
	if a.size() == 1:
		return _dist_point_to_polyline(a[0], b)
	if b.size() == 1:
		return _dist_point_to_polyline(b[0], a)
	var best := INF
	for i in a.size() - 1:
		for j in b.size() - 1:
			best = minf(best, _seg_seg_dist(a[i], a[i + 1], b[j], b[j + 1]))
	return best


# Influence from source system to a point is blocked if the point is inside an
# anomaly or the line to it crosses one. Used by both the logic claim and the field.
func influence_blocked(src: Vector2, dst: Vector2) -> bool:
	if anomalies.is_empty():
		return false
	return point_in_anomaly(dst) or segment_hits_anomaly(src, dst)


# The one place a storm enters the sim: precomputes its AABB so every anomaly dict
# always carries `bb`. Map-gen and tests both go through here.
func add_anomaly(pts: PackedVector2Array, r: float) -> void:
	anomalies.append({"pts": pts, "r": r, "bb": anomaly_bbox(pts, r)})


# Bounding box of a spine, grown by r on every side — a cheap AABB reject volume.
static func anomaly_bbox(pts: PackedVector2Array, r: float) -> Rect2:
	if pts.is_empty():
		return Rect2()
	var bb := Rect2(pts[0], Vector2.ZERO)
	for i in range(1, pts.size()):
		bb = bb.expand(pts[i])
	return bb.grow(r)


# influence_blocked between two systems, memoized by ordered id pair. The map is
# immutable after gen, so a blocked pair stays blocked forever — no invalidation.
func _pair_blocked(src_id: int, dst_id: int, src_pos: Vector2, dst_pos: Vector2) -> bool:
	if anomalies.is_empty():
		return false
	var key: int = src_id * 100000 + dst_id
	var v = _blocked_pair.get(key)
	if v == null:
		v = point_in_anomaly(dst_pos) or segment_hits_anomaly(src_pos, dst_pos)
		_blocked_pair[key] = v
	return v


func influence_reach(system_id: int, empire_id: int) -> float:
	var r := SimConstants.BORDER_A2 * system_influence(system_id, empire_id)
	# An observation post owned by this empire here doubles how far influence reaches.
	if systems[system_id].obs_post_empire_id == empire_id:
		r *= SimConstants.OBS_POST_REACH_MULT
	return r


# Per-tick cache of every empire's influence sources. Only systems that actually
# project influence (have a colony) contribute to any claim, but there are few of
# them relative to the whole map — iterating all systems per claim_strength call
# made owner-resolution O(planets²) even on an empty early-game map. Rebuilt once
# per tick, keyed by `day`. Each entry: {id, inf, reach, pos}.
func _influence_sources(empire_id: int) -> Array:
	if _src_cache_day != day:
		_src_cache_day = day
		_src_cache.clear()
	if _src_cache.has(empire_id):
		return _src_cache[empire_id]
	var out: Array = []
	for sys in systems.values():
		var inf := system_influence(sys.id, empire_id)
		if inf <= 0.0:
			continue
		out.append({"id": sys.id, "inf": inf, "reach": influence_reach(sys.id, empire_id),
			"pos": sys.map_pos})
	_src_cache[empire_id] = out
	return out


# Claim on a target system: max over own influence sources of influence/distance,
# counting only sources whose reach actually covers the target. Own presence in
# the target system is an absolute claim. The influence/distance form makes
# contested borders sit exactly where border1/border2 = influence1/influence2.
func claim_strength(target_system_id: int, empire_id: int) -> float:
	var best := 0.0
	var tpos: Vector2 = systems[target_system_id].map_pos
	for src in _influence_sources(empire_id):
		if src.id == target_system_id:
			# A colony's claim on its own system is strong but FINITE, so overwhelming
			# enemy influence can overrun it (the system flips; the colony survives
			# inside a tiny bubble and goes disconnected). Take the max — an enemy needs
			# to beat this, not merely tie it.
			best = maxf(best, src.inf / SimConstants.SELF_CLAIM_DIST)
			continue
		var d: float = src.pos.distance_to(tpos)
		if d <= src.reach and not _pair_blocked(src.id, target_system_id, src.pos, tpos):
			best = maxf(best, src.inf / d)
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


# Cached owner, rebuilt once per tick (keyed by `day`). system_owner is O(planets²)
# and gets hammered inside AI pathfinding and gating; the cache turns those into O(1)
# lookups. Safe within a tick — ownership only shifts gradually between ticks.
func owner_cached(system_id: int) -> int:
	if _owner_cache_day != day:
		_owner_cache_day = day
		_owner_cache.clear()
		for sid in systems:
			_owner_cache[sid] = system_owner(sid)
	return _owner_cache.get(system_id, -1)


func is_under_influence(system_id: int, empire_id: int) -> bool:
	return owner_cached(system_id) == empire_id


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
	if not SimConstants.NEIGHBOR_BONUS_ENABLED:
		return 1.0   # master switch OFF (see NEIGHBOR_BONUS_ENABLED); code kept for later
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


# Single chokepoint for spending alloy on ships/structures. Debits the tier stockpile
# AND records the outlay in spent_nat so income-rate readouts show production only, not
# the dip from a purchase. Pass a negative amount to refund (e.g. a spoiled build).
func _pay(empire_id: int, tier: int, amount: float) -> void:
	var e: Empire = empires[empire_id]
	e.nat[tier] -= amount
	e.spent_nat[tier] += amount


# Water is a FLOW: surplus/day = last tick's (income − demand) normalized to one day.
# It's the empire's spare water — how much a new colony can draw before the empire tips
# into deficit (which shrinks population). Founding is gated on it so expansion is limited
# by how much water territory you hold, not just alloys.
func water_surplus_per_day(empire_id: int) -> float:
	var e: Empire = empires.get(empire_id)
	if e == null:
		return 0.0
	return (e.water_income - e.water_demand) / SimConstants.TICK_DAYS


# Water/day a freshly-founded colony adds to demand: its seed population's draw plus the
# fixed per-colony overhead (the sprawl cost, WATER_PER_COLONY — a flat 0.5, NOT an
# exponential). Shown in the UI and used to gate founding.
func new_colony_water_per_day(_empire_id: int) -> float:
	return SimConstants.START_POP * SimConstants.WATER_PER_POP \
		+ SimConstants.WATER_PER_COLONY


# Enough spare water flow to supply one more colony? (income − demand covers its draw.)
func has_water_for_new_colony(empire_id: int) -> bool:
	return water_surplus_per_day(empire_id) >= new_colony_water_per_day(empire_id)


func can_found_colony(empire_id: int, planet_id: int) -> bool:
	var e: Empire = empires.get(empire_id)
	return e != null and e.nat[0] >= SimConstants.FOUND_COST_ALLOYS \
		and has_water_for_new_colony(empire_id) \
		and _colony_target_ok(empire_id, planet_id)


func found_colony(empire_id: int, planet_id: int) -> bool:
	if not can_found_colony(empire_id, planet_id):
		return false
	_pay(empire_id, 0, SimConstants.FOUND_COST_ALLOYS)
	var c := inject_colony(empire_id, planet_id, SimConstants.START_POP, false)
	return c != null


func can_build_mine(empire_id: int, planet_id: int) -> bool:
	# "Wherever deposits exist within reach" — influence-gated, a colony in the
	# system is not required.
	var e: Empire = empires.get(empire_id)
	return e != null and e.nat[0] >= SimConstants.MINE_COST_ALLOYS \
		and _mine_target_ok(empire_id, planet_id)


func build_mine(empire_id: int, planet_id: int) -> bool:
	if not can_build_mine(empire_id, planet_id):
		return false
	_pay(empire_id, 0, SimConstants.MINE_COST_ALLOYS)
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
			var o := owner_cached(nb)
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
	if e == null or e.nat[0] < _construction_cost(build_type):
		return false
	# A colony draws water; don't dispatch one the empire can't supply (same gate as
	# found_colony). Mines have no water cost, so they skip it.
	if build_type == SimConstants.Build.COLONY and not has_water_for_new_colony(empire_id):
		return false
	if not _construction_target_ok(empire_id, build_type, target_id):
		return false
	var cap := capital_system(empire_id)
	var tsys := _target_system_of(build_type, target_id)
	if cap == -1 or tsys == -1:
		return false
	if cap == tsys:
		return true   # build in the capital's own system, no travel
	return not lane_path_friendly(cap, tsys, empire_id).is_empty()


func order_construction(empire_id: int, build_type: int, target_id: int) -> bool:
	if not can_order_construction(empire_id, build_type, target_id):
		return false
	var cap := capital_system(empire_id)
	var tsys := _target_system_of(build_type, target_id)
	_pay(empire_id, 0, _construction_cost(build_type))
	builders.append({"id": _next_id, "eid": empire_id, "sys": cap,
		"path": lane_path_friendly(cap, tsys, empire_id), "prog": 0.0,
		"type": build_type, "target": target_id})
	_next_id += 1
	return true


func builder_position(b: Dictionary) -> Vector2:
	if b.path.is_empty():
		return systems[b.sys].map_pos
	return systems[b.sys].map_pos.lerp(systems[b.path[0]].map_pos, b.prog)


# True if a construction vessel can no longer legally reach its target. Mutates
# b.path to reroute around freshly-hostile intermediate systems when a friendly
# path still exists (so a vessel bends around an advancing border instead of
# ploughing through it). Enemy = a system owned by any empire other than eid.
func _builder_route_blocked(b: Dictionary, eid: int, tsys: int) -> bool:
	# Stranded: the player (or another rival) overran the system the vessel is in.
	var here := owner_cached(b.sys)
	if here != -1 and here != eid:
		return true
	# The target system itself turned hostile — can't deliver without invading.
	var to := owner_cached(tsys)
	if tsys != b.sys and to != -1 and to != eid:
		return true
	# Any hop still ahead (bar the target) that turned hostile forces a reroute.
	var needs_reroute := false
	for sid in b.path:
		if sid == tsys:
			continue
		var o := owner_cached(sid)
		if o != -1 and o != eid:
			needs_reroute = true
			break
	if needs_reroute:
		if b.sys == tsys:
			b.path = []   # already home; let the arrival branch place it
			return false
		var route := lane_path_friendly(b.sys, tsys, eid)
		if route.is_empty():
			return true   # no friendly way through — scrap it
		b.path = route
	return false


# Move vessels a tick; when one reaches its target system, place the structure (or
# refund if the target is no longer valid). Called from tick().
func _advance_builders(dt_days: float) -> void:
	var done: Array = []
	var scrapped: Array = []
	for b in builders:
		var eid: int = b.eid
		var tsys := _target_system_of(b.type, b.target)
		# A civilian vessel can't cross enemy territory, and borders MOVE while it's
		# in flight — the route computed at dispatch goes stale the moment an empire's
		# influence advances across it. Re-check every tick: reroute around new enemy
		# ground if a friendly path still exists, else scrap the vessel and refund.
		if tsys == -1 or _builder_route_blocked(b, eid, tsys):
			scrapped.append(b)
			continue
		if not b.path.is_empty():
			var length: float = maxf(system_distance(b.sys, b.path[0]), 1.0)
			b.prog += SimConstants.BUILDER_SPEED * dt_days / length
			if b.prog >= 1.0:
				b.sys = b.path.pop_front()
				b.prog = 0.0
		if b.path.is_empty():   # arrived at the target system
			done.append(b)
	for b in scrapped:
		builders.erase(b)
		_pay(b.eid, 0, -_construction_cost(b.type))   # nothing built — refund dispatch
	for b in done:
		builders.erase(b)
		var eid: int = b.eid
		if _construction_target_ok(eid, b.type, b.target):
			if b.type == SimConstants.Build.COLONY:
				inject_colony(eid, b.target, SimConstants.START_POP, false)
			else:
				planets[b.target].mine_empire_id = eid
		else:   # target spoiled in transit — refund what was paid at dispatch
			_pay(eid, 0, -_construction_cost(b.type))


func toggle_emigration(empire_id: int, planet_id: int) -> void:
	var p: Planet = planets.get(planet_id)
	if p != null and p.colony != null and p.colony.empire_id == empire_id:
		p.colony.emigrating = not p.colony.emigrating


func toggle_abandon(empire_id: int, planet_id: int) -> void:
	var p: Planet = planets.get(planet_id)
	if p != null and p.colony != null and p.colony.empire_id == empire_id:
		p.colony.abandoning = not p.colony.abandoning


# A mine can be upgraded when the same planet holds a big enough colony of the
# owning empire (and there are alloys to pay for it).
func can_upgrade_mine(empire_id: int, planet_id: int) -> bool:
	var p: Planet = planets.get(planet_id)
	var e: Empire = empires.get(empire_id)
	if p == null or e == null or not p.has_mine() or p.mine_empire_id != empire_id:
		return false
	if p.mine_level >= SimConstants.MINE_MAX_LEVEL:
		return false
	if e.nat[0] < SimConstants.MINE_UPGRADE_COST_ALLOYS:
		return false
	var c: Colony = p.colony
	return c != null and c.empire_id == empire_id \
		and c.population >= (p.mine_level + 1) * SimConstants.MINE_UPGRADE_POP


func upgrade_mine(empire_id: int, planet_id: int) -> bool:
	if not can_upgrade_mine(empire_id, planet_id):
		return false
	_pay(empire_id, 0, SimConstants.MINE_UPGRADE_COST_ALLOYS)
	planets[planet_id].mine_level += 1
	return true


# Supply depot: one per system, built in your influence for alloys.
func can_build_depot(empire_id: int, system_id: int) -> bool:
	var e: Empire = empires.get(empire_id)
	return e != null and systems.has(system_id) \
		and systems[system_id].depot_empire_id == -1 \
		and e.nat[0] >= SimConstants.DEPOT_COST_ALLOYS \
		and is_under_influence(system_id, empire_id)


func build_depot(empire_id: int, system_id: int) -> bool:
	if not can_build_depot(empire_id, system_id):
		return false
	_pay(empire_id, 0, SimConstants.DEPOT_COST_ALLOYS)
	systems[system_id].depot_empire_id = empire_id
	return true


# Observation post: one per system, built in your influence for alloys. Doubles the
# system's influence reach (see influence_reach).
func can_build_obs_post(empire_id: int, system_id: int) -> bool:
	var e: Empire = empires.get(empire_id)
	return e != null and systems.has(system_id) \
		and systems[system_id].obs_post_empire_id == -1 \
		and e.nat[0] >= SimConstants.OBS_POST_COST_ALLOYS \
		and is_under_influence(system_id, empire_id)


func build_obs_post(empire_id: int, system_id: int) -> bool:
	if not can_build_obs_post(empire_id, system_id):
		return false
	_pay(empire_id, 0, SimConstants.OBS_POST_COST_ALLOYS)
	systems[system_id].obs_post_empire_id = empire_id
	return true


# Citadel: one per system, built in your influence for a heavy alloy cost. A fortress
# that walls the system off (see _blocks_enemy_transit) until an attacker bombards its
# massive hull to zero.
func can_build_citadel(empire_id: int, system_id: int) -> bool:
	var e: Empire = empires.get(empire_id)
	return e != null and systems.has(system_id) \
		and systems[system_id].citadel_empire_id == -1 \
		and e.nat[0] >= SimConstants.CITADEL_COST_ALLOYS \
		and is_under_influence(system_id, empire_id)


func build_citadel(empire_id: int, system_id: int) -> bool:
	if not can_build_citadel(empire_id, system_id):
		return false
	_pay(empire_id, 0, SimConstants.CITADEL_COST_ALLOYS)
	systems[system_id].citadel_empire_id = empire_id
	systems[system_id].citadel_hp = SimConstants.CITADEL_MAX_HP
	return true


# Imperial center: one per system, on your influence, over one of your colonies. Building it
# is level 1 (+10% influence, eats T1 alloy). You then DIAL the level 1..max via a menu, where
# max is gated by colony size (max_imperial_level). Each level raises the bonus and the alloy-
# tier drain (see the imperial tick step), and the bonus winds up/down with charge rather than
# snapping in. Amplifies system_influence; the alloy cost is charged per tick.
func can_build_imperial(empire_id: int, system_id: int) -> bool:
	var e: Empire = empires.get(empire_id)
	return e != null and systems.has(system_id) \
		and systems[system_id].imperial_empire_id == -1 \
		and e.nat[0] >= SimConstants.IMPERIAL_COST_ALLOYS \
		and is_under_influence(system_id, empire_id) \
		and _empire_has_colony_in(empire_id, system_id)


func build_imperial(empire_id: int, system_id: int) -> bool:
	if not can_build_imperial(empire_id, system_id):
		return false
	_pay(empire_id, 0, SimConstants.IMPERIAL_COST_ALLOYS)
	systems[system_id].imperial_empire_id = empire_id
	systems[system_id].imperial_level = 1
	systems[system_id].imperial_charge = 0.0   # winds up from cold — no instant bonus
	_invalidate_influence_caches()
	return true


# The dial: set the center to an exact level. level 0 demolishes it. Clamped to the colony-
# size gate so you can never pick above max_imperial_level. Charge carries across a level
# change (it re-winds toward the new tier's affordability). The single UI command — upgrade/
# lower below are thin wrappers kept for the AI and tests.
func set_imperial_level(empire_id: int, system_id: int, level: int) -> bool:
	if not systems.has(system_id):
		return false
	var s: StarSystem = systems[system_id]
	if s.imperial_empire_id != empire_id or s.imperial_level < 1:
		return false
	level = clampi(level, 0, max_imperial_level(system_id))
	if level == s.imperial_level:
		return false
	s.imperial_level = level
	if level <= 0:
		s.imperial_empire_id = -1
		s.imperial_charge = 0.0
	_invalidate_influence_caches()
	return true


# Raise the center's level by one (up to the colony-size gate). Free — the alloy drain is the
# cost. Winds up with charge, not instantly.
func can_upgrade_imperial(empire_id: int, system_id: int) -> bool:
	if not systems.has(system_id):
		return false
	var s: StarSystem = systems[system_id]
	return s.imperial_empire_id == empire_id and s.imperial_level >= 1 \
		and s.imperial_level < max_imperial_level(system_id)


func upgrade_imperial(empire_id: int, system_id: int) -> bool:
	if not can_upgrade_imperial(empire_id, system_id):
		return false
	return set_imperial_level(empire_id, system_id, systems[system_id].imperial_level + 1)


# Lower the center's level by one; dropping below level 1 demolishes it entirely.
func can_lower_imperial(empire_id: int, system_id: int) -> bool:
	if not systems.has(system_id):
		return false
	var s: StarSystem = systems[system_id]
	return s.imperial_empire_id == empire_id and s.imperial_level >= 1


func lower_imperial(empire_id: int, system_id: int) -> bool:
	if not can_lower_imperial(empire_id, system_id):
		return false
	return set_imperial_level(empire_id, system_id, systems[system_id].imperial_level - 1)


# A fleet is in supply if a friendly depot sits in its system or a lane-neighbor.
# True if a friendly supply depot sits within DEPOT_SUPPLY_JUMPS lane hops of the
# fleet's system (0 hops = same system) — the safe supply radius that negates border
# attrition. BFS out to the jump limit; sorted neighbours keep it deterministic.
func _fleet_supplied(f: Fleet) -> bool:
	var seen := {f.system_id: 0}
	var queue: Array = [f.system_id]
	while not queue.is_empty():
		var s: int = queue.pop_front()
		if systems[s].depot_empire_id == f.empire_id:
			return true
		var d: int = seen[s]
		if d >= SimConstants.DEPOT_SUPPLY_JUMPS:
			continue
		var nbs: Array = lane_neighbors(s)
		nbs.sort()
		for nb in nbs:
			if not seen.has(nb):
				seen[nb] = d + 1
				queue.append(nb)
	return false


# Is this fleet in SAFE space (no reserve drain, no attrition)? Safe if it sits on its own
# border, ONE lane hop beyond it (free border grace — routine skirmishes need no supply
# line), or within a friendly depot's radius.
func _fleet_safe(f: Fleet) -> bool:
	if owner_cached(f.system_id) == f.empire_id:
		return true
	for nb in lane_neighbors(f.system_id):
		if owner_cached(nb) == f.empire_id:
			return true
	return _fleet_supplied(f)


# Public wrapper: is this fleet currently in safe supply space? (Renderer uses it to flag a
# fleet that's burning its supply reserve / bleeding attrition out in foreign space.)
func fleet_supplied(f: Fleet) -> bool:
	return _fleet_safe(f)


# Fraction of the supply reserve a fleet has left (1 = full, 0 = dry → taking attrition).
func fleet_reserve_frac(f: Fleet) -> float:
	return clampf(f.supply_reserve / SimConstants.SUPPLY_RESERVE_DAYS, 0.0, 1.0)


# True once a fleet is unsafe AND out of reserve — i.e. actively losing hull to attrition.
func fleet_starving(f: Fleet) -> bool:
	return not _fleet_safe(f) and f.supply_reserve <= 0.0


# The set of systems that are SAFE for an empire's fleets — no border attrition there.
# A system is safe if the empire owns its border OR a friendly supply depot sits within
# DEPOT_SUPPLY_JUMPS lane hops (multi-source BFS from every friendly depot). Returned as
# {system_id: true} so the renderer can tint the supplied reach when a fleet is selected.
func supply_safe_systems(empire_id: int) -> Dictionary:
	var safe := {}
	for sid in systems:
		if owner_cached(sid) == empire_id:
			safe[sid] = true
	# +1 hop border grace (no depot needed): the ring of systems one lane out from any
	# owned system is safe too, so border skirmishes stay attrition-free.
	for sid in systems:
		if owner_cached(sid) == empire_id:
			for nb in lane_neighbors(sid):
				safe[nb] = true
	var dist := {}
	var queue: Array = []
	for sid in systems:
		if systems[sid].depot_empire_id == empire_id:
			dist[sid] = 0
			safe[sid] = true
			queue.append(sid)
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		var d: int = dist[cur]
		if d >= SimConstants.DEPOT_SUPPLY_JUMPS:
			continue
		var nbs: Array = lane_neighbors(cur)
		nbs.sort()
		for nb in nbs:
			if not dist.has(nb):
				dist[nb] = d + 1
				safe[nb] = true
				queue.append(nb)
	return safe


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


# A stationary enemy fleet (with ships) sitting in this system — i.e. a live battle.
func _has_enemy_fleet(empire_id: int, system_id: int) -> bool:
	for f in fleets:
		if f.empire_id != empire_id and not f.is_moving() \
				and f.system_id == system_id and f.ship_count() > 0:
			return true
	return false


# FTL-inhibitor pin (Stellaris-style), so fleets can't teleport-dodge in and out of an
# engagement. Returns for a stationary fleet:
#   2 = LOCKED — an enemy fleet is here (a battle): no jump at all until it resolves.
#   1 = RETREAT-ONLY — sitting over an enemy colony: may only fall back the way it came
#       (prev_system); it can't advance deeper, it must take the world or withdraw.
#   0 = FREE.
func fleet_pin(f: Fleet) -> int:
	if f.is_moving():
		return 0
	if _has_enemy_fleet(f.empire_id, f.system_id):
		return 2
	if _has_enemy_colony(f.empire_id, f.system_id):
		return 1
	return 0


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
		and capital_system(empire_id) != -1


# Build one ship (role, tier) above the empire's most-populated city, paid in the
# tier's national military resource. It joins (or forms) a stationary fleet there.
func build_ship(empire_id: int, role: int, tier: int) -> bool:
	if not can_build_ship(empire_id, tier):
		return false
	var sys := capital_system(empire_id)
	_pay(empire_id, tier - 1, SimConstants.SHIP_NAT_COST)
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


# True if this system stops an enemy fleet from passing THROUGH it: it holds an enemy
# colony (planets block movement), or a standing enemy citadel (a fortress that must be
# bombarded down to advance past). Such a system can still be a fleet's destination —
# you march in to attack it — but a route may not thread through it to somewhere beyond.
func _blocks_enemy_transit(empire_id: int, system_id: int) -> bool:
	if _has_enemy_colony(empire_id, system_id):
		return true
	var sys: StarSystem = systems[system_id]
	return sys.citadel_empire_id != -1 and sys.citadel_empire_id != empire_id \
		and sys.citadel_hp > 0.0


# Lane BFS for a fleet: like lane_path, but a route may not pass THROUGH a system that
# blocks enemy transit (enemy colony or standing enemy citadel). The destination itself
# is always reachable if a lane leads to it — you can always march in to attack. [] if
# no legal route.
func lane_path_fleet(from_sys: int, to_sys: int, empire_id: int) -> Array[int]:
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
			if nb == to_sys or not _blocks_enemy_transit(empire_id, nb):
				prev[nb] = s
				queue.append(nb)
	if not prev.has(to_sys):
		return out
	var cur := to_sys
	while cur != from_sys:
		out.push_front(cur)
		cur = prev[cur]
	return out


# Order a fleet to a system. Returns false (order refused) when the fleet is pinned:
# locked in a fleet battle (can't move), or over an enemy colony and told to advance
# somewhere other than its retreat lane. This is the FTL inhibitor — it stops fleets
# (the AI especially) from jumping away the instant a fight turns against them.
func order_fleet(fleet_id: int, dest_system: int) -> bool:
	var f := get_fleet(fleet_id)
	if f == null:
		return false
	var pin := fleet_pin(f)
	if pin == 2:
		return false   # in a battle — held until it resolves
	if pin == 1 and dest_system != f.prev_system:
		return false   # over an enemy colony — retreat the way you came, or take it
	# Fleets can't thread through enemy-held systems (they must go around, or make the
	# blocking system their target). No legal route = order refused.
	var route := lane_path_fleet(f.system_id, dest_system, f.empire_id)
	if route.is_empty():
		return false
	f.path = route
	f.progress = 0.0
	return true


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
	# Destroying a colony that is an empire's CAPITAL ends that empire outright: all its
	# colonies are wiped (a decapitated empire does not fight on from a remnant). Collect
	# the fallen capitals first, so an empire is only eliminated once.
	var fallen_capitals := {}
	for c in destroyed_colonies:
		var e: Empire = empires.get(c.empire_id)
		if e != null and e.capital_planet_id == c.planet_id:
			fallen_capitals[c.empire_id] = true
	for c in destroyed_colonies:
		if planets[c.planet_id].colony == c:   # may already be gone via elimination
			planets[c.planet_id].colony = null
			colonies.erase(c)
	for eid in fallen_capitals:
		_eliminate_empire(eid)
	if not destroyed_colonies.is_empty():
		_invalidate_influence_caches()

	# Border attrition, "oxygen" model: a fleet in unsafe space first burns a depletable
	# supply reserve; only once that hits 0 does it bleed hull ∝ its own size. Safe space
	# (own border, +1 hop grace, or a depot radius) refills the reserve fast. This buys a
	# raid-and-return window instead of the old instant death-strike. Moving fleets are
	# keyed on the system they're leaving — marching through foreign space still costs.
	for f in fleets:
		if _fleet_safe(f):
			f.supply_reserve = minf(SimConstants.SUPPLY_RESERVE_DAYS,
				f.supply_reserve + SimConstants.SUPPLY_REFILL_MULT * dt_days)
			continue
		f.supply_reserve = maxf(0.0, f.supply_reserve - dt_days)
		if f.supply_reserve <= 0.0:
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
		# No per-battle cap: full stack power decides the kill rate, so force ratio
		# actually matters (a 100:1 fleet melts the enemy far faster than a 10:1 one).
		# Un-steamroll comes from throughput-limited production, border attrition, and
		# slow population bombardment — not from flattening every battle to one rate.
		power[eid] = p
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
	# BOMBARD_RATE keeps killing population SLOW (vision): a fleet must sit over a
	# world for many days to grind it down — and it takes border attrition while it
	# does — so no colony falls to a single pass.
	budget *= dt_days * SimConstants.BOMBARD_RATE
	if budget <= 0.0:
		return
	# A standing enemy citadel soaks bombardment before the colony behind it takes any:
	# the fortress must fall first. It has enormous hull, so this is many ticks of siege.
	var sys: StarSystem = systems[system_id]
	if sys.citadel_empire_id != -1 and sys.citadel_empire_id != empire_id \
			and sys.citadel_hp > 0.0:
		var hit: float = minf(budget, sys.citadel_hp)
		sys.citadel_hp -= hit
		budget -= hit
		if sys.citadel_hp <= 0.0:
			sys.citadel_hp = 0.0
			sys.citadel_empire_id = -1   # destroyed — the way past is open
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

	# Supply lines: refresh which colonies can still trace a friendly path to their
	# capital. Disconnected ones drop out of influence, refining and the water pool
	# below. (One-tick-lagged; see recompute_connectivity.)
	recompute_connectivity(dt_days)

	# 1. Mines. Water is a FLOW into per-tick water_income (never banked); minerals are
	#    banked (they feed the alloy chain). Reset the water flow at the top of the tick.
	for e in empires.values():
		e.water_income = 0.0
		e.water_demand = 0.0
	for p in planets.values():
		if p.has_mine():
			var e: Empire = empires[p.mine_empire_id]
			var out: float = p.mine_output() * dt_days * e.efficiency
			if p.deposit_type == SimConstants.Deposit.WATER:
				e.water_income += out
			elif p.deposit_type == SimConstants.Deposit.MINERAL:
				e.minerals += out

	# 1b. Cap the banked MINERAL stockpile to a few days of refining budget, so mining
	#     past what cities can process is wasted (minerals stay a real constraint) and
	#     there's no giant buffer. Scales with refining budget so it never starves.
	var refine_cap := {}   # empire -> total refining budget/day
	for c in colonies:
		if c.established and _is_colony_active(c):
			refine_cap[c.empire_id] = refine_cap.get(c.empire_id, 0.0) \
				+ c.refine_capacity()
	for e in empires.values():
		e.minerals = minf(e.minerals, maxf(SimConstants.RAW_STOCK_MIN,
			refine_cap.get(e.id, 0.0) * SimConstants.RAW_STOCK_DAYS))

	# Variety gate: tiers VARIETY_MIN_TIER+ need BOTH deposit types mined (diverse
	# territory), not just a big single-resource stockpile.
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

	# 2. Refining — the single alloy pyramid. Each established city splits its budget
	#    EQUALLY across the tiers it qualifies for (pop gates + variety), minerals->T1,
	#    T(n-1)->T(n). Each tier yields TIER_YIELD^tier per unit of budget, so higher
	#    tiers are progressively harder (the pyramid); a tier whose input ran out passes
	#    its unused budget UP to the next. Earlier colonies draw first (deterministic).
	for c in colonies:
		if not c.established or not _is_colony_active(c):
			continue   # disconnected colonies produce nothing (no refining contribution)
		var e: Empire = empires[c.empire_id]
		var maxtier := 0
		for t in 5:
			if c.population < SimConstants.MIL_CUTOFF[t]:
				break
			if t >= SimConstants.VARIETY_MIN_TIER and not mines_both.has(e.id):
				break
			maxtier = t + 1
		if maxtier == 0:
			continue
		var budget: float = c.refine_capacity() * e.efficiency * dt_days
		var share: float = budget / maxtier
		var carry := 0.0
		for t in maxtier:
			var cap_t: float = share + carry
			var yld: float = pow(SimConstants.TIER_YIELD, t)
			# Clamp to >=0: imperial drain can push a tier's stock negative (a visible debt),
			# and a negative input must not run refining backwards.
			var input_avail: float = maxf(0.0, (e.minerals if t == 0 else e.nat[t - 1]))
			var made: float = minf(cap_t * yld, input_avail)
			if t == 0:
				e.minerals -= made
			else:
				e.nat[t - 1] -= made
			e.nat[t] += made
			carry = cap_t - (made / yld if yld > 0.0 else cap_t)

	# 2b. Imperial centers burn alloy. Each running center drains a fixed amount of its
	#     level's tier per day straight from the stockpile — which is ALLOWED TO GO NEGATIVE
	#     (a visible debt the HUD shows red). Then every center's CHARGE winds toward 1 if its
	#     tier's post-drain stock is non-negative (fed) or toward 0 if it went negative
	#     (starved), at 1/IMPERIAL_RAMP_DAYS per day — symmetric wind-up/wind-down. A colony
	#     that has shrunk below the level's pop gate is clamped down (and demolished at 0).
	var imp_drain := {}   # empire_id -> [per-tier drain this tick]
	for sid in systems:
		var sysd: StarSystem = systems[sid]
		if sysd.imperial_level <= 0 or sysd.imperial_empire_id == -1:
			continue
		# Shrinking colony loses levels it can no longer support (so you can't build big then
		# starve the city to keep a high center on a now-tiny outpost).
		var cap_lvl: int = max_imperial_level(sid)
		if sysd.imperial_level > cap_lvl:
			sysd.imperial_level = cap_lvl
		if sysd.imperial_level <= 0:
			sysd.imperial_empire_id = -1
			sysd.imperial_charge = 0.0
			continue
		var eid: int = sysd.imperial_empire_id
		if not imp_drain.has(eid):
			imp_drain[eid] = [0.0, 0.0, 0.0, 0.0, 0.0]
		imp_drain[eid][sysd.imperial_level - 1] += \
			SimConstants.IMPERIAL_ALLOY_DRAIN * dt_days
	# Apply the per-tier drain (stock may go negative), then record which tiers are fed.
	var tier_fed := {}   # empire_id -> [bool per tier]
	for e in empires.values():
		var drains = imp_drain.get(e.id, null)   # Array or null
		var fed: Array = [true, true, true, true, true]
		for tier in 5:
			var want: float = (drains[tier] if drains != null else 0.0)
			e.nat[tier] -= want
			fed[tier] = e.nat[tier] >= 0.0
		tier_fed[e.id] = fed
	# Wind each center's charge up (fed) or down (starved) at the symmetric ramp rate.
	var ramp: float = dt_days / SimConstants.IMPERIAL_RAMP_DAYS
	for sid in systems:
		var sysd: StarSystem = systems[sid]
		if sysd.imperial_level <= 0 or sysd.imperial_empire_id == -1:
			continue
		var fed: Array = tier_fed.get(sysd.imperial_empire_id, null)
		var ok: bool = fed == null or fed[sysd.imperial_level - 1]
		sysd.imperial_charge = clampf(
			sysd.imperial_charge + (ramp if ok else -ramp), 0.0, 1.0)

	# 3. Population's need is WATER, as a FLOW. Compare this tick's water income to the
	#    whole population's demand; the SIGN sets growth direction. No bank — so pop
	#    settles where water income supports it (income / WATER_PER_POP), never banks a
	#    surplus to over-grow on, and never crashes off a drained reserve.
	var grow_sign := {}
	for e in empires.values():
		# Demand = Σ over the empire's colonies of (pop*WATER_PER_POP + a fixed per-colony
		# overhead). The overhead is what makes sprawl cost more than concentration: the
		# same total pop spread across more colonies pays the overhead more times. An
		# imperial center in a colony's system ADDS to its per-pop draw (buying influence
		# with water), so it raises demand rather than lowering it.
		var demand := 0.0
		for c in colonies:
			if c.empire_id != e.id or not _is_colony_active(c):
				continue   # disconnected colonies are off the shared water pool
			# Water demand is pop draw + per-colony overhead. Imperial centers no longer
			# touch water — they run on alloy (drained in the imperial step above).
			demand += c.population * SimConstants.WATER_PER_POP + SimConstants.WATER_PER_COLONY
		e.water_demand = demand * dt_days
		var balance: float = e.water_income - e.water_demand
		grow_sign[e.id] = 0 if is_zero_approx(balance) \
			else (1 if balance > 0.0 else -1)

	# 4. Apply population change. Surplus -> grow by the diminishing-returns curve
	#    × neighbor bonus (off by default); deficit -> shrink; zero -> hold.
	for c in colonies:
		if not _is_colony_active(c):
			# Disconnected: cut off from the empire's water pool, it survives ONLY on
			# water underneath it. Over a water deposit it keeps growing (self-supplied,
			# though it still produces nothing); otherwise its people die off at the
			# immigration rate until it empties out (removed in the pass after step 5).
			if planets[c.planet_id].deposit_type == SimConstants.Deposit.WATER:
				c.population += Colony.growth_per_day(c.population) * dt_days
				if not c.established and c.population >= SimConstants.ACTIVATION_POP:
					c.established = true
			else:
				c.population -= SimConstants.IMMIGRATION_RATE * c.population * dt_days
			continue
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
	#    other colonies, letting the player shift population (and influence). An
	#    abandoned colony sheds at DOUBLE rate and is barred from being a recipient
	#    (0x in-immigration), so it drains toward MIN_POP fast.
	for c in colonies:
		if not _is_colony_active(c):
			continue   # cut off from the empire — can't ship people in or out
		var rate := 0.0
		if c.abandoning:
			rate = SimConstants.IMMIGRATION_RATE * SimConstants.ABANDON_RATE_MULT
		elif c.emigrating:
			rate = SimConstants.IMMIGRATION_RATE
		if rate <= 0.0:
			continue
		var others: Array[Colony] = []
		for o in colonies:
			if o != c and o.empire_id == c.empire_id and not o.abandoning \
					and _is_colony_active(o):
				others.append(o)
		if others.is_empty():
			continue
		var shed: float = minf(
			c.population * rate * dt_days,
			c.population - SimConstants.MIN_POP)
		if shed <= 0.0:
			continue
		c.population -= shed
		var each := shed / others.size()
		for o in others:
			o.population += each

	# 5b. Remove emptied colonies. An abandoned colony (drained to MIN_POP) or a
	#     disconnected one that died off (no water underneath) vanishes from the map —
	#     it disappears rather than lingering at a floor. A normally-shrinking connected
	#     colony holds at MIN_POP and is NOT removed.
	var emptied: Array[Colony] = []
	for c in colonies:
		if c.population <= SimConstants.MIN_POP and (c.abandoning or not _is_colony_active(c)):
			emptied.append(c)
	for c in emptied:
		_remove_colony(c)

	# 6. Fleets move along lanes (one hop per tick at most).
	for f in fleets:
		if f.path.is_empty():
			continue
		var length: float = maxf(system_distance(f.system_id, f.path[0]), 1.0)
		f.progress += SimConstants.FLEET_SPEED * dt_days / length
		if f.progress >= 1.0:
			f.prev_system = f.system_id   # remember where we came from (legal retreat)
			f.system_id = f.path.pop_front()
			f.progress = 0.0

	# 6b. Construction vessels advance and place their structure on arrival.
	_advance_builders(dt_days)

	# 7. Combat: fleets auto-fight where enemies meet, else bombard (see 0.25.0).
	_resolve_combat(dt_days)

	# 8. Structures follow the border — but a colony ANCHORS them. Only the MINE is a
	#    captured civilian structure: it changes hands to whoever now controls the system,
	#    UNLESS the original owner still holds a colony there (a disconnected holdout keeps
	#    its mine even while an enemy border washes over the bubble). The IMPERIAL CENTRE is
	#    colony-bound — part of its colony, cleared with it in _remove_colony — so it is
	#    never captured; the branch here only catches a stray one and razes it. The MILITARY
	#    structures — supply depot, observation post, citadel — can never be handed to the
	#    enemy: if an enemy border takes their system and no friendly colony shelters them,
	#    they are destroyed (scorched, not captured). A sheltering colony keeps them standing,
	#    and the citadel then defends until it — or the colony — is bombarded down.
	#    Colonies themselves never flip (they must be bombarded to fall).
	var struct_systems := {}
	for p in planets.values():
		if p.has_mine():
			struct_systems[p.system_id] = true
	for sys in systems.values():
		if sys.depot_empire_id != -1 or sys.obs_post_empire_id != -1 \
				or sys.imperial_empire_id != -1 or sys.citadel_empire_id != -1:
			struct_systems[sys.id] = true
	var owner_of := {}
	for sid in struct_systems:
		owner_of[sid] = owner_cached(sid)
	for p in planets.values():
		if p.has_mine():
			var o: int = owner_of[p.system_id]
			if o != -1 and o != p.mine_empire_id \
					and not _empire_has_colony_in(p.mine_empire_id, p.system_id):
				p.mine_empire_id = o
	for sys in systems.values():
		var o: int = owner_of.get(sys.id, -1)
		if o == -1:
			continue
		if sys.depot_empire_id != -1 and o != sys.depot_empire_id \
				and not _empire_has_colony_in(sys.depot_empire_id, sys.id):
			sys.depot_empire_id = -1   # supply depot is military — razed, never captured
		if sys.obs_post_empire_id != -1 and o != sys.obs_post_empire_id \
				and not _empire_has_colony_in(sys.obs_post_empire_id, sys.id):
			sys.obs_post_empire_id = -1   # observation post is military — razed, never captured
		if sys.imperial_empire_id != -1 and o != sys.imperial_empire_id \
				and not _empire_has_colony_in(sys.imperial_empire_id, sys.id):
			# Imperial centre is colony-bound (normally cleared with its colony in
			# _remove_colony). If one is ever found with no sheltering colony, its colony
			# has already fallen, so it's gone — never captured by the conqueror.
			sys.imperial_empire_id = -1
			sys.imperial_level = 0
			sys.imperial_charge = 0.0
		if sys.citadel_empire_id != -1 and o != sys.citadel_empire_id \
				and not _empire_has_colony_in(sys.citadel_empire_id, sys.id):
			sys.citadel_empire_id = -1   # a fort is razed, never captured
			sys.citadel_hp = 0.0
