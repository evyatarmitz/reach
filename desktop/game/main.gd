extends Node2D

# Render/UI layer. Reads Sim state, forwards commands. No game rules live here.

const SPEEDS: Array[float] = [0.0, 1.0, 3.0, 10.0]
# Base clock slowed (1.0 -> 0.5 -> 0.4) so the whole sim reads slower in real
# time; the speed dial multiplies this, so fast-forward is still one click away.
const DAYS_PER_REAL_SECOND := 0.4
# Ceiling on sim ticks executed in one frame (see _process). Steady-state 10× needs
# <1/frame; this only bites when a frame hitches, keeping input responsive.
const MAX_TICKS_PER_FRAME := 8
# WASD / arrow-key map pan, in screen pixels per second (÷ zoom so it feels the same at
# every zoom level). Held-key panning runs in _process for smoothness.
const PAN_SPEED := 780.0

var sim: Sim
var player_empire_id := -1
var speed_idx := 1
var day_accum := 0.0
var selected_planet_id := -1
var selected_fleet_id := -1
var view_system_id := -1  # -1 = galaxy view, otherwise the focused system

const ZOOM_MIN := 0.35
const ZOOM_MAX := 2.5

# Border field: sampled on a world grid, refreshed on a timer (borders drift
# slowly, so per-frame recompute is wasted work). Each entry is [center, color]
# for a frontier cell — drawn as a dot at the cell's own centre so each empire's
# edge sits inside its territory and hostile seams show BOTH colours.
const BORDER_CELL := 26.0   # coarser (was 18) to cut the border-recompute cost — the
                            # 0.5s rebake was a synchronous main-thread spike that
                            # stuttered camera pans. Contour is drawn as a smooth curve
                            # so a coarser grid barely changes how the border looks.
const FIELD_MAX_CELLS := 130.0  # cap fog/border grid cells per axis. Bumped 100→130 for
                                # a sharper fog/border edge now that the bake runs on a
                                # worker thread (cost is ~cells² but off the main frame).
const BORDER_REFRESH := 0.6
const UI_REFRESH := 0.066   # HUD/panel refresh cadence (~15 Hz), decoupled from FPS
const LABEL_ZOOM := 0.85     # only draw per-system name/count labels at/above this
                             # zoom — when zoomed out they overlap into unreadable
                             # mush AND draw_string dominates frame cost.
const BORDER_EPS := 0.01     # tiny rival-claim floor so bubble-vs-empty edges draw
const FOG_CELL := 22.0       # sample cell for the fog texture (linearly filtered). Finer
                             # again (30→22) for a crisper lit edge; bake is off-thread.
# VR fill. The fog must reach PAST the border (the border is your influence edge;
# the fog is your SIGHT, which sees further). VR_SIGHT_REACH is how far sight
# extends beyond influence reach — the player's fog claim is sampled with reach
# scaled by this, so the field exists (and feathers) past the border instead of
# hard-cutting at it. VR_CLAIM_FLOOR is the open-space fade threshold, tuned so the
# feather completes around the extended sight edge (no hard disc). VR_BAND is the
# feather width in claim-ratio units. Fog stays soft/organic; border sits inside it.
const VR_SIGHT_REACH := 1.8   # was 1.5; ~20% more sight reach so VR shows more ground
                              # past the border (open space beyond your bubble edge).
# Claim threshold that both (a) separates a real contested border from open space —
# a rival claim above this means "contested", so VR stops at the border — and (b)
# sets how far open-space VR reaches (out to where the player's sight-claim drops to
# this). Low, so any real neighbour counts as contested and open sight reaches well
# out for early warning.
const VR_CLAIM_FLOOR := 0.4
const VR_BAND := 0.6
# Contested VR: fog is full across owned ground and feathers to 0 across this band
# just past the border, so the border sits on the lit edge (not outside it). Wider
# band (was 0.18) = VR bleeds further into a rival's side before fading — ~20% more
# visible ground past a contested border, matching the open-space sight bump.
const VR_BORDER_FEATHER := 0.30
const SAVE_PATH := "user://reach_save.json"
const FLEET_ICON_OFF := Vector2(0, -17)   # drawn above the system so it stays clickable
const FLEET_CLICK_R := 24.0   # screen-space click radius for fleets (÷ zoom in _select_at)
const BORDER_INSET := 3.5    # push each empire's border curve into its own territory
const COMBAT_FLASH_DAYS := 5.0   # how long a clash starburst lingers on the map

var cam: Camera2D
var _panning := false
var _galaxy_cam_pos := Vector2.ZERO   # persisted galaxy pan/zoom across view switches
var _galaxy_cam_zoom := 1.0
var _map_lo := Vector2.ZERO
var _map_hi := Vector2.ZERO
var _border_segments: Array = []   # [a, b, color] line segments
var _border_timer := 0.0
var _ui_timer := 0.0
var _rebake_thread: Thread = null   # worker baking the fog/border grids off-thread
var _rebake_result: Dictionary = {}
var _system_owner := {}     # system_id -> empire_id, cached with the border field
var _system_vr := {}        # system_id -> 0 none / 1 partial / 2 full VR
var _explored := {}         # system_id -> true, ever seen (gray once out of VR)
var _stale := {}            # system_id -> {owner, colonies}, last-seen snapshot
var _hover_system := -1     # known system currently under the cursor (symbols shown)
var _hover_hold := false    # autoshot: freeze the hovered system for the screenshot
var _fog_tex: ImageTexture  # baked fog: feathered lit / grey memory / transparent
var _fog_rect := Rect2()    # world-space rect the fog texture covers
var _fog_seen := {}         # "gx,gy" -> true, cells ever in VR (explored memory)
var _starfield: Array = []  # backdrop: [pos, radius, Color] faint stars (static)
var _has_anomalies := false # cached each refresh so _claim_at skips anomaly tests

var raw_label: Label       # what you gather: water flow (net/day)
var goods_label: RichTextLabel   # minerals + alloy tiers 1-5: amount over income rate
var _tier_icons: Array = []      # [ImageTexture] tier 1-5 badge icons (index 0-4)
var day_label: Label
# Income-rate readout: one stockpile sample per in-game day; the displayed "+N/day" is
# the slope across the last RATE_WINDOW_DAYS. Alloy samples add spent_nat so buying a
# ship doesn't read as negative income (production only). Minerals aren't spent on
# purchases, so its stockpile slope is already clean.
const RATE_WINDOW_DAYS := 8.0
var _rate_hist: Array = []   # [{d:float, min:float, nat:PackedFloat32Array(5)}], oldest first
var _last_sample_day := -1
# Perpetual calendar (no leap years) for the D/M/Y date readout.
const _MONTH_DAYS := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
var standing_label: Label
var hint_label: Label
var top_bar: PanelContainer   # the top HUD bar; hint/event labels dock below its real height
var _tooltip_panel: PanelContainer   # Paradox-style hover popup (map nodes + HUD terms)
var _tooltip_label: RichTextLabel
var _ui_tips: Array = []              # [Control, bbcode] HUD elements with an explainer
var event_label: Label          # top-left feed of recent autonomous events
var _events: Array = []         # [day, text] recent events, newest last
var _prev_pcolonies: Dictionary = {}  # planet_id -> system_id, player's colonies
var _seen_combat: Dictionary = {}     # system_id -> last combat day already logged
var speed_buttons: Array[Button] = []
var panel: PanelContainer
var ship_panel: PanelContainer   # top-right shipyard; the selection panel docks below it
var panel_title: Label
var panel_body: Label
var colonize_btn: Button
var mine_btn: Button
var emigrate_btn: Button
var merge_btn: Button
var split_btn: Button
var spec_food_btn: Button
var spec_alloy_btn: Button
var upgrade_btn: Button
var depot_btn: Button
var obs_post_btn: Button
var transport_btn: Button
var ship_f_btns: Array = []   # fighter build buttons, tier 1-5
var ship_b_btns: Array = []   # bomber build buttons, tier 1-5
var menu_overlay: PanelContainer
var intro_overlay: PanelContainer
var legend_panel: PanelContainer
var controls_page: Control   # rebindable key-binding page (K, or the pause menu)
# The key map and the controls UI now live in menu/, shared with the main-menu Options
# page; Keybinds is the static source of truth for action -> keycode. Preloaded (not
# class_name) so they resolve even with a stale global class cache in a headless build.
const ControlsPageScript := preload("res://menu/controls_page.gd")
const Keybinds := preload("res://menu/keybinds.gd")
const UiStyle := preload("res://menu/ui_style.gd")
var overlay_title: Label
var overlay_resume: Button
var overlay_save: Button
var overlay_update_btn: Button
var overlay_update_apply: Button
var overlay_update_status: Label
const UpdaterScript := preload("res://game/updater.gd")
var _updater: Node
var _game_over := false
var _speed_before_menu := 1     # speed to restore when the pause menu closes
var planet_list: VBoxContainer
var _planet_rows: Array = []   # [Button, planet_id] rows for the open system
var _panel_system := -1        # which system the planet list was built for


func _ready() -> void:
	# Black space so fogged (unseen) area reads as truly dark, not grey.
	RenderingServer.set_default_clear_color(Color(0.02, 0.02, 0.03))
	# Linear-filter the baked fog texture so its low-res samples interpolate into a
	# smooth influence-shaped gradient instead of visible cells. (Only the fog is a
	# texture here; lines/text/arcs are vector-drawn and unaffected.)
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# New game from the menu's settings, or the default demo map. (A pending load
	# replaces this after the UI/camera exist.)
	if not Session.config.is_empty():
		sim = Sim.generate_map(Session.config)
	else:
		sim = Sim.new_demo()
	player_empire_id = sim.empires.keys()[0]  # first empire = human player
	Keybinds.ensure_loaded()   # defaults + any saved rebindings, before the UI reads them
	_build_tier_icons()
	_build_ui()
	_init_camera()
	var is_load := Session.load_path != ""
	if is_load:
		var p := Session.load_path
		Session.load_path = ""
		load_game(p)
	if "--autoshot" in OS.get_cmdline_user_args():
		_autoshot()
	elif not is_load:
		# New game: welcome the player (paused) with the goal + first steps.
		intro_overlay.visible = true
		speed_idx = 0


func save_game(path: String = SAVE_PATH) -> void:
	var d := {"sim": sim.serialize(), "player": player_empire_id,
		"explored": _explored.keys(), "stale": _stale,
		"fog_seen": _fog_seen.keys(),
		"cx": _galaxy_cam_pos.x, "cy": _galaxy_cam_pos.y, "cz": _galaxy_cam_zoom}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d))
		f.close()


func load_game(path: String = SAVE_PATH) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		return false
	sim = Sim.deserialize(d.sim)
	player_empire_id = int(d.player)
	_explored = {}
	for k in d.explored:
		_explored[int(k)] = true
	_stale = {}
	for k in d.stale:
		var s: Dictionary = d.stale[k]
		var planets := {}
		for pk in s.get("planets", {}):
			var pi: Dictionary = s["planets"][pk]
			planets[int(pk)] = {
				"colony": bool(pi.get("colony", false)),
				"colony_owner": int(pi.get("colony_owner", -1)),
				"established": bool(pi.get("established", false)),
				"mine": bool(pi.get("mine", false)),
				"mine_owner": int(pi.get("mine_owner", -1)),
				"mine_level": int(pi.get("mine_level", 0)),
			}
		_stale[int(k)] = {"owner": int(s.get("owner", -1)),
			"depot": int(s.get("depot", -1)), "planets": planets}
	_fog_seen = {}
	for k in d.fog_seen:
		_fog_seen[k] = true
	_compute_map_bounds()
	_galaxy_cam_pos = Vector2(d.cx, d.cy)
	_galaxy_cam_zoom = d.cz
	view_system_id = -1
	selected_planet_id = -1
	selected_fleet_id = -1
	_panel_system = -1
	_rate_hist.clear()          # time jumped — rebuild the income-rate window from here
	_last_sample_day = -1
	_recompute_borders()
	return true


func _compute_map_bounds() -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for sys in sim.systems.values():
		lo = lo.min(sys.map_pos)
		hi = hi.max(sys.map_pos)
	_map_lo = lo
	_map_hi = hi
	_build_starfield()


# A static field of faint background stars covering the map (plus generous margin),
# so empty space reads as deep space rather than flat black. Seeded → stable across
# frames; drawn behind the fog. Most are dim white; a few carry a cool/warm tint.
func _build_starfield() -> void:
	_starfield.clear()
	if _map_lo.x == INF:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 990099   # fixed seed: identical every run
	var lo := _map_lo - Vector2(400, 400)
	var hi := _map_hi + Vector2(400, 400)
	var area := (hi - lo)
	var count := int(clampf(area.x * area.y / 4200.0, 120, 900))
	for i in count:
		var p := Vector2(rng.randf_range(lo.x, hi.x), rng.randf_range(lo.y, hi.y))
		var r := rng.randf_range(0.5, 1.7)
		var a := rng.randf_range(0.05, 0.32)
		var col := Color(1, 1, 1, a)
		var tint := rng.randf()
		if tint < 0.16:
			col = Color(0.6, 0.75, 1.0, a)      # cool blue-white
		elif tint < 0.28:
			col = Color(1.0, 0.85, 0.65, a)     # warm amber
		_starfield.append([p, r, col])


func _init_camera() -> void:
	cam = Camera2D.new()
	add_child(cam)
	cam.make_current()
	# Frame the whole galaxy: center on the map's midpoint, zoom to fit.
	_compute_map_bounds()
	var vp := get_viewport_rect().size
	var span := (_map_hi - _map_lo) + Vector2(240, 240)  # margin
	_galaxy_cam_pos = (_map_lo + _map_hi) * 0.5
	_galaxy_cam_zoom = clampf(minf(vp.x / span.x, vp.y / span.y),
		ZOOM_MIN, ZOOM_MAX)


