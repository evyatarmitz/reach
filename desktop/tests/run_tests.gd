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
	# Integer tick count — accumulating 0.1 in a float would drift past `days`
	# and run an extra tick.
	for i in int(round(days / SimConstants.TICK_DAYS)):
		sim.tick(SimConstants.TICK_DAYS)


# One empire, one system at origin with two planets (first has a deposit), an
# established pop-150 anchor colony on planet B for influence, plus an empty
# far-away system out of reach. Returns handles for the pieces.
func make_scenario() -> Dictionary:
	var sim := Sim.new()
	var e := sim.add_empire("Alpha", Color.WHITE)
	var s1 := sim.add_system("Home")
	s1.map_pos = Vector2.ZERO
	var deposit_p := sim.add_planet(s1.id, "Home I")
	deposit_p.has_deposit = true
	var plain_p := sim.add_planet(s1.id, "Home II")
	var anchor_p := sim.add_planet(s1.id, "Home III")
	var far := sim.add_system("Far")
	far.map_pos = Vector2(5000, 0)
	var far_p := sim.add_planet(far.id, "Far I")
	far_p.has_deposit = true
	sim.add_lane(s1.id, far.id)
	var anchor := sim.inject_colony(e.id, anchor_p.id, 150.0, true)
	anchor.days_since_established = 1000000.0  # upkeep fully tapered
	anchor.population = 150.0
	return {"sim": sim, "e": e, "home": s1, "far": far,
		"deposit_p": deposit_p, "plain_p": plain_p, "anchor_p": anchor_p,
		"far_p": far_p, "anchor": anchor}


func _init() -> void:
	_test_topology()
	_test_founding()
	_test_influence_nonstacking()
	_test_influence_gating()
	_test_border_contest()
	_test_neighbor_bonus()
	_test_mining()
	_test_mine_income_routing()
	_test_production_input()
	_test_drain_and_growth()
	_test_activation_taper_production()
	_test_diminishing_returns()
	_test_starvation()
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
	# Connectivity: BFS over lanes must reach every system.
	var visited := {}
	var queue: Array[int] = [sim.systems.keys()[0]]
	while not queue.is_empty():
		var sid: int = queue.pop_front()
		if visited.has(sid):
			continue
		visited[sid] = true
		for n in sim.lane_neighbors(sid):
			queue.append(n)
	check(visited.size() == sim.systems.size(),
		"lane graph is fully connected")
	check(sim.empires.size() >= 1 and sim.colonies.size() >= 1,
		"demo starts with an empire and a homeworld")


