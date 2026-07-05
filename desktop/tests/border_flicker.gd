extends SceneTree

# Robo-mode reproduction for "rival border phases in and out despite being inside VR."
# Both empires are AI-driven so they expand and their borders meet. Each cycle we tick,
# rebuild the field snapshot, scan the map for RIVAL-owned points sitting on a border,
# and for each one compare the two draw-gate rules at that contour point:
#   - NEW rule: VR tested AT the contour midpoint (what the fix uses).
#   - OLD rule: VR tested 12px INTO the owning (rival) side (the buggy pre-fix probe).
# "in VR but OLD-rule dropped" > 0 means the old rule hid border lines that are plainly
# inside VR; that count changing cycle-to-cycle is the flicker. The fix draws them all.

func _init() -> void:
	Session.config = {"system_count": 60, "empire_count": 2, "ai_efficiency": 1.0,
		"seed": 7}
	Session.load_path = ""
	var main: Node = load("res://game/main.tscn").instantiate()
	get_root().add_child(main)
	for i in 5:
		await process_frame
	main.sim.add_ai(main.player_empire_id)   # robo: player also plays, so borders meet

	var step := 22.0
	for cycle in 10:
		for i in 300:
			main.sim.tick(SimConstants.TICK_DAYS)
		var job: Dictionary = main._prep_field()
		var ids: Array = job.ids
		var pos: Array = job.pos
		var infl: Array = job.infl
		var reach: Array = job.reach
		var reach_vr: Array = job.reach_vr
		var pk: int = job.pk
		if pk == -1:
			print("cycle %d: player has no sources yet" % cycle)
			continue
		var lo: Vector2 = main._map_lo - Vector2(140, 140)
		var hi: Vector2 = main._map_hi + Vector2(140, 140)
		var in_vr := 0        # rival-border contour points inside the player's VR
		var old_dropped := 0  # of those, how many the OLD 12px-probe rule would hide
		var x := lo.x
		while x < hi.x:
			var y := lo.y
			while y < hi.y:
				var p := Vector2(x, y)
				var owner: int = main._owner_at(p, ids, pos, infl, reach)
				if owner != -1 and owner != main.player_empire_id:
					for d in [Vector2(step, 0), Vector2(-step, 0),
							Vector2(0, step), Vector2(0, -step)]:
						if main._owner_at(p + d, ids, pos, infl, reach) == owner:
							continue
						var mid: Vector2 = p + d * 0.5           # ~contour point
						var into_rival: Vector2 = (-d).normalized()
						if main._vr_at(mid, ids, pos, infl, reach, reach_vr, pk) > 0.0:
							in_vr += 1
							var probe: Vector2 = mid + into_rival * 12.0
							if main._vr_at(probe, ids, pos, infl, reach, reach_vr, pk) <= 0.0:
								old_dropped += 1
						break   # count each border cell once
				y += step
			x += step
		print("cycle %d: rival-border pts in VR=%d, OLD-probe rule would hide=%d"
			% [cycle, in_vr, old_dropped])
	print("BORDER FLICKER PROBE DONE")
	quit()