func _process(delta: float) -> void:
	var speed := SPEEDS[speed_idx]
	if speed > 0.0:
		day_accum += delta * DAYS_PER_REAL_SECOND * speed
		# Fixed-size ticks regardless of speed/framerate: determinism lives in
		# the sim, the dial only changes how many ticks run per real second.
		# Cap ticks-per-frame so a single slow frame (GC hitch, big border rebuild)
		# can't leave a huge day_accum that then runs dozens of ticks next frame and
		# starves input/pan — better to run the sim a hair slow than to freeze.
		var run := 0
		while day_accum >= SimConstants.TICK_DAYS and run < MAX_TICKS_PER_FRAME:
			sim.tick(SimConstants.TICK_DAYS)
			day_accum -= SimConstants.TICK_DAYS
			run += 1
		if day_accum >= SimConstants.TICK_DAYS:
			day_accum = 0.0   # drop the backlog rather than spiral
	# Fog/border rebake: kick it on a worker thread on the timer, apply when it lands.
	# Off-thread so the heavy grid bake can't drop a frame mid-pan.
	_poll_rebake()
	_border_timer -= delta
	if _border_timer <= 0.0 and _rebake_thread == null:
		_border_timer = BORDER_REFRESH
		_start_rebake()
	_handle_key_pan(delta)   # WASD / arrows nudge the camera every frame
	_apply_camera()   # every frame → smooth pan/zoom
	_update_tooltip() # every frame so the hover popup tracks the cursor smoothly
	# HUD/panel + hover + events refresh at ~15 Hz, not every frame: they run sim
	# queries that don't need per-frame updates and were choking input/pan.
	_ui_timer -= delta
	if _ui_timer <= 0.0:
		_ui_timer = UI_REFRESH
		_update_hover()
		_scan_events()
		_check_game_over()
		_refresh_ui()
	# Redraw every frame: the viewport doesn't retain the canvas between frames here, so
	# skipping a redraw shows a cleared background (a visible flicker). The pan-lag fix is
	# instead to make each _draw cheap — viewport culling + zoom-gated labels in
	# _draw_galaxy — not to redraw less often.
	queue_redraw()


# Watch for autonomous happenings the player should know about — colonies lost,
# battles in systems they can see — and surface them in the top-left feed. (Things
# the player did themselves, like founding a colony, aren't logged — they know.)
func _scan_events() -> void:
	# Player colony losses (a planet that was ours no longer has our colony).
	var now := {}
	for c in sim.colonies:
		if c.empire_id == player_empire_id:
			now[c.planet_id] = sim.planets[c.planet_id].system_id
	if not _prev_pcolonies.is_empty():
		for pid in _prev_pcolonies:
			if not now.has(pid):
				var sid: int = _prev_pcolonies[pid]
				var nm: String = sim.systems[sid].name if sim.systems.has(sid) else "?"
				_log_event("✖ Colony lost at %s" % nm)
	_prev_pcolonies = now
	# Battles at systems the player can currently see.
	for sid in sim.combat_at:
		var d: float = sim.combat_at[sid]
		if d > _seen_combat.get(sid, -1.0) and _sys_live(sid):
			_seen_combat[sid] = d
			_log_event("⚔ Battle at %s" % sim.systems[sid].name)
	_refresh_events()


func _log_event(text: String) -> void:
	_events.append([sim.day, text])


# Keep the newest 5 events from the last 25 days; render them into the feed label.
func _refresh_events() -> void:
	var kept: Array = []
	for e in _events:
		if sim.day - e[0] <= 25.0:
			kept.append(e)
	while kept.size() > 5:
		kept.pop_front()
	_events = kept
	if event_label != null:
		var lines := ""
		for e in _events:
			lines += "%s\n" % e[1]
		event_label.text = lines


# Defeat when the player holds no colonies; victory when only the player does.
func _check_game_over() -> void:
	if _game_over:
		return
	var player_has := false
	var rival_has := false
	for c in sim.colonies:
		if c.empire_id == player_empire_id:
			player_has = true
		else:
			rival_has = true
	if player_has and rival_has:
		return
	_game_over = true
	speed_idx = 0
	menu_overlay.visible = true
	overlay_resume.visible = false
	overlay_save.visible = false
	overlay_title.text = "Victory!" if player_has else "Defeated"


func _toggle_menu() -> void:
	# The in-game menu pauses the sim while open and restores the prior speed on
	# close, so opening it never lets the game run on unwatched. No-op once the game
	# is over — that overlay isn't dismissable.
	if _game_over:
		return
	if menu_overlay.visible:
		menu_overlay.visible = false
		speed_idx = _speed_before_menu
	else:
		_speed_before_menu = speed_idx
		speed_idx = 0
		overlay_title.text = "Paused"
		overlay_resume.visible = true
		overlay_save.visible = true
		overlay_save.text = "Save game"
		menu_overlay.visible = true


func _update_hover() -> void:
	if _hover_hold:   # autoshot drives the hover manually
		return
	_hover_system = -1
	var mp := get_global_mouse_position()
	for sys in sim.systems.values():
		if _sys_known(sys.id) and mp.distance_to(sys.map_pos) <= 22.0:
			_hover_system = sys.id
			return


# Sample the influence field on a world grid and emit bold colored edge LINES
# where the owning empire changes — the deformed border.
#
# Perf: influence per system is computed ONCE here into flat per-empire arrays;
# the per-cell owner test is then pure float math over the few systems that
# actually have colonies (not every system × its planets, per cell). This is
# what keeps the 0.4s refresh from stalling the main thread / freezing input.
# Synchronous field rebuild (prep on main thread + bake inline + apply). Used at
# startup and by the autoshot. The live game uses the async path (_start_rebake /
# _poll_rebake) so the heavy grid bake runs off the main thread and can't hitch a pan.
func _recompute_borders() -> void:
	_apply_field(_bake_field(_prep_field()))


# Main-thread prep: snapshot each empire's influence sources into flat arrays and
# resolve per-system owner/VR/explored/stale. Returns everything the (off-thread) bake
# needs; the bake must not read live sim state beyond immutable anomalies.
func _prep_field() -> Dictionary:
	_system_owner.clear()
	_has_anomalies = not sim.anomalies.is_empty()
	# Per-empire sources: parallel packed arrays of (position, influence, reach).
	var ids: Array = []
	var pos: Array = []
	var infl: Array = []
	var reach: Array = []
	for e in sim.empires.values():
		var pv := PackedVector2Array()
		var iv := PackedFloat32Array()
		var rv := PackedFloat32Array()
		for sys in sim.systems.values():
			var f := sim.system_influence(sys.id, e.id)
			if f > 0.0:
				pv.append(sys.map_pos)
				iv.append(f)
				# Use the sim's reach (which applies the observation-post doubling)
				# so posts push the border AND extend VR here, not just the logic.
				rv.append(sim.influence_reach(sys.id, e.id))
		if pv.size() > 0:
			ids.append(e.id)
			pos.append(pv)
			infl.append(iv)
			reach.append(rv)

	var pk := ids.find(player_empire_id)   # player's index in the source arrays

	# VR/sight uses the player's influence reach scaled up (sight sees further than
	# influence claims), so visibility — fog fill, revealed systems, and the borders
	# you can see — all extend PAST your border, not up to it. Ownership and the
	# border contour itself still use the real reach (that's your actual influence).
	var reach_vr: Array = reach.duplicate()
	if pk != -1:
		var rvs := PackedFloat32Array()
		for rv in reach[pk]:
			rvs.append(rv * VR_SIGHT_REACH)
		reach_vr[pk] = rvs

	# Field VR: visibility follows the ACTUAL influence — a point is in VR where
	# the player's claim, scaled by SIGHT, still beats the strongest rival there
	# (so it fills the influence territory and extends 1.5x IN FRONT of the border,
	# and stops as a rival dominates). FULL (2) where the field says so or you hold
	# the system; PARTIAL (1) one lane-jump out for structure; explored stays grey.
	_system_vr.clear()
	var full := {}
	for sys in sim.systems.values():
		_system_owner[sys.id] = _owner_at(sys.map_pos, ids, pos, infl, reach)
		if _player_vr_at(sys.map_pos, ids, pos, infl, reach, reach_vr, pk) \
				or sim._empire_has_colony_in(player_empire_id, sys.id) \
				or sim.empire_fleet_in_system(player_empire_id, sys.id):
			full[sys.id] = true
	for sys in sim.systems.values():
		_system_vr[sys.id] = 2 if full.has(sys.id) else 0
	for sid in full:
		for nb in sim.lane_neighbors(sid):
			if not full.has(nb):
				_system_vr[nb] = maxi(_system_vr[nb], 1)
	for sys in sim.systems.values():
		if _system_vr[sys.id] >= 1:
			_explored[sys.id] = true
		if _system_vr[sys.id] == 2:
			_stale[sys.id] = _snapshot_system(sys)
	return {"ids": ids, "pos": pos, "infl": infl, "reach": reach,
		"reach_vr": reach_vr, "pk": pk}


# Off-thread bake: pure grid work from the prep snapshot -> a fog Image, its world rect,
# and the border-contour segments. Reads only the job arrays, static map bounds, and
# immutable anomalies (via the pure _claim_at/_vr_at helpers), plus _fog_seen which it
# owns for the duration of one rebake. The caller applies the result on the main thread
# (texture upload + segment swap) so no rendering call happens off-thread.
func _bake_field(job: Dictionary) -> Dictionary:
	var ids: Array = job.ids
	var pos: Array = job.pos
	var infl: Array = job.infl
	var reach: Array = job.reach
	var reach_vr: Array = job.reach_vr
	var pk: int = job.pk
	var segments: Array = []
	# Influence-shaped fog: sample a CONTINUOUS VR value on a grid and bake it into
	# a texture (drawn with linear filtering) so the lit region reads as the smooth
	# influence shape with a feathered edge — not axis-aligned blocks, not a hard
	# reach disc. Per cell: v in [0,1] = how deep inside VR it is; v>0 marks the
	# cell explored (grey memory once it later drops out of VR).
	var flo := _map_lo - Vector2(140, 140)
	var fhi := _map_hi + Vector2(140, 140)
	# Adaptive cell size: never finer than FOG_CELL, but coarsen on big maps so the
	# grid never exceeds ~FIELD_MAX_CELLS per axis — keeps the recompute affordable
	# at large planet counts (the fog is only viewed zoomed out there anyway).
	var fspan: float = maxf(fhi.x - flo.x, fhi.y - flo.y)
	var fcell: float = maxf(FOG_CELL, fspan / FIELD_MAX_CELLS)
	var fcols: int = maxi(1, int((fhi.x - flo.x) / fcell) + 1)
	var frows: int = maxi(1, int((fhi.y - flo.y) / fcell) + 1)
	var img := Image.create(fcols, frows, false, Image.FORMAT_RGBA8)
	for gy in frows:
		for gx in fcols:
			var c := Vector2(flo.x + (gx + 0.5) * fcell, flo.y + (gy + 0.5) * fcell)
			var v := _vr_at(c, ids, pos, infl, reach, reach_vr, pk)
			var key := "%d,%d" % [gx, gy]
			if v > 0.0:
				_fog_seen[key] = true
			# Composite feathered lit over grey memory over transparent (black bg).
			var base_a := 0.6 if _fog_seen.has(key) else 0.0
			var fa: float = v + base_a * (1.0 - v)
			var col := Color(0, 0, 0, 0)
			if fa > 0.0001:
				var lit := Vector3(0.13, 0.13, 0.15) * v
				var mem := Vector3(0.07, 0.07, 0.08) * (base_a * (1.0 - v))
				var rgb: Vector3 = (lit + mem) / fa
				col = Color(rgb.x, rgb.y, rgb.z, fa)
			img.set_pixel(gx, gy, col)
	var fog_rect := Rect2(flo, fhi - flo)

	# Sample each empire's claim on a grid of POINTS (cell corners), then trace a
	# smooth marching-squares contour of every empire's dominance margin
	# (claim_E − strongest rival claim). The zero-contour is that empire's border
	# — the hostile seam AND its bubble edge against empty space — as an
	# interpolated CURVE, not an axis-aligned staircase.
	var lo := _map_lo - Vector2(140, 140)
	var hi := _map_hi + Vector2(140, 140)
	# Adaptive like the fog grid: coarsen on big maps so the corner grid stays bounded.
	var bspan: float = maxf(hi.x - lo.x, hi.y - lo.y)
	var bcell: float = maxf(BORDER_CELL, bspan / FIELD_MAX_CELLS)
	var pcols := int((hi.x - lo.x) / bcell) + 2   # +1 cells -> +2 corners
	var prows := int((hi.y - lo.y) / bcell) + 2
	var claims: Array = []   # claims[k] = PackedFloat32Array over all corner points
	for k in ids.size():
		var arr := PackedFloat32Array()
		arr.resize(pcols * prows)
		for gy in prows:
			for gx in pcols:
				arr[gy * pcols + gx] = _claim_at(
					Vector2(lo.x + gx * bcell, lo.y + gy * bcell),
					pos[k], infl[k], reach[k])
		claims.append(arr)

	# Draw rivals first, the player's own empire last, so at a coincident seam
	# (where both empires' margin=0 curves overlap) the player sees its own colour.
	var order: Array = []
	for k in ids.size():
		if ids[k] != player_empire_id:
			order.append(k)
	for k in ids.size():
		if ids[k] == player_empire_id:
			order.append(k)
	for k in order:
		var ck: PackedFloat32Array = claims[k]
		var col: Color = sim.empires[ids[k]].color
		for cy in prows - 1:
			for cx in pcols - 1:
				var i_tl := cy * pcols + cx
				var i_tr := cy * pcols + cx + 1
				var i_br := (cy + 1) * pcols + cx + 1
				var i_bl := (cy + 1) * pcols + cx
				# Skip cells this empire doesn't reach (avoids tracing a rival's
				# bubble edge in the wrong colour where both claims are ~0).
				if ck[i_tl] <= 0.0 and ck[i_tr] <= 0.0 \
						and ck[i_br] <= 0.0 and ck[i_bl] <= 0.0:
					continue
				var p_tl := Vector2(lo.x + cx * bcell, lo.y + cy * bcell)
				var p_tr := p_tl + Vector2(bcell, 0)
				var p_br := p_tl + Vector2(bcell, bcell)
				var p_bl := p_tl + Vector2(0, bcell)
				# Subtract a small floor from the rival claim so an empire's edge
				# against EMPTY space (both claims ~0) still crosses zero and draws
				# a contour — otherwise a lone/uncontested bubble showed no curve.
				var m_tl := ck[i_tl] - maxf(_best_other(claims, k, i_tl), BORDER_EPS)
				var m_tr := ck[i_tr] - maxf(_best_other(claims, k, i_tr), BORDER_EPS)
				var m_br := ck[i_br] - maxf(_best_other(claims, k, i_br), BORDER_EPS)
				var m_bl := ck[i_bl] - maxf(_best_other(claims, k, i_bl), BORDER_EPS)
				# Centroid of this cell's INSIDE corners (margin >= 0) — the
				# empire's own side. Each segment is nudged toward it so a shared
				# seam shows both empires' curves side by side, not overlapping.
				var corners := [p_tl, p_tr, p_br, p_bl]
				var margins := [m_tl, m_tr, m_br, m_bl]
				var in_sum := Vector2.ZERO
				var in_n := 0
				for ci in 4:
					if margins[ci] >= 0.0:
						in_sum += corners[ci]
						in_n += 1
				var inside_c: Vector2 = in_sum / in_n if in_n > 0 \
					else (p_tl + p_br) * 0.5
				for seg in _ms_segments(corners, margins):
					var mid: Vector2 = (seg[0] + seg[1]) * 0.5
					var off := inside_c - mid
					if off.length() > 0.01:
						off = off.normalized() * BORDER_INSET
					# Draw the border where the player can see it — tested at the contour
					# point itself. Since 0.70.0 VR is FULL at the border and feathers PAST
					# it, so the line sits in lit fog and this is stable. (The old code
					# probed 12px into the OWNING side; for a RIVAL's border that landed deep
					# in rival space where the player's VR is marginal, so the line flickered
					# in and out between rebakes as the border drifted — despite the seam
					# plainly being inside VR.)
					if _player_vr_at(mid, ids, pos, infl, reach, reach_vr, pk):
						segments.append([seg[0] + off, seg[1] + off, col])
	return {"img": img, "fog_rect": fog_rect, "segments": segments}


