extends SceneTree

# Headless balance probe — NOT a pass/fail test. Runs a full all-AI game (the
# player slot is driven by the same AI so nobody sits idle) and prints how the two
# design pillars actually behave over a long game:
#   Pillar 1 — uncapped BUT self-limiting population growth (should plateau by
#              throughput/geometry, not explode, not hard-cap).
#   Pillar 2 — no steamroll (no single empire should own the whole map quickly).
# Plus economy health (do T0 stockpiles balloon? do cities ever refine enough?).
#
# Run: godot --headless --path desktop --script res://tests/balance_report.gd
# Optional: pass "seed=NNN systems=NN empires=N days=NNNN" via -- args.

func _cfg_from_args() -> Dictionary:
	var cfg := {"seed": 20260702, "system_count": 50, "empire_count": 4,
		"ai_efficiency": 1.0}
	var days := 3000.0
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"seed": cfg.seed = int(kv[1])
			"systems": cfg.system_count = int(kv[1])
			"empires": cfg.empire_count = int(kv[1])
			"days": days = float(kv[1])
	cfg["_days"] = days
	return cfg


func _totals(sim: Sim) -> Dictionary:
	# Per empire: pop, colonies, systems owned, T0/T1 stockpiles, mil, fleet hull.
	var out := {}
	for e in sim.empires.values():
		out[e.id] = {"pop": 0.0, "col": 0, "sys": 0,
			"water": e.water, "minerals": e.minerals, "food": e.food,
			"alloys": e.alloys, "mil": 0.0, "hull": 0.0, "ships": 0}
		for v in e.nat:
			out[e.id]["mil"] += v
	for c in sim.colonies:
		if out.has(c.empire_id):
			out[c.empire_id]["pop"] += c.population
			out[c.empire_id]["col"] += 1
	for sys in sim.systems.values():
		var o := sim.system_owner(sys.id)
		if out.has(o):
			out[o]["sys"] += 1
	for f in sim.fleets:
		if out.has(f.empire_id):
			out[f.empire_id]["hull"] += f.hull()
			out[f.empire_id]["ships"] += f.ship_count()
	return out


func _fmt_row(day: float, t: Dictionary, ids: Array) -> String:
	var s := "day %5d | " % int(day)
	for id in ids:
		var r: Dictionary = t[id]
		s += "E%d pop%6d col%2d sys%2d  " % [id, int(r.pop), r.col, r.sys]
	return s


func _init() -> void:
	var cfg := _cfg_from_args()
	var days: float = cfg["_days"]
	cfg.erase("_days")
	var sim := Sim.generate_map(cfg)
	var ids: Array = sim.empires.keys()
	ids.sort()
	# Drive the player slot (the one empire without an AI) so all empires play.
	var with_ai := {}
	for ai in sim.ais:
		with_ai[ai.empire_id] = true
	for id in ids:
		if not with_ai.has(id):
			sim.add_ai(id)

	print("=== BALANCE REPORT ===")
	print("seed=%d systems=%d empires=%d days=%d  (map has %d systems)" %
		[cfg.seed, cfg.system_count, cfg.empire_count, int(days), sim.systems.size()])
	print("")

	var step := SimConstants.TICK_DAYS
	var total_ticks := int(round(days / step))
	var sample_every := int(round(300.0 / step))   # sample every 300 days

	var peak_pop := {}
	var peak_water := {}
	var peak_total_pop := 0.0
	var history: Array = []   # [day, totals]
	for id in ids:
		peak_pop[id] = 0.0
		peak_water[id] = 0.0

	for tick_i in total_ticks + 1:
		if tick_i % sample_every == 0:
			var t := _totals(sim)
			history.append([sim.day, t])
			print(_fmt_row(sim.day, t, ids))
			var tp := 0.0
			for id in ids:
				peak_pop[id] = maxf(peak_pop[id], t[id].pop)
				peak_water[id] = maxf(peak_water[id], t[id].water + t[id].minerals)
				tp += t[id].pop
			peak_total_pop = maxf(peak_total_pop, tp)
		if tick_i < total_ticks:
			sim.tick(step)

	print("")
	print("=== SUMMARY ===")
	# Pillar 1: growth self-limits. Compare final total pop to peak — a healthy
	# plateau sits near its peak (didn't crash) and the peak is finite/not runaway.
	var last: Dictionary = history[history.size() - 1][1]
	var final_total := 0.0
	for id in ids:
		final_total += last[id].pop
	print("Pillar 1 (growth): peak total pop = %d, final = %d (%.0f%% of peak)"
		% [int(peak_total_pop), int(final_total),
			100.0 * final_total / maxf(peak_total_pop, 1.0)])
	var biggest_col_pop := 0.0
	for c in sim.colonies:
		biggest_col_pop = maxf(biggest_col_pop, c.population)
	print("  largest single colony pop = %d (watch for runaway lone cities)"
		% int(biggest_col_pop))

	# Pillar 2: no steamroll. Report final system share + when/if anyone hit >=75%.
	var total_sys := sim.systems.size()
	var shares: Array = []
	for id in ids:
		shares.append(100.0 * last[id].sys / maxf(total_sys, 1))
	shares.sort()
	shares.reverse()
	var share_str := ""
	for s in shares:
		share_str += "%.0f%% " % s
	print("Pillar 2 (no steamroll): final system share (high→low) = %s" % share_str)
	var steamroll_day := -1.0
	for h in history:
		for id in ids:
			if h[1][id].sys >= 0.75 * total_sys:
				steamroll_day = h[0]
				break
		if steamroll_day >= 0.0:
			break
	if steamroll_day >= 0.0:
		print("  WARNING: an empire reached >=75%% of the map by day %d (possible steamroll)"
			% int(steamroll_day))
	else:
		print("  OK: no empire exceeded 75%% of the map during the run")

	# Economy: T0 balloon check (raw water+minerals dwarfing what cities refine).
	var worst_t0 := 0.0
	for id in ids:
		worst_t0 = maxf(worst_t0, last[id].water + last[id].minerals)
	print("Economy: largest final raw T0 stockpile (water+minerals) = %d" % int(worst_t0))
	print("  (if this is enormous vs pop, mines out-produce refining — a known knob)")
	var total_ships := 0
	for id in ids:
		total_ships += last[id].ships
	print("Combat: total ships alive at end = %d, colonies remaining = %d"
		% [total_ships, sim.colonies.size()])
	# Military tiers: max stockpile per tier across empires — confirms whether the
	# higher ship tiers are actually reachable (were dead content when 0).
	var maxnat := [0.0, 0.0, 0.0, 0.0, 0.0]
	for e in sim.empires.values():
		for t in 5:
			maxnat[t] = maxf(maxnat[t], e.nat[t])
	print("Military: max per-tier stockpile T1-5 = %d·%d·%d·%d·%d (0 = tier unreachable)"
		% [int(maxnat[0]), int(maxnat[1]), int(maxnat[2]), int(maxnat[3]), int(maxnat[4])])
	quit()
