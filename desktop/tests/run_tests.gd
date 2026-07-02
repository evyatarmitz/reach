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


func first_planet_id(sim: Sim) -> int:
	return sim.systems.values()[0].planet_ids[0]


func _init() -> void:
	_test_topology()
	_test_founding()
	_test_mining()
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
	var d := sim.system_distance(sim.systems.keys()[0], sim.systems.keys()[1])
	check(d > 0.0, "distinct systems have positive distance")


func _test_founding() -> void:
	var sim := Sim.new_demo()
	var pid := first_planet_id(sim)
	var raw_before := sim.raw
	check(sim.found_colony(pid), "founding succeeds on empty planet with funds")
	check(sim.raw == raw_before - SimConstants.FOUND_COST,
		"founding deducts exactly the flat cost")
	check(not sim.found_colony(pid), "founding fails on already-colonized planet")
	var sim2 := Sim.new_demo()
	sim2.raw = SimConstants.FOUND_COST - 1.0
	check(not sim2.found_colony(first_planet_id(sim2)),
		"founding fails when stockpile is short")
	check(sim2.raw == SimConstants.FOUND_COST - 1.0,
		"failed founding costs nothing")


func _test_mining() -> void:
	var sim := Sim.new_demo()
	var pid := first_planet_id(sim)  # Meridian I has a deposit in the demo
	check(not sim.can_build_mine(pid),
		"mine requires a colony in the system (reach)")
	sim.found_colony(pid)
	var no_deposit_pid: int = sim.systems.values()[0].planet_ids[1]
	check(not sim.can_build_mine(no_deposit_pid),
		"mine requires a deposit")
	var raw_before := sim.raw
	check(sim.build_mine(pid), "mine builds on reachable deposit")
	check(sim.raw == raw_before - SimConstants.MINE_COST,
		"mine deducts its cost")
	check(not sim.can_build_mine(pid), "no second mine on the same planet")
	raw_before = sim.raw
	run_days(sim, 10.0)
	# Only flows: mine income, colony upkeep (unestablished → no production).
	check(is_equal_approx(sim.raw, raw_before
		+ (SimConstants.MINE_RAW_PER_DAY - SimConstants.COLONY_UPKEEP_BASE) * 10.0),
		"mine income rate is exact")


func _test_production_input() -> void:
	var sim := Sim.new_demo()
	sim.found_colony(first_planet_id(sim))
	var c: Colony = sim.colonies[0]
	c.established = true
	c.population = 200.0
	c.days_since_established = 100000.0  # upkeep fully tapered → only production
	# Starved factory: capacity exists but no input, so no output.
	sim.raw = 0.0
	run_days(sim, 5.0)
	check(sim.goods == 0.0, "production without raw input yields nothing")
	# Limited input: exactly raw/ratio goods come out, then it dries up.
	sim.raw = 10.0
	run_days(sim, 50.0)
	check(is_equal_approx(sim.goods, 10.0 / SimConstants.GOODS_RAW_PER_GOOD),
		"limited raw converts at exactly the input ratio")
	check(sim.raw == 0.0, "production consumed the whole stockpile")
	# Unthrottled: conservation holds — raw consumed == goods gained × ratio.
	sim.raw = 1000000.0
	var raw_0 := sim.raw
	var goods_0 := sim.goods
	run_days(sim, 20.0)
	check(is_equal_approx(raw_0 - sim.raw,
		(sim.goods - goods_0) * SimConstants.GOODS_RAW_PER_GOOD),
		"raw consumed matches goods produced times the ratio")


func _test_drain_and_growth() -> void:
	var sim := Sim.new_demo()
	sim.found_colony(first_planet_id(sim))
	var raw_after_found := sim.raw
	var pop_before: float = sim.colonies[0].population
	run_days(sim, 10.0)
	check(sim.raw < raw_after_found, "unestablished colony drains the stockpile")
	check(is_equal_approx(raw_after_found - sim.raw,
		SimConstants.COLONY_UPKEEP_BASE * 10.0),
		"drain rate matches upkeep constant")
	check(sim.colonies[0].population > pop_before, "supplied colony grows")
	check(sim.goods == 0.0, "unestablished colony produces nothing")


func _test_activation_taper_production() -> void:
	var sim := Sim.new_demo()
	sim.raw = 100000.0  # never starve; this test is about the lifecycle
	sim.found_colony(first_planet_id(sim))
	var c: Colony = sim.colonies[0]
	run_days(sim, 500.0)
	check(c.established, "colony crosses activation threshold and establishes")
	check(c.population >= SimConstants.ACTIVATION_POP,
		"established implies pop >= threshold")
	check(sim.goods > 0.0, "established colony produced tier-1 output")
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
	var sim := Sim.new_demo()
	sim.found_colony(first_planet_id(sim))
	sim.raw = 0.0
	var pop_before: float = sim.colonies[0].population
	run_days(sim, 20.0)
	check(sim.colonies[0].population == pop_before,
		"unsupplied colony stalls instead of growing")
	check(sim.raw == 0.0, "stockpile never goes negative")


func _test_determinism() -> void:
	var a := Sim.new_demo()
	var b := Sim.new_demo()
	for sim in [a, b]:
		sim.found_colony(first_planet_id(sim))
		run_days(sim, 300.0)
	check(a.raw == b.raw and a.goods == b.goods \
		and a.colonies[0].population == b.colonies[0].population,
		"identical runs produce bit-identical state")