# Apply a baked field result on the main thread: upload the fog texture and swap in the
# new border segments. (ImageTexture creation is a GPU op, so it stays on the main thread.)
func _apply_field(res: Dictionary) -> void:
	_fog_tex = ImageTexture.create_from_image(res.img)
	_fog_rect = res.fog_rect
	_border_segments = res.segments


# --- async field rebake -------------------------------------------------------
# The live game runs _prep_field on the main thread (cheap; snapshots sim state) then
# bakes the grids on a worker thread, so the ~2x/sec rebake never blocks a frame. The
# result is applied on the next frame once the thread finishes.
func _start_rebake() -> void:
	if _rebake_thread != null:
		return
	var job := _prep_field()
	_rebake_result = {}
	_rebake_thread = Thread.new()
	_rebake_thread.start(_bake_field.bind(job))


func _poll_rebake() -> void:
	if _rebake_thread != null and not _rebake_thread.is_alive():
		_rebake_result = _rebake_thread.wait_to_finish()
		_rebake_thread = null
		if not _rebake_result.is_empty():
			_apply_field(_rebake_result)


func _exit_tree() -> void:
	# Don't leak/crash on a worker mid-bake when the scene tears down.
	if _rebake_thread != null:
		_rebake_thread.wait_to_finish()
		_rebake_thread = null


# Freeze everything the player is allowed to REMEMBER about a system last seen in
# full VR: system owner, depot, and per-planet colony existence/owner + mines found
# (NO population — that's live-only). Names, positions and deposits are static, so
# they're read live for any explored system, not stored here.
func _snapshot_system(sys: StarSystem) -> Dictionary:
	var planets := {}
	for pid in sys.planet_ids:
		var p: Planet = sim.planets[pid]
		planets[pid] = {
			"colony": p.colony != null,
			"colony_owner": p.colony.empire_id if p.colony != null else -1,
			"established": p.colony != null and p.colony.established,
			"mine": p.has_mine(),
			"mine_owner": p.mine_empire_id if p.has_mine() else -1,
			"mine_level": p.mine_level if p.has_mine() else 0,
		}
	return {"owner": _system_owner.get(sys.id, -1),
		"depot": sys.depot_empire_id, "planets": planets}


# One empire's combined claim at a world point: (Σi)² / Σ(d·i) over its sources
# within reach; 0 if none reach. A large finite stands in for "on a source" so
# marching-squares interpolation never divides by an infinity.
func _claim_at(p: Vector2, pv: PackedVector2Array, iv: PackedFloat32Array,
		rv: PackedFloat32Array) -> float:
	# Anomalies block influence AND sight: no claim inside one, and a source can't
	# project across one. Since fog rides this field too, VR routes around them.
	if _has_anomalies and sim.point_in_anomaly(p):
		return 0.0
	var si := 0.0
	var sri := 0.0
	for j in pv.size():
		var d := p.distance_to(pv[j])
		if d <= rv[j] and not (_has_anomalies and sim.segment_hits_anomaly(pv[j], p)):
			si += iv[j]
			sri += d * iv[j]
	if si <= 0.0:
		return 0.0
	return 1.0e9 if sri <= 0.0 else (si * si) / sri


# The player's VR value in [0,1] at a world point. Two regimes so sight tracks the
# BORDER, not raw influence:
#  - Contested (a real rival claims here, above the open-space floor): lit where the
#    player's REAL claim beats the rival — VR fills owned ground and STOPS at the
#    border. Growing your population past a border a rival is holding no longer
#    creeps VR into their space; it moves only when the border itself moves.
#  - Open space (no real rival): lit out to the player's extended SIGHT reach, for
#    early warning ahead of an uncontested frontier.
func _vr_at(p: Vector2, ids: Array, pos: Array, infl: Array, reach: Array,
		reach_vr: Array, pk: int) -> float:
	if pk == -1:
		return 0.0
	var rival := 0.0
	for k in ids.size():
		if k != pk:
			rival = maxf(rival, _claim_at(p, pos[k], infl[k], reach[k]))
	if rival > VR_CLAIM_FLOOR:
		var pc_real := _claim_at(p, pos[pk], infl[pk], reach[pk])
		if pc_real <= 0.0:
			return 0.0
		# FULL brightness across owned ground, feathering to 0 in a thin band right
		# AT the border — so the fog reaches the border (border sits on the lit edge),
		# not fading short of it. (Feathering up-from-the-border pulled VR inward and
		# left your own border floating outside the lit area.)
		return clampf((pc_real / rival - (1.0 - VR_BORDER_FEATHER)) / VR_BORDER_FEATHER,
			0.0, 1.0)
	var pc_ext := _claim_at(p, pos[pk], infl[pk], reach_vr[pk])
	if pc_ext <= 0.0:
		return 0.0
	return clampf((pc_ext / VR_CLAIM_FLOOR - 1.0) / VR_BAND, 0.0, 1.0)


func _player_vr_at(p: Vector2, ids: Array, pos: Array, infl: Array, reach: Array,
		reach_vr: Array, pk: int) -> bool:
	return _vr_at(p, ids, pos, infl, reach, reach_vr, pk) > 0.0


func _best_other(claims: Array, k: int, pi: int) -> float:
	var best := 0.0
	for j in claims.size():
		if j != k:
			var v: float = claims[j][pi]
			if v > best:
				best = v
	return best


# Owner of a world point (argmax claim), -1 if none reach. Used for system rings.
func _owner_at(p: Vector2, ids: Array, pos: Array, infl: Array, reach: Array) -> int:
	var best := -1
	var best_claim := 0.0
	for k in ids.size():
		var c := _claim_at(p, pos[k], infl[k], reach[k])
		if c > best_claim:
			best_claim = c
			best = ids[k]
	return best


# Marching-squares contour segments of the level set margin=0 inside one cell.
# Corners in order [TL, TR, BR, BL]; edges connect consecutive corners. Crossings
# are linearly interpolated for a smooth curve.
func _ms_segments(p: Array, m: Array) -> Array:
	var inside := [m[0] >= 0.0, m[1] >= 0.0, m[2] >= 0.0, m[3] >= 0.0]
	var e := {}   # edge index -> crossing point
	for edge in 4:
		var a: int = edge
		var b: int = (edge + 1) % 4
		if inside[a] != inside[b]:
			var t: float = m[a] / (m[a] - m[b])
			e[edge] = (p[a] as Vector2).lerp(p[b], t)
	var keys: Array = e.keys()
	if keys.size() == 2:
		return [[e[keys[0]], e[keys[1]]]]
	if keys.size() == 4:   # saddle — connect adjacent edge pairs
		return [[e[0], e[3]], [e[1], e[2]]]
	return []


# One always-on galaxy camera now (the old orbital system view is gone —
# clicking a system just opens its planet list in the side panel).
func _apply_camera() -> void:
	cam.position = _galaxy_cam_pos
	cam.zoom = Vector2(_galaxy_cam_zoom, _galaxy_cam_zoom)


# Held-key camera pan (WASD, physical-position so it works on any layout, + arrows).
# World-space step is divided by zoom so the on-screen speed is constant. Suppressed
# while a modal overlay is up so the keys don't slide the map behind it.
func _handle_key_pan(delta: float) -> void:
	if (intro_overlay != null and intro_overlay.visible) \
			or (menu_overlay != null and menu_overlay.visible) \
			or (controls_page != null and controls_page.visible):
		return
	var dir := Vector2.ZERO
	if _pan_held("pan_up") or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if _pan_held("pan_down") or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if _pan_held("pan_left") or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if _pan_held("pan_right") or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if dir != Vector2.ZERO:
		_galaxy_cam_pos += dir.normalized() * (PAN_SPEED * delta / _galaxy_cam_zoom)


func _pan_held(action: String) -> bool:
	var kc: int = Keybinds.keycode(action)
	return kc != 0 and Input.is_key_pressed(kc)


# Ship hotkey slot -> role/tier (1-5 Fighter T1-5, 6-10 Bomber T1-5), built ×1/×10/×100
# per the held modifier.
func _build_from_hotkey(slot: int) -> void:
	var role: int = SimConstants.Role.FIGHTER if slot <= 5 else SimConstants.Role.BOMBER
	var tier: int = slot if slot <= 5 else slot - 5
	_build_ships(role, tier, _build_count_from_mods())


# Ctrl = ×100, Shift = ×10, otherwise ×1. Shared by the number-row hotkeys and the
# shipyard buttons so both honour the same batch modifiers.
func _build_count_from_mods() -> int:
	if Input.is_key_pressed(KEY_CTRL):
		return 100
	if Input.is_key_pressed(KEY_SHIFT):
		return 10
	return 1


# Build up to `count` of a ship, stopping early if the tier's alloy runs out; report
# what actually happened in the event log.
func _build_ships(role: int, tier: int, count: int) -> void:
	var made := 0
	for _i in count:
		if not sim.build_ship(player_empire_id, role, tier):
			break
		made += 1
	var rname: String = "Fighter" if role == SimConstants.Role.FIGHTER else "Bomber"
	if made == 0:
		_log_event("✖ Can't build %s T%d — need %d tier-%d alloy"
			% [rname, tier, int(SimConstants.SHIP_NAT_COST), tier])
	elif made < count:
		_log_event("⚙ Built %d× %s T%d (out of alloy — wanted %d)" % [made, rname, tier, count])
	else:
		_log_event("⚙ Built %d× %s T%d" % [made, rname, tier])


# --- Rebindable action dispatch -------------------------------------------------

# Run the game action bound to a key (empty string = unbound, does nothing).
func _dispatch_action(action: String) -> void:
	match action:
		"pause":
			speed_idx = 0 if speed_idx != 0 else 1
		"speed_up":
			speed_idx = mini(SPEEDS.size() - 1, speed_idx + 1)
		"speed_down":
			speed_idx = maxi(0, speed_idx - 1)
		"legend":
			if legend_panel != null:
				legend_panel.visible = not legend_panel.visible
		"controls":
			if controls_page != null and not controls_page.visible:
				controls_page.open()
		"save":
			save_game()
		"load":
			load_game()
		_:
			if action.begins_with("ship_"):
				_build_from_hotkey(int(action.trim_prefix("ship_")))


# Esc: close the top-most overlay if one is open, otherwise pause + open the menu.
func _on_escape() -> void:
	if intro_overlay != null and intro_overlay.visible:
		intro_overlay.visible = false
		speed_idx = 1
	elif legend_panel != null and legend_panel.visible:
		legend_panel.visible = false
	elif menu_overlay != null and menu_overlay.visible:
		_toggle_menu()
	elif view_system_id != -1 or selected_planet_id != -1 or selected_fleet_id != -1:
		view_system_id = -1
		selected_planet_id = -1
		selected_fleet_id = -1
	else:
		_toggle_menu()


func _unhandled_input(event: InputEvent) -> void:
	# Right-drag to pan, wheel to zoom (always active now).
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_panning = event.pressed
			return
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_galaxy_cam_zoom = clampf(_galaxy_cam_zoom * 1.1, ZOOM_MIN, ZOOM_MAX)
			return
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_galaxy_cam_zoom = clampf(_galaxy_cam_zoom / 1.1, ZOOM_MIN, ZOOM_MAX)
			return
	if _panning and event is InputEventMouseMotion:
		_galaxy_cam_pos -= event.relative / _galaxy_cam_zoom
		return

	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_select_at(get_global_mouse_position())
	elif event is InputEventKey and event.pressed and not event.echo:
		# The controls page captures its own keys (rebinding, and Esc/K to close) in
		# _unhandled_key_input, which runs before this — so while it's open, swallow any
		# game hotkey that reaches here so it can't fire behind the panel.
		if controls_page != null and controls_page.visible:
			return
		# Esc: close the top overlay, else pause + open the menu.
		if event.keycode == KEY_ESCAPE:
			_on_escape()
			return
		# Numpad +/- are fixed speed shortcuts on top of the rebindable = / -.
		if event.keycode == KEY_KP_ADD:
			speed_idx = mini(SPEEDS.size() - 1, speed_idx + 1)
		elif event.keycode == KEY_KP_SUBTRACT:
			speed_idx = maxi(0, speed_idx - 1)
		else:
			_dispatch_action(Keybinds.action_for(event.keycode))


