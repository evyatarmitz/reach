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
	e.alloys = 100000.0
	e.food = 1.0e12
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
	_test_influence_nonstacking()
	_test_influence_gating()
	_test_border_contest()
	_test_influence_field()
	_test_fog_of_war()
	_test_neighbor_bonus()
	_test_ai_rival()
	_test_mining()
	_test_conversion()
	_test_food_growth()
	_test_diminishing_returns()
	_test_emigration()
	_test_fleets()
	_test_military_resources()
	_test_specialization()
	_test_mine_upgrade()
	_test_power_ceiling()
	_test_attrition_and_depot()
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


func _test_founding() -> void:
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	var alloys_before: float = e.alloys
	check(sim.found_colony(e.id, sc.plain_p.id),
		"founding succeeds on empty planet under influence with alloys")
	check(is_equal_approx(e.alloys, alloys_before - SimConstants.FOUND_COST_ALLOYS),
		"founding deducts exactly the alloy cost")
	check(not sim.found_colony(e.id, sc.plain_p.id),
		"founding fails on already-colonized planet")
	var sc2 := make_scenario()
	sc2.e.alloys = SimConstants.FOUND_COST_ALLOYS - 1.0
	check(not sc2.sim.found_colony(sc2.e.id, sc2.plain_p.id),
		"founding fails when alloys are short")
	check(sc2.e.alloys == SimConstants.FOUND_COST_ALLOYS - 1.0,
		"failed founding costs nothing")


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
	e.food = 1.0e12   # never food-limited; this tests the neighbor multiplier
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
	var rig := _neighbor_rig()
	check(is_equal_approx(rig.sim.neighbor_growth_multiplier(rig.subject), 1.0),
		"isolated colony has neighbor multiplier 1.0")
	var rig2 := _neighbor_rig()
	_add_established(rig2.sim, rig2.e, Vector2(250, 0), 200.0)
	var m_near: float = rig2.sim.neighbor_growth_multiplier(rig2.subject)
	check(m_near > 1.0, "an established neighbor in another system boosts growth")
	var rig3 := _neighbor_rig()
	_add_established(rig3.sim, rig3.e, Vector2(500, 0), 200.0)
	check(rig3.sim.neighbor_growth_multiplier(rig3.subject) < m_near,
		"a farther neighbor boosts less (1/R falloff)")
	var rig5 := _neighbor_rig()
	var rig5_sim: Sim = rig5.sim
	var pa2: Planet = rig5_sim.add_planet(rig5.a.id, "A II")
	rig5_sim.inject_colony(rig5.e.id, pa2.id, 300.0, true)
	check(is_equal_approx(rig5_sim.neighbor_growth_multiplier(rig5.subject), 1.0),
		"same-system established colony contributes no neighbor bonus")
	# End to end: clustered colony out-grows an isolated identical one (both have
	# unlimited food, so only the neighbor bonus differs).
	var iso := _neighbor_rig()
	var clu := _neighbor_rig()
	_add_established(clu.sim, clu.e, Vector2(250, 0), 300.0)
	run_days(iso.sim, 100.0)
	run_days(clu.sim, 100.0)
	check(clu.subject.population > iso.subject.population,
		"over time, a clustered colony grows past an isolated one")


