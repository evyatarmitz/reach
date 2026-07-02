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
	_test_founding()
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