func _select_at(pos: Vector2) -> void:
	# 1. With a fleet selected, a click on a known system orders it there.
	if selected_fleet_id != -1:
		for sys in sim.systems.values():
			if pos.distance_to(sys.map_pos) <= 20.0 and _sys_known(sys.id):
				var fl := sim.get_fleet(selected_fleet_id)
				if not sim.order_fleet(selected_fleet_id, sys.id) and fl != null:
					# Refused by the FTL pin — tell the player why instead of silence.
					if sim.fleet_pin(fl) == 2:
						_log_event("🔒 Fleet held in battle — can't jump until it's decided")
					else:
						_log_event("⚓ Fleet pinned over an enemy world — can only retreat")
				selected_fleet_id = -1
				return
	# 2. Click near one of your fleets (drawn above its system) to select it. The catch
	#    radius is SCREEN-space (÷ zoom), floored to the icon size, so fleets stay easy to
	#    grab when zoomed out instead of shrinking to an unclickable dot.
	var fleet_r: float = maxf(15.0, FLEET_CLICK_R / _galaxy_cam_zoom)
	for f in sim.fleets:
		if f.empire_id == player_empire_id \
				and pos.distance_to(sim.fleet_position(f) + FLEET_ICON_OFF) <= fleet_r:
			selected_fleet_id = f.id
			view_system_id = -1
			return
	# 3. Click a known system to open its planet-list menu (side panel).
	for sys in sim.systems.values():
		if pos.distance_to(sys.map_pos) <= 20.0 and _sys_known(sys.id):
			view_system_id = sys.id
			# One planet per node — auto-select it so the panel shows the planet's
			# actions directly (no system→planet-list step).
			selected_planet_id = sys.planet_ids[0] if not sys.planet_ids.is_empty() \
				else -1
			selected_fleet_id = -1
			return
	# Empty space -> close panel / deselect.
	view_system_id = -1
	selected_fleet_id = -1


var _fog_disabled := false   # debug/screenshot only


func _sys_live(sid: int) -> bool:     # full VR right now
	return _fog_disabled or _system_vr.get(sid, 0) == 2


func _sys_known(sid: int) -> bool:    # full/partial VR now OR explored before
	return _fog_disabled or _system_vr.get(sid, 0) >= 1 or _explored.has(sid)


func _draw() -> void:
	_draw_galaxy()
	# Ring the system whose planet-list menu is open.
	if view_system_id != -1 and sim.systems.has(view_system_id):
		draw_arc(sim.systems[view_system_id].map_pos, 16.0, 0.0, TAU, 32,
			Color(1, 1, 1, 0.6), 1.5)


func _draw_galaxy() -> void:
	var font := ThemeDB.fallback_font
	# Visible world rect (camera centre ± half-viewport/zoom), padded. Systems/stars/
	# labels outside it are skipped — without this, zooming in still drew (and shaped
	# the labels of) every off-screen system on a big map.
	var half := get_viewport_rect().size / (2.0 * maxf(_galaxy_cam_zoom, 0.001))
	var view_lo := _galaxy_cam_pos - half - Vector2(80, 80)
	var view_hi := _galaxy_cam_pos + half + Vector2(80, 80)
	# Deep-space backdrop: faint static stars, behind everything.
	for s in _starfield:
		draw_circle(s[0], s[1], s[2])
	# Influence-shaped fog on the black background: one baked texture, drawn with
	# linear filtering (see _ready) so the feathered lit region hugs the player's
	# actual influence with a smooth edge — no blocks, no hard reach disc. Lit fades
	# to grey explored-memory to never-seen black. Baked in the border refresh.
	if _fog_tex != null:
		draw_texture_rect(_fog_tex, _fog_rect, false)
	# Cosmic anomalies: a magenta nebula haze with a darker core — physical hazards
	# that block influence and sight, so they're always visible (you route around
	# them). Drawn over the fog.
	for an in sim.anomalies:
		var ac: Vector2 = an.pos
		var ar: float = an.r
		for i in 5:
			var t := float(i) / 5.0
			var col := Color(0.5, 0.2, 0.6, 0.10 + t * 0.06)
			draw_circle(ac, ar * (1.0 - t * 0.8), col)
		draw_arc(ac, ar, 0.0, TAU, 48, Color(0.7, 0.4, 0.9, 0.35), 1.5)
	# Deformed influence borders (already fog-gated to VR in _recompute_borders).
	# Two passes: a wide translucent underlay for a soft glow, then the crisp core.
	for seg in _border_segments:
		var gc: Color = seg[2]
		gc.a = 0.22
		draw_line(seg[0], seg[1], gc, 5.0)
	for seg in _border_segments:
		draw_line(seg[0], seg[1], seg[2], 2.0)
	# Lanes: full between two known systems; HALF (out to the midpoint) when one
	# end is known and the other is never-seen; nothing when neither is known.
	var lane_col := Color(1, 1, 1, 0.13)
	for lane in sim.lanes:
		var a: Vector2 = sim.systems[lane[0]].map_pos
		var b: Vector2 = sim.systems[lane[1]].map_pos
		var ka := _sys_known(lane[0])
		var kb := _sys_known(lane[1])
		if ka and kb:
			draw_line(a, b, lane_col, 1.5)
		elif ka:
			draw_line(a, (a + b) * 0.5, lane_col, 1.5)
		elif kb:
			draw_line(b, (a + b) * 0.5, lane_col, 1.5)
	for sys in sim.systems.values():
		var sp: Vector2 = sys.map_pos
		if sp.x < view_lo.x or sp.x > view_hi.x or sp.y < view_lo.y or sp.y > view_hi.y:
			continue   # off-screen: skip star + labels
		var live := _sys_live(sys.id)
		if not (live or _sys_known(sys.id)):
			continue   # never seen -> stays black
		if live:
			# Live: bright glowing star sized by its population, owner ring, colonies.
			var cc := 0
			var spop := 0.0
			for pid in sys.planet_ids:
				var pcol: Colony = sim.planets[pid].colony
				if pcol != null:
					cc += 1
					spop += pcol.population
			var sscale: float = 1.0 + clampf(spop / 2500.0, 0.0, 1.0) * 0.7
			_draw_star(sys.map_pos, _star_color(sys.id), 1.0, sscale)
			if sys.depot_empire_id != -1:   # supply depot: filled square
				draw_rect(Rect2(sys.map_pos + Vector2(-16, -16), Vector2(6, 6)),
					sim.empires[sys.depot_empire_id].color)
			if sys.obs_post_empire_id != -1:   # observation post: ringed dot (eye)
				var oc: Color = sim.empires[sys.obs_post_empire_id].color
				draw_arc(sys.map_pos + Vector2(-13, -18), 4.0, 0.0, TAU, 12, oc, 1.5)
				draw_circle(sys.map_pos + Vector2(-13, -18), 1.3, oc)
			if sys.transport_empire_id != -1:   # transport hub: small chevron/link
				var tc: Color = sim.empires[sys.transport_empire_id].color
				var tp: Vector2 = sys.map_pos + Vector2(-4, -18)
				draw_line(tp + Vector2(-3, 2), tp, tc, 1.5)
				draw_line(tp, tp + Vector2(3, 2), tc, 1.5)
			var owner: int = _system_owner.get(sys.id, -1)
			if owner != -1:
				draw_arc(sys.map_pos, 13.0 * sscale, 0.0, TAU, 32,
					sim.empires[owner].color, 2.0)
			if _galaxy_cam_zoom >= LABEL_ZOOM:
				if cc > 0:
					draw_string(font, sys.map_pos + Vector2(14.0, -12.0), str(cc),
						HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.35, 1.0, 0.5))
				_draw_name(font, sys.map_pos + Vector2(-60.0, 26.0), sys.name,
					Color(1, 1, 1, 0.85))
		else:
			# Explored but out of VR: dim star + the frozen last-seen snapshot
			# (owner ring + colony count as of last sight — no live data).
			_draw_star(sys.map_pos, _star_color(sys.id), 0.4)
			var snap: Dictionary = _stale.get(sys.id, {})
			var sowner: int = snap.get("owner", -1)
			if sowner != -1:
				var gc: Color = sim.empires[sowner].color
				gc.a = 0.4
				draw_arc(sys.map_pos, 13.0, 0.0, TAU, 32, gc, 1.5)
			if _galaxy_cam_zoom >= LABEL_ZOOM:
				var scc := 0
				for pinfo in snap.get("planets", {}).values():
					if pinfo.get("colony", false):
						scc += 1
				if scc > 0:
					draw_string(font, sys.map_pos + Vector2(14.0, -12.0), str(scc),
						HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.5, 0.7, 0.55, 0.6))
				_draw_name(font, sys.map_pos + Vector2(-60.0, 26.0), sys.name,
					Color(1, 1, 1, 0.5))

	# Combat indicators (for systems the player can see): a LIVE battle or bombardment
	# pulses persistently and distinctly; recently-ended combat leaves a fading
	# afterglow — so combat is legible, not silent.
	var pulse := 0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.006)
	for sid in sim.combat_at:
		if not _sys_live(sid) or not sim.systems.has(sid):
			continue
		var p: Vector2 = sim.systems[sid].map_pos
		var kind: int = sim.combat_kind.get(sid, -1)
		if kind == 0:
			# Live fleet battle: pulsing red-orange clash — a ring + crossed swords.
			var bc := Color(1.0, 0.4, 0.2, 0.35 + 0.4 * pulse)
			draw_arc(p, 15.0 + 3.0 * pulse, 0.0, TAU, 28, bc, 2.0)
			for k in 2:
				var d := Vector2.RIGHT.rotated(PI * 0.25 + k * PI * 0.5) * 12.0
				draw_line(p - d, p + d, Color(1.0, 0.5, 0.25, 0.9), 2.5)
		elif kind == 1:
			# Live bombardment: pulsing yellow streaks raining onto the system.
			var yc := Color(1.0, 0.85, 0.2, 0.5 + 0.4 * pulse)
			for k in 3:
				var x := p.x - 8.0 + k * 8.0
				draw_line(Vector2(x, p.y - 20.0), Vector2(x, p.y - 10.0), yc, 2.0)
			draw_arc(p, 14.0, 0.0, TAU, 24, Color(1.0, 0.8, 0.2, 0.3 * pulse), 1.5)
		else:
			# Ended recently: fading red starburst afterglow.
			var age: float = sim.day - sim.combat_at[sid]
			if age < 0.0 or age > COMBAT_FLASH_DAYS:
				continue
			var fc := Color(1.0, 0.35, 0.2, (1.0 - age / COMBAT_FLASH_DAYS) * 0.7)
			for k in 4:
				var d := Vector2.RIGHT.rotated(k * PI / 4.0) * 10.0
				draw_line(p - d, p + d, fc, 2.0)

	# Construction vessels in transit: a small hollow square (a "cargo box") in the
	# empire's colour. Own always visible; a rival's only while in your VR.
	for b in sim.builders:
		if not (b.eid == player_empire_id or _sys_live(b.sys)):
			continue
		var bp: Vector2 = sim.builder_position(b)
		var bc: Color = sim.empires[b.eid].color
		draw_rect(Rect2(bp - Vector2(3.5, 3.5), Vector2(7, 7)), bc, false, 1.5)
		draw_line(bp - Vector2(2, 0), bp + Vector2(2, 0), bc, 1.0)

	# Fleets: your own always visible; a rival's only while it sits in your VR.
	# Drawn as an arrowhead in the empire's colour, pointed along its heading; a
	# selected fleet gets a ring and a dashed line to its destination.
	for f in sim.fleets:
		var own := f.empire_id == player_empire_id
		if not (own or _sys_live(f.system_id)):
			continue
		var fp := sim.fleet_position(f) + FLEET_ICON_OFF   # above the system node
		var col: Color = sim.empires[f.empire_id].color
		var dir := Vector2.UP
		if f.is_moving():
			var d: Vector2 = sim.systems[f.path[0]].map_pos - sim.fleet_position(f)
			if d.length() > 0.1:
				dir = d.normalized()
		var perp := dir.orthogonal()
		var tip := fp + dir * 8.0
		var bl := fp - dir * 5.0 + perp * 6.0
		var br := fp - dir * 5.0 - perp * 6.0
		var tail := fp - dir * 2.0
		var arrow := PackedVector2Array([tip, bl, tail, br])
		draw_colored_polygon(arrow, col)
		draw_polyline(PackedVector2Array([tip, bl, tail, br, tip]),
			Color(0, 0, 0, 0.55), 1.0)
		# Power at a glance: a stripe (below) per 10 fighters, a star (above) per
		# 10 bombers.
		var nf := 0
		var nb := 0
		for t in 5:
			nf += f.fighters[t]
			nb += f.bombers[t]
		for i in nf / 10:
			var y := fp.y + 9.0 + i * 3.0
			draw_line(Vector2(fp.x - 6, y), Vector2(fp.x + 6, y), Color.WHITE, 1.5)
		for i in nb / 10:
			var c := Vector2(fp.x - 8 + i * 7.0, fp.y - 12.0)
			draw_colored_polygon(PackedVector2Array([
				c + Vector2(0, -3), c + Vector2(3, 0),
				c + Vector2(0, 3), c + Vector2(-3, 0)]), Color(1, 1, 0.4))
		if f.id == selected_fleet_id:
			draw_arc(fp, 10.0, 0.0, TAU, 24, Color.WHITE, 1.5)
			if f.is_moving():
				draw_line(fp, sim.systems[f.path[f.path.size() - 1]].map_pos,
					Color(1, 1, 1, 0.4), 1.0)

	# Hover: a faint ring for feedback + a row of symbols showing what's inside.
	if _hover_system != -1 and sim.systems.has(_hover_system) \
			and _sys_known(_hover_system):
		draw_arc(sim.systems[_hover_system].map_pos, 18.0, 0.0, TAU, 32,
			Color(1, 1, 1, 0.35), 1.0)
		_draw_system_symbols(sim.systems[_hover_system])


# Under a hovered system: one glyph per planet — filled circle = colony (owner
# colour), diamond = uncolonised deposit (blue water / orange minerals), a small
# bright square overlaid = a mine; plus a square for a system supply depot.
# One-line hover readout for the hint area — live detail for a system in sight, the
# frozen last-seen snapshot otherwise (respects fog; no live enemy data in grey).
func _add_ui_tip(ctrl: Control, bbcode: String) -> void:
	_ui_tips.append([ctrl, bbcode])