func _test_ai_rival() -> void:
	var sim := Sim.new()
	var e := sim.add_empire("AI", Color.RED)
	e.alloys = 10000.0
	var home := sim.add_system("Home")
	home.map_pos = Vector2.ZERO
	sim.inject_colony(e.id, sim.add_planet(home.id, "Home I").id, 150.0, true)
	var near := sim.add_system("Near")
	near.map_pos = Vector2(200, 0)
	var near_p := sim.add_planet(near.id, "Near I")
	near_p.deposit_type = SimConstants.Deposit.MINERAL
	var far := sim.add_system("Far")
	far.map_pos = Vector2(5000, 0)
	var far_p := sim.add_planet(far.id, "Far I")
	far_p.deposit_type = SimConstants.Deposit.MINERAL

	var ai := EmpireAI.new(e.id)
	ai.maybe_act(sim)
	check(sim.planets[near_p.id].colony != null
		and sim.planets[near_p.id].colony.empire_id == e.id,
		"AI colonizes a reachable empty system")
	check(sim.planets[near_p.id].has_mine(),
		"AI builds a mine on a reachable deposit")
	check(sim.planets[far_p.id].colony == null and not sim.planets[far_p.id].has_mine(),
		"AI never acts outside its influence (same gating as the player)")
	var after_first: int = sim.colonies.size()
	ai.maybe_act(sim)
	check(sim.colonies.size() == after_first,
		"AI respects its action interval (no acting every tick)")

	var demo := Sim.new_demo()
	var rival_id: int = demo.empires.keys()[1]
	run_days(demo, 400.0)
	var rival_colonies := 0
	for c in demo.colonies:
		if c.empire_id == rival_id:
			rival_colonies += 1
	check(rival_colonies >= 2, "rival AI expands to multiple colonies over time")
	# The AI also builds ships once its cities produce military resources.
	var rival_ships := 0
	for f in demo.fleets:
		if f.empire_id == rival_id:
			rival_ships += f.ship_count()
	check(rival_ships >= 1, "rival AI builds ships once it can afford them")


