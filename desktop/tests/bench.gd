extends SceneTree

# Headless sim benchmark: build a full demo map, run it a while so it fills out
# (colonies, fleets, mines), then time a batch of ticks. Isolates SIM cost from
# rendering. Run: godot --headless --path desktop --script res://tests/bench.gd

func _init() -> void:
	var sim := Sim.new_demo()
	# Warm the map up so counts are realistic (fleets built, borders spread).
	for i in 2000:
		sim.tick(SimConstants.TICK_DAYS)
	print("--- after warmup ---")
	print("systems=%d planets=%d colonies=%d fleets=%d empires=%d anomalies=%d builders=%d" % [
		sim.systems.size(), sim.planets.size(), sim.colonies.size(),
		sim.fleets.size(), sim.empires.size(), sim.anomalies.size(), sim.builders.size()])

	var N := 1000
	var t0 := Time.get_ticks_usec()
	for i in N:
		sim.tick(SimConstants.TICK_DAYS)
	var us := Time.get_ticks_usec() - t0
	print("TICK: %d ticks in %.1f ms  =>  %.3f ms/tick" % [N, us / 1000.0, us / 1000.0 / N])

	# Isolate the per-tick owner-cache rebuild (system_owner over all systems).
	var reps := 200
	t0 = Time.get_ticks_usec()
	for i in reps:
		sim._invalidate_influence_caches()
		for s in sim.systems.values():
			sim.owner_cached(s.id)   # first call forces the full rebuild
	us = Time.get_ticks_usec() - t0
	print("owner_cache REBUILD x %d: %.3f ms/rebuild" % [reps, us / 1000.0 / reps])

	# Isolate anomaly-blocking cost across all system pairs (what the rebuild hammers).
	var syslist := sim.systems.values()
	reps = 20
	t0 = Time.get_ticks_usec()
	for i in reps:
		for a in syslist:
			for b in syslist:
				sim.influence_blocked(a.map_pos, b.map_pos)
	us = Time.get_ticks_usec() - t0
	print("influence_blocked x all pairs (%d^2) x %d: %.3f ms/pass" % [
		syslist.size(), reps, us / 1000.0 / reps])

	# Time a few of the queries the renderer/UI hammer every frame.
	reps = 2000
	t0 = Time.get_ticks_usec()
	for i in reps:
		for s in sim.systems.values():
			sim.owner_cached(s.id)
	us = Time.get_ticks_usec() - t0
	print("owner_cached x all systems x %d: %.3f ms/pass" % [reps, us / 1000.0 / reps])

	t0 = Time.get_ticks_usec()
	for i in reps:
		for f in sim.fleets:
			sim.fleet_position(f)
	us = Time.get_ticks_usec() - t0
	print("fleet_position x all fleets x %d: %.3f ms/pass" % [reps, us / 1000.0 / reps])

	quit()