# Drive the floating hover tooltip: a HUD explainer if the cursor is over a registered
# HUD figure, else a rich node card if it's over a known map node, else hidden. Follows
# the cursor, flipped/clamped so it never runs off-screen.
func _update_tooltip() -> void:
	if _tooltip_panel == null:
		return
	if (intro_overlay != null and intro_overlay.visible) \
			or (legend_panel != null and legend_panel.visible) \
			or (controls_page != null and controls_page.visible):
		_tooltip_panel.visible = false
		return
	var sm := get_viewport().get_mouse_position()
	var txt := ""
	for entry in _ui_tips:
		var c: Control = entry[0]
		if c.visible and c.get_global_rect().has_point(sm):
			txt = entry[1]
			break
	if txt == "" and not _hover_hold and _hover_system != -1 \
			and _sys_known(_hover_system):
		txt = _node_tooltip(_hover_system)
	if txt == "":
		_tooltip_panel.visible = false
		return
	_tooltip_label.text = txt
	_tooltip_panel.visible = true
	_tooltip_panel.reset_size()
	var vp := get_viewport_rect().size
	var sz := _tooltip_panel.size
	var p := sm + Vector2(18.0, 18.0)
	if p.x + sz.x > vp.x:
		p.x = sm.x - sz.x - 14.0
	if p.y + sz.y > vp.y:
		p.y = sm.y - sz.y - 14.0
	_tooltip_panel.position = Vector2(maxf(4.0, p.x), maxf(4.0, p.y))


# Rich (BBCode) hover card for a known map node — name, owner, population, deposit,
# mine, structures, live combat, and whether it's live or last-seen intel.
func _node_tooltip(sid: int) -> String:
	var sys: StarSystem = sim.systems[sid]
	var live := _sys_live(sid)
	var snap: Dictionary = _stale.get(sid, {})
	var lines: Array = ["[b]%s[/b]" % sys.name]
	var owner: int = _system_owner.get(sid, -1) if live else int(snap.get("owner", -1))
	if owner != -1:
		var e: Empire = sim.empires[owner]
		lines.append("[color=#%s]●[/color] %s" % [e.color.to_html(false), e.name])
	else:
		lines.append("[color=#888888]○[/color] unclaimed")
	var pl: Planet = sim.planets[sys.planet_ids[0]]
	if pl.deposit_type == SimConstants.Deposit.WATER:
		lines.append("Deposit: [color=#88bbff]Water[/color]")
	elif pl.deposit_type == SimConstants.Deposit.MINERAL:
		lines.append("Deposit: [color=#d0a060]Minerals[/color]")
	if live:
		var c: Colony = pl.colony
		if c != null:
			var st := "city" if c.established else "colony · %d%% to activation" \
				% int(c.activation_progress() * 100.0)
			lines.append("Population: [b]%.0f[/b]  ([i]%s[/i])" % [c.population, st])
		if pl.has_mine():
			lines.append("Mine: %s (L%d)" % [sim.empires[pl.mine_empire_id].name,
				pl.mine_level + 1])
		var structs: Array = []
		if sys.depot_empire_id != -1:
			structs.append("supply depot")
		if sys.obs_post_empire_id != -1:
			structs.append("observation post")
		if sys.transport_empire_id != -1:
			structs.append("transport hub")
		if not structs.is_empty():
			lines.append("Structures: %s" % ", ".join(structs))
		var kind: int = sim.combat_kind.get(sid, -1)
		if kind == 0:
			lines.append("[color=#ff6644]⚔ battle in progress[/color]")
		elif kind == 1:
			lines.append("[color=#ffcc44]☄ under bombardment[/color]")
		lines.append("[color=#7a8a99][i]in your view[/i][/color]")
	else:
		if snap.get("planets", {}).get(sys.planet_ids[0], {}).get("colony", false):
			lines.append("Colony (as last seen)")
		lines.append("[color=#7a8a99][i]out of view — last-seen intel[/i][/color]")
	return "\n".join(lines)


func _hover_summary(sid: int) -> String:
	var sys: StarSystem = sim.systems[sid]
	# Live combat takes over the readout: who's fighting and how strong.
	if _sys_live(sid) and sim.combat_kind.has(sid):
		var powers := sim.fleet_powers_in(sid)
		if sim.combat_kind[sid] == 0:
			var parts: Array = []
			for eid in powers:
				parts.append("%s %.0f⚔" % [sim.empires[eid].name, powers[eid].combat])
			return "%s — BATTLE: %s" % [sys.name, " vs ".join(parts)]
		else:
			var att: int = powers.keys()[0] if not powers.is_empty() else -1
			var an: String = sim.empires[att].name if att != -1 else "?"
			return "%s — %s bombarding the colony" % [sys.name, an]
	if _sys_live(sid):
		var owner: int = _system_owner.get(sid, -1)
		var oname: String = sim.empires[owner].name if owner != -1 else "unclaimed"
		var pop := 0.0
		var colonized := false
		for pid in sys.planet_ids:
			var c: Colony = sim.planets[pid].colony
			if c != null:
				pop += c.population
				colonized = true
		if colonized:
			return "%s — %s · pop %s" % [sys.name, oname, _fmt_num(pop)]
		return "%s — %s · uncolonised" % [sys.name, oname]
	var snap: Dictionary = _stale.get(sid, {})
	var so: int = snap.get("owner", -1)
	var oname2: String = sim.empires[so].name if so != -1 else "unknown"
	return "%s — last seen: %s" % [sys.name, oname2]


func _builder_inbound(planet_id: int) -> bool:
	for b in sim.builders:
		if b.eid == player_empire_id and b.target == planet_id:
			return true
	return false


func _fmt_num(v: float) -> String:
	# Compact big numbers for the status bar (21214 -> "21.2k").
	if v >= 1000.0:
		return "%.1fk" % (v / 1000.0)
	return "%.0f" % v


# Sim day 0 = 1 Jan of START_YEAR; full-day granularity (tenths don't show on the date).
func _fmt_date(total_days: int) -> String:
	if total_days < 0:
		total_days = 0
	var y: int = SimConstants.START_YEAR + total_days / 365
	var doy: int = total_days % 365
	var m := 0
	while m < 11 and doy >= _MONTH_DAYS[m]:
		doy -= _MONTH_DAYS[m]
		m += 1
	return "%02d/%02d/%d" % [doy + 1, m + 1, y]


# Slope of a tracked resource across the rate window (units per day). key: "min" for
# minerals, else the alloy tier index 0-4.
func _rate_of(key: String, tier: int) -> float:
	if _rate_hist.size() < 2:
		return 0.0
	var latest: Dictionary = _rate_hist[-1]
	var oldest: Dictionary = _rate_hist[0]
	var span: float = latest.d - oldest.d
	if span <= 0.0:
		return 0.0
	var newv: float = latest.min if key == "min" else latest.nat[tier]
	var oldv: float = oldest.min if key == "min" else oldest.nat[tier]
	return (newv - oldv) / span


# Colour + sign a per-day rate for the HUD ("+1.4/d" green, "-0.3/d" red, "0.0/d" grey).
# Alloy production is small and fractional, so always show one decimal (k-suffix stays
# one decimal too, e.g. "+1.2k/d").
func _fmt_rate(r: float) -> String:
	var col := "#8a8f99"
	var sign := ""
	if r > 0.05:
		col = "#7fd08a"; sign = "+"
	elif r < -0.05:
		col = "#e0736b"; sign = "-"
	var a := absf(r)
	var mag: String = ("%.1fk" % (a / 1000.0)) if a >= 1000.0 else ("%.1f" % a)
	return "[color=%s]%s%s/d[/color]" % [col, sign, mag]


# One stockpile snapshot per in-game day, feeding the income-rate readout.
func _sample_rates(player: Empire) -> void:
	var di := int(floor(sim.day))
	if di == _last_sample_day:
		return
	_last_sample_day = di
	var adj := PackedFloat32Array()
	for t in 5:
		adj.append(player.nat[t] + player.spent_nat[t])
	_rate_hist.append({"d": float(di), "min": player.minerals, "nat": adj})
	while _rate_hist.size() > 2 and _rate_hist[0].d < float(di) - RATE_WINDOW_DAYS:
		_rate_hist.pop_front()


func _star_color(sid: int) -> Color:
	# Deterministic spectral tint per system so the map reads as varied real stars.
	match sid % 5:
		0: return Color(0.72, 0.83, 1.0)   # blue-white
		1: return Color(1.0, 1.0, 1.0)     # white
		2: return Color(1.0, 0.95, 0.82)   # warm white
		3: return Color(1.0, 0.85, 0.5)    # amber
		_: return Color(1.0, 0.62, 0.42)   # orange-red


# A centered map label with a soft dark drop-shadow, so names lift off the fog/stars
# (depth + readability) instead of blending into the background.
func _draw_name(font: Font, pos: Vector2, text: String, col: Color) -> void:
	draw_string(font, pos + Vector2(1.0, 1.5), text, HORIZONTAL_ALIGNMENT_CENTER, 120,
		12, Color(0.0, 0.0, 0.0, col.a * 0.85))
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, 120, 12, col)


# Water deposit — a teardrop (pointed top, round bulb) with a rim and a highlight glint.
func _draw_water_drop(c: Vector2) -> void:
	var body := Color(0.35, 0.72, 1.0)
	var drop := PackedVector2Array([
		c + Vector2(0.0, -6.0),
		c + Vector2(2.1, -2.4), c + Vector2(3.7, 1.1), c + Vector2(3.0, 3.6),
		c + Vector2(0.0, 4.9),
		c + Vector2(-3.0, 3.6), c + Vector2(-3.7, 1.1), c + Vector2(-2.1, -2.4)])
	draw_colored_polygon(drop, body)
	draw_polyline(PackedVector2Array([drop[0], drop[1], drop[2], drop[3], drop[4],
		drop[5], drop[6], drop[7], drop[0]]), Color(0.85, 0.95, 1.0, 0.7), 1.0)
	draw_circle(c + Vector2(-1.1, 1.4), 1.1, Color(1, 1, 1, 0.8))   # glint


# Mineral deposit — an upright faceted gem (diamond with a lighter top facet + rim).
func _draw_gem(c: Vector2) -> void:
	var top := c + Vector2(0.0, -5.2)
	var rgt := c + Vector2(4.6, -0.6)
	var bot := c + Vector2(0.0, 5.2)
	var lft := c + Vector2(-4.6, -0.6)
	var mrgt := c + Vector2(2.3, -0.6)
	var mlft := c + Vector2(-2.3, -0.6)
	draw_colored_polygon(PackedVector2Array([top, rgt, bot, lft]),
		Color(0.9, 0.58, 0.28))                                    # gem body
	draw_colored_polygon(PackedVector2Array([top, rgt, mrgt, mlft]),
		Color(1.0, 0.78, 0.42))                                    # brighter top-right facet
	draw_polyline(PackedVector2Array([top, rgt, bot, lft, top]),
		Color(1.0, 0.85, 0.55, 0.7), 1.0)
	draw_line(lft, rgt, Color(1.0, 0.85, 0.55, 0.5), 1.0)          # girdle line


func _draw_star(pos: Vector2, col: Color, intensity: float, scale := 1.0) -> void:
	# A luminous body with depth: a wide faint corona, tighter coloured glow layers, a
	# bright core and a hot near-white pip. scale grows it with the system's population.
	# Stacked translucent discs read as volume; MSAA keeps every edge crisp.
	var corona := col
	corona.a = 0.06 * intensity
	draw_circle(pos, 20.0 * scale, corona)          # outer haze — the "reach" of the light
	corona.a = 0.10 * intensity
	draw_circle(pos, 13.0 * scale, corona)
	var g := col
	for i in 3:                                       # coloured glow falloff
		g.a = (0.14 + i * 0.10) * intensity
		draw_circle(pos, (9.0 - i * 2.4) * scale, g)
	var core := col.lerp(Color.WHITE, 0.55)
	core.a = 0.7 + 0.3 * intensity
	draw_circle(pos, (3.6 + 0.8 * intensity) * scale, core)
	var pip := Color(1, 1, 1, 0.85 * intensity)      # hot white centre for a sharp glint
	draw_circle(pos, (1.4 + 0.4 * intensity) * scale, pip)


func _draw_system_symbols(sys: StarSystem) -> void:
	# Live systems show current contents; explored-but-out-of-VR systems show only
	# the frozen snapshot (colonies/mines as last seen — no colonies built after you
	# left, no live owner changes). Deposits are static, so they're always shown.
	var live := _sys_live(sys.id)
	var snap: Dictionary = _stale.get(sys.id, {})
	var snap_planets: Dictionary = snap.get("planets", {})
	var pids: Array = sys.planet_ids
	var depot_owner: int = sys.depot_empire_id if live else snap.get("depot", -1)
	var n := pids.size() + (1 if depot_owner != -1 else 0)
	var step := 15.0
	var start := sys.map_pos + Vector2(-(n - 1) * step * 0.5, 30.0)
	var i := 0
	for pid in pids:
		var p: Planet = sim.planets[pid]
		var c := start + Vector2(i * step, 0)
		# Dynamic bits (colony, mine) come from the snapshot when not live.
		var pinfo: Dictionary = snap_planets.get(pid, {})
		var has_colony: bool = (p.colony != null) if live else pinfo.get("colony", false)
		var colony_owner: int = (p.colony.empire_id if p.colony != null else -1) \
			if live else pinfo.get("colony_owner", -1)
		var established: bool = (p.colony != null and p.colony.established) if live \
			else pinfo.get("established", false)
		var has_mine: bool = p.has_mine() if live else pinfo.get("mine", false)
		var mine_owner: int = p.mine_empire_id if live else pinfo.get("mine_owner", -1)
		if has_colony and colony_owner != -1:
			# Colony: filled owner-colour disc with a dark rim for contrast; a white
			# ring means it's still growing (not yet an established city).
			draw_circle(c, 6.0, Color(0, 0, 0, 0.5))
			draw_circle(c, 5.0, sim.empires[colony_owner].color)
			if not established:
				draw_arc(c, 5.0, 0.0, TAU, 16, Color(1, 1, 1, 0.7), 1.0)
		elif p.has_deposit():
			# Shape-coded so each reads without relying on colour: water = a teardrop,
			# minerals = a faceted gem.
			if p.deposit_type == SimConstants.Deposit.WATER:
				_draw_water_drop(c)
			else:
				_draw_gem(c)
		else:
			draw_circle(c, 2.5, Color(0.5, 0.5, 0.55))
		if has_mine and mine_owner != -1:
			# Mine: bracketed square in the owner's colour over the planet glyph.
			draw_rect(Rect2(c + Vector2(-3.5, -3.5), Vector2(7, 7)),
				sim.empires[mine_owner].color, false, 1.5)
		i += 1
	if depot_owner != -1:
		var dcpos := start + Vector2(i * step, 0)
		draw_rect(Rect2(dcpos + Vector2(-4, -4), Vector2(8, 8)),
			sim.empires[depot_owner].color)


