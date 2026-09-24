extends SceneTree

# Headless sim tests: godot --headless --path desktop --script res://tests/run_tests.gd
# (run --import once first so global class names resolve).

var failures := 0


func check(cond: bool, test_name: String) -> void:
	if cond:
		print("PASS  ", test_name)
	else:
		failures += 1
		print("FAIL  ", test_name)


func run_days(sim: Sim, days: float) -> void:
	for i in int(round(days / SimConstants.TICK_DAYS)):
		sim.tick(SimConstants.TICK_DAYS)


# One empire, one home system at origin (planet 0 = water deposit, planet 1 =
# plain, planet 2 = an established anchor colony pop 150 for influence), plus a
# far system out of reach. Empire has plenty of alloys and food so construction
# and food-growth don't interfere with influence/gating tests.
func make_scenario() -> Dictionary:
	var sim := Sim.new()
	var e := sim.add_empire("Alpha", Color.WHITE)
	e.nat[0] = 100000.0   # plenty of T1 alloy so construction never blocks these tests
	e.water_income = 1000.0   # ample spare water flow so the founding water-gate never
	                          # blocks these influence/gating tests (see has_water_for_new_colony)
	var s1 := sim.add_system("Home")
	s1.map_pos = Vector2.ZERO
	var deposit_p := sim.add_planet(s1.id, "Home I")
	deposit_p.deposit_type = SimConstants.Deposit.WATER
	var plain_p := sim.add_planet(s1.id, "Home II")
	var anchor_p := sim.add_planet(s1.id, "Home III")
	var far := sim.add_system("Far")
	far.map_pos = Vector2(5000, 0)
	var far_p := sim.add_planet(far.id, "Far I")
	far_p.deposit_type = SimConstants.Deposit.WATER
	sim.add_lane(s1.id, far.id)
	var anchor := sim.inject_colony(e.id, anchor_p.id, 150.0, true)
	return {"sim": sim, "e": e, "home": s1, "far": far,
		"deposit_p": deposit_p, "plain_p": plain_p, "anchor_p": anchor_p,
		"far_p": far_p, "anchor": anchor}


func _init() -> void:
	_test_topology()
	_test_procedural()
	_test_founding()
	_test_water_gate()
	_test_influence_nonstacking()
	_test_influence_gating()
	_test_border_contest()
	_test_influence_field()
	_test_fog_of_war()
	_test_neighbor_bonus()
	_test_ai_rival()
	_test_mining()
	_test_conversion()
	_test_water_growth()
	_test_diminishing_returns()
	_test_emigration()
	_test_fleets()
	_test_military_resources()
	_test_specialization()
	_test_mine_upgrade()
	_test_combat_scaling()
	_test_fleet_pin()
	_test_enemy_transit_block()
	_test_citadel()
	_test_attrition_and_depot()
	_test_structure_capture()
	_test_support_structures()
	_test_resource_variety()
	_test_construction_vessel()
	_test_anomalies()
	_test_difficulty()
	_test_save_load()
	_test_determinism()
	if failures == 0:
		print("ALL TESTS PASSED")
	else:
		print(failures, " TEST(S) FAILED")
	quit(1 if failures > 0 else 0)


func _test_topology() -> void:
	var sim := Sim.new_demo()
	check(sim.systems.size() >= 5, "demo map has several systems")
	var lanes_valid := true
	for l in sim.lanes:
		if not (sim.systems.has(l[0]) and sim.systems.has(l[1])):
			lanes_valid = false
	check(lanes_valid, "every lane connects two existing systems")
	var all_have_planets := true
	for sys in sim.systems.values():
		if sys.planet_ids.is_empty():
			all_have_planets = false
	check(all_have_planets, "every system has at least one planet")
	var visited := {}
	var queue: Array[int] = [sim.systems.keys()[0]]
	while not queue.is_empty():
		var sid: int = queue.pop_front()
		if visited.has(sid):
			continue
		visited[sid] = true
		for n in sim.lane_neighbors(sid):
			queue.append(n)
	check(visited.size() == sim.systems.size(), "lane graph is fully connected")
	check(sim.empires.size() >= 1 and sim.colonies.size() >= 1,
		"demo starts with an empire and a homeworld")


func _is_connected(sim: Sim) -> bool:
	var visited := {}
	var queue: Array = [sim.systems.keys()[0]]
	while not queue.is_empty():
		var sid: int = queue.pop_front()
		if visited.has(sid):
			continue
		visited[sid] = true
		for nb in sim.lane_neighbors(sid):
			queue.append(nb)
	return visited.size() == sim.systems.size()


func _test_procedural() -> void:
	var cfg: Dictionary = Sim.default_map_config()
	cfg.empire_count = 5
	var a := Sim.generate_map(cfg)
	check(a.empires.size() == 5, "generator honors the requested empire count")
	check(_is_connected(a), "procedural map is fully connected (no islands)")
	check(a.systems.size() >= 20, "procedural map places a substantial map")
	# Determinism: same config -> identical map (system count + positions).
	var b := Sim.generate_map(cfg)
	var same := a.systems.size() == b.systems.size()
	for sid in a.systems:
		if not b.systems.has(sid) or a.systems[sid].map_pos != b.systems[sid].map_pos:
			same = false
	check(same, "same config produces an identical map (seeded, deterministic)")
	# A different seed produces a different layout.
	var cfg2: Dictionary = Sim.default_map_config()
	cfg2.seed = 999
	var c := Sim.generate_map(cfg2)
	check(_is_connected(c), "a different seed is also fully connected")
	# Lane density: min (0) = a spanning tree (connected, exactly n-1 lanes); max (1) =
	# more lanes, still connected, and NEVER any crossing pair (planar Delaunay set).
	var sparse_cfg: Dictionary = Sim.default_map_config()
	sparse_cfg.lane_density = 0.0
	var sparse := Sim.generate_map(sparse_cfg)
	check(_is_connected(sparse), "min lane density is still one connected mesh (no islands)")
	check(sparse.lanes.size() == sparse.systems.size() - 1,
		"min lane density is a spanning tree (n-1 lanes)")
	var dense_cfg: Dictionary = Sim.default_map_config()
	dense_cfg.lane_density = 1.0
	var dense := Sim.generate_map(dense_cfg)
	check(_is_connected(dense), "max lane density is still connected")
	check(dense.lanes.size() > sparse.lanes.size(),
		"more density means more lanes")
	check(_no_lane_crossings(dense), "lanes never cross (planar lane graph)")


# True if no two lanes cross (share no endpoint yet their segments intersect). The lane
# graph must stay planar at every density — the "no crossover" map rule.
func _no_lane_crossings(sim: Sim) -> bool:
	for a in sim.lanes.size():
		var la: Array = sim.lanes[a]
		var p1: Vector2 = sim.systems[la[0]].map_pos
		var p2: Vector2 = sim.systems[la[1]].map_pos
		for b in range(a + 1, sim.lanes.size()):
			var lb: Array = sim.lanes[b]
			if la[0] == lb[0] or la[0] == lb[1] or la[1] == lb[0] or la[1] == lb[1]:
				continue   # shared endpoint: touching is not crossing
			var p3: Vector2 = sim.systems[lb[0]].map_pos
			var p4: Vector2 = sim.systems[lb[1]].map_pos
			if Geometry2D.segment_intersects_segment(p1, p2, p3, p4) != null:
				return false
	return true


func _test_founding() -> void:
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	var alloys_before: float = e.nat[0]
	check(sim.found_colony(e.id, sc.plain_p.id),
		"founding succeeds on empty planet under influence with alloys")
	check(is_equal_approx(e.nat[0], alloys_before - SimConstants.FOUND_COST_ALLOYS),
		"founding deducts exactly the alloy cost")
	check(not sim.found_colony(e.id, sc.plain_p.id),
		"founding fails on already-colonized planet")
	var sc2 := make_scenario()
	sc2.e.nat[0] = SimConstants.FOUND_COST_ALLOYS - 1.0
	check(not sc2.sim.found_colony(sc2.e.id, sc2.plain_p.id),
		"founding fails when alloys are short")
	check(sc2.e.nat[0] == SimConstants.FOUND_COST_ALLOYS - 1.0,
		"failed founding costs nothing")


