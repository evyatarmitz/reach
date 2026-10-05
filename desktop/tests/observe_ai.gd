extends SceneTree

# Scratch observation (not a pass/fail test): run the demo map a long time and print
# how colonies are distributed across empires over time. Eyeballing for the two pillars:
# no single empire should swallow the whole map (un-snowballable combat), and the
# population total should keep climbing (uncapped-but-self-limiting growth).

func _init() -> void:
	var sim := Sim.new_demo()
	var eids: Array = sim.empires.keys()
	eids.sort()
	print("day | ", " ".join(eids.map(func(e): return "E%d" % e)), " | total_pop  total_ships  max_share%")
	for step in 30000:   # 3000 days
		sim.tick(SimConstants.TICK_DAYS)
		if step % 2500 != 0:
			continue
		var cols := {}
		var pop := 0.0
		for e in eids:
			cols[e] = 0
		for c in sim.colonies:
			cols[c.empire_id] = cols.get(c.empire_id, 0) + 1
			pop += c.population
		var ships := 0
		for f in sim.fleets:
			ships += f.ship_count()
		var total_cols := 0
		var most := 0
		for e in eids:
			total_cols += cols[e]
			most = maxi(most, cols[e])
		var share := 0.0
		if total_cols > 0:
			share = 100.0 * most / total_cols
		var row := "%4d | " % int(sim.day)
		for e in eids:
			row += "%3d " % cols[e]
		row += "| %9.0f  %6d  %6.0f%%" % [pop, ships, share]
		print(row)
	quit()