# --- generated tier icons (the fallback font has no dice/numeral glyphs) -------------
# A tier badge: a rounded square in the tier's colour with dice-face pips (1-5) so the
# tier reads as a little icon, not "T1". Built once and cached in _tier_icons.
func _build_tier_icons() -> void:
	_tier_icons.clear()
	for t in range(1, 6):
		_tier_icons.append(_make_tier_icon(t))


func _tier_hue(tier: int) -> Color:
	match tier:
		1: return Color(0.72, 0.52, 0.32)   # bronze
		2: return Color(0.72, 0.76, 0.82)   # silver
		3: return Color(0.95, 0.78, 0.35)   # gold
		4: return Color(0.42, 0.8, 0.98)    # cyan
		_: return Color(0.82, 0.5, 1.0)     # violet


func _dice_pips(tier: int) -> Array:
	var a := 0.3
	var b := 0.5
	var c := 0.7
	match tier:
		1: return [Vector2(b, b)]
		2: return [Vector2(a, a), Vector2(c, c)]
		3: return [Vector2(a, a), Vector2(b, b), Vector2(c, c)]
		4: return [Vector2(a, a), Vector2(c, a), Vector2(a, c), Vector2(c, c)]
		_: return [Vector2(a, a), Vector2(c, a), Vector2(b, b), Vector2(a, c), Vector2(c, c)]


func _make_tier_icon(tier: int) -> ImageTexture:
	var s := 26
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var hue := _tier_hue(tier)
	var bg := hue.darkened(0.4)
	var edge := hue.lightened(0.15)
	var m := 2.0
	var rad := 6.0
	var lo := Vector2(m + rad, m + rad)
	var hi := Vector2(s - m - rad, s - m - rad)
	for y in s:
		for x in s:
			var pt := Vector2(x + 0.5, y + 0.5)
			var q := Vector2(clampf(pt.x, lo.x, hi.x), clampf(pt.y, lo.y, hi.y))
			var d := pt.distance_to(q)
			if d <= rad:
				img.set_pixel(x, y, edge if d > rad - 1.4 else bg)   # rim + fill
	for p in _dice_pips(tier):
		_fill_disc(img, p.x * s, p.y * s, s * 0.088, Color(1, 1, 1, 0.96))
	return ImageTexture.create_from_image(img)


func _fill_disc(img: Image, cx: float, cy: float, r: float, col: Color) -> void:
	var r2 := r * r
	for y in range(maxi(0, int(cy - r)), mini(img.get_height(), int(cy + r) + 1)):
		for x in range(maxi(0, int(cx - r)), mini(img.get_width(), int(cx + r) + 1)):
			var dx := x + 0.5 - cx
			var dy := y + 0.5 - cy
			if dx * dx + dy * dy <= r2:
				img.set_pixel(x, y, col)


# A thin vertical divider between HUD groups in the top bar.
func _bar_sep() -> VSeparator:
	var s := VSeparator.new()
	s.modulate = Color(1, 1, 1, 0.25)
	return s


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var top := PanelContainer.new()
	top_bar = top
	UiStyle.make_opaque_bar(top)   # solid bg so the small resource figures read over the map
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	# Keep the top-left hint / event labels just under the bar's real bottom (its height
	# depends on the resource text), so they never tuck under the now-opaque bar.
	top.resized.connect(_dock_top_labels)
	layer.add_child(top)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 24)
	top.add_child(bar)

	# Ordered groups, thin separators between: Day | gather (water/minerals) | alloys |
	# your standing. Colour-coded; the per-figure detail lives in the hover tooltip.
	day_label = Label.new()
	day_label.modulate = Color(1, 1, 1, 0.9)
	raw_label = Label.new()                        # what you GATHER
	raw_label.modulate = Color(0.7, 0.86, 1.0)     # cool blue
	goods_label = RichTextLabel.new()              # what you REFINE (alloy tiers, w/ icons)
	goods_label.bbcode_enabled = true
	goods_label.fit_content = true
	goods_label.scroll_active = false
	goods_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	goods_label.custom_minimum_size = Vector2(430, 0)
	goods_label.add_theme_font_size_override("normal_font_size", 14)
	standing_label = Label.new()
	standing_label.modulate = Color(1, 1, 1, 0.7)
	bar.add_child(day_label)
	bar.add_child(_bar_sep())
	bar.add_child(raw_label)
	bar.add_child(_bar_sep())
	bar.add_child(goods_label)
	bar.add_child(_bar_sep())
	bar.add_child(standing_label)
	# Paradox-style explainers: hovering a figure opens a window on what it is and how the
	# mechanic works. (Map-node hover is handled in _update_tooltip.)
	_add_ui_tip(raw_label, "[b]Water[/b]\n[color=#88bbff]Water[/color] is your population's lifeblood — a [i]flow[/i], not a stockpile. The number is your net per day: water your mines produce minus what your people need. Population grows while it's positive, shrinks while negative; you can't bank a surplus, so pop settles at the level your water territory supports. Hold more water worlds to raise that ceiling.")
	_add_ui_tip(goods_label, "[b]Minerals & alloys — amount over income[/b]\nEach column shows the [i]stockpile[/i] with its per-day income below (averaged over the last %d days; [color=#7fd08a]green[/color] rising, [color=#e0736b]red[/color] falling). Building ships or structures does [i]not[/i] count against income — the rate is production only.\n\n[color=#d0a060]Minerals[/color] are the mined raw. They refine into [color=#aaffaa]tier-1 alloy[/color], each higher tier from the one below, and only bigger cities reach the higher tiers — a pyramid (lots of T1, very few T5). Tier 1 also pays for construction; a ship of tier N costs tier-N alloy. Tiers 3+ need you to mine BOTH water and minerals." % int(RATE_WINDOW_DAYS))

	hint_label = Label.new()
	hint_label.modulate = Color(1, 1, 1, 0.5)
	hint_label.position = Vector2(16.0, 40.0)
	layer.add_child(hint_label)

	event_label = Label.new()
	event_label.position = Vector2(16.0, 64.0)
	event_label.add_theme_font_size_override("font_size", 12)
	event_label.modulate = Color(1, 0.9, 0.7, 0.85)
	layer.add_child(event_label)

	# Floating hover tooltip (Paradox-style). Raised above the HUD via z_index; never
	# eats mouse input so it can't block clicks or its own hover target.
	_tooltip_panel = PanelContainer.new()
	_tooltip_panel.visible = false
	_tooltip_panel.z_index = 200
	_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tsb := StyleBoxFlat.new()
	tsb.bg_color = Color(0.07, 0.08, 0.11, 0.97)
	tsb.border_color = Color(0.45, 0.55, 0.75, 0.7)
	tsb.set_border_width_all(1)
	tsb.set_corner_radius_all(5)
	tsb.set_content_margin_all(9)
	tsb.shadow_color = Color(0, 0, 0, 0.5)
	tsb.shadow_size = 6
	_tooltip_panel.add_theme_stylebox_override("panel", tsb)
	_tooltip_label = RichTextLabel.new()
	_tooltip_label.bbcode_enabled = true
	_tooltip_label.fit_content = true
	_tooltip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tooltip_label.custom_minimum_size = Vector2(300, 0)
	_tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_label.add_theme_font_size_override("normal_font_size", 13)
	_tooltip_panel.add_child(_tooltip_label)
	layer.add_child(_tooltip_panel)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	for i in SPEEDS.size():
		var b := Button.new()
		b.text = "Pause" if i == 0 else "%dx" % int(SPEEDS[i])
		b.toggle_mode = true
		b.pressed.connect(func() -> void: speed_idx = i)
		bar.add_child(b)
		speed_buttons.append(b)

	var menu_btn := Button.new()
	menu_btn.text = "Menu"
	menu_btn.pressed.connect(_toggle_menu)
	bar.add_child(menu_btn)

	panel = PanelContainer.new()
	UiStyle.make_opaque(panel)   # solid bg so it never shows the shipyard/map through it
	layer.add_child(panel)
	# Docked to the right edge, BELOW the top-right shipyard panel and down to just above
	# the bottom — a fixed lane of its own, so the selection readout can never overlap the
	# shipyard's helper text (it used to float around vertical center and collide with it).
	# offset_bottom hugs the floor; offset_top is a sane fallback that _dock_selection_panel
	# overrides with the shipyard's real bottom once it lays out.
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -292.0
	panel.offset_right = -12.0
	panel.offset_top = 340.0
	panel.offset_bottom = -12.0
	# A ScrollContainer so a content-heavy colony (planet list + long body + many action
	# buttons) scrolls inside the docked lane instead of running its lowest buttons off the
	# bottom of the screen. Horizontal scroll off — the panel width is fixed.
	var panel_scroll := ScrollContainer.new()
	panel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(panel_scroll)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	panel_scroll.add_child(vbox)
	panel_title = Label.new()
	planet_list = VBoxContainer.new()   # one selectable row per planet
	planet_list.add_theme_constant_override("separation", 2)
	panel_body = Label.new()            # detail for the selected planet / fleet
	panel_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	colonize_btn = Button.new()
	colonize_btn.text = "Found colony (%d alloys)" % int(SimConstants.FOUND_COST_ALLOYS)
	colonize_btn.pressed.connect(_on_colonize)
	mine_btn = Button.new()
	mine_btn.text = "Build mine (%d alloys)" % int(SimConstants.MINE_COST_ALLOYS)
	mine_btn.pressed.connect(_on_build_mine)
	emigrate_btn = Button.new()
	emigrate_btn.pressed.connect(_on_emigrate)
	merge_btn = Button.new()
	merge_btn.text = "Merge fleets here"
	merge_btn.pressed.connect(_on_merge)
	split_btn = Button.new()
	split_btn.text = "Split fleet"
	split_btn.pressed.connect(_on_split)
	spec_food_btn = Button.new()
	spec_food_btn.pressed.connect(func() -> void: _on_spec(SimConstants.Spec.FOOD))
	spec_alloy_btn = Button.new()
	spec_alloy_btn.pressed.connect(func() -> void: _on_spec(SimConstants.Spec.ALLOY))
	upgrade_btn = Button.new()
	upgrade_btn.pressed.connect(_on_upgrade_mine)
	depot_btn = Button.new()
	depot_btn.pressed.connect(_on_build_depot)
	obs_post_btn = Button.new()
	obs_post_btn.pressed.connect(_on_build_obs_post)
	transport_btn = Button.new()
	transport_btn.pressed.connect(_on_build_transport)
	vbox.add_child(panel_title)
	vbox.add_child(planet_list)
	vbox.add_child(panel_body)
	vbox.add_child(colonize_btn)
	vbox.add_child(mine_btn)
	vbox.add_child(upgrade_btn)
	vbox.add_child(emigrate_btn)
	vbox.add_child(spec_food_btn)
	vbox.add_child(spec_alloy_btn)
	vbox.add_child(depot_btn)
	vbox.add_child(obs_post_btn)
	vbox.add_child(transport_btn)
	vbox.add_child(merge_btn)
	vbox.add_child(split_btn)

	_build_ship_panel(layer)
	_build_menu_overlay(layer)
	_build_legend(layer)
	_build_controls_panel(layer)
	_build_intro(layer)


# One-time welcome for a new game: what this game is and the first things to do.
# Shown paused; dismissed with Begin. Not shown on a loaded save or the autoshot.
func _build_intro(layer: CanvasLayer) -> void:
	intro_overlay = PanelContainer.new()
	UiStyle.make_opaque(intro_overlay)
	intro_overlay.set_anchors_preset(Control.PRESET_CENTER)
	intro_overlay.anchor_left = 0.5
	intro_overlay.anchor_right = 0.5
	intro_overlay.anchor_top = 0.5
	intro_overlay.anchor_bottom = 0.5
	intro_overlay.offset_left = -270
	intro_overlay.offset_right = 270
	intro_overlay.offset_top = -160
	intro_overlay.offset_bottom = 160
	intro_overlay.visible = false
	layer.add_child(intro_overlay)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	intro_overlay.add_child(v)
	var title := Label.new()
	title.text = "Welcome, cultivator"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	v.add_child(title)
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(520, 0)
	body.text = "You have no body and no direct control — you cultivate a population and it does the rest.\n\n• Click a planet to open it. Send a construction vessel to found a colony or build a mine — it travels the lanes from your capital and can't cross enemy space.\n• Population lives on WATER: your water mines feed it directly, and it's a flow, not a stockpile — grow only as far as your water income supports, or it shrinks. Population drives influence, and influence sets your borders.\n• Minerals refine up a single alloy chain (T1→T5): small cities make lots of cheap T1 (which also pays for building), big cities reach the rare high tiers. High tiers need both water and mineral mines.\n• Build ships (top-right) to defend and to bombard enemy worlds. Use the speed dial (top-right) to skip slow stretches.\n• Press L for a legend of every map symbol.\n\nGoal: grow, spread, and outlast the rival empires."
	v.add_child(body)
	var begin := Button.new()
	begin.text = "Begin"
	begin.custom_minimum_size = Vector2(0, 38)
	begin.pressed.connect(func() -> void:
		intro_overlay.visible = false
		speed_idx = 1)
	v.add_child(begin)


