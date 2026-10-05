extends SceneTree

# Regression test for the siege-alert pile-up: sim.combat_kind is rebuilt every tick,
# so a sustained bombardment used to re-log an event and re-push a jump alert on every
# ~15Hz scan -> hundreds of identical "under siege" alerts, counter rising live.
# _scan_events now fires only on the combat START edge and keeps ONE live alert per
# active siege, cleared when the fight ends. This drives _scan_events directly over
# many scans and checks the alert count stays sane.

func _init() -> void:
	Session.config = {"system_count": 120, "empire_count": 4, "ai_efficiency": 1.0, "seed": 42}
	Session.load_path = ""
	var main: Node = load("res://game/main.tscn").instantiate()
	get_root().add_child(main)
	for i in 5:
		await process_frame
	for i in 2000:
		main.sim.tick(SimConstants.TICK_DAYS)
	main._fog_disabled = true   # make _sys_live true everywhere

	var sid := -1
	for s in main.sim.systems:
		if main._system_has_player_colony(s):
			sid = s
			break
	assert(sid != -1, "no player colony to besiege")
	var bsid := -1
	for s in main.sim.systems:
		if not main._system_has_player_colony(s):
			bsid = s
			break
	assert(bsid != -1, "no non-player system for the battle case")

	# Seed the prev-dicts (avoids a false "colony lost" on the first manual scan), then
	# clear to a known baseline.
	main._scan_events()
	main._alerts.clear(); main._combat_prev = {}; main._events.clear(); main._alert_idx = 0

	# Phase A: our colony under bombardment for 200 consecutive scans.
	for i in 200:
		main.sim.combat_kind = {sid: 1}
		main._scan_events()
	var live := 0
	for a in main._alerts:
		if a.get("live", false):
			live += 1
	assert(main._alerts.size() == 1, "sustained siege: expected 1 alert, got %d" % main._alerts.size())
	assert(live == 1 and main._alerts[0]["sid"] == sid, "the single alert should be the live siege")
	print("SUSTAINED SIEGE (200 scans) -> %d alert (expected 1)" % main._alerts.size())

	# Phase B: siege ends -> the live alert is dropped.
	main.sim.combat_kind = {}
	main._scan_events()
	assert(main._alerts.size() == 0, "siege ended: %d alert(s) left behind" % main._alerts.size())
	print("SIEGE ENDED -> %d alerts (expected 0)" % main._alerts.size())

	# Phase C: a fresh siege re-announces exactly one.
	for i in 50:
		main.sim.combat_kind = {sid: 1}
		main._scan_events()
	assert(main._alerts.size() == 1, "re-siege: expected 1 alert, got %d" % main._alerts.size())
	print("RE-SIEGE (50 scans) -> %d alert (expected 1)" % main._alerts.size())

	# Phase D: a battle at a system with NO player colony -> no jump alert (feed only).
	main._alerts.clear(); main._combat_prev = {}
	for i in 30:
		main.sim.combat_kind = {bsid: 0}
		main._scan_events()
	assert(main._alerts.size() == 0, "battle at non-player system made %d alert(s)" % main._alerts.size())
	print("NON-PLAYER BATTLE (30 scans) -> %d alerts (expected 0)" % main._alerts.size())

	print("ALERT DEDUPE OK")
	quit()