func _test_water_gate() -> void:
	# Founding is gated on spare water flow, not just alloys: an empire running no water
	# surplus can't found even with alloys to burn; restore its water income and it can.
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	e.water_income = 0.0   # no spare water flow
	e.water_demand = 0.0
	check(not sim.has_water_for_new_colony(e.id),
		"an empire with no spare water flow can't supply a new colony")
	check(not sim.can_found_colony(e.id, sc.plain_p.id),
		"founding is blocked when there's no spare water, even with alloys")
	e.water_income = sim.new_colony_water_per_day(e.id) * SimConstants.TICK_DAYS + 0.001
	check(sim.has_water_for_new_colony(e.id),
		"just enough spare water flow clears the gate")
	check(sim.can_found_colony(e.id, sc.plain_p.id),
		"founding succeeds once water covers the new colony's draw")


func _test_influence_nonstacking() -> void:
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	check(is_equal_approx(sim.system_influence(sc.home.id, e.id),
		SimConstants.INFLUENCE_A1 * 150.0),
		"influence = A1 x pop of the strongest center")
	check(is_equal_approx(sim.influence_reach(sc.home.id, e.id),
		SimConstants.BORDER_A2 * SimConstants.INFLUENCE_A1 * 150.0),
		"uncontested reach = A2 x influence")
	sim.inject_colony(e.id, sc.plain_p.id, 100.0, true)
	check(is_equal_approx(sim.system_influence(sc.home.id, e.id),
		SimConstants.INFLUENCE_A1 * 150.0),
		"same-system colonies do not stack influence (max, not sum)")
	sim.planets[sc.plain_p.id].colony.population = 400.0
	check(is_equal_approx(sim.system_influence(sc.home.id, e.id),
		SimConstants.INFLUENCE_A1 * 400.0),
		"the strongest center defines the system's influence")


func _test_influence_gating() -> void:
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	check(not sim.can_found_colony(e.id, sc.far_p.id),
		"cannot colonize outside influence reach")
	check(not sim.can_build_mine(e.id, sc.far_p.id),
		"cannot mine outside influence reach")
	var near := sim.add_system("Near")
	near.map_pos = Vector2(200, 0)
	var near_p := sim.add_planet(near.id, "Near I")
	near_p.deposit_type = SimConstants.Deposit.MINERAL
	check(sim.can_found_colony(e.id, near_p.id),
		"can colonize a neighbor system inside reach")
	check(sim.can_build_mine(e.id, near_p.id),
		"can mine a covered neighbor system without a colony there")


func _test_border_contest() -> void:
	var sim := Sim.new()
	var e1 := sim.add_empire("Strong", Color.RED)
	var e2 := sim.add_empire("Weak", Color.BLUE)
	var a := sim.add_system("A")
	a.map_pos = Vector2.ZERO
	var b := sim.add_system("B")
	b.map_pos = Vector2(300, 0)
	sim.inject_colony(e1.id, sim.add_planet(a.id, "A I").id, 200.0, true)
	sim.inject_colony(e2.id, sim.add_planet(b.id, "B I").id, 100.0, true)
	var left := sim.add_system("Left")
	left.map_pos = Vector2(190, 0)
	sim.add_planet(left.id, "L I")
	var right := sim.add_system("Right")
	right.map_pos = Vector2(210, 0)
	sim.add_planet(right.id, "R I")
	check(sim.system_owner(left.id) == e1.id,
		"contested: left of the influence-ratio point goes to the stronger")
	check(sim.system_owner(right.id) == e2.id,
		"contested: right of the influence-ratio point goes to the weaker")
	sim.planets[sim.systems[b.id].planet_ids[0]].colony.population = 400.0
	sim._invalidate_influence_caches()   # direct pop write within a frozen tick
	check(sim.system_owner(left.id) == e2.id,
		"borders are live: outgrowing the rival moves the line")


func _test_influence_field() -> void:
	var sim := Sim.new()
	var e1 := sim.add_empire("A", Color.RED)
	var e2 := sim.add_empire("B", Color.BLUE)
	var sa := sim.add_system("A")
	sa.map_pos = Vector2.ZERO
	sim.inject_colony(e1.id, sim.add_planet(sa.id, "a").id, 200.0, true)
	var sb := sim.add_system("B")
	sb.map_pos = Vector2(300, 0)
	sim.inject_colony(e2.id, sim.add_planet(sb.id, "b").id, 100.0, true)
	check(sim.point_owner(Vector2(150, 0)) == e1.id,
		"field: point left of the ratio border belongs to the stronger empire")
	check(sim.point_owner(Vector2(250, 0)) == e2.id,
		"field: point right of the ratio border belongs to the weaker empire")
	check(sim.point_owner(Vector2(5000, 0)) == -1,
		"field: point beyond every bubble's reach is unclaimed")
	var claim_one: float = sim.empire_claim_at(Vector2(200, 0), e1.id)
	var sc := sim.add_system("C")
	sc.map_pos = Vector2(0, 120)
	sim.inject_colony(e1.id, sim.add_planet(sc.id, "c").id, 200.0, true)
	check(sim.empire_claim_at(Vector2(200, 0), e1.id) > claim_one,
		"field: a second reaching friendly source adds friction (higher claim)")
	var base: float = sim.empire_claim_at(Vector2(150, 0), e1.id)
	sim.inject_colony(e1.id, sim.add_planet(sa.id, "a2").id, 100.0, true)
	check(is_equal_approx(sim.empire_claim_at(Vector2(150, 0), e1.id), base),
		"field: same-system colonies don't stack (max, not sum)")


func _test_fog_of_war() -> void:
	var sim := Sim.new()
	var e := sim.add_empire("A", Color.WHITE)
	var home := sim.add_system("Home")
	home.map_pos = Vector2.ZERO
	sim.inject_colony(e.id, sim.add_planet(home.id, "H").id, 100.0, true)
	# influence reach = 1.8*100 = 180; sight = SIGHT_INFLUENCE_FACTOR * 180.
	var sight: float = SimConstants.SIGHT_INFLUENCE_FACTOR \
		* sim.influence_reach(home.id, e.id)
	check(sim.is_point_visible(home.map_pos, e.id), "own colony's system is visible")
	check(sim.is_point_visible(Vector2(sight - 1.0, 0.0), e.id),
		"a point just inside the scaled sight range is visible")
	check(not sim.is_point_visible(Vector2(sight + 1.0, 0.0), e.id),
		"a point just beyond the scaled sight range is not visible")
	check(sight > sim.influence_reach(home.id, e.id),
		"sight range exceeds influence range (fog is 1.2-2x influence)")
	# A mine grants a flat sensor range with no colony present.
	var sim2 := Sim.new()
	var e2 := sim2.add_empire("B", Color.WHITE)
	var s := sim2.add_system("S")
	s.map_pos = Vector2(1000, 0)
	var mp := sim2.add_planet(s.id, "M")
	mp.deposit_type = SimConstants.Deposit.WATER
	mp.mine_empire_id = e2.id
	check(sim2.is_point_visible(s.map_pos, e2.id), "a mine is a flat sight source")
	check(not sim2.is_point_visible(Vector2(0, 0), e2.id),
		"points far from all presence are fogged")


func _neighbor_rig() -> Dictionary:
	var sim := Sim.new()
	var e := sim.add_empire("N", Color.WHITE)
	var a := sim.add_system("A")
	a.map_pos = Vector2.ZERO
	var pa := sim.add_planet(a.id, "A I")
	var subject := sim.inject_colony(e.id, pa.id, 200.0, true)
	return {"sim": sim, "e": e, "a": a, "subject": subject}