# A bottom-left key explaining the map symbols/colours. Hidden by default, toggled
# with L (the hint line advertises it). Plain text — clear without needing icons.
func _build_legend(layer: CanvasLayer) -> void:
	legend_panel = PanelContainer.new()
	UiStyle.make_opaque(legend_panel)
	legend_panel.anchor_top = 1.0
	legend_panel.anchor_bottom = 1.0
	legend_panel.offset_left = 12.0
	legend_panel.offset_top = -232.0
	legend_panel.offset_bottom = -60.0
	legend_panel.visible = false
	layer.add_child(legend_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	legend_panel.add_child(v)
	var lines := [
		"[ LEGEND ]  (L to hide)",
		"star glow — a system (colour = star type)",
		"ring round star — controlling empire",
		"number by star — colonies there",
		"arrow — fleet;  — stripe = 10 fighters",
		"   ◆ above = 10 bombers",
		"bright = in sight · dim = last-seen · black = unknown",
		"bold coloured line — contested border",
		"hover a system for its planets",
		"● colony  ◆ mineral  ○ water  ▫ mine",
		"□ depot  ◉ obs-post (2x reach)  ⌃ transport",
		"purple nebula — anomaly (blocks influence + sight)",
	]
	for i in lines.size():
		var l := Label.new()
		l.text = lines[i]
		l.add_theme_font_size_override("font_size", 11)
		l.modulate = Color(1, 1, 1, 0.85) if i == 0 else Color(1, 1, 1, 0.6)
		v.add_child(l)


# The rebindable key-binding page. Toggled with K or from the pause menu; the same
# component (menu/controls_page.gd) also backs the main-menu Options button, so the two
# stay identical and share the Keybinds store.
func _build_controls_panel(layer: CanvasLayer) -> void:
	controls_page = ControlsPageScript.new()
	controls_page.visible = false
	layer.add_child(controls_page)


func _build_menu_overlay(layer: CanvasLayer) -> void:
	menu_overlay = PanelContainer.new()
	UiStyle.make_opaque(menu_overlay)
	menu_overlay.set_anchors_preset(Control.PRESET_CENTER)
	menu_overlay.anchor_left = 0.5
	menu_overlay.anchor_right = 0.5
	menu_overlay.anchor_top = 0.5
	menu_overlay.anchor_bottom = 0.5
	menu_overlay.offset_left = -150
	menu_overlay.offset_right = 150
	menu_overlay.offset_top = -160
	menu_overlay.offset_bottom = 160
	menu_overlay.visible = false
	layer.add_child(menu_overlay)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	menu_overlay.add_child(v)
	overlay_title = Label.new()
	overlay_title.text = "Paused"
	overlay_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_title.add_theme_font_size_override("font_size", 28)
	v.add_child(overlay_title)
	overlay_resume = Button.new()
	overlay_resume.text = "Resume"
	overlay_resume.pressed.connect(func() -> void:
		menu_overlay.visible = false
		speed_idx = _speed_before_menu)
	v.add_child(overlay_resume)
	overlay_save = Button.new()
	overlay_save.text = "Save game"
	overlay_save.pressed.connect(func() -> void:
		save_game()
		overlay_save.text = "Saved!")
	v.add_child(overlay_save)
	var controls_btn := Button.new()
	controls_btn.text = "Controls"
	controls_btn.pressed.connect(func() -> void:
		menu_overlay.visible = false
		speed_idx = _speed_before_menu
		if controls_page != null:
			controls_page.open())
	v.add_child(controls_btn)
	var quit := Button.new()
	quit.text = "Quit to menu"
	quit.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://menu/menu.tscn"))
	v.add_child(quit)

	# --- self-update (installed Windows build only) ---
	var sep := HSeparator.new()
	v.add_child(sep)
	var ver := Label.new()
	ver.text = "Reach v%s" % UpdaterScript.CURRENT
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ver.modulate = Color(1, 1, 1, 0.5)
	ver.add_theme_font_size_override("font_size", 11)
	v.add_child(ver)
	_updater = UpdaterScript.new()
	add_child(_updater)
	_updater.check_done.connect(_on_update_check_done)
	_updater.apply_started.connect(func() -> void:
		overlay_update_status.text = "Downloading update…"
		overlay_update_apply.disabled = true
		overlay_update_btn.disabled = true)
	_updater.apply_failed.connect(func(msg: String) -> void:
		overlay_update_status.text = "Update failed: %s" % msg
		overlay_update_btn.disabled = false)
	overlay_update_btn = Button.new()
	overlay_update_btn.text = "Check for updates"
	overlay_update_btn.pressed.connect(func() -> void:
		overlay_update_status.text = "Checking…"
		overlay_update_btn.disabled = true
		_updater.check_for_update())
	v.add_child(overlay_update_btn)
	overlay_update_apply = Button.new()
	overlay_update_apply.text = "Update & restart"
	overlay_update_apply.visible = false
	overlay_update_apply.pressed.connect(func() -> void: _updater.apply_update())
	v.add_child(overlay_update_apply)
	overlay_update_status = Label.new()
	overlay_update_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_update_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overlay_update_status.custom_minimum_size = Vector2(280, 0)
	overlay_update_status.modulate = Color(1, 1, 1, 0.7)
	overlay_update_status.add_theme_font_size_override("font_size", 11)
	v.add_child(overlay_update_status)


func _on_update_check_done(available: bool, latest: String, note: String) -> void:
	overlay_update_btn.disabled = false
	overlay_update_apply.visible = available
	if available:
		overlay_update_status.text = "Update available: v%s" % latest
	else:
		overlay_update_status.text = note


# Top-right shipyard: a Fighter and Bomber build button per tier 1-5. Each click
# builds one ship at the empire's most-populated city; a button is enabled only
# when that tier's national resource can pay for it.
func _build_ship_panel(layer: CanvasLayer) -> void:
	var sp := PanelContainer.new()
	ship_panel = sp
	UiStyle.make_opaque(sp)   # solid bg so the map doesn't bleed through the tier note
	sp.anchor_left = 1.0
	sp.anchor_right = 1.0
	sp.offset_left = -232.0
	sp.offset_right = -12.0
	sp.offset_top = 40.0
	# Dock the selection panel just under the shipyard's ACTUAL bottom, and keep it there
	# if the shipyard ever re-lays-out (font/DPI change) — no brittle hard-coded height.
	sp.resized.connect(_dock_selection_panel)
	layer.add_child(sp)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	sp.add_child(box)
	var head := Label.new()
	head.text = "Build ships — by tier"
	head.modulate = Color(1, 1, 1, 0.7)
	box.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 3)
	box.add_child(grid)
	for s in ["Fighter", "Bomber"]:
		var h := Label.new()
		h.text = s
		h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		grid.add_child(h)
	# One row per tier. The tier reads from the button's icon (a dice-pip badge), so no
	# "T1..T5" text; the column header gives the role.
	for t in range(1, 6):
		var fb := Button.new()
		fb.icon = _tier_icons[t - 1]
		fb.text = "  Fighter"
		fb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fb.pressed.connect(func() -> void:
			_build_ships(SimConstants.Role.FIGHTER, t, _build_count_from_mods()))
		grid.add_child(fb)
		ship_f_btns.append(fb)
		var bb := Button.new()
		bb.icon = _tier_icons[t - 1]
		bb.text = "  Bomber"
		bb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bb.pressed.connect(func() -> void:
			_build_ships(SimConstants.Role.BOMBER, t, _build_count_from_mods()))
		grid.add_child(bb)
		ship_b_btns.append(bb)
	# Clarify what ships are paid with — the tier's ALLOY (shown in the top bar).
	var note := Label.new()
	note.text = "Each ship costs %d of that tier's alloy (top bar).\nShift = build ×10, Ctrl = ×100.  Hotkeys 1-5 Fighter, 6-0 Bomber.\nHigh tiers (tier %d+) need BOTH water & mineral mines." \
		% [int(SimConstants.SHIP_NAT_COST), SimConstants.VARIETY_MIN_TIER + 1]
	note.add_theme_font_size_override("font_size", 10)
	note.modulate = Color(1, 1, 1, 0.5)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(note)


# Keep the right-edge selection panel docked just below the shipyard's real bottom, so the
# two never overlap regardless of font/DPI (the shipyard's height isn't hard-coded here).
func _dock_selection_panel() -> void:
	if panel == null or ship_panel == null:
		return
	panel.offset_top = ship_panel.offset_top + ship_panel.size.y + 12.0


# Park the top-left hint + event feed just below the top bar's real bottom, so they clear
# the (now opaque) bar regardless of its height.
func _dock_top_labels() -> void:
	if top_bar == null:
		return
	var y := top_bar.size.y + 6.0
	if hint_label != null:
		hint_label.position = Vector2(16.0, y)
	if event_label != null:
		event_label.position = Vector2(16.0, y + 24.0)


func _on_colonize() -> void:
	# Dispatch a construction vessel from the capital (it travels lanes, can't cross
	# enemy territory, and founds the colony on arrival).
	if selected_planet_id != -1:
		sim.order_construction(player_empire_id, SimConstants.Build.COLONY,
			selected_planet_id)


func _on_build_mine() -> void:
	if selected_planet_id != -1:
		sim.order_construction(player_empire_id, SimConstants.Build.MINE,
			selected_planet_id)


func _on_emigrate() -> void:
	if selected_planet_id != -1:
		sim.toggle_emigration(player_empire_id, selected_planet_id)


func _on_spec(kind: int) -> void:
	if selected_planet_id != -1:
		var c: Colony = sim.planets[selected_planet_id].colony
		# Toggle off if pressing the active one, else set it.
		if c != null and c.spec == kind:
			sim.set_specialization(player_empire_id, selected_planet_id,
				SimConstants.Spec.NONE)
		else:
			sim.set_specialization(player_empire_id, selected_planet_id, kind)


func _on_upgrade_mine() -> void:
	if selected_planet_id != -1:
		sim.upgrade_mine(player_empire_id, selected_planet_id)


func _on_build_depot() -> void:
	if view_system_id != -1:
		sim.build_depot(player_empire_id, view_system_id)


func _on_build_obs_post() -> void:
	if view_system_id != -1:
		sim.build_obs_post(player_empire_id, view_system_id)


func _on_build_transport() -> void:
	if view_system_id != -1:
		sim.build_transport(player_empire_id, view_system_id)


func _on_merge() -> void:
	if selected_fleet_id != -1:
		sim.merge_fleets_into(selected_fleet_id)


func _on_split() -> void:
	if selected_fleet_id != -1:
		var g := sim.split_fleet(selected_fleet_id)
		if g != null:
			selected_fleet_id = g.id


# Rebuild the per-planet selectable rows for the open system.
func _rebuild_planet_list(sys_id: int) -> void:
	for row in _planet_rows:
		(row[0] as Button).queue_free()
	_planet_rows.clear()
	for pid in sim.systems[sys_id].planet_ids:
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func() -> void: selected_planet_id = pid)
		planet_list.add_child(b)
		_planet_rows.append([b, pid])


func _planet_row_text(planet: Planet, live: bool, pinfo: Dictionary) -> String:
	var tag := planet.name
	if live:
		if planet.colony != null:
			tag += "  ● %.0f%s" % [planet.colony.population,
				"" if planet.colony.established else " (growing)"]
		elif planet.has_deposit():
			tag += "  ◆ %s" % ["", "water", "minerals"][planet.deposit_type]
	else:
		# Frozen: colony existence only (no population), else the static deposit.
		if pinfo.get("colony", false):
			tag += "  ●"
		elif planet.has_deposit():
			tag += "  ◆ %s" % ["", "water", "minerals"][planet.deposit_type]
	return tag


# Read-only detail for a planet in an explored-but-out-of-sight system: static
# deposit plus the frozen last-seen colony/mine — no population, no live changes.
func _show_planet_frozen(planet: Planet, pinfo: Dictionary) -> void:
	for b in [colonize_btn, mine_btn, emigrate_btn, upgrade_btn, spec_food_btn,
			spec_alloy_btn]:
		b.visible = false
	var dep_name: String = ["none", "water", "minerals"][planet.deposit_type]
	var lines := "Deposit: %s" % dep_name
	if pinfo.get("colony", false):
		var co: int = pinfo.get("colony_owner", -1)
		var oname: String = sim.empires[co].name if co != -1 else "unknown"
		var kind: String = "established city" if pinfo.get("established", false) \
			else "young colony"
		lines += "\nColony: %s (%s)" % [oname, kind]
	if pinfo.get("mine", false):
		var mo: int = pinfo.get("mine_owner", -1)
		var mname: String = sim.empires[mo].name if mo != -1 else "unknown"
		lines += "\nMine: %s (L%d)" % [mname, int(pinfo.get("mine_level", 1))]
	panel_body.text = "%s\n\n— out of sight; last-seen intel —" % lines