func _test_founding() -> void:
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	var raw_before: float = e.raw
	check(sim.found_colony(e.id, sc.plain_p.id),
		"founding succeeds on empty planet under influence with funds")
	check(e.raw == raw_before - SimConstants.FOUND_COST,
		"founding deducts exactly the flat cost")
	check(not sim.found_colony(e.id, sc.plain_p.id),
		"founding fails on already-colonized planet")
	var sc2 := make_scenario()
	sc2.e.raw = SimConstants.FOUND_COST - 1.0
	check(not sc2.sim.found_colony(sc2.e.id, sc2.plain_p.id),
		"founding fails when stockpile is short")
	check(sc2.e.raw == SimConstants.FOUND_COST - 1.0,
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
	# Add a weaker colony in the SAME system: influence must not stack.
	sim.inject_colony(e.id, sc.plain_p.id, 100.0, true)
	check(is_equal_approx(sim.system_influence(sc.home.id, e.id),
		SimConstants.INFLUENCE_A1 * 150.0),
		"same-system colonies do not stack influence (max, not sum)")
	# A stronger one raises it.
	sc.sim.planets[sc.plain_p.id].colony.population = 400.0
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
	# Bring a covered neighbor system into range: reach 270 with pop 150.
	var near := sim.add_system("Near")
	near.map_pos = Vector2(200, 0)
	var near_p := sim.add_planet(near.id, "Near I")
	near_p.has_deposit = true
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
	var pa := sim.add_planet(a.id, "A I")
	var pb := sim.add_planet(b.id, "B I")
	sim.inject_colony(e1.id, pa.id, 200.0, true)
	sim.inject_colony(e2.id, pb.id, 100.0, true)
	# Ratio rule: border sits where 200/d1 = 100/d2 -> at x = 200 of 300.
	var left := sim.add_system("Left")
	left.map_pos = Vector2(190, 0)
	sim.add_planet(left.id, "L I")
	var right := sim.add_system("Right")
	right.map_pos = Vector2(210, 0)
	sim.add_planet(right.id, "R I")
	check(sim.system_owner(left.id) == e1.id,
		"contested: system left of the influence-ratio point goes to the stronger")
	check(sim.system_owner(right.id) == e2.id,
		"contested: system right of the influence-ratio point goes to the weaker")
	check(sim.system_owner(a.id) == e1.id and sim.system_owner(b.id) == e2.id,
		"own presence in a system is an absolute claim")
	# Outgrow the rival: the border MOVES. Weak doubles its pop.
	sim.planets[pb.id].colony.population = 400.0
	check(sim.system_owner(left.id) == e2.id,
		"borders are live: outgrowing the rival moves the line")
	# Reach limits still apply: a system beyond everyone's reach is unclaimed.
	var out := sim.add_system("Out")
	out.map_pos = Vector2(5000, 0)
	sim.add_planet(out.id, "O I")
	check(sim.system_owner(out.id) == -1,
		"systems beyond all reach are unclaimed")


# Build a fresh empire with a subject colony in system A and configurable
# established centers in other systems, all with unlimited supply.
func _neighbor_rig() -> Dictionary:
	var sim := Sim.new()
	var e := sim.add_empire("N", Color.WHITE)
	e.raw = 1.0e12
	var a := sim.add_system("A")
	a.map_pos = Vector2.ZERO
	var pa := sim.add_planet(a.id, "A I")
	var subject := sim.inject_colony(e.id, pa.id, 200.0, true)
	subject.days_since_established = 1.0e9  # no upkeep noise
	return {"sim": sim, "e": e, "a": a, "subject": subject}


func _add_established(sim: Sim, e: Empire, pos: Vector2, pop: float) -> void:
	var s := sim.add_system("S%d" % sim.systems.size())
	s.map_pos = pos
	var p := sim.add_planet(s.id, "P")
	sim.inject_colony(e.id, p.id, pop, true)


func _test_neighbor_bonus() -> void:
	# Baseline: no neighbors → multiplier is exactly 1.
	var rig := _neighbor_rig()
	check(is_equal_approx(
		rig.sim.neighbor_growth_multiplier(rig.subject), 1.0),
		"isolated colony has neighbor multiplier 1.0")

	# One established neighbor in another system raises the multiplier.
	var rig2 := _neighbor_rig()
	_add_established(rig2.sim, rig2.e, Vector2(250, 0), 200.0)
	var m_near: float = rig2.sim.neighbor_growth_multiplier(rig2.subject)
	check(m_near > 1.0, "an established neighbor in another system boosts growth")

	# 1/R falloff: the same neighbor farther away boosts less.
	var rig3 := _neighbor_rig()
	_add_established(rig3.sim, rig3.e, Vector2(500, 0), 200.0)
	var m_far: float = rig3.sim.neighbor_growth_multiplier(rig3.subject)
	check(m_far < m_near, "a farther neighbor boosts less (1/R falloff)")
	check(is_equal_approx(m_near - 1.0, (m_far - 1.0) * 2.0),
		"halving distance doubles the bonus (exact 1/R)")

	# Compounding: two neighbors give more than one.
	var rig4 := _neighbor_rig()
	_add_established(rig4.sim, rig4.e, Vector2(250, 0), 200.0)
	_add_established(rig4.sim, rig4.e, Vector2(0, 250), 200.0)
	check(rig4.sim.neighbor_growth_multiplier(rig4.subject) > m_near,
		"two neighbors compound to a larger bonus than one")

	# Same-system colony gives NO neighbor bonus (it competes, not boosts).
	var rig5 := _neighbor_rig()
	var rig5_sim: Sim = rig5.sim
	var pa2: Planet = rig5_sim.add_planet(rig5.a.id, "A II")
	rig5_sim.inject_colony(rig5.e.id, pa2.id, 300.0, true)
	check(is_equal_approx(
		rig5.sim.neighbor_growth_multiplier(rig5.subject), 1.0),
		"same-system established colony contributes no neighbor bonus")

	# Only same-empire, only established centers count.
	var rig6 := _neighbor_rig()
	var rig6_sim: Sim = rig6.sim
	var rival: Empire = rig6_sim.add_empire("Rival", Color.RED)
	_add_established(rig6_sim, rival, Vector2(250, 0), 500.0)
	check(is_equal_approx(
		rig6_sim.neighbor_growth_multiplier(rig6.subject), 1.0),
		"a rival's established center gives no bonus")
	var s: StarSystem = rig6_sim.add_system("Unest")
	s.map_pos = Vector2(0, 250)
	var pun: Planet = rig6_sim.add_planet(s.id, "U")
	rig6_sim.inject_colony(rig6.e.id, pun.id, 90.0, false)  # not established
	check(is_equal_approx(
		rig6_sim.neighbor_growth_multiplier(rig6.subject), 1.0),
		"an unestablished same-empire center gives no bonus")

	# End to end: clustered colony out-grows an isolated identical one.
	var iso := _neighbor_rig()
	var clu := _neighbor_rig()
	_add_established(clu.sim, clu.e, Vector2(250, 0), 300.0)
	run_days(iso.sim, 100.0)
	run_days(clu.sim, 100.0)
	check(clu.subject.population > iso.subject.population,
		"over time, a clustered colony grows past an isolated one")


func _test_mining() -> void:
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	check(not sim.can_build_mine(e.id, sc.plain_p.id),
		"mine requires a deposit")
	var raw_before: float = e.raw
	check(sim.build_mine(e.id, sc.deposit_p.id),
		"mine builds on reachable deposit")
	check(e.raw == raw_before - SimConstants.MINE_COST,
		"mine deducts its cost")
	check(not sim.can_build_mine(e.id, sc.deposit_p.id),
		"no second mine on the same planet")


func _test_mine_income_routing() -> void:
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	var other := sim.add_empire("Bystander", Color.GRAY)
	# Direct-set the mine (income test, not a gating test) and remove the
	# anchor's production noise by zeroing its pop... instead park anchor:
	sc.anchor.population = 0.0
	sim.planets[sc.deposit_p.id].mine_empire_id = e.id
	var e_before: float = e.raw
	var other_before: float = other.raw
	run_days(sim, 10.0)
	check(is_equal_approx(e.raw,
		e_before + SimConstants.MINE_RAW_PER_DAY * 10.0),
		"mine income rate is exact and credits the owner")
	check(other.raw == other_before,
		"other empires get nothing from a rival's mine")


func _test_production_input() -> void:
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	sc.anchor.population = 200.0  # the established anchor IS the factory
	# Starved factory: capacity exists but no input, so no output.
	e.raw = 0.0
	run_days(sim, 5.0)
	check(e.goods == 0.0, "production without raw input yields nothing")
	# Limited input: exactly raw/ratio goods come out, then it dries up.
	e.raw = 10.0
	run_days(sim, 50.0)
	check(is_equal_approx(e.goods, 10.0 / SimConstants.GOODS_RAW_PER_GOOD),
		"limited raw converts at exactly the input ratio")
	check(e.raw == 0.0, "production consumed the whole stockpile")
	# Unthrottled: conservation holds — raw consumed == goods gained x ratio.
	e.raw = 1000000.0
	var raw_0: float = e.raw
	var goods_0: float = e.goods
	run_days(sim, 20.0)
	check(is_equal_approx(raw_0 - e.raw,
		(e.goods - goods_0) * SimConstants.GOODS_RAW_PER_GOOD),
		"raw consumed matches goods produced times the ratio")


func _test_drain_and_growth() -> void:
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	sc.anchor.population = 0.0  # silence the anchor; subject colony only
	var c := sim.inject_colony(e.id, sc.plain_p.id, SimConstants.START_POP, false)
	var raw_before: float = e.raw
	run_days(sim, 10.0)
	check(e.raw < raw_before, "unestablished colony drains the stockpile")
	check(is_equal_approx(raw_before - e.raw,
		SimConstants.COLONY_UPKEEP_BASE * 10.0),
		"drain rate matches upkeep constant")
	check(c.population > SimConstants.START_POP, "supplied colony grows")
	check(e.goods == 0.0, "unestablished colony produces nothing")


func _test_activation_taper_production() -> void:
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	sc.anchor.population = 0.0
	e.raw = 100000.0
	var c := sim.inject_colony(e.id, sc.plain_p.id, SimConstants.START_POP, false)
	run_days(sim, 500.0)
	check(c.established, "colony crosses activation threshold and establishes")
	check(c.population >= SimConstants.ACTIVATION_POP,
		"established implies pop >= threshold")
	check(e.goods > 0.0, "established colony produced tier-1 output")
	check(c.upkeep_per_day() < SimConstants.COLONY_UPKEEP_BASE * 0.01,
		"upkeep has tapered to near zero long after activation")
	# Taper is monotonic: upkeep right at activation must exceed later upkeep.
	var fresh := Colony.new()
	fresh.established = true
	fresh.days_since_established = 0.0
	check(is_equal_approx(fresh.upkeep_per_day(), SimConstants.COLONY_UPKEEP_BASE),
		"taper starts at the full base rate")
	fresh.days_since_established = SimConstants.UPKEEP_TAPER_DAYS
	check(fresh.upkeep_per_day() < SimConstants.COLONY_UPKEEP_BASE,
		"taper decreases over time")


func _test_diminishing_returns() -> void:
	# Relative growth (dpop/pop) must strictly fall as pop rises — flattening
	# without any hard cap (growth stays positive at any size).
	var rel_small: float = Colony.growth_per_day(100.0) / 100.0
	var rel_big: float = Colony.growth_per_day(1000.0) / 1000.0
	var rel_huge: float = Colony.growth_per_day(100000.0) / 100000.0
	check(rel_big < rel_small, "relative growth falls from 100 to 1000 pop")
	check(rel_huge < rel_big, "relative growth keeps falling at 100k pop")
	check(Colony.growth_per_day(100000.0) > 0.0,
		"no hard cap: growth still positive at 100k pop")


func _test_starvation() -> void:
	var sc := make_scenario()
	var sim: Sim = sc.sim
	var e: Empire = sc.e
	sc.anchor.population = 0.0
	var c := sim.inject_colony(e.id, sc.plain_p.id, SimConstants.START_POP, false)
	e.raw = 0.0
	run_days(sim, 20.0)
	check(c.population == SimConstants.START_POP,
		"unsupplied colony stalls instead of growing")
	check(e.raw == 0.0, "stockpile never goes negative")


func _test_determinism() -> void:
	var a := Sim.new_demo()
	var b := Sim.new_demo()
	for sim: Sim in [a, b]:
		var e_id: int = sim.empires.keys()[0]
		var home: StarSystem = sim.systems.values()[0]
		sim.build_mine(e_id, home.planet_ids[0])
		sim.found_colony(e_id, home.planet_ids[1])
		run_days(sim, 300.0)
	var same := a.day == b.day
	for i in a.colonies.size():
		if a.colonies[i].population != b.colonies[i].population:
			same = false
	for k in a.empires:
		if a.empires[k].raw != b.empires[k].raw \
				or a.empires[k].goods != b.empires[k].goods:
			same = false
	check(same, "identical runs produce bit-identical state")