func _add_established(sim: Sim, e: Empire, pos: Vector2, pop: float) -> void:
	var s := sim.add_system("S%d" % sim.systems.size())
	s.map_pos = pos
	sim.inject_colony(e.id, sim.add_planet(s.id, "P").id, pop, true)


func _test_neighbor_bonus() -> void:
	# The neighbor bonus is OFF (NEIGHBOR_BONUS_ENABLED = false): the multiplier is a
	# flat 1.0 no matter the neighbours. Code is kept for a possible future mode; these
	# assertions lock in that the master switch actually neutralises it.
	var rig := _neighbor_rig()
	check(is_equal_approx(rig.sim.neighbor_growth_multiplier(rig.subject), 1.0),
		"isolated colony: neighbor multiplier 1.0")
	var rig2 := _neighbor_rig()
	_add_established(rig2.sim, rig2.e, Vector2(250, 0), 200.0)
	check(is_equal_approx(rig2.sim.neighbor_growth_multiplier(rig2.subject), 1.0),
		"even WITH a nearby established neighbour the multiplier stays 1.0 (bonus off)")
	var rig6 := _neighbor_rig()
	for k in 8:
		_add_established(rig6.sim, rig6.e, Vector2(200 + k, 0), 5000.0)
	check(is_equal_approx(rig6.sim.neighbor_growth_multiplier(rig6.subject), 1.0),
		"a dense cluster still gives 1.0 — no bonus, no runaway (switch off)")


func _test_ai_rival() -> void:
	var sim := Sim.new()
	var e := sim.add_empire("AI", Color.RED)
	e.nat[0] = 10000.0
	e.water_income = 1000.0   # spare water flow so the colony vessel clears the water gate
	var home := sim.add_system("Home")
	home.map_pos = Vector2.ZERO
	sim.inject_colony(e.id, sim.add_planet(home.id, "Home I").id, 150.0, true)
	var near := sim.add_system("Near")
	near.map_pos = Vector2(200, 0)
	sim.add_lane(home.id, near.id)   # vessels travel lanes, so a route is needed
	var near_p := sim.add_planet(near.id, "Near I")
	near_p.deposit_type = SimConstants.Deposit.MINERAL
	var far := sim.add_system("Far")
	far.map_pos = Vector2(5000, 0)
	sim.add_lane(near.id, far.id)
	var far_p := sim.add_planet(far.id, "Far I")
	far_p.deposit_type = SimConstants.Deposit.MINERAL

	var ai := EmpireAI.new(e.id)
	ai.maybe_act(sim)   # dispatches construction vessels toward Near
	var dispatched: int = sim.builders.size()
	check(dispatched >= 1, "AI dispatches a construction vessel to expand")
	ai.maybe_act(sim)   # still within the action interval — must not act again
	check(sim.builders.size() == dispatched,
		"AI respects its action interval (no acting every tick)")
	run_days(sim, 12.0)   # let the vessels reach Near and build (standalone AI not ticked)
	check(sim.planets[near_p.id].colony != null
		and sim.planets[near_p.id].colony.empire_id == e.id,
		"AI colonizes a reachable empty system (via a vessel)")
	check(sim.planets[near_p.id].has_mine(),
		"AI builds a mine on a reachable deposit (via a vessel)")
	check(sim.planets[far_p.id].colony == null and not sim.planets[far_p.id].has_mine(),
		"AI never builds outside its influence (same gating as the player)")

	var demo := Sim.new_demo()
	var rival_id: int = demo.empires.keys()[1]
	# Track PEAK expansion/military over the run — a colony or fleet lost to a rival's
	# attack later shouldn't fail an "it can expand and arm" test.
	var max_colonies := 0
	var max_ships := 0
	for _i in 4000:   # 400 days at 0.1/tick
		demo.tick(SimConstants.TICK_DAYS)
		var cc := 0
		for c in demo.colonies:
			if c.empire_id == rival_id:
				cc += 1
		max_colonies = maxi(max_colonies, cc)
		var sc := 0
		for f in demo.fleets:
			if f.empire_id == rival_id:
				sc += f.ship_count()
		max_ships = maxi(max_ships, sc)
	check(max_colonies >= 2, "rival AI expands to multiple colonies over time")
	check(max_ships >= 1, "rival AI builds ships once it can afford them")


func _test_mining() -> void:
	# Gating (alloy cost + influence), via the shared scenario.
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	check(not sim.can_build_mine(e.id, sc.plain_p.id), "mine requires a deposit")
	var alloys_before: float = e.nat[0]
	check(sim.build_mine(e.id, sc.deposit_p.id), "mine builds on reachable deposit")
	check(is_equal_approx(e.nat[0], alloys_before - SimConstants.MINE_COST_ALLOYS),
		"mine deducts its alloy cost")
	check(not sim.can_build_mine(e.id, sc.deposit_p.id),
		"no second mine on the same planet")

	# Income by deposit type — isolated (no city) so nothing converts it away.
	var sim2 := Sim.new()
	var w := sim2.add_empire("W", Color.WHITE)
	var other := sim2.add_empire("O", Color.GRAY)
	var sysw := sim2.add_system("W")
	sysw.map_pos = Vector2.ZERO
	var wp := sim2.add_planet(sysw.id, "wp")
	wp.deposit_type = SimConstants.Deposit.WATER
	wp.mine_empire_id = w.id
	var mp := sim2.add_planet(sysw.id, "mp")
	mp.deposit_type = SimConstants.Deposit.MINERAL
	mp.mine_empire_id = w.id
	sim2.tick(SimConstants.TICK_DAYS)
	check(is_equal_approx(w.water_income, wp.mine_output() * SimConstants.TICK_DAYS),
		"water-deposit mine feeds the per-tick water FLOW at this deposit's richness")
	check(is_equal_approx(w.minerals, mp.mine_output() * SimConstants.TICK_DAYS),
		"mineral-deposit mine banks minerals at this deposit's richness")
	check(other.water_income == 0.0 and other.minerals == 0.0,
		"other empires get nothing from a rival's mines")
	# Richness varies by deposit and its estimate bracket contains the truth.
	check(wp.mine_output() != mp.mine_output(),
		"different deposits have different richness")
	var est := wp.output_estimate()
	check(wp.mine_output() >= est.x and wp.mine_output() <= est.y,
		"the pre-build estimate bracket contains the true output")


func _test_conversion() -> void:
	# Refining: an established city turns banked minerals into tier-1 alloy.
	var sim := Sim.new()
	var e := sim.add_empire("C", Color.WHITE)
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	sim.inject_colony(e.id, sim.add_planet(s.id, "p").id, 200.0, true)
	e.minerals = 400.0
	e.nat = [0.0, 0.0, 0.0, 0.0, 0.0]
	sim.tick(SimConstants.TICK_DAYS)
	check(e.nat[0] > 0.0, "an established city refines minerals into tier-1 alloy")
	check(e.minerals < 400.0, "refining consumes minerals")

	# Input-limited: with only a sliver of minerals, all of it is consumed (no more).
	var sim2 := Sim.new()
	var e2 := sim2.add_empire("C2", Color.WHITE)
	var s2 := sim2.add_system("S")
	s2.map_pos = Vector2.ZERO
	# Small city (pop 100 -> tier 1 only, so no tier-2 step eats the T1 it makes) with a
	# sliver of minerals below one tick's budget: all of it is consumed, and only that.
	sim2.inject_colony(e2.id, sim2.add_planet(s2.id, "p").id, 100.0, true)
	e2.minerals = 0.05   # far below one tick's tier-1 refining budget
	e2.nat = [0.0, 0.0, 0.0, 0.0, 0.0]
	sim2.tick(SimConstants.TICK_DAYS)
	check(is_equal_approx(e2.minerals, 0.0) and e2.nat[0] > 0.0,
		"refining is partial and input-limited (all 0.05 minerals used, not more)")

	# Unestablished colonies refine nothing.
	var sim3 := Sim.new()
	var e3 := sim3.add_empire("C3", Color.WHITE)
	var s3 := sim3.add_system("S")
	s3.map_pos = Vector2.ZERO
	sim3.inject_colony(e3.id, sim3.add_planet(s3.id, "p").id, 50.0, false)
	e3.minerals = 400.0   # under the raw-stockpile cap floor so it isn't clamped
	sim3.tick(SimConstants.TICK_DAYS)
	check(is_equal_approx(e3.minerals, 400.0),
		"an unestablished colony refines no minerals")