func _refresh_ui() -> void:
	var player: Empire = sim.empires[player_empire_id]
	# Water is a flow (income vs population demand, per day — never banked); minerals are
	# the one banked raw; the five alloy tiers are the refined goods (T1 also builds).
	_sample_rates(player)
	var w_in: float = player.water_income / SimConstants.TICK_DAYS
	var w_need: float = player.water_demand / SimConstants.TICK_DAYS
	raw_label.text = "Water %+.0f/day" % [w_in - w_need]   # a flow — no stockpile
	# Minerals + the five alloy tiers as a 2-row grid: amount over its income rate
	# (per-day slope, production only). A table keeps the rate aligned under each amount.
	goods_label.clear()
	goods_label.push_table(6)
	# Row 1 — amounts (minerals as text, tiers with their badge icons).
	goods_label.push_cell(); goods_label.append_text("Min %s" % _fmt_num(player.minerals)); goods_label.pop()
	for t in 5:
		goods_label.push_cell()
		goods_label.add_image(_tier_icons[t], 14, 14)
		goods_label.append_text(" %s" % _fmt_num(player.nat[t]))
		goods_label.pop()
	# Row 2 — the matching income rates.
	goods_label.push_cell(); goods_label.append_text(_fmt_rate(_rate_of("min", 0))); goods_label.pop()
	for t in 5:
		goods_label.push_cell(); goods_label.append_text(_fmt_rate(_rate_of("nat", t))); goods_label.pop()
	goods_label.pop()   # table
	day_label.text = _fmt_date(int(floor(sim.day)))
	# Player's own standing (no fog concern — it's your empire): systems / pop /
	# colonies, so you can gauge where you stand without counting the map.
	var psys := 0
	for sid in _system_owner:   # cached each border refresh — no per-frame recompute
		if _system_owner[sid] == player_empire_id:
			psys += 1
	var ppop := 0.0
	var pcol := 0
	for c in sim.colonies:
		if c.empire_id == player_empire_id:
			ppop += c.population
			pcol += 1
	standing_label.text = "◆ Worlds %d · Pop %s · Colonies %d" \
		% [psys, _fmt_num(ppop), pcol]
	for i in speed_buttons.size():
		speed_buttons[i].button_pressed = (i == speed_idx)
	for t in 5:   # enable ship buttons only for tiers the player can pay for
		var affordable := sim.can_build_ship(player_empire_id, t + 1)
		ship_f_btns[t].disabled = not affordable
		ship_b_btns[t].disabled = not affordable

	var fleet: Fleet = sim.get_fleet(selected_fleet_id) if selected_fleet_id != -1 \
		else null
	if fleet != null:
		hint_label.text = "Click a planet to send the fleet · Esc to deselect"
		_show_fleet_panel(fleet)
		return
	if view_system_id != -1 and sim.systems.has(view_system_id):
		hint_label.text = "Planet actions · Esc to close"
		_show_system_panel(view_system_id)
		return
	# Node details now live in the hover tooltip (near the cursor); the hint line just
	# reminds the controls.
	hint_label.text = "Hover for details · right-drag pan · wheel zoom · click to open · L: legend"
	panel.visible = false
	_panel_system = -1


# A who-vs-who battle readout for a system: every belligerent by name and combat
# power (yours first, marked), then a plain-language verdict of how it's going for you.
# Text-only (the panel is a plain Label), so it reads clearly without colour.
func _battle_readout(sid: int, my_eid: int) -> String:
	var powers := sim.fleet_powers_in(sid)
	var mine: float = powers[my_eid].combat if powers.has(my_eid) else 0.0
	var enemy := 0.0
	var lines: Array = ["⚔ BATTLE at %s" % sim.systems[sid].name]
	lines.append("   you: %.0f⚔" % mine)
	for eid in powers:
		if eid == my_eid:
			continue
		enemy += powers[eid].combat
		lines.append("   %s: %.0f⚔" % [sim.empires[eid].name, powers[eid].combat])
	lines.append("   → %s" % _battle_verdict(mine, enemy))
	return "\n".join(lines)


# Plain-language read on a fleet fight from the player's side, by power ratio.
func _battle_verdict(mine: float, enemy: float) -> String:
	if mine <= 0.0:
		return "your fleet is spent"
	if enemy <= 0.0:
		return "enemy broken — mopping up"
	var r := mine / enemy
	if r >= 3.0:
		return "crushing them — near-instant"
	if r >= 1.5:
		return "winning clearly"
	if r >= 1.1:
		return "upper hand"
	if r >= 0.9:
		return "evenly matched — a grind"
	if r >= 0.5:
		return "outgunned — losing ground"
	return "being overwhelmed — retreat?"


func _show_fleet_panel(fleet: Fleet) -> void:
	panel.visible = true
	planet_list.visible = false
	_panel_system = -1
	panel_title.text = "Fleet"
	var loc: String = sim.systems[fleet.system_id].name
	var comp := ""
	for t in 5:
		if fleet.fighters[t] > 0:
			comp += "F%d×%d  " % [t + 1, fleet.fighters[t]]
		if fleet.bombers[t] > 0:
			comp += "B%d×%d  " % [t + 1, fleet.bombers[t]]
	if comp == "":
		comp = "(empty)"
	# Combat status: a full who-vs-who readout with a verdict, plus the pin state so
	# you know whether this fleet is locked in the fight or free to move.
	var combat_line := ""
	if not fleet.is_moving():
		var pin := sim.fleet_pin(fleet)
		if pin == 2:   # enemy fleet present — a live battle
			combat_line = "\n\n" + _battle_readout(fleet.system_id, fleet.empire_id)
			combat_line += "\n🔒 held in the fight — no jump until it's decided"
		elif pin == 1:   # over an enemy world, no enemy fleet — bombarding
			combat_line = "\n\n☄ bombarding the enemy world here"
			if fleet.prev_system != -1 and sim.systems.has(fleet.prev_system):
				combat_line += "\n⚓ pinned — can only fall back to %s" \
					% sim.systems[fleet.prev_system].name
	panel_body.text = "At: %s%s\nCombat %.0f · Bomb %.0f\n%s%s" % [loc,
		"  → moving" if fleet.is_moving() else "",
		fleet.combat_power(), fleet.bomb_power(), comp, combat_line]
	for b in [colonize_btn, mine_btn, emigrate_btn, upgrade_btn, spec_food_btn,
			spec_alloy_btn, depot_btn, obs_post_btn, transport_btn]:
		b.visible = false
	merge_btn.visible = true
	merge_btn.disabled = fleet.is_moving() or not _another_fleet_here(fleet)
	split_btn.visible = true
	split_btn.disabled = fleet.is_moving() or fleet.ship_count() < 2


func _another_fleet_here(fleet: Fleet) -> bool:
	for f in sim.fleets:
		if f != fleet and f.empire_id == fleet.empire_id and not f.is_moving() \
				and f.system_id == fleet.system_id:
			return true
	return false


func _show_system_panel(sys_id: int) -> void:
	panel.visible = true
	planet_list.visible = false   # one planet per node — shown directly, no list
	merge_btn.visible = false
	split_btn.visible = false
	panel_title.text = sim.systems[sys_id].name
	if _panel_system != sys_id:
		_rebuild_planet_list(sys_id)
		_panel_system = sys_id
	# Explored-but-not-live systems are read-only: everything shown is the frozen
	# last-seen snapshot, no controls, no live population/ownership.
	var live := _sys_live(sys_id)
	var snap: Dictionary = _stale.get(sys_id, {})
	var snap_planets: Dictionary = snap.get("planets", {})
	# System-level supply depot control (independent of the selected planet).
	if not live:
		depot_btn.visible = false
	elif sim.systems[sys_id].depot_empire_id == player_empire_id:
		depot_btn.visible = true
		depot_btn.disabled = true
		depot_btn.text = "Supply depot: built"
	elif sim.is_under_influence(sys_id, player_empire_id):
		depot_btn.visible = true
		depot_btn.text = "Build supply depot (%d alloys)" \
			% int(SimConstants.DEPOT_COST_ALLOYS)
		depot_btn.disabled = not sim.can_build_depot(player_empire_id, sys_id)
	else:
		depot_btn.visible = false
	# Observation post (doubles influence reach + early warning).
	var sysd: StarSystem = sim.systems[sys_id]
	if not live:
		obs_post_btn.visible = false
	elif sysd.obs_post_empire_id == player_empire_id:
		obs_post_btn.visible = true
		obs_post_btn.disabled = true
		obs_post_btn.text = "Observation post: built"
	elif sim.is_under_influence(sys_id, player_empire_id):
		obs_post_btn.visible = true
		obs_post_btn.text = "Build observation post (%d alloys)" \
			% int(SimConstants.OBS_POST_COST_ALLOYS)
		obs_post_btn.disabled = not sim.can_build_obs_post(player_empire_id, sys_id)
	else:
		obs_post_btn.visible = false
	# Transportation hub (strengthens the neighbor bonus).
	if not live:
		transport_btn.visible = false
	elif sysd.transport_empire_id == player_empire_id:
		transport_btn.visible = true
		transport_btn.disabled = true
		transport_btn.text = "Transport hub: built"
	elif sim.is_under_influence(sys_id, player_empire_id):
		transport_btn.visible = true
		transport_btn.text = "Build transport hub (%d alloys)" \
			% int(SimConstants.TRANSPORT_COST_ALLOYS)
		transport_btn.disabled = not sim.can_build_transport(player_empire_id, sys_id)
	else:
		transport_btn.visible = false
	# Refresh row labels and highlight the selected planet.
	for row in _planet_rows:
		var b: Button = row[0]
		var pid: int = row[1]
		b.text = _planet_row_text(sim.planets[pid], live, snap_planets.get(pid, {}))
		b.modulate = Color.WHITE if pid == selected_planet_id \
			else Color(1, 1, 1, 0.7)

	var planet: Planet = sim.planets.get(selected_planet_id)
	if planet == null or planet.system_id != sys_id:
		panel_body.text = "Select a planet."
		for b in [colonize_btn, mine_btn, emigrate_btn, upgrade_btn, spec_food_btn,
				spec_alloy_btn]:
			b.visible = false
		return

	if not live:
		_show_planet_frozen(planet, snap_planets.get(planet.id, {}))
		return

	var dep_name: String = ["none", "water", "minerals"][planet.deposit_type]
	var deposit_line := "Deposit: %s" % dep_name
	if planet.has_deposit():
		if planet.has_mine():
			deposit_line += " · %.1f/day" % planet.mine_output()
		else:
			var est := planet.output_estimate()
			deposit_line += " · est. %d-%d/day" % [int(est.x), int(est.y)]
	var influence_note := "" if sim.is_under_influence(planet.system_id,
		player_empire_id) else "\nOutside your influence."
	var inbound := _builder_inbound(planet.id)
	if planet.colony == null:
		panel_body.text = "%s%s\n\nFounding costs %d alloys; a construction vessel carries it from your capital (can't cross enemy space).%s" \
			% [deposit_line, influence_note, int(SimConstants.FOUND_COST_ALLOYS),
				"\n⚙ vessel inbound…" if inbound else ""]
		colonize_btn.visible = true
		colonize_btn.text = "Send colony vessel (%d alloys)" \
			% int(SimConstants.FOUND_COST_ALLOYS)
		colonize_btn.disabled = not sim.can_order_construction(
			player_empire_id, SimConstants.Build.COLONY, planet.id)
	else:
		var c := planet.colony
		var status := "ESTABLISHED CITY" if c.established \
			else "growing… %d%% to activation" % int(c.activation_progress() * 100.0)
		var refine := ""
		if c.established:
			var mt := 0
			for t in 5:
				if c.population >= SimConstants.MIL_CUTOFF[t]:
					mt = t + 1
			refine = "\nRefines ≈%.1f/day, up to alloy T%d (T%d+ needs both mine types)" \
				% [c.refine_capacity(), mt, SimConstants.VARIETY_MIN_TIER + 1]
		panel_body.text = "Owner: %s\n%s\nPop: %.1f%s\n%s" \
			% [sim.empires[c.empire_id].name, status, c.population, refine, deposit_line]
		colonize_btn.visible = false
	mine_btn.visible = planet.has_deposit() and not planet.has_mine()
	mine_btn.text = "Send mine vessel (%d alloys)" % int(SimConstants.MINE_COST_ALLOYS)
	mine_btn.disabled = not sim.can_order_construction(
		player_empire_id, SimConstants.Build.MINE, planet.id)
	var own_colony: bool = planet.colony != null \
		and planet.colony.empire_id == player_empire_id
	emigrate_btn.visible = own_colony
	if own_colony:
		emigrate_btn.text = "Immigration: ON" if planet.colony.emigrating \
			else "Immigration: off"
	# Mine upgrade (own mine on this planet).
	upgrade_btn.visible = planet.has_mine() \
		and planet.mine_empire_id == player_empire_id
	if upgrade_btn.visible:
		upgrade_btn.text = "Upgrade mine (L%d, %d alloys)" \
			% [planet.mine_level, int(SimConstants.MINE_UPGRADE_COST_ALLOYS)]
		upgrade_btn.disabled = not sim.can_upgrade_mine(player_empire_id, planet.id)
	# Specialization (own established city).
	var can_spec: bool = own_colony and planet.colony.established
	spec_food_btn.visible = false   # food removed; only the refining spec remains
	spec_alloy_btn.visible = can_spec
	if can_spec:
		var sp: int = planet.colony.spec
		spec_alloy_btn.text = ("◆ " if sp == SimConstants.Spec.ALLOY else "") \
			+ "Specialize refining"


# Debug hook for automated visual verification: found a colony, run fast for a
# couple of real seconds, save galaxy + system screenshots, quit.
func _autoshot() -> void:
	# The player already starts with a home planet + mines. For the screenshot only,
	# let it expand too (via the same AI) so it meets a rival and the border falls
	# inside player sight — otherwise fog correctly hides it. Not part of normal play.
	sim.add_ai(player_empire_id)
	# Advance the sim directly (deterministic, instant) so both empires expand
	# and the galaxy shows a real two-color contest.
	speed_idx = 0
	for i in 3000:  # 300 days
		sim.tick(SimConstants.TICK_DAYS)
		if i % 200 == 0:   # build up the explored/stale memory as territory shifts
			_recompute_borders()
	# Build a few ships (they appear at the most-populated city) so a fleet marker
	# shows in the galaxy shot.
	sim.empires[player_empire_id].nat[0] = 5000.0
	for _k in 24:
		sim.build_ship(player_empire_id, SimConstants.Role.FIGHTER, 1)
	for _k in 12:
		sim.build_ship(player_empire_id, SimConstants.Role.BOMBER, 1)
	for f in sim.fleets:
		if f.empire_id == player_empire_id:
			selected_fleet_id = f.id
			break
	# Fog stays ON for the galaxy shot so the live / gray-explored / black states
	# and the border inside the player's VR all show. Force a hover so the
	# per-system symbol row is captured.
	_hover_hold = true
	var home: StarSystem = sim.systems[sim.most_populated_system(player_empire_id)]
	_hover_system = home.id
	_recompute_borders()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_galaxy.png")
	# Second shot: the system/planet selection panel. Clear the fleet selection first —
	# _refresh_ui() returns on the fleet branch before it reaches the system branch, so a
	# lingering selected_fleet_id kept the panel on "Fleet" and the two shots came out
	# identical. Then refresh the UI + redraw so the panel and the system ring actually paint.
	selected_fleet_id = -1
	_hover_hold = false
	view_system_id = home.id
	selected_planet_id = home.planet_ids[0]
	_refresh_ui()
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot.png")
	print("autoshots saved: ", ProjectSettings.globalize_path("user://"))
	get_tree().quit()