func _test_mining() -> void:
	# Gating (alloy cost + influence), via the shared scenario.
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	check(not sim.can_build_mine(e.id, sc.plain_p.id), "mine requires a deposit")
	var alloys_before: float = e.alloys
	check(sim.build_mine(e.id, sc.deposit_p.id), "mine builds on reachable deposit")
	check(is_equal_approx(e.alloys, alloys_before - SimConstants.MINE_COST_ALLOYS),
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
	run_days(sim2, 10.0)
	check(is_equal_approx(w.water, wp.mine_output() * 10.0),
		"water-deposit mine yields water at this deposit's richness")
	check(is_equal_approx(w.minerals, mp.mine_output() * 10.0),
		"mineral-deposit mine yields minerals at this deposit's richness")
	check(other.water == 0.0 and other.minerals == 0.0,
		"other empires get nothing from a rival's mines")
	# Richness varies by deposit and its estimate bracket contains the truth.
	check(wp.mine_output() != mp.mine_output(),
		"different deposits have different richness")
	var est := wp.output_estimate()
	check(wp.mine_output() >= est.x and wp.mine_output() <= est.y,
		"the pre-build estimate bracket contains the true output")


func _test_conversion() -> void:
	var sim := Sim.new()
	var e := sim.add_empire("C", Color.WHITE)
	e.food = 0.0
	e.alloys = 0.0
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	var city := sim.inject_colony(e.id, sim.add_planet(s.id, "p").id, 200.0, true)
	# Plenty of input: a full tick converts up to capacity of each chain. Measure
	# WATER consumed (food is also eaten by pop the same tick, so the food
	# stockpile isn't a clean readout of what was refined).
	e.water = 1.0e6
	e.minerals = 1.0e6
	var cap_before: float = city.food_capacity()   # pop grows during the tick
	sim.tick(SimConstants.TICK_DAYS)
	check(is_equal_approx(1.0e6 - e.water, cap_before * SimConstants.TICK_DAYS),
		"established city refines water into food at capacity when input is ample")
	check(e.alloys > 0.0, "established city refines minerals into alloys")

	# Partial: only a little water (below one tick's capacity) -> all of it is
	# consumed and that's all the food made (5W -> 5F, not a full-capacity 20F).
	var sim2 := Sim.new()
	var e2 := sim2.add_empire("C2", Color.WHITE)
	e2.food = 0.0
	var s2 := sim2.add_system("S")
	s2.map_pos = Vector2.ZERO
	var city2 := sim2.inject_colony(e2.id, sim2.add_planet(s2.id, "p").id, 200.0, true)
	e2.water = 0.3   # far below one tick's capacity
	check(0.3 < city2.food_capacity() * SimConstants.TICK_DAYS,
		"test setup: available water is below full conversion capacity")
	sim2.tick(SimConstants.TICK_DAYS)
	check(is_equal_approx(e2.water, 0.0) and e2.food > 0.0,
		"conversion is partial and input-limited (all 0.3W consumed, not more)")

	# Unestablished colonies refine nothing.
	var sim3 := Sim.new()
	var e3 := sim3.add_empire("C3", Color.WHITE)
	e3.food = 1.0e9   # keep it alive (surplus), isolate the conversion check
	var s3 := sim3.add_system("S")
	s3.map_pos = Vector2.ZERO
	sim3.inject_colony(e3.id, sim3.add_planet(s3.id, "p").id, 50.0, false)
	e3.water = 1000.0
	var water_before: float = e3.water
	sim3.tick(SimConstants.TICK_DAYS)
	check(is_equal_approx(e3.water, water_before),
		"an unestablished colony refines no water into food")


func _test_food_growth() -> void:
	# Surplus -> grow.
	var sim := Sim.new()
	var e := sim.add_empire("G", Color.WHITE)
	e.food = 1.0e6
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	var c := sim.inject_colony(e.id, sim.add_planet(s.id, "p").id, 50.0, false)
	run_days(sim, 5.0)
	check(c.population > 50.0, "food surplus makes population grow")

	# Deficit -> shrink (population CAN decrease now — the earlier bug is fixed).
	var sim2 := Sim.new()
	var e2 := sim2.add_empire("S", Color.WHITE)
	e2.food = 0.0   # no food, no mines -> pure deficit
	var s2 := sim2.add_system("S")
	s2.map_pos = Vector2.ZERO
	var c2 := sim2.inject_colony(e2.id, sim2.add_planet(s2.id, "p").id, 200.0, true)
	run_days(sim2, 20.0)
	check(c2.population < 200.0,
		"food deficit shrinks population (no longer grows on empty stores)")

	# Shrink is floored: population never drops below MIN_POP or below zero.
	var sim3 := Sim.new()
	var e3 := sim3.add_empire("F", Color.WHITE)
	e3.food = 0.0
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
	e.food = 1.0e12
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
	e.food = 1.0e12
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
	e.food = 1.0e12
	e.alloys = 1.0e9   # ample input to the chain
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	sim.inject_colony(e.id, sim.add_planet(s.id, "big").id, 3000.0, true)
	run_days(sim, 40.0)
	# The chain feeds upward, so a maxed city ends holding the TOP tier (lower
	# tiers get consumed to make the next) — that's the "spread cities for a mix"
	# pressure. Just confirm it reached tier 5.
	check(e.nat[4] > 0.0, "a city above the top cutoff refines all the way to tier 5")

	var sim2 := Sim.new()
	var e2 := sim2.add_empire("M2", Color.WHITE)
	e2.food = 1.0e12
	e2.alloys = 1.0e9
	var s2 := sim2.add_system("S")
	s2.map_pos = Vector2.ZERO
	sim2.inject_colony(e2.id, sim2.add_planet(s2.id, "small").id, 150.0, true)
	run_days(sim2, 40.0)
	check(e2.nat[0] > 0.0 and e2.nat[1] == 0.0,
		"a small city (below the tier-2 cutoff) refines only tier 1")


func _test_specialization() -> void:
	var sim := Sim.new()
	var e := sim.add_empire("S", Color.WHITE)
	e.food = 0.0
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	var c := sim.inject_colony(e.id, sim.add_planet(s.id, "p").id, 300.0, true)
	check(is_equal_approx(c.spec_factor(SimConstants.Spec.FOOD), 1.0),
		"an unspecialized colony has no bonus")
	sim.set_specialization(e.id, c.planet_id, SimConstants.Spec.FOOD)
	check(c.spec_strength == 0.0, "a fresh specialization starts at zero strength")
	e.water = 1.0e9   # keep the city refining so the ramp advances
	run_days(sim, SimConstants.SPEC_RAMP_DAYS * 2.0)
	check(is_equal_approx(c.spec_strength, 1.0), "specialization ramps to full strength")
	check(c.spec_factor(SimConstants.Spec.FOOD) > 1.0
		and is_equal_approx(c.spec_factor(SimConstants.Spec.ALLOY), 1.0),
		"a food-specialized city boosts food only")
	# Switching resets the ramp (inertia).
	sim.set_specialization(e.id, c.planet_id, SimConstants.Spec.ALLOY)
	check(c.spec_strength == 0.0, "switching specialization resets the ramp (inertia)")


func _test_mine_upgrade() -> void:
	var sim := Sim.new()
	var e := sim.add_empire("U", Color.WHITE)
	e.food = 1.0e12
	e.alloys = 1.0e9
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


func _test_power_ceiling() -> void:
	# Two attacker stacks both well over the ceiling (and staying over it across
	# the window) inflict the SAME damage — extra ships add no punch, only hull.
	var lost_at_cap := _window_enemy_loss(8)
	var lost_over_cap := _window_enemy_loss(30)
	check(is_equal_approx(lost_at_cap, lost_over_cap),
		"combat damage is hard-capped: a huge stack hits no harder than the ceiling")
	check(lost_at_cap > 0.0, "combat still does damage")


# Defender hull lost over 30 days when attacked by `n` tier-5 fighters. The
# defender is huge (survives) so we read the attacker's (capped) damage output.
func _window_enemy_loss(n: int) -> float:
	var sim := Sim.new()
	var atk := sim.add_empire("A", Color.RED)
	var def := sim.add_empire("D", Color.BLUE)
	var s := sim.add_system("S")
	s.map_pos = Vector2.ZERO
	var af := sim._fleet_at(atk.id, s.id)
	af.fighters[4] = n
	var df := sim._fleet_at(def.id, s.id)
	df.fighters[0] = 100000   # huge defender: survives, and its own damage stays capped
	var before := df.hull()
	run_days(sim, 30.0)
	return before - df.hull()


func _test_attrition_and_depot() -> void:
	# home (owned) linked to a far, unowned system where a fleet will overstay.
	var sim := Sim.new()
	var e := sim.add_empire("E", Color.WHITE)
	e.food = 1.0e12
	e.alloys = 1.0e9
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
	run_days(sim, SimConstants.ATTRITION_GRACE_DAYS + 60.0)
	check(f.hull() < hull0, "a fleet overstaying unowned space bleeds hull to attrition")

	# Same, but a supply depot in the system negates attrition.
	var sim2 := Sim.new()
	var e2 := sim2.add_empire("E2", Color.WHITE)
	e2.food = 1.0e12
	var far2 := sim2.add_system("Far")
	far2.map_pos = Vector2(5000, 0)
	sim2.add_planet(far2.id, "F")
	far2.depot_empire_id = e2.id   # depot present
	var g := sim2._fleet_at(e2.id, far2.id)
	g.fighters[0] = 200
	var ghull0: float = g.hull()
	run_days(sim2, SimConstants.ATTRITION_GRACE_DAYS + 60.0)
	check(is_equal_approx(g.hull(), ghull0), "a supply depot negates overstay attrition")

	# Depot build gating: allowed in your influence, not outside it.
	check(sim.can_build_depot(e.id, home.id), "can build a depot in your own system")
	check(not sim.can_build_depot(e.id, far.id),
		"cannot build a depot outside your influence")
	check(sim.build_depot(e.id, home.id) and sim.systems[home.id].depot_empire_id == e.id,
		"building a depot marks the system")


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
		if ea.water != eb.water or ea.minerals != eb.minerals \
				or ea.food != eb.food or ea.alloys != eb.alloys:
			same = false
	check(same, "identical runs produce bit-identical state")
