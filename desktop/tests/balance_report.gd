extends SceneTree

# Balance instrumentation (not a pass/fail unit test — a tuning instrument).
#
# Runs the full sim across several seeds and measures the two design pillars from
# vision.md, so the "tune until it feels right" constants (diminishing-returns
# exponent, neighbour-bonus falloff, attrition %, grace period, power ceiling...) can
# be adjusted against hard numbers instead of vibes:
#
#   PILLAR 1 — growth is uncapped but self-limiting. Population should climb a long way
#     and then PLATEAU as colonies saturate the map geometry and diminishing returns
#     bite — never hit a flat designed ceiling early, never run away forever.
#   PILLAR 2 — combat never snowballs. No empire should sweep the whole map (reach 100%
#     of colonies), and no single sample interval should flip a large fraction of the
#     map (that would be a "decisive fight" winning the war).
#
# Tweak the knobs below, run:
#   godot --headless --path . -s tests/balance_report.gd
# and read the per-seed table + the pillar verdict at the bottom.

const SEEDS: Array = [20260702, 1, 7, 42]
const HORIZON_DAYS: float = 1500.0
const SAMPLE_DAYS: float = 25.0
# A single sample interval flipping more than this fraction of the map = a "decisive
# fight" red flag (one battle deciding the war).
const DECISIVE_FRAC: float = 0.45
# Population at the end should stay within this band of its peak to count as a healthy
# plateau (rather than a collapse or a still-runaway curve).
const PLATEAU_BAND: float = 0.80


func _init() -> void:
	print("=== Reach balance report ===")
	print("seeds=", SEEDS, "  horizon=", HORIZON_DAYS, "d  sample=", SAMPLE_DAYS, "d\n")
	print("seed      | start_pop  peak_pop  end_pop  plateau | peak_share%  end_empires | max_swing")
	var any_snowball := false
	var any_decisive := false
	var any_runaway := false
	var peak_share_all := 0.0
	for seed in SEEDS:
		var r := _run_one(seed)
		var plateau: bool = r.end_pop >= PLATEAU_BAND * r.peak_pop and r.peak_pop > 3.0 * r.start_pop
		var snowball: bool = r.peak_share >= 99.9                 # total map domination
		var decisive: bool = r.max_swing_frac > DECISIVE_FRAC
		any_snowball = any_snowball or snowball
		any_decisive = any_decisive or decisive
		any_runaway = any_runaway or not plateau
		peak_share_all = maxf(peak_share_all, r.peak_share)
		print("%-9d | %9.0f %9.0f %8.0f  %-7s | %9.0f%%  %11d | %d cols (%.0f%% of map)%s%s" % [
			seed, r.start_pop, r.peak_pop, r.end_pop, ("yes" if plateau else "NO"),
			r.peak_share, r.end_empires, r.max_swing_cols, 100.0 * r.max_swing_frac,
			("  <-- SNOWBALL" if snowball else ""),
			("  <-- DECISIVE" if decisive else "")])
	print("\n--- pillar verdict ---")
	print("P1 growth self-limits : ", ("OK — every seed grew >3x and plateaued"
		if not any_runaway else "WARN — a seed never plateaued (cap too hard, or runaway)"))
	print("P2 no total snowball  : ", ("OK — no empire ever took the whole map (peak share %.0f%%)" % peak_share_all
		if not any_snowball else "WARN — an empire reached ~100%% of the map"))
	print("   no decisive fight  : ", ("OK — no interval flipped >%.0f%% of the map" % (100.0 * DECISIVE_FRAC)
		if not any_decisive else "WARN — a single interval flipped >%.0f%% of the map" % (100.0 * DECISIVE_FRAC)))
	quit()


func _run_one(seed: int) -> Dictionary:
	var sim := Sim.generate_map({"seed": seed})
	var eids: Array = sim.empires.keys()
	var start_pop := _total_pop(sim)
	var peak_pop := start_pop
	var end_pop := start_pop
	var peak_share := _max_share(sim)
	var max_swing_cols := 0
	var max_swing_frac := 0.0
	var prev_cols := _colony_counts(sim, eids)
	var ticks := int(HORIZON_DAYS / SimConstants.TICK_DAYS)
	var sample_every := int(SAMPLE_DAYS / SimConstants.TICK_DAYS)
	for step in ticks:
		sim.tick(SimConstants.TICK_DAYS)
		if step % sample_every != 0:
			continue
		var pop := _total_pop(sim)
		peak_pop = maxf(peak_pop, pop)
		end_pop = pop
		peak_share = maxf(peak_share, _max_share(sim))
		var cols := _colony_counts(sim, eids)
		var total := 0
		for e in eids:
			total += cols[e]
		# Biggest single-empire colony change since the last sample, as a share of the
		# current map — catches a war decided in one swing.
		for e in eids:
			var d: int = absi(cols[e] - prev_cols[e])
			if d > max_swing_cols:
				max_swing_cols = d
			if total > 0:
				max_swing_frac = maxf(max_swing_frac, float(d) / float(total))
		prev_cols = cols
	return {
		"start_pop": start_pop, "peak_pop": peak_pop, "end_pop": end_pop,
		"peak_share": peak_share, "max_swing_cols": max_swing_cols,
		"max_swing_frac": max_swing_frac, "end_empires": _live_empires(sim, eids),
	}


func _total_pop(sim: Sim) -> float:
	var p := 0.0
	for c in sim.colonies:
		p += c.population
	return p


func _colony_counts(sim: Sim, eids: Array) -> Dictionary:
	var cols := {}
	for e in eids:
		cols[e] = 0
	for c in sim.colonies:
		cols[c.empire_id] = cols.get(c.empire_id, 0) + 1
	return cols


func _max_share(sim: Sim) -> float:
	var eids: Array = sim.empires.keys()
	var cols := _colony_counts(sim, eids)
	var total := 0
	var most := 0
	for e in eids:
		total += cols[e]
		most = maxi(most, cols[e])
	return 100.0 * most / total if total > 0 else 0.0


func _live_empires(sim: Sim, eids: Array) -> int:
	var cols := _colony_counts(sim, eids)
	var n := 0
	for e in eids:
		if cols[e] > 0:
			n += 1
	return n