func _test_water_growth() -> void:
	# Water income above demand -> grow.
	var sim := Sim.new()
	var e := sim.add_empire("G", Color.WHITE)
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	var wp := sim.add_planet(s.id, "w")   # a water mine feeds the population
	wp.deposit_type = SimConstants.Deposit.WATER
	wp.mine_empire_id = e.id
	var c := sim.inject_colony(e.id, sim.add_planet(s.id, "p").id, 50.0, false)
	run_days(sim, 5.0)
	check(c.population > 50.0, "water income above demand makes population grow")

	# No water income -> deficit -> shrink (no bank to coast on).
	var sim2 := Sim.new()
	var e2 := sim2.add_empire("S", Color.WHITE)
	var s2 := sim2.add_system("S")
	s2.map_pos = Vector2.ZERO
	var c2 := sim2.inject_colony(e2.id, sim2.add_planet(s2.id, "p").id, 200.0, true)
	run_days(sim2, 20.0)
	check(c2.population < 200.0,
		"no water income shrinks population (nothing banked to grow on)")

	# Shrink is floored: population never drops below MIN_POP or below zero.
	var sim3 := Sim.new()
	var e3 := sim3.add_empire("F", Color.WHITE)
	var s3 := sim3.add_system("S")
	s3.map_pos = Vector2.ZERO
	var c3 := sim3.inject_colony(e3.id, sim3.add_planet(s3.id, "p").id, 5.0, false)
	run_days(sim3, 2000.0)
	check(c3.population >= SimConstants.MIN_POP and c3.population > 0.0,
		"starving population is floored, not driven negative")


func _test_diminishing_returns() -> void:
	var rel_small: float = Colony.growth_per_day(100.0) / 100.0
	var rel_big: float = Colony.growth_per_day(1000.0) / 1000.0
	var rel_huge: float = Colony.growth_per_day(100000.0) / 100000.0
	check(rel_big < rel_small, "relative growth falls from 100 to 1000 pop")
	check(rel_huge < rel_big, "relative growth keeps falling at 100k pop")
	check(Colony.growth_per_day(100000.0) > 0.0,
		"no hard cap: growth still positive at 100k pop")


func _test_emigration() -> void:
	# Big source so shedding dominates the (tiny, concurrent) growth step.
	var sim := Sim.new()
	var e := sim.add_empire("E", Color.WHITE)
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	var src := sim.inject_colony(e.id, sim.add_planet(s.id, "a").id, 100000.0, true)
	var d1 := sim.inject_colony(e.id, sim.add_planet(s.id, "b").id, 100.0, true)
	var d2 := sim.inject_colony(e.id, sim.add_planet(s.id, "c").id, 100.0, true)
	var src0: float = src.population
	var d10: float = d1.population
	sim.toggle_emigration(e.id, src.planet_id)
	check(src.emigrating, "toggle turns emigration on for the player's colony")
	sim.tick(SimConstants.TICK_DAYS)
	check(src.population < src0, "an emigrating colony loses population")
	check(d1.population > d10 and is_equal_approx(d1.population, d2.population),
		"shed population is split equally among the empire's other colonies")
	sim.toggle_emigration(e.id, src.planet_id)
	check(not src.emigrating, "toggling again turns emigration off")


func _test_fleets() -> void:
	# Three systems in a line A-B-C; empire has a big city at B (its shipyard).
	var sim := Sim.new()
	var e := sim.add_empire("E", Color.WHITE)
	e.nat = [1000.0, 0.0, 0.0, 0.0, 0.0]   # tier-1 military resource to build with
	var a := sim.add_system("A")
	a.map_pos = Vector2.ZERO
	var b := sim.add_system("B")
	b.map_pos = Vector2(120, 0)
	var c := sim.add_system("C")
	c.map_pos = Vector2(240, 0)
	sim.add_lane(a.id, b.id)
	sim.add_lane(b.id, c.id)
	sim.inject_colony(e.id, sim.add_planet(b.id, "B I").id, 500.0, true)

	var nat0: float = e.nat[0]
	check(sim.build_ship(e.id, SimConstants.Role.FIGHTER, 1),
		"building a fighter succeeds with the tier resource + a city")
	check(is_equal_approx(e.nat[0], nat0 - SimConstants.SHIP_NAT_COST),
		"a ship costs its tier's national resource")
	check(sim.fleets.size() == 1 and sim.fleets[0].system_id == b.id
		and sim.fleets[0].fighters[0] == 1,
		"the ship appears in a fleet at the most-populated (shipyard) system")
	check(sim.fleets[0].combat_power() > 0.0, "a fighter gives the fleet combat power")
	check(not sim.can_build_ship(e.id, 3),
		"cannot build a tier the empire has no resource for")

	# Lane movement: order the fleet A? no — it's at B; send it to C via the lane.
	var f: Fleet = sim.fleets[0]
	var path := sim.lane_path(b.id, c.id)
	check(path.size() == 1 and path[0] == c.id, "lane_path routes B->C")
	sim.order_fleet(f.id, c.id)
	check(f.is_moving(), "an ordered fleet is moving")
	run_days(sim, 20.0)
	check(f.system_id == c.id and not f.is_moving(),
		"the fleet travels the lane and arrives")

	# Bombardment: park a bomber over an enemy colony; it dies weakest-first.
	sim.build_ship(e.id, SimConstants.Role.BOMBER, 1)   # spawns at B (the city)
	var bomber_fleet: Fleet = null
	for fl in sim.fleets:
		if fl.system_id == b.id and fl.bombers[0] > 0:
			bomber_fleet = fl
	sim.order_fleet(bomber_fleet.id, c.id)
	run_days(sim, 20.0)
	var rival := sim.add_empire("R", Color.RED)
	var enemy := sim.inject_colony(rival.id, sim.add_planet(c.id, "C I").id, 150.0, true)
	var pop0: float = enemy.population
	sim.tick(SimConstants.TICK_DAYS)
	check(enemy.population < pop0, "a parked bomber bombards an enemy colony")
	run_days(sim, 300.0)
	check(sim.planets[enemy.planet_id].colony == null,
		"sustained bombardment destroys the colony (dropped under the cutoff)")

	# Merge/split: ships build into one fleet at the shipyard, so two fleets only
	# exist once they converge from elsewhere. Send one to A, build another, send
	# it to A too, then merge them there.
	e.nat[0] = 1000.0
	sim.build_ship(e.id, SimConstants.Role.FIGHTER, 1)
	sim.build_ship(e.id, SimConstants.Role.FIGHTER, 1)
	var fa: Fleet = null
	for fl in sim.fleets:
		if fl.system_id == b.id and not fl.is_moving() and fl.fighters[0] >= 2:
			fa = fl
	sim.order_fleet(fa.id, a.id)
	run_days(sim, 10.0)
	sim.build_ship(e.id, SimConstants.Role.FIGHTER, 1)
	sim.build_ship(e.id, SimConstants.Role.FIGHTER, 1)
	var fb: Fleet = null
	for fl in sim.fleets:
		if fl.system_id == b.id and not fl.is_moving():
			fb = fl
	sim.order_fleet(fb.id, a.id)
	run_days(sim, 10.0)
	var at_a: Array = []
	for fl in sim.fleets:
		if fl.empire_id == e.id and fl.system_id == a.id and not fl.is_moving():
			at_a.append(fl)
	check(at_a.size() >= 2, "two fleets converged on the same system")
	var keep: Fleet = at_a[0]
	sim.merge_fleets_into(keep.id)
	check(keep.fighters[0] == 4, "merge combines the ships into one fleet")
	var g := sim.split_fleet(keep.id)
	check(g != null and keep.fighters[0] == 2 and g.fighters[0] == 2,
		"split halves the ships into a new fleet")

	# Fleet combat: fighters beat an equal-strength bomber fleet.
	var sim2 := Sim.new()
	var e1 := sim2.add_empire("F", Color.RED)
	var e2 := sim2.add_empire("G", Color.BLUE)
	var s := sim2.add_system("S")
	s.map_pos = Vector2.ZERO
	var fighters := sim2._fleet_at(e1.id, s.id)
	fighters.fighters[2] = 5
	var bombers := sim2._fleet_at(e2.id, s.id)
	bombers.bombers[2] = 5
	run_days(sim2, 60.0)
	check(fighters.ship_count() > bombers.ship_count(),
		"in fleet combat the fighter fleet out-survives the bomber fleet")


func _test_military_resources() -> void:
	# A big city refines the whole tier chain; a small one only tier 1.
	var sim := Sim.new()
	var e := sim.add_empire("M", Color.WHITE)
	e.minerals = 1.0e9   # ample raw input to the chain
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	sim.inject_colony(e.id, sim.add_planet(s.id, "big").id, 3000.0, true)
	# The top tiers need deposit variety, so give this empire both mine types (the water
	# mine also feeds the population so the big city holds its size).
	var wm := sim.add_planet(s.id, "w")
	wm.deposit_type = SimConstants.Deposit.WATER
	wm.mine_empire_id = e.id
	var mm := sim.add_planet(s.id, "m")
	mm.deposit_type = SimConstants.Deposit.MINERAL
	mm.mine_empire_id = e.id
	run_days(sim, 40.0)
	# The chain feeds upward, so a maxed city ends holding the TOP tier (lower
	# tiers get consumed to make the next) — that's the "spread cities for a mix"
	# pressure. Just confirm it reached tier 5.
	check(e.nat[4] > 0.0, "a city above the top cutoff refines all the way to tier 5")

	var sim2 := Sim.new()
	var e2 := sim2.add_empire("M2", Color.WHITE)
	e2.minerals = 1.0e9   # raw input; small city should turn it into T1 only
	var s2 := sim2.add_system("S")
	s2.map_pos = Vector2.ZERO
	sim2.inject_colony(e2.id, sim2.add_planet(s2.id, "small").id, 100.0, true)
	run_days(sim2, 5.0)
	check(e2.nat[0] > 0.0 and e2.nat[1] == 0.0,
		"a small city (below the tier-2 cutoff) refines only tier 1")


func _test_resource_variety() -> void:
	# Top military tiers need diverse territory: an empire mining only minerals can't
	# refine tier VARIETY_MIN_TIER+; adding a water mine unlocks it.
	var sim := Sim.new()
	var e := sim.add_empire("V", Color.WHITE)
	e.nat = [1.0e9, 0.0, 0.0, 0.0, 0.0]   # ample T1 so the chain can cascade upward
	e.minerals = 1.0e9
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	sim.inject_colony(e.id, sim.add_planet(s.id, "big").id, 3000.0, true)
	var mp := sim.add_planet(s.id, "min")   # mineral mine only
	mp.deposit_type = SimConstants.Deposit.MINERAL
	mp.mine_empire_id = e.id
	run_days(sim, 5.0)   # short: pop stays above the tier cutoffs, cascade completes
	# The chain drains lower tiers UP, so without variety the top REACHED tier is
	# VARIETY_MIN_TIER-1; tiers at/above the variety gate stay 0.
	var gate := SimConstants.VARIETY_MIN_TIER
	var blocked := true
	for t in range(gate, 5):
		if e.nat[t] != 0.0:
			blocked = false
	check(blocked, "tiers at/above the variety gate are blocked without deposit variety")
	var lower := 0.0
	for t in gate:
		lower += e.nat[t]
	check(lower > 0.0, "lower military tiers still produce without variety")
	var wp := sim.add_planet(s.id, "wat")   # now add a water mine → variety
	wp.deposit_type = SimConstants.Deposit.WATER
	wp.mine_empire_id = e.id
	run_days(sim, 5.0)
	check(e.nat[4] > 0.0,
		"the top tier is reached once both deposit types are mined")


func _test_support_structures() -> void:
	# Observation post doubles the system's influence reach.
	var sim := Sim.new()
	var e := sim.add_empire("O", Color.WHITE)
	e.nat[0] = 100000.0
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	sim.inject_colony(e.id, sim.add_planet(s.id, "p").id, 200.0, true)
	var reach_before := sim.influence_reach(s.id, e.id)
	check(sim.build_obs_post(e.id, s.id), "observation post builds in own influence")
	check(is_equal_approx(sim.influence_reach(s.id, e.id),
		reach_before * SimConstants.OBS_POST_REACH_MULT),
		"observation post doubles influence reach")

	# Imperial center: a symmetric trade — it RAISES the system's colony influence
	# (bigger borders) in exchange for RAISING water demand (+10% at L1). Compare a
	# baseline empire against an identical one that builds an imperial center.
	var sim2 := Sim.new()
	var e2 := sim2.add_empire("T", Color.WHITE)
	e2.nat[0] = 100000.0
	e2.water_income = 1000.0
	var a := sim2.add_system("A")
	a.map_pos = Vector2.ZERO
	sim2.inject_colony(e2.id, sim2.add_planet(a.id, "pa").id, 500.0, true)

	var sim3 := Sim.new()
	var e3 := sim3.add_empire("T", Color.WHITE)
	e3.nat[0] = 100000.0
	e3.water_income = 1000.0
	var a3 := sim3.add_system("A")
	a3.map_pos = Vector2.ZERO
	sim3.inject_colony(e3.id, sim3.add_planet(a3.id, "pa").id, 500.0, true)
	var infl_before := sim3.system_influence(a3.id, e3.id)
	check(sim3.build_imperial(e3.id, a3.id), "imperial center builds in own influence")
	check(sim3.systems[a3.id].imperial_empire_id == e3.id, "the center belongs to its empire")
	check(sim3.systems[a3.id].imperial_level == 1, "a fresh imperial center is level 1")
	check(sim3.system_influence(a3.id, e3.id) > infl_before,
		"imperial center raises the system's colony influence")

	sim2.tick(SimConstants.TICK_DAYS)
	sim3.tick(SimConstants.TICK_DAYS)
	check(e3.water_demand > e2.water_demand,
		"imperial center raises water demand (paying influence with water)")

	# Sprawl penalty: many small colonies cost more water than the same total pop
	# concentrated (per-colony overhead), but only marginally ("close, but not the same").
	var sim4 := Sim.new()
	var e4 := sim4.add_empire("C", Color.WHITE)
	var s4 := sim4.add_system("S")
	s4.map_pos = Vector2.ZERO
	sim4.inject_colony(e4.id, sim4.add_planet(s4.id, "p").id, 200.0, true)
	sim4.tick(SimConstants.TICK_DAYS)
	var concentrated: float = e4.water_demand

	var sim5 := Sim.new()
	var e5 := sim5.add_empire("C", Color.WHITE)
	var s5 := sim5.add_system("S")
	s5.map_pos = Vector2.ZERO
	sim5.inject_colony(e5.id, sim5.add_planet(s5.id, "p1").id, 100.0, true)
	sim5.inject_colony(e5.id, sim5.add_planet(s5.id, "p2").id, 100.0, true)
	sim5.tick(SimConstants.TICK_DAYS)
	var spread: float = e5.water_demand
	check(spread > concentrated,
		"spreading the same pop over more colonies costs more water (sprawl penalty)")
	check(spread < concentrated * 1.5,
		"the sprawl penalty stays marginal, not punitive")


func _test_construction_vessel() -> void:
	# A dispatched vessel travels then builds on arrival (not instant).
	var sim := Sim.new()
	var e := sim.add_empire("C", Color.WHITE)
	e.nat[0] = 100000.0
	e.water_income = 1000.0   # spare water flow so the colony vessel clears the water gate
	var a := sim.add_system("A")
	a.map_pos = Vector2.ZERO
	var b := sim.add_system("B")
	b.map_pos = Vector2(200, 0)
	sim.add_lane(a.id, b.id)
	sim.inject_colony(e.id, sim.add_planet(a.id, "cap").id, 1000.0, true)
	var target := sim.add_planet(b.id, "t").id
	check(sim.order_construction(e.id, SimConstants.Build.COLONY, target),
		"dispatch a colony construction vessel")
	check(sim.builders.size() == 1, "a construction vessel is in transit")
	check(sim.planets[target].colony == null,
		"colony is NOT placed instantly — the vessel must travel")
	run_days(sim, 40.0)
	check(sim.planets[target].colony != null, "colony placed on vessel arrival")
	check(sim.builders.is_empty(), "vessel is consumed on arrival")

	# A vessel cannot route through another empire's territory.
	var s2 := Sim.new()
	var me := s2.add_empire("Me", Color.WHITE)
	me.nat[0] = 100000.0
	me.water_income = 1000.0   # water headroom so enemy territory is the ONLY blocker tested
	var foe := s2.add_empire("Foe", Color.RED)
	var sa := s2.add_system("A")
	sa.map_pos = Vector2.ZERO
	var sm := s2.add_system("M")
	sm.map_pos = Vector2(100, 0)
	var sb := s2.add_system("B")
	sb.map_pos = Vector2(200, 0)
	s2.add_lane(sa.id, sm.id)
	s2.add_lane(sm.id, sb.id)
	s2.inject_colony(me.id, s2.add_planet(sa.id, "cap").id, 2000.0, true)
	s2.inject_colony(foe.id, s2.add_planet(sm.id, "foe").id, 100.0, true)
	var tb := s2.add_planet(sb.id, "tb").id
	check(s2.system_owner(sm.id) == foe.id, "test setup: rival owns the middle system")
	check(s2.is_under_influence(sb.id, me.id), "test setup: target is under my influence")
	check(not s2.can_order_construction(me.id, SimConstants.Build.COLONY, tb),
		"a vessel can't be dispatched through enemy territory")


func _test_anomalies() -> void:
	var sim := Sim.new()
	var e := sim.add_empire("A", Color.WHITE)
	var a := sim.add_system("A")
	a.map_pos = Vector2.ZERO
	var b := sim.add_system("B")
	b.map_pos = Vector2(300, 0)
	sim.add_planet(b.id, "pb")
	sim.inject_colony(e.id, sim.add_planet(a.id, "pa").id, 1000.0, true)
	check(sim.claim_strength(b.id, e.id) > 0.0,
		"influence reaches an in-range system with no anomaly between")
	# A snaking band (spine polyline) laid across the A→B line blocks influence.
	sim.add_anomaly(PackedVector2Array([Vector2(150, -80), Vector2(150, 80)]), 60.0)
	check(sim.claim_strength(b.id, e.id) == 0.0,
		"a storm band across the line between two systems blocks influence")
	check(sim.point_in_anomaly(Vector2(150, 0)),
		"point_in_anomaly true inside a band")
	check(not sim.point_in_anomaly(Vector2(150, 500)),
		"point_in_anomaly false well outside")
	# Fleets are NOT blocked by storms: a band lying over a lane leaves the route valid.
	var sm := Sim.new()
	var se := sm.add_empire("A", Color.WHITE)
	var s0 := sm.add_system("S0"); s0.map_pos = Vector2.ZERO
	var s1 := sm.add_system("S1"); s1.map_pos = Vector2(200, 0)
	sm.add_lane(s0.id, s1.id)
	var pf := sm._fleet_at(se.id, s0.id); pf.fighters[0] = 3
	sm.add_anomaly(PackedVector2Array([Vector2(100, -60), Vector2(100, 60)]), 50.0)
	check(sm.order_fleet(pf.id, s1.id) and pf.is_moving(),
		"a fleet can move through a storm laid across its lane")
	# A generated map keeps storm bands clear of every system (lanes are fair game now).
	var m := Sim.new_demo()
	var ok := true
	for an in m.anomalies:
		for s in m.systems.values():
			if Sim._dist_point_to_polyline(s.map_pos, an.pts) < an.r:
				ok = false
	check(ok, "generated storm bands never overlap a system")


func _test_specialization() -> void:
	var sim := Sim.new()
	var e := sim.add_empire("S", Color.WHITE)
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	var c := sim.inject_colony(e.id, sim.add_planet(s.id, "p").id, 300.0, true)
	check(is_equal_approx(c.spec_factor(SimConstants.Spec.ALLOY), 1.0),
		"an unspecialized colony has no bonus")
	sim.set_specialization(e.id, c.planet_id, SimConstants.Spec.ALLOY)
	check(c.spec_strength == 0.0, "a fresh specialization starts at zero strength")
	run_days(sim, SimConstants.SPEC_RAMP_DAYS * 2.0)
	check(is_equal_approx(c.spec_strength, 1.0), "specialization ramps to full strength")
	check(c.spec_factor(SimConstants.Spec.ALLOY) > 1.0,
		"a refining-specialized city boosts its refining output")
	# Switching resets the ramp (inertia).
	sim.set_specialization(e.id, c.planet_id, SimConstants.Spec.FOOD)
	check(c.spec_strength == 0.0, "switching specialization resets the ramp (inertia)")


func _test_mine_upgrade() -> void:
	var sim := Sim.new()
	var e := sim.add_empire("U", Color.WHITE)
	e.nat[0] = 1.0e9
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	var p := sim.add_planet(s.id, "p")
	p.deposit_type = SimConstants.Deposit.MINERAL
	p.mine_empire_id = e.id
	var small := sim.inject_colony(e.id, p.id, 100.0, true)
	var out0: float = p.mine_output()
	check(not sim.can_upgrade_mine(e.id, p.id),
		"cannot upgrade a mine without a big enough same-planet colony")
	small.population = SimConstants.MINE_UPGRADE_POP + 10.0
	check(sim.can_upgrade_mine(e.id, p.id),
		"can upgrade once the colony passes the pop threshold")
	check(sim.upgrade_mine(e.id, p.id) and p.mine_level == 1,
		"upgrading raises the mine level")
	check(p.mine_output() > out0, "an upgraded mine outputs more")


func _test_combat_scaling() -> void:
	# Force ratio decides the kill rate: a 10x-bigger attacker inflicts far more damage
	# in the same window (the old flat per-battle cap made every ratio kill at one rate).
	var small := _attacker_output(5, 2.0)
	var big := _attacker_output(50, 2.0)
	check(small > 0.0, "fleet combat does damage")
	check(big > small * 4.0,
		"a much bigger fleet kills much faster — force ratio matters, no flat cap")


# Defender hull lost over `days` when attacked by `n` tier-5 fighters. The defender is
# a big, tanky, LOW-attack bomber wall: it survives the window and barely returns fire,
# so we read (near-)purely the attacker's damage output, which now scales with n.
func _attacker_output(n: int, days: float) -> float:
	var sim := Sim.new()
	var atk := sim.add_empire("A", Color.RED)
	var def := sim.add_empire("D", Color.BLUE)
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	s.depot_empire_id = def.id   # isolate combat: no border attrition on the defender
	var af := sim._fleet_at(atk.id, s.id)
	af.fighters[4] = n
	var df := sim._fleet_at(def.id, s.id)
	df.bombers[0] = 500   # tanky + weak return fire, so the attacker survives the window
	var before := df.hull()
	run_days(sim, days)
	return before - df.hull()


func _test_fleet_pin() -> void:
	# FTL inhibitor: over an enemy colony a fleet may only retreat the way it came;
	# in a fleet battle it can't jump at all.
	var sim := Sim.new()
	var me := sim.add_empire("Me", Color.BLUE)
	var foe := sim.add_empire("Foe", Color.RED)
	var a := sim.add_system("A"); a.map_pos = Vector2.ZERO
	var b := sim.add_system("B"); b.map_pos = Vector2(100, 0)
	var c := sim.add_system("C"); c.map_pos = Vector2(200, 0)
	sim.add_lane(a.id, b.id)
	sim.add_lane(b.id, c.id)
	var f := sim._fleet_at(me.id, a.id)
	f.fighters[0] = 3
	check(sim.order_fleet(f.id, b.id), "free fleet accepts a move order")
	run_days(sim, 5.0)
	check(f.system_id == b.id and not f.is_moving(), "fleet advanced A->B")
	check(f.prev_system == a.id, "fleet remembers it came from A")
	# Enemy colony appears at B -> retreat-only pin.
	sim.inject_colony(foe.id, sim.add_planet(b.id, "B I").id, 100.0, true)
	check(sim.fleet_pin(f) == 1, "over an enemy colony -> retreat-only pin")
	check(not sim.order_fleet(f.id, c.id), "cannot advance past a pinning colony")
	check(f.path.is_empty(), "the refused advance left the fleet in place")
	check(sim.order_fleet(f.id, a.id), "may retreat the way it came (to A)")
	# Hard pin: an enemy fleet in the same system locks movement entirely.
	var sim2 := Sim.new()
	var m2 := sim2.add_empire("M", Color.BLUE)
	var f2 := sim2.add_empire("F", Color.RED)
	var x := sim2.add_system("X"); x.map_pos = Vector2.ZERO
	var y := sim2.add_system("Y"); y.map_pos = Vector2(100, 0)
	sim2.add_lane(x.id, y.id)
	var g := sim2._fleet_at(m2.id, x.id); g.fighters[0] = 3
	var h := sim2._fleet_at(f2.id, x.id); h.fighters[0] = 3
	check(sim2.fleet_pin(g) == 2, "enemy fleet present -> locked (battle)")
	check(not sim2.order_fleet(g.id, y.id), "cannot jump out of an active battle")


func _test_enemy_transit_block() -> void:
	# A fleet may not thread a route THROUGH an enemy-held system (its colony blocks
	# passage). Layout: A -- B(enemy colony) -- C, plus a detour A -- D -- C.
	var sim := Sim.new()
	var me := sim.add_empire("Me", Color.BLUE)
	var foe := sim.add_empire("Foe", Color.RED)
	var a := sim.add_system("A"); a.map_pos = Vector2.ZERO
	var b := sim.add_system("B"); b.map_pos = Vector2(100, 0)
	var c := sim.add_system("C"); c.map_pos = Vector2(200, 0)
	sim.add_lane(a.id, b.id)
	sim.add_lane(b.id, c.id)
	sim.inject_colony(foe.id, sim.add_planet(b.id, "B I").id, 100.0, true)
	var f := sim._fleet_at(me.id, a.id); f.fighters[0] = 3
	# Only route A->C is through the enemy colony at B: refused.
	check(not sim.order_fleet(f.id, c.id),
		"cannot route through an enemy-held system to reach a system beyond it")
	# But B itself is a legal destination — you march in to attack it.
	check(sim.order_fleet(f.id, b.id) and f.is_moving(),
		"an enemy-held system is still a legal attack destination")
	# Add a detour A -- D -- C that avoids B: now A->C routes around.
	var d := sim.add_system("D"); d.map_pos = Vector2(100, 200)
	sim.add_lane(a.id, d.id)
	sim.add_lane(d.id, c.id)
	var f2 := sim._fleet_at(me.id, a.id); f2.fighters[0] = 3
	check(sim.order_fleet(f2.id, c.id), "a detour around the enemy system is accepted")
	check(f2.path.has(d.id) and not f2.path.has(b.id),
		"the accepted route goes through the neutral detour, not the enemy system")


func _test_citadel() -> void:
	# A citadel walls a system off: enemy fleets can't pass through it until it's
	# bombarded down. Layout: A(my depot) -- B(foe citadel) -- C.
	var sim := Sim.new()
	var me := sim.add_empire("Me", Color.BLUE)
	var foe := sim.add_empire("Foe", Color.RED)
	foe.nat[0] = 1.0e9
	var a := sim.add_system("A"); a.map_pos = Vector2.ZERO
	var b := sim.add_system("B"); b.map_pos = Vector2(100, 0)
	var c := sim.add_system("C"); c.map_pos = Vector2(200, 0)
	sim.add_lane(a.id, b.id)
	sim.add_lane(b.id, c.id)
	sim.add_planet(a.id, "pa"); sim.add_planet(b.id, "pb"); sim.add_planet(c.id, "pc")
	a.depot_empire_id = me.id   # keeps my besieger supplied one hop into B (no attrition)

	# Foe raises a citadel at B (built directly to skip influence gating in this fixture).
	b.citadel_empire_id = foe.id
	b.citadel_hp = SimConstants.CITADEL_MAX_HP
	var mover := sim._fleet_at(me.id, a.id); mover.fighters[0] = 3
	check(not sim.order_fleet(mover.id, c.id),
		"a standing enemy citadel blocks passage through its system")
	check(sim.order_fleet(mover.id, b.id) and mover.is_moving(),
		"the citadel system is still a legal attack destination")

	# A besieging bomber fleet sits on B and grinds the citadel down.
	var siege := sim._fleet_at(me.id, b.id); siege.bombers[0] = 400
	var hp0: float = sim.systems[b.id].citadel_hp
	run_days(sim, 20.0)
	check(sim.systems[b.id].citadel_hp < hp0, "bombardment damages the citadel's hull")
	# Grind it all the way down.
	run_days(sim, 4000.0)
	check(sim.systems[b.id].citadel_empire_id == -1,
		"a fully bombarded citadel is destroyed")
	# With the citadel gone, a fresh fleet can route A -> C through B.
	var mover2 := sim._fleet_at(me.id, a.id); mover2.fighters[0] = 3
	check(sim.order_fleet(mover2.id, c.id),
		"once the citadel falls, passage through the system reopens")

	# Build gating: heavy alloy cost, only in your own influence.
	var sim2 := Sim.new()
	var e2 := sim2.add_empire("E", Color.WHITE)
	var s := sim2.add_system("S"); s.map_pos = Vector2.ZERO
	sim2.inject_colony(e2.id, sim2.add_planet(s.id, "p").id, 200.0, true)
	e2.nat[0] = SimConstants.CITADEL_COST_ALLOYS - 1.0
	check(not sim2.can_build_citadel(e2.id, s.id), "can't afford a citadel just short of cost")
	e2.nat[0] = SimConstants.CITADEL_COST_ALLOYS + 1.0
	check(sim2.can_build_citadel(e2.id, s.id), "can build a citadel in your influence with alloys")
	check(sim2.build_citadel(e2.id, s.id)
		and sim2.systems[s.id].citadel_empire_id == e2.id
		and is_equal_approx(sim2.systems[s.id].citadel_hp, SimConstants.CITADEL_MAX_HP),
		"a built citadel stands at full hull for its empire")
	check(not sim2.can_build_citadel(e2.id, s.id), "only one citadel per system")


func _test_attrition_and_depot() -> void:
	# home (owned) linked to a far, unowned system where a fleet will overstay.
	var sim := Sim.new()
	var e := sim.add_empire("E", Color.WHITE)
	e.nat[0] = 1.0e9
	var home := sim.add_system("Home")
	home.map_pos = Vector2.ZERO
	sim.inject_colony(e.id, sim.add_planet(home.id, "H").id, 150.0, true)
	var far := sim.add_system("Far")
	far.map_pos = Vector2(5000, 0)   # out of the home's influence
	sim.add_planet(far.id, "F")
	sim.add_lane(home.id, far.id)

	var f := sim._fleet_at(e.id, far.id)
	f.fighters[0] = 200
	var hull0: float = f.hull()
	run_days(sim, 30.0)   # no grace period: it bleeds right away
	check(f.hull() < hull0, "a fleet outside its borders bleeds hull to attrition immediately")

	# Same, but a supply depot in the system negates attrition.
	var sim2 := Sim.new()
	var e2 := sim2.add_empire("E2", Color.WHITE)
	var far2 := sim2.add_system("Far")
	far2.map_pos = Vector2(5000, 0)
	sim2.add_planet(far2.id, "F")
	far2.depot_empire_id = e2.id   # depot present
	var g := sim2._fleet_at(e2.id, far2.id)
	g.fighters[0] = 200
	var ghull0: float = g.hull()
	run_days(sim2, 30.0)
	check(is_equal_approx(g.hull(), ghull0), "a supply depot negates attrition in its own system")

	# The depot's supply radius reaches DEPOT_SUPPLY_JUMPS hops: a fleet exactly that
	# many jumps from a friendly depot is safe; one hop further bleeds.
	var sim3 := Sim.new()
	var e3 := sim3.add_empire("E3", Color.WHITE)
	var chain: Array[int] = []
	for i in range(SimConstants.DEPOT_SUPPLY_JUMPS + 2):
		var sN := sim3.add_system("N%d" % i)
		sN.map_pos = Vector2(5000 + i * 500, 0)   # all far from any influence
		sim3.add_planet(sN.id, "p%d" % i)
		chain.append(sN.id)
		if i > 0:
			sim3.add_lane(chain[i - 1], chain[i])
	sim3.systems[chain[0]].depot_empire_id = e3.id   # depot at the head of the chain
	# Fleet exactly DEPOT_SUPPLY_JUMPS hops out — inside the radius, safe.
	var inr := sim3._fleet_at(e3.id, chain[SimConstants.DEPOT_SUPPLY_JUMPS])
	inr.fighters[0] = 200
	var inr0: float = inr.hull()
	# Fleet one hop beyond the radius — bleeds.
	var outr := sim3._fleet_at(e3.id, chain[SimConstants.DEPOT_SUPPLY_JUMPS + 1])
	outr.fighters[0] = 200
	var outr0: float = outr.hull()
	run_days(sim3, 30.0)
	check(is_equal_approx(inr.hull(), inr0),
		"a depot supplies fleets up to DEPOT_SUPPLY_JUMPS lane hops away")
	check(outr.hull() < outr0,
		"a fleet beyond the depot's supply radius still bleeds")

	# Depot build gating: allowed in your influence, not outside it.
	check(sim.can_build_depot(e.id, home.id), "can build a depot in your own system")
	check(not sim.can_build_depot(e.id, far.id),
		"cannot build a depot outside your influence")
	check(sim.build_depot(e.id, home.id) and sim.systems[home.id].depot_empire_id == e.id,
		"building a depot marks the system")


func _test_structure_capture() -> void:
	# An empty system with a rival's undefended mine; a stronger empire's border
	# extends over it and captures the mine (colonies would NOT flip like this).
	var sim := Sim.new()
	var strong := sim.add_empire("Strong", Color.RED)
	var weak := sim.add_empire("Weak", Color.BLUE)
	var base := sim.add_system("Base")
	base.map_pos = Vector2.ZERO
	sim.inject_colony(strong.id, sim.add_planet(base.id, "B").id, 400.0, true)
	var mid := sim.add_system("Mid")     # empty system next to Strong's base
	mid.map_pos = Vector2(150, 0)
	var mp := sim.add_planet(mid.id, "M")
	mp.deposit_type = SimConstants.Deposit.MINERAL
	mp.mine_empire_id = weak.id          # weak owns a mine here, but no colony
	check(sim.system_owner(mid.id) == strong.id,
		"the empty system is inside the strong empire's border")
	sim.tick(SimConstants.TICK_DAYS)
	check(mp.mine_empire_id == strong.id,
		"a mine changes hands to whoever controls the system as the border shifts")


func _test_difficulty() -> void:
	# Empire.efficiency scales mining output. Same mine, two efficiencies -> the
	# higher-efficiency empire banks more of the T0 resource per tick.
	var low := _mined_over(0.5)
	var high := _mined_over(1.5)
	check(high > low and low > 0.0,
		"empire efficiency (difficulty) scales resource gathering")
	# The generator applies ai_efficiency to AI empires, not the player.
	var sim := Sim.generate_map({"ai_efficiency": 0.5, "empire_count": 3})
	var ids: Array = sim.empires.keys()
	check(is_equal_approx(sim.empires[ids[0]].efficiency, 1.0),
		"the player empire keeps efficiency 1.0")
	check(is_equal_approx(sim.empires[ids[1]].efficiency, 0.5),
		"AI empires take the configured difficulty efficiency")


func _mined_over(eff: float) -> float:
	var sim := Sim.new()
	var e := sim.add_empire("E", Color.WHITE)
	e.efficiency = eff
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	var p := sim.add_planet(s.id, "p")
	p.deposit_type = SimConstants.Deposit.WATER
	p.mine_empire_id = e.id
	sim.tick(SimConstants.TICK_DAYS)
	return e.water_income   # water is a flow now; income this tick reflects mine output


func _test_save_load() -> void:
	var a := Sim.new_demo()
	run_days(a, 150.0)   # evolve so there's real state (colonies, resources, maybe ships)
	# Full JSON round-trip, as a real save would do.
	var b := Sim.deserialize(JSON.parse_string(JSON.stringify(a.serialize())))
	check(is_equal_approx(a.day, b.day), "save/load preserves the day")
	check(a.empires.size() == b.empires.size()
		and a.systems.size() == b.systems.size()
		and a.planets.size() == b.planets.size()
		and a.lanes.size() == b.lanes.size(),
		"save/load preserves counts (empires/systems/planets/lanes)")
	check(a.colonies.size() == b.colonies.size()
		and a.fleets.size() == b.fleets.size(),
		"save/load preserves colonies and fleets")
	var same_res := true
	for id in a.empires:
		var ea: Empire = a.empires[id]
		var eb: Empire = b.empires[id]
		if not (is_equal_approx(ea.nat[0], eb.nat[0])
				and is_equal_approx(ea.minerals, eb.minerals)
				and is_equal_approx(ea.efficiency, eb.efficiency)):
			same_res = false
	check(same_res, "save/load preserves empire resources + efficiency")
	var same_pop := true
	for i in a.colonies.size():
		if not is_equal_approx(a.colonies[i].population, b.colonies[i].population):
			same_pop = false
	check(same_pop, "save/load preserves colony populations")
	# The loaded sim keeps running correctly.
	var day_before := b.day
	run_days(b, 5.0)
	check(b.day > day_before, "a loaded sim continues to tick")


func _test_determinism() -> void:
	var a := Sim.new_demo()
	var b := Sim.new_demo()
	for sim: Sim in [a, b]:
		run_days(sim, 300.0)
	var same := a.day == b.day and a.colonies.size() == b.colonies.size()
	for i in a.colonies.size():
		if a.colonies[i].population != b.colonies[i].population:
			same = false
	for k in a.empires:
		var ea: Empire = a.empires[k]
		var eb: Empire = b.empires[k]
		if ea.minerals != eb.minerals or ea.nat[0] != eb.nat[0] \
				or ea.nat[4] != eb.nat[4]:
			same = false
	check(same, "identical runs produce bit-identical state")
