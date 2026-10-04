extends Node2D

# Render/UI layer. Reads Sim state, forwards commands. No game rules live here.

const SPEEDS: Array[float] = [0.0, 1.0, 2.0, 4.0, 7.0, 10.0]
# Index 0 is paused; indices 1..5 are the five dial levels, shown as a strip of five
# chevrons that light up toward "+". Spans the old 1x-10x range on a gentle ramp.
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
var selected_fleets: Array[int] = []   # rectangle multi-select; a group move order
var view_system_id := -1  # -1 = galaxy view, otherwise the focused system

# Left-drag box-select of fleets (world space). _drag_active while the button is held;
# _dragging once it's moved past DRAG_SELECT_MIN (below that it's treated as a click).
var _drag_active := false
var _dragging := false
var _drag_start := Vector2.ZERO
var _drag_cur := Vector2.ZERO
const DRAG_SELECT_MIN := 8.0   # world units of travel before a press becomes a drag

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
const FOG_CELL := 16.0       # sample cell for the fog texture (linearly filtered). Finer
                             # again (30→22→16); the baked image is then box-blurred so the
                             # fog + storm-shadow edges read as smooth CURVES, not a
                             # grid staircase. Bake + blur both run off the main thread.
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
const FLEET_CROWN_GAP := 12.0   # extra lift for a parked fleet above a system's building row
const FLEET_CLICK_R := 24.0   # screen-space click radius for fleets (÷ zoom in _select_at)
const BORDER_INSET := 3.5    # push each empire's border curve into its own territory
const BORDER_HOLE_BRIDGE := 2   # grow the sight-visible border set this many contour hops
                                # so a short dip in VR (a storm's shadow, a feather notch)
                                # mid-border doesn't punch a hole; whole fogged borders,
                                # seeded by nothing, still never appear
const COMBAT_FLASH_DAYS := 5.0   # how long a clash starburst lingers on the map

var cam: Camera2D
var _panning := false
var _galaxy_cam_pos := Vector2.ZERO   # persisted galaxy pan/zoom across view switches
var _galaxy_cam_zoom := 1.0
var _map_lo := Vector2.ZERO
var _map_hi := Vector2.ZERO
var _border_segments: Array = []   # [{pts: PackedVector2Array, col: Color}] smoothed polylines
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
var _always_show_resources := false   # setting: draw every known system's deposit glyph,
                                       # not just the hovered one (toggled in the menu)
var _fog_tex: ImageTexture  # baked fog: feathered lit / grey memory / transparent
var _fog_rect := Rect2()    # world-space rect the fog texture covers
var _fog_seen := {}         # "gx,gy" -> true, cells ever in VR (explored memory)
var _starfield: Array = []  # backdrop: [pos, radius, Color] faint stars (static)
var _has_anomalies := false # cached each refresh so _claim_at skips anomaly tests
var _storm_bands: Array = [] # per-anomaly baked haze-blob centers; anomalies are
                            # immutable after map-gen, so this is built once (not per frame)
var _glow_tex: ImageTexture  # soft radial disc (white, alpha falloff). Linear-filtered,
                            # so star glows read smooth at any size — our stand-in for the
                            # 2D MSAA the GL-compatibility renderer won't give us.

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
var _prev_pstructs: Dictionary = {}   # "sid:kind" -> system_id, player-owned structures last scan
# Location-anchored alerts (lost building/colony, colony under siege) for the bottom
# jump bar. Separate from _events: these carry a system to fly the camera to, and are
# windowed by wall-clock seconds (what the player actually experiences), not sim days.
var _alerts: Array = []               # [{"t": ms, "text": String, "sid": int}], oldest first
var _alert_idx := 0                   # next alert the jump button will fly to (oldest->newest)
var alert_btn: Button                 # bottom-center "N alerts — jump" button
const ALERT_WINDOW_MS := 18000.0      # keep alerts from the last ~18s
var speed_chevrons: Array[Label] = []   # the 5-level dial strip; lit up to speed_idx
var speed_readout: Label                 # "Paused" / "2x" etc. beside the dial
var speed_slower_btn: Button             # clickable "◀" (same as the - key)
var speed_faster_btn: Button             # clickable "▶" (same as the + key)
var panel: PanelContainer
var ship_panel: PanelContainer   # top-right shipyard; the selection panel docks below it
var ship_body: VBoxContainer     # the collapsible part (tier grid + cost note)
var ship_head_btn: Button        # header toggles the shipyard collapsed/expanded
var ship_collapsed := false      # collapsed → selection panel reclaims the right column
var panel_title: Label
var panel_body: Label
var colonize_btn: Button
var mine_btn: Button
var emigrate_btn: Button
var abandon_btn: Button
var move_capital_btn: Button
var merge_btn: Button
var split_btn: Button
var spec_food_btn: Button
var spec_alloy_btn: Button
var upgrade_btn: Button
var depot_btn: Button
var obs_post_btn: Button
var imperial_btn: Button          # shown only to BUILD a center when none exists
var imperial_menu: MenuButton     # the dial once built: a popup to pick level 1..max / demolish
var citadel_btn: Button
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
	# Deep-navy space so unseen area reads as dark DEEP SPACE, not a flat black void
	# (was near-pure black at 0.02, which made the map feel like a big empty hole).
	RenderingServer.set_default_clear_color(Color(0.045, 0.05, 0.07))
	# Linear-filter the baked fog texture so its low-res samples interpolate into a
	# smooth influence-shaped gradient instead of visible cells. (Only the fog is a
	# texture here; lines/text/arcs are vector-drawn and unaffected.)
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_glow_tex = _make_glow_texture()
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
				_push_alert("✖ Colony lost at %s" % nm, sid)
	_prev_pcolonies = now
	# Player buildings lost (razed on border loss, or transferred away). One alert per
	# structure that was ours last scan and isn't now.
	var pstructs := {}
	for sid2 in sim.systems:
		var s2 = sim.systems[sid2]
		if s2.depot_empire_id == player_empire_id:    pstructs["%d:depot" % sid2] = sid2
		if s2.obs_post_empire_id == player_empire_id: pstructs["%d:obs" % sid2] = sid2
		if s2.imperial_empire_id == player_empire_id: pstructs["%d:imperial" % sid2] = sid2
		if s2.citadel_empire_id == player_empire_id:  pstructs["%d:citadel" % sid2] = sid2
	if not _prev_pstructs.is_empty():
		var kind_name := {"depot": "supply depot", "obs": "observatory",
			"imperial": "imperial center", "citadel": "citadel"}
		for key in _prev_pstructs:
			if not pstructs.has(key):
				var sid3: int = _prev_pstructs[key]
				var nm2: String = sim.systems[sid3].name if sim.systems.has(sid3) else "?"
				var kind: String = kind_name.get(String(key).split(":")[1], "building")
				_push_alert("⌂ Lost %s at %s" % [kind, nm2], sid3)
	_prev_pstructs = pstructs
	# Combat at systems the player can currently see. Battle (enemy fleets clashing) and
	# bombardment (a lone fleet grinding a colony) are distinct mechanics everywhere else in
	# the UI, so the feed distinguishes them too — combat_kind is fresh from this tick's
	# _resolve_combat when combat_at was just set.
	for sid in sim.combat_at:
		var d: float = sim.combat_at[sid]
		if d > _seen_combat.get(sid, -1.0) and _sys_live(sid):
			_seen_combat[sid] = d
			if sim.combat_kind.get(sid, 0) == 1:
				_log_event("☄ Bombardment at %s" % sim.systems[sid].name)
				# Bombardment of one of OUR systems = a colony under siege: worth a jump alert.
				if _system_has_player_colony(sid):
					_push_alert("☄ Colony under siege at %s" % sim.systems[sid].name, sid)
			else:
				_log_event("⚔ Battle at %s" % sim.systems[sid].name)
	_refresh_events()
	_refresh_alerts()


func _system_has_player_colony(sid: int) -> bool:
	for pid in sim.systems[sid].planet_ids:
		var c = sim.planets[pid].colony
		if c != null and c.empire_id == player_empire_id:
			return true
	return false


# Append a camera-jumpable alert and keep the list inside the wall-clock window.
func _push_alert(text: String, sid: int) -> void:
	_alerts.append({"t": Time.get_ticks_msec(), "text": text, "sid": sid})


# Drop stale alerts, reset the cycle when the list empties, refresh the button label.
func _refresh_alerts() -> void:
	var nowt := float(Time.get_ticks_msec())
	var kept: Array = []
	for a in _alerts:
		if nowt - float(a["t"]) <= ALERT_WINDOW_MS:
			kept.append(a)
	_alerts = kept
	if _alert_idx >= _alerts.size():
		_alert_idx = 0
	if alert_btn != null:
		if _alerts.is_empty():
			alert_btn.visible = false
		else:
			alert_btn.visible = true
			var cur: Dictionary = _alerts[_alert_idx]
			alert_btn.text = "  ▸ %s   (%d/%d — click to fly)  " % [
				cur["text"], _alert_idx + 1, _alerts.size()]


# Fly the camera to the current alert's system, then advance to the next (oldest->newest).
func _on_alert_pressed() -> void:
	if _alerts.is_empty():
		return
	_alert_idx = clampi(_alert_idx, 0, _alerts.size() - 1)
	var sid: int = _alerts[_alert_idx]["sid"]
	if sim.systems.has(sid):
		_galaxy_cam_pos = sim.systems[sid].map_pos
	_alert_idx = (_alert_idx + 1) % _alerts.size()
	_refresh_alerts()


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


# Pre-sample each storm's spine into overlapping haze-blob centers, once. Anomalies
# never change after map-gen, so _draw reuses these instead of resampling every frame.
func _bake_storm_bands() -> void:
	_storm_bands.clear()
	for an in sim.anomalies:
		var pts: PackedVector2Array = an.pts
		var ar: float = an.r
		var band := PackedVector2Array()
		for i in pts.size() - 1:
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var segs := maxi(1, int(a.distance_to(b) / (ar * 0.5)))
			for s in segs:
				band.append(a.lerp(b, float(s) / float(segs)))
		band.append(pts[pts.size() - 1])
		_storm_bands.append(band)


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
				var lit := Vector3(0.17, 0.17, 0.20) * v
				var mem := Vector3(0.10, 0.10, 0.12) * (base_a * (1.0 - v))
				var rgb: Vector3 = (lit + mem) / fa
				col = Color(rgb.x, rgb.y, rgb.z, fa)
			img.set_pixel(gx, gy, col)
	# The storm punches VR=0 and the lit edge lands on cell boundaries, so the raw grid
	# staircases. Two box-blur passes round every edge into a smooth curve (the whole map
	# reads curvier) — cheap CPU work on this small image, still off the main thread.
	_box_blur_image(img)
	_box_blur_image(img)
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
		var kpos: PackedVector2Array = pos[k]   # this empire's colony positions
		# Collect this empire's raw contour segments (un-nudged), each carrying the
		# unit direction toward its cell's interior. Chained into polylines and
		# smoothed below so the border reads as a flowing curve, not faceted twigs.
		var raw: Array = []       # every contour segment [a, b, dir] this empire has
		var raw_vis: Array = []   # parallel: is that segment's midpoint in player VR?
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
					var idir := inside_c - mid
					idir = idir.normalized() if idir.length() > 0.01 else Vector2.ZERO
					# Draw the border where the player can see it — tested at the contour
					# point itself. Since 0.70.0 VR is FULL at the border and feathers PAST
					# it, so the line sits in lit fog and this is stable. (The old code
					# probed 12px into the OWNING side; for a RIVAL's border that landed deep
					# in rival space where the player's VR is marginal, so the line flickered
					# in and out between rebakes as the border drifted — despite the seam
					# plainly being inside VR.)
					raw.append([seg[0], seg[1], idir])
					raw_vis.append(_player_vr_at(mid, ids, pos, infl, reach, reach_vr, pk))
		# Keep every VR-visible segment, then grow that set a couple of contour hops so a
		# short sight-dip inside an otherwise-visible border (a storm's shadow, a feather
		# notch) is bridged instead of leaving a hole. A border lying wholly in fog is
		# seeded by no visible segment, so it still never appears.
		var badj := {}   # endpoint key -> segment indices touching it
		for i in raw.size():
			for kk in [_bq(raw[i][0]), _bq(raw[i][1])]:
				if not badj.has(kk):
					badj[kk] = []
				badj[kk].append(i)
		var keep: Array = raw_vis.duplicate()
		for _pass in BORDER_HOLE_BRIDGE:
			var to_add: Array = []
			for i in raw.size():
				if keep[i]:
					continue
				var touches := false
				for kk in [_bq(raw[i][0]), _bq(raw[i][1])]:
					for j in badj[kk]:
						if keep[j]:
							touches = true
							break
					if touches:
						break
				if touches:
					to_add.append(i)
			for i in to_add:
				keep[i] = true
		var esegs: Array = []
		for i in raw.size():
			if keep[i]:
				esegs.append(raw[i])
		# Chain the visible segments into connected polylines, inset each toward the
		# empire's interior (so a shared seam shows both colours side by side), then
		# Chaikin-smooth so the grid faceting rounds off into a curve.
		for chain in _chain_border_segments(esegs):
			var cpts: Array = chain.pts
			var cdirs: Array = chain.dirs
			var closed: bool = chain.closed
			# Disregard an influence ISLAND (vision rule: a blob needs a colony inside):
			# a CLOSED border loop enclosing none of this empire's colonies is territory
			# claimed by pure falloff math with no colony in it — drop the loop so the
			# neighbours' borders fill the gap. Open chains are partial borders, not
			# islands, so they're always kept.
			if closed:
				var has_colony := false
				for cp in kpos:
					if _point_in_poly(cp, cpts):
						has_colony = true
						break
				if not has_colony:
					continue
			var inset: Array = []
			for vi in cpts.size():
				var d: Vector2 = cdirs[vi]
				d = d.normalized() * BORDER_INSET if d.length() > 0.001 else Vector2.ZERO
				inset.append((cpts[vi] as Vector2) + d)
			# Closed loops smooth without pinned endpoints and wrap around, so the whole
			# ring becomes a flowing curve (no seam kink at an arbitrary start vertex).
			var sm: Array = _chaikin(inset, 3, closed)
			if sm.size() >= 2:
				var packed := PackedVector2Array(sm)
				if closed:
					packed.append(sm[0])   # close the ring for draw_polyline
				segments.append({"pts": packed, "col": col})
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
	# God-view (screenshot/debug): show every empire's border regardless of player sight.
	return _fog_disabled or _vr_at(p, ids, pos, infl, reach, reach_vr, pk) > 0.0


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


# Quantise a contour point to an integer key. Adjacent cells produce algebraically
# identical shared-edge crossings, but the two float expressions can differ by an ULP,
# so snap to 1/8 world-unit before matching — far below the visible threshold.
func _bq(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x * 8.0), roundi(p.y * 8.0))


# Chain marching-squares segments (each [a, b, inside_dir]) into connected polylines by
# endpoint matching. Returns [{pts: Array[Vector2], dirs: Array[Vector2]}] where dirs[i]
# is the summed interior direction at pts[i] (used to inset the whole curve inward).
func _chain_border_segments(segs: Array) -> Array:
	var adj := {}    # Vector2i key -> Array of segment indices touching it
	var keys := []   # keys[i] = [key(a), key(b)]
	for i in segs.size():
		var ka := _bq(segs[i][0])
		var kb := _bq(segs[i][1])
		keys.append([ka, kb])
		for kk in [ka, kb]:
			if not adj.has(kk):
				adj[kk] = []
			adj[kk].append(i)
	var used := {}
	var out: Array = []
	for i0 in segs.size():
		if used.has(i0):
			continue
		used[i0] = true
		var pts: Array = [segs[i0][0], segs[i0][1]]
		var dirs: Array = [segs[i0][2], segs[i0][2]]
		var tail_key: Vector2i = keys[i0][1]
		var head_key: Vector2i = keys[i0][0]
		# Extend from the tail (append), then from the head (prepend).
		while true:
			var nxt := _next_seg(adj, tail_key, used)
			if nxt < 0:
				break
			used[nxt] = true
			dirs[dirs.size() - 1] += segs[nxt][2]
			var other: int = 1 if keys[nxt][0] == tail_key else 0
			pts.append(segs[nxt][other])
			dirs.append(segs[nxt][2])
			tail_key = keys[nxt][other]
		while true:
			var nxt := _next_seg(adj, head_key, used)
			if nxt < 0:
				break
			used[nxt] = true
			dirs[0] += segs[nxt][2]
			var other: int = 1 if keys[nxt][0] == head_key else 0
			pts.insert(0, segs[nxt][other])
			dirs.insert(0, segs[nxt][2])
			head_key = keys[nxt][other]
		# A chain that returns to its start is a CLOSED loop (an empire's ring border or
		# an island). Fold the duplicate closing vertex back into the start so the loop
		# can be smoothed as a wrap-around curve, and flag it for the island test.
		var closed := false
		if pts.size() > 3 and _bq(pts[0]) == _bq(pts[pts.size() - 1]):
			closed = true
			dirs[0] += dirs[dirs.size() - 1]
			pts.remove_at(pts.size() - 1)
			dirs.remove_at(dirs.size() - 1)
		out.append({"pts": pts, "dirs": dirs, "closed": closed})
	return out


func _next_seg(adj: Dictionary, k: Vector2i, used: Dictionary) -> int:
	if not adj.has(k):
		return -1
	for i in adj[k]:
		if not used.has(i):
			return i
	return -1


# Chaikin corner-cutting: each pass replaces every edge with two points at 1/4 and 3/4,
# rounding the polyline toward a quadratic B-spline. OPEN chains pin their endpoints so
# they stay anchored to their neighbours; CLOSED loops wrap around with no pinned point,
# so the entire ring becomes one continuous curve (no kink at an arbitrary start vertex).
func _chaikin(pts: Array, iters: int, closed := false) -> Array:
	var p: Array = pts
	for _it in iters:
		if p.size() < 3:
			break
		var np: Array = []
		if closed:
			var n := p.size()
			for i in n:
				var a: Vector2 = p[i]
				var b: Vector2 = p[(i + 1) % n]
				np.append(a.lerp(b, 0.25))
				np.append(a.lerp(b, 0.75))
		else:
			np.append(p[0])
			for i in p.size() - 1:
				var a: Vector2 = p[i]
				var b: Vector2 = p[i + 1]
				np.append(a.lerp(b, 0.25))
				np.append(a.lerp(b, 0.75))
			np.append(p[p.size() - 1])
		p = np
	return p


# Even-odd point-in-polygon (ray cast). Used to test whether an empire's colony lies
# inside a closed border loop — a loop enclosing none of its colonies is a disregarded
# influence island (vision: an influence blob needs a colony inside).
func _point_in_poly(pt: Vector2, poly: Array) -> bool:
	var inside := false
	var n := poly.size()
	var j := n - 1
	for i in n:
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[j]
		if (a.y > pt.y) != (b.y > pt.y):
			var x := a.x + (pt.y - a.y) / (b.y - a.y) * (b.x - a.x)
			if pt.x < x:
				inside = not inside
		j = i
	return inside


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

	# Left button: press begins a potential box-select; drag past a threshold makes it a
	# rectangle; release either commits the box (multi-select) or falls back to a click.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag_active = true
			_dragging = false
			_drag_start = get_global_mouse_position()
			_drag_cur = _drag_start
		elif _drag_active:
			_drag_active = false
			if _dragging:
				_box_select(_drag_start, _drag_cur)
			else:
				_select_at(_drag_start)
			_dragging = false
			queue_redraw()
		return
	if _drag_active and event is InputEventMouseMotion:
		_drag_cur = get_global_mouse_position()
		if _drag_start.distance_to(_drag_cur) > DRAG_SELECT_MIN:
			_dragging = true
			queue_redraw()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		# The controls page captures its own keys (rebinding, and Esc/K to close) in
		# _unhandled_key_input, which runs before this — so while it's open, swallow any
		# game hotkey that reaches here so it can't fire behind the panel.
		if controls_page != null and controls_page.visible:
			return
		# Esc: close the top overlay, else pause + open the menu.
		if event.keycode == KEY_ESCAPE:
			_on_escape()
			return
		# +/- step the speed dial, both on the numpad and the main row (KEY_EQUAL is the
		# unshifted "+"), fixed on top of the rebindable = / - actions.
		if event.keycode == KEY_KP_ADD or event.keycode == KEY_EQUAL:
			speed_idx = mini(SPEEDS.size() - 1, speed_idx + 1)
		elif event.keycode == KEY_KP_SUBTRACT or event.keycode == KEY_MINUS:
			speed_idx = maxi(0, speed_idx - 1)
		else:
			_dispatch_action(Keybinds.action_for(event.keycode))


func _select_at(pos: Vector2) -> void:
	# 0. With a rectangle group selected, a click on a known system sends the whole group
	#    there; a click anywhere else drops the group and falls through to normal select.
	if not selected_fleets.is_empty():
		for sys in sim.systems.values():
			if pos.distance_to(sys.map_pos) <= 20.0 and _sys_known(sys.id):
				_order_group(sys.id)
				return
		selected_fleets.clear()
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
				and pos.distance_to(_fleet_icon_pos(f)) <= fleet_r:
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


# Box-select: pick every player fleet whose icon falls inside the dragged rectangle
# (world space). Populates selected_fleets for a group move; the first also drives the
# single-fleet panel. An empty box just clears any selection.
func _box_select(a: Vector2, b: Vector2) -> void:
	var rect := Rect2(a, Vector2.ZERO).expand(b)
	selected_fleets.clear()
	for f in sim.fleets:
		if f.empire_id == player_empire_id \
				and rect.has_point(_fleet_icon_pos(f)):
			selected_fleets.append(f.id)
	if selected_fleets.is_empty():
		selected_fleet_id = -1
		view_system_id = -1
		return
	selected_fleet_id = selected_fleets[0]
	view_system_id = -1
	var n := selected_fleets.size()
	_log_event("▭ Selected %d %s — click a system to move them" % [
		n, "fleet" if n == 1 else "fleets"])


# Order every fleet in the box selection to a destination system; report how many
# actually got underway (pinned/blocked fleets are silently skipped in a group order).
func _order_group(dest_sys: int) -> void:
	var moved := 0
	for fid in selected_fleets:
		if sim.get_fleet(fid) != null and sim.order_fleet(fid, dest_sys):
			moved += 1
	_log_event("➤ %d of %d fleets moving out" % [moved, selected_fleets.size()])
	selected_fleets.clear()
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
	if _fog_tex != null and not _fog_disabled:
		draw_texture_rect(_fog_tex, _fog_rect, false)
	# Cosmic anomalies ("storms"): a magenta nebula haze snaking along a spine. They
	# block influence and sight (not movement), so they're always visible — a blind
	# corridor to route sight around but fly fleets through. The band is a capsule
	# chain: overlapping haze blobs down the spine, then a bright outline of the same
	# rounded sausage so its edges read clearly.
	if _storm_bands.size() != sim.anomalies.size():
		_bake_storm_bands()
	for ai in sim.anomalies.size():
		var an = sim.anomalies[ai]
		var pts: PackedVector2Array = an.pts
		var ar: float = an.r
		var band: PackedVector2Array = _storm_bands[ai]
		# The storm punches VR=0 into the fog, and that fog is sampled on a coarse grid, so
		# its dark edge staircases while the storm body curves — an ugly blocky shadow. Lay
		# a smooth navy shadow band down the ACTUAL spine first (quadratic-soft glow discs,
		# same deep-space navy as the backdrop): it recolours that jagged fog edge into a
		# curve that follows the storm, before the violet haze paints over it. Kept near the
		# storm's own footprint so it curves the existing shadow rather than growing it.
		for c in band:
			_draw_glow(c, ar * 1.30, Color(0.05, 0.055, 0.08, 0.6))
		# Nebula body: layered soft discs down the spine, from a wide cool indigo breath
		# inward to a warm magenta core. Overlapping glows accumulate toward the centre,
		# so the storm reads as a turbulent charged cloud with depth — not a flat sausage.
		# Alphas are up from the old whisper-faint set: the storm blocks sight, so the fog
		# under it is black, and a too-thin haze read as a dark void with a purple fringe.
		# A fuller cloud paints over that footprint so the storm reads as a glowing nebula.
		var haze := [
			[1.15, Color(0.26, 0.17, 0.42, 0.11)],    # cool indigo outer breath
			[0.90, Color(0.39, 0.21, 0.52, 0.16)],
			[0.62, Color(0.54, 0.27, 0.60, 0.21)],
			[0.40, Color(0.72, 0.36, 0.66, 0.27)],    # warm magenta core
		]
		for h in haze:
			var hr: float = ar * (h[0] as float)
			var hc: Color = h[1]
			for c in band:
				_draw_glow(c, hr, hc)
		# A bright turbulent filament threads the spine — the storm's charged "eye". Kept
		# THIN: a fat polyline has square butt-caps and hard miter joints that read as
		# rectangular clipping, so the soft round glow bands above carry the body instead.
		if pts.size() >= 2:
			draw_polyline(pts, Color(0.86, 0.66, 1.0, 0.22), 4.0, true)   # soft filament halo
			draw_polyline(pts, Color(0.92, 0.74, 1.0, 0.5), 2.0, true)    # crisp bright core
		# Charged knots sparkle along the band, giving the cloud texture and shimmer.
		for c in band:
			_draw_glow(c, ar * 0.15, Color(0.95, 0.83, 1.0, 0.16))
		# Soft rounded ends — glow blobs, not a hard ring.
		_draw_glow(pts[0], ar * 0.55, Color(0.60, 0.34, 0.66, 0.14))
		_draw_glow(pts[pts.size() - 1], ar * 0.55, Color(0.60, 0.34, 0.66, 0.14))
	# Deformed influence borders (already fog-gated to VR in _recompute_borders).
	# Two passes: a wide translucent underlay for a soft glow, then the crisp core.
	for bl in _border_segments:
		var gc: Color = bl.col
		gc.a = 0.22
		draw_polyline(bl.pts, gc, 5.0, true)
	for bl in _border_segments:
		draw_polyline(bl.pts, bl.col, 2.0, true)
	# Lanes: full between two known systems; HALF (out to the midpoint) when one
	# end is known and the other is never-seen; nothing when neither is known.
	var lane_col := Color(1, 1, 1, 0.13)
	for lane in sim.lanes:
		var a: Vector2 = sim.systems[lane[0]].map_pos
		var b: Vector2 = sim.systems[lane[1]].map_pos
		var ka := _sys_known(lane[0])
		var kb := _sys_known(lane[1])
		if ka and kb:
			draw_line(a, b, lane_col, 1.5, true)
		elif ka:
			draw_line(a, (a + b) * 0.5, lane_col, 1.5, true)
		elif kb:
			draw_line(b, (a + b) * 0.5, lane_col, 1.5, true)
	# Each empire's capital (its most-populated system — the de-facto shipyard) gets a
	# distinctive star glyph. Resolved once per frame so the per-system loop is a lookup.
	var capitals := {}
	for e in sim.empires.values():
		var cap: int = sim.capital_system(e.id)
		if cap != -1:
			capitals[cap] = e.color
	for sys in sim.systems.values():
		var sp: Vector2 = sys.map_pos
		if sp.x < view_lo.x or sp.x > view_hi.x or sp.y < view_lo.y or sp.y > view_hi.y:
			continue   # off-screen: skip star + labels
		var live := _sys_live(sys.id)
		if not (live or _sys_known(sys.id)):
			continue   # never seen -> stays black
		if live:
			# Live: bright glowing star sized by its population, owner ring, colonies.
			var spop := 0.0
			for pid in sys.planet_ids:
				var pcol: Colony = sim.planets[pid].colony
				if pcol != null:
					spop += pcol.population
			var sscale: float = 1.0 + clampf(spop / 2500.0, 0.0, 1.0) * 0.7
			_draw_star(sys.map_pos, _star_color(sys.id), 1.0, sscale)
			# Ring radius drives where every label/symbol nests — a capital's star ring is
			# the widest (15*sscale). All offsets below derive from it so nothing collides
			# with the ring (or each other) as the star scales up with population.
			var ring_r: float = (15.0 if capitals.has(sys.id) else 13.0) * sscale
			var label_y: float = 15.0 * sscale + 12.0   # clears even the widest (capital) ring
			# Structure badges tuck just ABOVE the ring, scaled to clear it.
			var col_owner := -1
			for cpid in sys.planet_ids:
				if sim.planets[cpid].colony != null:
					col_owner = sim.planets[cpid].colony.empire_id
					break
			_draw_structure_badges(sys.map_pos, sys.depot_empire_id,
				sys.obs_post_empire_id, sys.imperial_empire_id, sys.imperial_level,
				sys.citadel_empire_id, -(15.0 * sscale + 8.0), col_owner)
			var owner: int = _system_owner.get(sys.id, -1)
			if owner != -1:
				# A capital's owner ring is drawn as a 5-point STAR outline instead of a
				# circle — the seat of the empire reads at a glance, no floating glyph.
				if capitals.has(sys.id):
					_draw_capital_ring(sys.map_pos, sim.empires[owner].color, ring_r)
				else:
					draw_arc(sys.map_pos, ring_r, 0.0, TAU, 40,
						sim.empires[owner].color, 2.0, true)
			# A disconnected (overrun/cut-off) colony still holds a POCKET of territory
			# around its own star in its owner's colour, even though the broad region has
			# flipped to whoever surrounds it. Drawn as a real border bubble (filled claim +
			# outline), sized to reach about halfway to the nearest star — held ground, not a dot.
			for pid in sys.planet_ids:
				var dcol: Colony = sim.planets[pid].colony
				if dcol != null and not sim._is_colony_active(dcol):
					var bc: Color = sim.empires[dcol.empire_id].color
					var br: float = _bubble_radius(sys.id)
					draw_circle(sys.map_pos, br, Color(bc.r, bc.g, bc.b, 0.12))
					draw_arc(sys.map_pos, br, 0.0, TAU, 48,
						Color(bc.r, bc.g, bc.b, 0.22), 5.0, true)
					draw_arc(sys.map_pos, br, 0.0, TAU, 48, bc, 2.0, true)
					break   # one planet per node -> one bubble per system
			if _galaxy_cam_zoom >= LABEL_ZOOM:
				# colony shown by its skyline glyph in the crown above -- no count
				_draw_name(font, sys.map_pos + Vector2(-60.0, label_y), sys.name,
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
				draw_arc(sys.map_pos, 13.0, 0.0, TAU, 40, gc, 1.5, true)
			if _galaxy_cam_zoom >= LABEL_ZOOM:
				_draw_name(font, sys.map_pos + Vector2(-60.0, 26.0), sys.name,
					Color(1, 1, 1, 0.5))
		# Setting: draw this system's deposit glyph always (not just on hover). The
		# hovered system already shows the full symbol row, so skip it here.
		if _always_show_resources and sys.id != _hover_system:
			_draw_resource_hint(sys, live, _label_drop(sys) + 16.0)

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
			draw_arc(p, 15.0 + 3.0 * pulse, 0.0, TAU, 32, bc, 2.0, true)
			for k in 2:
				var d := Vector2.RIGHT.rotated(PI * 0.25 + k * PI * 0.5) * 12.0
				draw_line(p - d, p + d, Color(1.0, 0.5, 0.25, 0.9), 2.5, true)
		elif kind == 1:
			# Live bombardment: pulsing yellow streaks raining onto the system.
			var yc := Color(1.0, 0.85, 0.2, 0.5 + 0.4 * pulse)
			for k in 3:
				var x := p.x - 8.0 + k * 8.0
				draw_line(Vector2(x, p.y - 20.0), Vector2(x, p.y - 10.0), yc, 2.0)
			draw_arc(p, 14.0, 0.0, TAU, 32, Color(1.0, 0.8, 0.2, 0.3 * pulse), 1.5, true)
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

	# Supply overlay: press a fleet and every SAFE system lights up green — your own border
	# plus every system within a friendly depot's supply reach. That green field IS the
	# fleet's supply range; any selected fleet sitting OUTSIDE it is stranded and bleeding
	# border attrition (flagged red in the fleet pass below). Function-scoped so that pass
	# can reuse it.
	var supply_safe := {}
	if selected_fleet_id != -1 or not selected_fleets.is_empty():
		supply_safe = sim.supply_safe_systems(player_empire_id)
		for sid in supply_safe:
			var sp: Vector2 = sim.systems[sid].map_pos
			if sp.x < view_lo.x or sp.x > view_hi.x or sp.y < view_lo.y or sp.y > view_hi.y:
				continue
			draw_circle(sp, 15.0, Color(0.40, 1.0, 0.65, 0.07))
			draw_arc(sp, 15.0, 0.0, TAU, 32, Color(0.40, 1.0, 0.65, 0.5), 1.5, true)

	# Fleets: your own always visible; a rival's only while it sits in your VR.
	# Drawn as an arrowhead in the empire's colour, pointed along its heading; a
	# selected fleet gets a ring and a dashed line to its destination.
	for f in sim.fleets:
		var own := f.empire_id == player_empire_id
		if not (own or _sys_live(f.system_id)):
			continue
		var fp := _fleet_icon_pos(f)   # above the system node / building crown
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
		if f.id == selected_fleet_id or selected_fleets.has(f.id):
			draw_arc(fp, 10.0, 0.0, TAU, 32, Color.WHITE, 1.5, true)
			if f.is_moving():
				draw_line(fp, sim.systems[f.path[f.path.size() - 1]].map_pos,
					Color(1, 1, 1, 0.4), 1.0, true)
			# Outside the green supply field -> burning its supply reserve ("oxygen"). An
			# amber ring + reserve % while it still has reserve; flips to a red "OUT OF
			# SUPPLY" the moment the reserve runs dry and real attrition starts.
			if own and not supply_safe.has(f.system_id):
				var frac := sim.fleet_reserve_frac(f)
				var ring := Color(1.0, 0.65, 0.20, 0.85)
				var warn := "supply %d%%" % int(frac * 100.0)
				if frac <= 0.0:
					ring = Color(1.0, 0.30, 0.25, 0.95)
					warn = "OUT OF SUPPLY"
				draw_arc(fp, 13.0, 0.0, TAU, 32, ring, 2.0, true)
				_draw_name(font, fp + Vector2(0, -22), warn, ring)

	# Live box-select rectangle while the player is dragging.
	if _dragging:
		var r := Rect2(_drag_start, Vector2.ZERO).expand(_drag_cur)
		draw_rect(r, Color(0.6, 0.9, 1.0, 0.10))
		draw_rect(r, Color(0.7, 0.95, 1.0, 0.7), false, 1.0)

	# Hover: a faint ring for feedback + a row of symbols showing what's inside.
	if _hover_system != -1 and sim.systems.has(_hover_system) \
			and _sys_known(_hover_system):
		draw_arc(sim.systems[_hover_system].map_pos, 18.0, 0.0, TAU, 40,
			Color(1, 1, 1, 0.35), 1.0, true)
		_draw_system_symbols(sim.systems[_hover_system])


# Under a hovered system: one glyph per planet — filled circle = colony (owner
# colour), diamond = uncolonised deposit (blue water / orange minerals), a small
# owner-colour corner brackets framing it = a mine; a row of icon badges above the
# star = the system's structures (crate depot / eye obs-post / crown imperial center).
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
		if sys.imperial_empire_id != -1:
			structs.append("imperial center L%d (+%d%% influence, eats T%d)"
				% [sys.imperial_level, int(round(sim.imperial_bonus_at(sys.id) * 100.0)),
					sys.imperial_level])
		if sys.citadel_empire_id != -1:
			structs.append("citadel (%d%% hull)"
				% int(100.0 * sys.citadel_hp / SimConstants.CITADEL_MAX_HP))
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


# Colour + sign a per-day rate for the HUD ("+1.4/d" green, "-0.3/d" red, "0.0/d" dim).
# Idle (zero) rates are dimmed nearly to the bar background so a steady/paused economy's
# row of "0.0/d 0.0/d …" recedes and the eye lands on whatever is actually changing; only
# the +/- rates carry saturated colour.
# Alloy production is small and fractional, so always show one decimal (k-suffix stays
# one decimal too, e.g. "+1.2k/d").
func _fmt_rate(r: float) -> String:
	var col := "#565b66"   # dim: an idle rate should barely register
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
# mined = worked, drawn in full blue; unworked deposits are drawn greyscale so a glance
# tells tapped-vs-untapped without a frame.
func _draw_water_drop(c: Vector2, mined := true) -> void:
	var body := Color(0.35, 0.72, 1.0) if mined else Color(0.52, 0.55, 0.60)
	var rim := Color(0.85, 0.95, 1.0, 0.7) if mined else Color(0.78, 0.80, 0.84, 0.6)
	var glint := Color(1, 1, 1, 0.8) if mined else Color(1, 1, 1, 0.45)
	var drop := PackedVector2Array([
		c + Vector2(0.0, -6.0),
		c + Vector2(2.1, -2.4), c + Vector2(3.7, 1.1), c + Vector2(3.0, 3.6),
		c + Vector2(0.0, 4.9),
		c + Vector2(-3.0, 3.6), c + Vector2(-3.7, 1.1), c + Vector2(-2.1, -2.4)])
	draw_colored_polygon(drop, body)
	draw_polyline(PackedVector2Array([drop[0], drop[1], drop[2], drop[3], drop[4],
		drop[5], drop[6], drop[7], drop[0]]), rim, 1.0)
	draw_circle(c + Vector2(-1.1, 1.4), 1.1, glint)   # glint


# Mineral deposit — an upright faceted gem (diamond with a lighter top facet + rim).
# mined = worked, drawn in full amber; unworked is greyscale (see _draw_water_drop).
func _draw_gem(c: Vector2, mined := true) -> void:
	var body := Color(0.9, 0.58, 0.28) if mined else Color(0.54, 0.55, 0.58)
	var facet := Color(1.0, 0.78, 0.42) if mined else Color(0.74, 0.76, 0.80)
	var rim := Color(1.0, 0.85, 0.55, 0.7) if mined else Color(0.82, 0.84, 0.88, 0.6)
	var top := c + Vector2(0.0, -5.2)
	var rgt := c + Vector2(4.6, -0.6)
	var bot := c + Vector2(0.0, 5.2)
	var lft := c + Vector2(-4.6, -0.6)
	var mrgt := c + Vector2(2.3, -0.6)
	var mlft := c + Vector2(-2.3, -0.6)
	draw_colored_polygon(PackedVector2Array([top, rgt, bot, lft]), body)   # gem body
	draw_colored_polygon(PackedVector2Array([top, rgt, mrgt, mlft]), facet) # top-right facet
	draw_polyline(PackedVector2Array([top, rgt, bot, lft, top]), rim, 1.0)
	draw_line(lft, rgt, Color(rim.r, rim.g, rim.b, 0.5), 1.0)              # girdle line


# Structure badges: a system's built structures shown as a tidy centred row of
# owner-coloured icons just above the star. Laid out by count so 1-3 badges never
# collide (the old per-structure fixed offsets sat on different baselines and could
# overlap). Each icon is deliberately distinct: crate / eye / crown.
# Vertical drop (below a system's centre) at which its name / symbol row should sit, so
# labels always clear the population-scaled owner ring instead of cutting through it. The
# ring grows up to ~1.7x with population (and a capital's star ring is the widest at
# 15*sscale), so a fixed offset collided on big capitals — this tracks the same scale.
func _label_drop(sys: StarSystem) -> float:
	var spop := 0.0
	for pid in sys.planet_ids:
		var pcol: Colony = sim.planets[pid].colony
		if pcol != null:
			spop += pcol.population
	var sscale: float = 1.0 + clampf(spop / 2500.0, 0.0, 1.0) * 0.7
	return 15.0 * sscale + 12.0


# Radius of a disconnected colony's held-territory bubble: about half the distance to the
# nearest lane-neighbour star, so the pocket reaches roughly halfway to the next system.
# Floored so it always reads larger than the owner ring; falls back to the map's minimum
# star separation for a (lane-less) isolated node.
func _bubble_radius(system_id: int) -> float:
	var here: Vector2 = sim.systems[system_id].map_pos
	var nd := INF
	for nb in sim.lane_neighbors(system_id):
		nd = minf(nd, here.distance_to(sim.systems[nb].map_pos))
	if nd == INF:
		nd = SimConstants.MAP_MIN_SEPARATION
	return maxf(nd * 0.5, 18.0)


# Star size scales with the total population sitting in a system (matches the per-system
# draw loop). Kept here so the fleet-crown geometry derives from the same number.
func _system_star_scale(sys) -> float:
	var spop := 0.0
	for pid in sys.planet_ids:
		var pcol: Colony = sim.planets[pid].colony
		if pcol != null:
			spop += pcol.population
	return 1.0 + clampf(spop / 2500.0, 0.0, 1.0) * 0.7


# Does this system show at least one glyph in its crown (a colony or any structure)?
# If so, a parked fleet floats a row higher so it never overlaps a building or the star.
func _system_has_building(sys) -> bool:
	if sys.depot_empire_id != -1 or sys.obs_post_empire_id != -1 \
			or sys.imperial_empire_id != -1 or sys.citadel_empire_id != -1:
		return true
	for pid in sys.planet_ids:
		if sim.planets[pid].colony != null:
			return true
	return false


# Where a fleet's icon is drawn (and hit-tested). A moving fleet uses the flat default
# offset; a parked one nests just above its system's crown — in the top-of-star slot when
# the system is bare, or one row higher when a building already occupies that slot.
func _fleet_icon_pos(f) -> Vector2:
	var base: Vector2 = sim.fleet_position(f)
	if f.is_moving() or not sim.systems.has(f.system_id):
		return base + FLEET_ICON_OFF
	var sys = sim.systems[f.system_id]
	var sscale := _system_star_scale(sys)
	var crown_y := base.y - (15.0 * sscale + 8.0)   # the badge row, matching the draw loop
	if _system_has_building(sys):
		crown_y -= FLEET_CROWN_GAP
	return Vector2(base.x, crown_y)


# The "crown" of glyphs that arcs just above a star, centred so it stays symmetric as
# buildings are added (two buildings straddle the top; none sits dead-centre). The colony
# itself is the FIRST building in the bend (a little settlement skyline), then each
# military/civilian structure. A parked fleet nests above this row (see _fleet_icon_pos),
# so it never sits on top of the star. colony_id == -1 means no colony here.
func _draw_structure_badges(center: Vector2, depot_id: int, obs_id: int,
		imperial_id: int, imperial_level: int, citadel_id: int = -1,
		y_off: float = -20.0, colony_id: int = -1) -> void:
	var badges: Array = []
	if colony_id != -1:
		badges.append(["colony", sim.empires[colony_id].color, 0])
	if depot_id != -1:
		badges.append(["depot", sim.empires[depot_id].color, 0])
	if obs_id != -1:
		badges.append(["obs", sim.empires[obs_id].color, 0])
	if imperial_id != -1:
		badges.append(["imperial", sim.empires[imperial_id].color, imperial_level])
	if citadel_id != -1:
		badges.append(["citadel", sim.empires[citadel_id].color, 0])
	if badges.is_empty():
		return
	var gap := 10.0
	var x0: float = center.x - (badges.size() - 1) * gap * 0.5
	var y: float = center.y + y_off
	for i in badges.size():
		var p := Vector2(x0 + i * gap, y)
		var col: Color = badges[i][1]
		match badges[i][0]:
			"colony":   # the settlement itself: a little 3-building skyline
				draw_rect(Rect2(p + Vector2(-4.0, -1.5), Vector2(2.4, 4.5)), col)
				draw_rect(Rect2(p + Vector2(-1.2, -3.5), Vector2(2.4, 6.5)), col)
				draw_rect(Rect2(p + Vector2(1.6, -0.5), Vector2(2.4, 3.5)), col)
			"depot":   # supply crate: filled square
				draw_rect(Rect2(p + Vector2(-3, -3), Vector2(6, 6)), col)
			"obs":     # observation post: an eye (ring + pupil)
				draw_arc(p, 3.5, 0.0, TAU, 12, col, 1.5)
				draw_circle(p, 1.3, col)
			"imperial":   # imperial center: a crown — a bar with points, tick per level
				var lvl: int = badges[i][2]
				var pts := PackedVector2Array([
					p + Vector2(-3.5, 2.0), p + Vector2(-3.5, -1.0),
					p + Vector2(-1.5, 1.0), p + Vector2(0.0, -2.5),
					p + Vector2(1.5, 1.0), p + Vector2(3.5, -1.0),
					p + Vector2(3.5, 2.0)])
				draw_polyline(pts, col, 1.4)
				# One small pip under the crown per upgrade level (1-3) — reads the tier.
				for k in lvl:
					draw_circle(p + Vector2(-2.0 + k * 2.0, 3.6), 0.8, col)
			"citadel":   # fortress: a crenellated battlement (square with merlon teeth)
				draw_rect(Rect2(p + Vector2(-3.5, -1.0), Vector2(7.0, 4.0)), col, false, 1.3)
				for mx in [-3.5, -1.0, 1.5]:
					draw_rect(Rect2(p + Vector2(mx, -3.0), Vector2(2.0, 2.0)), col)


# One separable 1-2-1 box-blur pass over an RGBA image, in place. Used on the baked fog
# so its grid-quantised edges become smooth curves. Small image (<=FIELD_MAX_CELLS/axis),
# pure CPU (no rendering call), so it's safe to run on the off-thread bake worker.
func _box_blur_image(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	if w < 3 or h < 3:
		return
	var src := img.duplicate()
	for y in h:      # horizontal pass
		for x in w:
			var c0: Color = src.get_pixel(maxi(0, x - 1), y)
			var c1: Color = src.get_pixel(x, y)
			var c2: Color = src.get_pixel(mini(w - 1, x + 1), y)
			img.set_pixel(x, y, (c0 + c1 * 2.0 + c2) / 4.0)
	src = img.duplicate()
	for y in h:      # vertical pass
		for x in w:
			var c0: Color = src.get_pixel(x, maxi(0, y - 1))
			var c1: Color = src.get_pixel(x, y)
			var c2: Color = src.get_pixel(x, mini(h - 1, y + 1))
			img.set_pixel(x, y, (c0 + c1 * 2.0 + c2) / 4.0)


# A soft white radial disc: alpha falls off from the centre so, linear-filtered, it
# has no hard edge to alias. Tinted at draw time, it's every star's glow and core.
func _make_glow_texture(size: int = 64) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := (size - 1) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x - c, y - c).length() / c
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a))   # quadratic → soft halo
	return ImageTexture.create_from_image(img)


# Draw the glow disc centred at pos, radius r, tinted (rgb + alpha) by col.
func _draw_glow(pos: Vector2, r: float, col: Color) -> void:
	draw_texture_rect(_glow_tex, Rect2(pos - Vector2(r, r), Vector2(r * 2.0, r * 2.0)),
		false, col)


func _draw_star(pos: Vector2, col: Color, intensity: float, scale := 1.0) -> void:
	# A luminous body with depth, built from soft radial discs so every edge is smooth
	# (no MSAA on GL-compat): a wide faint corona, a coloured glow, a bright near-white
	# core and a hot pip. scale grows it with the system's population.
	var c := col
	c.a = 0.16 * intensity
	_draw_glow(pos, 20.0 * scale, c)                 # outer haze — the "reach" of the light
	c.a = 0.42 * intensity
	_draw_glow(pos, 11.0 * scale, c)                 # coloured body glow
	var core := col.lerp(Color.WHITE, 0.55)
	core.a = 0.85 + 0.15 * intensity
	_draw_glow(pos, (5.2 + 1.0 * intensity) * scale, core)
	_draw_glow(pos, (2.4 + 0.6 * intensity) * scale, Color(1, 1, 1, 0.9 * intensity))


# An empire's CAPITAL (its most-populated system — where its ships are built) gets its
# owner ring drawn as a 5-point STAR outline instead of a circle, so the seat of the
# empire reads instantly without a separate glyph floated above the star body.
func _draw_capital_ring(pos: Vector2, col: Color, radius: float) -> void:
	var ro: float = radius           # star tips
	var ri: float = radius * 0.46    # valleys — deep enough to read as a 5-point star
	var star := PackedVector2Array()
	for i in 11:   # 5 tips + 5 valleys, first point straight up, +1 to close the outline
		var ang: float = -PI / 2.0 + float(i) * PI / 5.0
		var r: float = ro if i % 2 == 0 else ri
		star.append(pos + Vector2(cos(ang), sin(ang)) * r)
	draw_polyline(star, col.darkened(0.4), 3.0, true)   # dark backing for contrast
	draw_polyline(star, col, 2.0, true)                 # crisp owner-colour star ring


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
	# Drop the row below the name (which itself clears the scaled ring), so the hovered
	# system's symbols never sit on its ring or its name — worst on a big capital.
	var start := sys.map_pos + Vector2(-(n - 1) * step * 0.5, _label_drop(sys) + 16.0)
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
			# minerals = a faceted gem. Full colour when the deposit is WORKED (a mine),
			# greyscale when untapped — so tapped-vs-untapped reads at a glance without
			# the old corner-bracket frame that mashed the glyph.
			var mined: bool = has_mine and mine_owner != -1
			if p.deposit_type == SimConstants.Deposit.WATER:
				_draw_water_drop(c, mined)
			else:
				_draw_gem(c, mined)
			# A mine is a structure that can change hands, so a worked deposit carries a thin
			# owner-colour halo — the only cue on the map of WHO owns the mine (and of it
			# flipping to a new owner when a border sweeps over it).
			if mined:
				draw_arc(c, 7.5, 0.0, TAU, 20, sim.empires[mine_owner].color, 1.5, true)
		else:
			draw_circle(c, 2.5, Color(0.5, 0.5, 0.55))
		i += 1
	if depot_owner != -1:
		var dcpos := start + Vector2(i * step, 0)
		draw_rect(Rect2(dcpos + Vector2(-4, -4), Vector2(8, 8)),
			sim.empires[depot_owner].color)


# Compact per-system deposit glyph for the "always show resources" setting: just the
# water/gem shape (mined = colour, untapped = greyscale) centred below the star, no
# colony/depot row. Uses live mine state in VR, else the last-seen snapshot.
func _draw_resource_hint(sys: StarSystem, live: bool, drop: float = 26.0) -> void:
	var snap_planets: Dictionary = _stale.get(sys.id, {}).get("planets", {})
	for pid in sys.planet_ids:
		var p: Planet = sim.planets[pid]
		if not p.has_deposit():
			continue
		var pinfo: Dictionary = snap_planets.get(pid, {})
		var has_mine: bool = p.has_mine() if live else pinfo.get("mine", false)
		var mine_owner: int = p.mine_empire_id if live else pinfo.get("mine_owner", -1)
		var mined: bool = has_mine and mine_owner != -1
		var c: Vector2 = sys.map_pos + Vector2(0.0, drop)
		if p.deposit_type == SimConstants.Deposit.WATER:
			_draw_water_drop(c, mined)
		else:
			_draw_gem(c, mined)
		if mined:
			draw_arc(c, 7.5, 0.0, TAU, 20, sim.empires[mine_owner].color, 1.5, true)


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

	# Bottom-center alert bar: one button listing recent camera-jumpable alerts (lost
	# building/colony, colony under siege). Each click flies to the next, oldest->newest.
	alert_btn = Button.new()
	alert_btn.visible = false
	alert_btn.focus_mode = Control.FOCUS_NONE
	alert_btn.add_theme_font_size_override("font_size", 14)
	alert_btn.add_theme_color_override("font_color", Color(1.0, 0.86, 0.55))
	var asb := StyleBoxFlat.new()
	asb.bg_color = Color(0.14, 0.10, 0.06, 0.95)
	asb.border_color = Color(0.85, 0.55, 0.2, 0.9)
	asb.set_border_width_all(1)
	asb.set_corner_radius_all(5)
	asb.set_content_margin_all(7)
	alert_btn.add_theme_stylebox_override("normal", asb)
	alert_btn.add_theme_stylebox_override("hover", asb)
	alert_btn.add_theme_stylebox_override("pressed", asb)
	alert_btn.anchor_left = 0.5
	alert_btn.anchor_right = 0.5
	alert_btn.anchor_top = 1.0
	alert_btn.anchor_bottom = 1.0
	alert_btn.grow_horizontal = Control.GROW_DIRECTION_BOTH
	alert_btn.grow_vertical = Control.GROW_DIRECTION_BEGIN
	alert_btn.offset_bottom = -22.0
	alert_btn.pressed.connect(_on_alert_pressed)
	layer.add_child(alert_btn)

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

	# Speed dial: [◀]  › › › › ›  [▶]  readout. The chevrons light up toward "+" to show
	# the current level (none lit = paused). The arrows step it; so do the + / - keys.
	var dial := HBoxContainer.new()
	dial.add_theme_constant_override("separation", 3)
	dial.tooltip_text = "Game speed — click the arrows or press + / - to change. Space pauses."

	speed_slower_btn = Button.new()
	speed_slower_btn.text = "◀"
	speed_slower_btn.focus_mode = Control.FOCUS_NONE
	speed_slower_btn.pressed.connect(func() -> void: speed_idx = maxi(0, speed_idx - 1))
	dial.add_child(speed_slower_btn)

	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 1)
	for i in 5:
		var chev := Label.new()
		chev.text = "›"
		chev.add_theme_font_size_override("font_size", 22)
		# Clicking a chevron jumps straight to that level (level = index + 1).
		chev.mouse_filter = Control.MOUSE_FILTER_STOP
		var lvl := i + 1
		chev.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and ev.pressed \
					and ev.button_index == MOUSE_BUTTON_LEFT:
				speed_idx = lvl)
		strip.add_child(chev)
		speed_chevrons.append(chev)
	dial.add_child(strip)

	speed_faster_btn = Button.new()
	speed_faster_btn.text = "▶"
	speed_faster_btn.focus_mode = Control.FOCUS_NONE
	speed_faster_btn.pressed.connect(func() -> void:
		speed_idx = mini(SPEEDS.size() - 1, speed_idx + 1))
	dial.add_child(speed_faster_btn)

	speed_readout = Label.new()
	speed_readout.custom_minimum_size = Vector2(52, 0)
	speed_readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	dial.add_child(speed_readout)

	bar.add_child(dial)

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
	abandon_btn = Button.new()
	abandon_btn.pressed.connect(_on_abandon)
	abandon_btn.tooltip_text = "Abandon colony — sheds population at double the emigration rate and takes in no new settlers, draining the colony toward empty. Use it to pull off a doomed or unwanted world."
	move_capital_btn = Button.new()
	move_capital_btn.text = "Make capital"
	move_capital_btn.pressed.connect(_on_move_capital)
	move_capital_btn.tooltip_text = "Move your capital here — the seat everything is supplied from (ships spawn here, and every colony must trace a friendly lane path back to it). Only a colony still connected to your current capital can become the new seat. If your capital ever falls, your empire is lost."
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
	depot_btn.tooltip_text = "Supply depot — negates border attrition for friendly fleets within 3 lane-jumps, projecting a safe supply radius into foreign space. Plant one forward to campaign past your own borders without bleeding hull."
	obs_post_btn = Button.new()
	obs_post_btn.pressed.connect(_on_build_obs_post)
	obs_post_btn.tooltip_text = "Observation post — doubles this system's influence reach (its border pushes twice as far) and, since sight rides influence, extends your vision well past the border (early warning)."
	var imperial_tip := "Imperial center — amplifies this system's colony influence (bigger borders, longer reach and vision) by burning alloy. Dial the level with the menu: each level adds +10% influence and drains a fixed amount of that tier's alloy per day (L1 eats T1 … L5 eats T5). The level you can pick is capped by the colony's size, and the bonus winds up and down over a few days rather than snapping in. Run a tier dry and its stockpile goes negative (red) until refining catches up."
	imperial_btn = Button.new()
	imperial_btn.pressed.connect(_on_build_imperial)
	imperial_btn.tooltip_text = imperial_tip
	imperial_menu = MenuButton.new()
	imperial_menu.flat = false
	imperial_menu.tooltip_text = imperial_tip
	imperial_menu.get_popup().id_pressed.connect(_on_imperial_level_pick)
	citadel_btn = Button.new()
	citadel_btn.pressed.connect(_on_build_citadel)
	citadel_btn.tooltip_text = "Citadel — an expensive fortress with enormous hull. Enemy fleets cannot pass THROUGH this system while it stands; they must stop and bombard it down first. Plant one on a chokepoint lane to wall off a whole region until it's destroyed."
	vbox.add_child(panel_title)
	vbox.add_child(planet_list)
	vbox.add_child(panel_body)
	vbox.add_child(colonize_btn)
	vbox.add_child(mine_btn)
	vbox.add_child(upgrade_btn)
	vbox.add_child(emigrate_btn)
	vbox.add_child(abandon_btn)
	vbox.add_child(move_capital_btn)
	vbox.add_child(spec_food_btn)
	vbox.add_child(spec_alloy_btn)
	vbox.add_child(depot_btn)
	vbox.add_child(obs_post_btn)
	vbox.add_child(imperial_btn)
	vbox.add_child(imperial_menu)
	vbox.add_child(citadel_btn)
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
	# Centered card, sized to its content. The body sits in a height-capped ScrollContainer
	# (below) so the whole card can never grow past the viewport — otherwise, at 1280x720
	# the welcome copy overflowed and pushed the "Begin" button off the bottom of the
	# screen, leaving a new player unable to dismiss the intro and start the game.
	intro_overlay.set_anchors_preset(Control.PRESET_CENTER)
	intro_overlay.anchor_left = 0.5
	intro_overlay.anchor_right = 0.5
	intro_overlay.anchor_top = 0.5
	intro_overlay.anchor_bottom = 0.5
	intro_overlay.grow_horizontal = Control.GROW_DIRECTION_BOTH
	intro_overlay.grow_vertical = Control.GROW_DIRECTION_BOTH
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
	# The body scrolls inside a fixed-height viewport; the title and Begin button stay
	# outside it, so Begin is always on-screen regardless of copy length or window size.
	var body_scroll := ScrollContainer.new()
	body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body_scroll.custom_minimum_size = Vector2(540, 440)
	v.add_child(body_scroll)
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(540, 0)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.text = "You have no body and no direct control — you cultivate a population and it does the rest.\n\n• Click a planet to open it. Send a construction vessel to found a colony or build a mine — it travels the lanes from your capital and can't cross enemy space.\n• Population lives on WATER: your water mines feed it directly, and it's a flow, not a stockpile — grow only as far as your water income supports, or it shrinks. Population drives influence, and influence sets your borders.\n• Minerals refine up a single alloy chain (T1→T5): small cities make lots of cheap T1 (which also pays for building), big cities reach the rare high tiers. High tiers need both water and mineral mines.\n• Build ships (top-right) to defend and to bombard enemy worlds. Use the speed dial (top-right) to skip slow stretches.\n• Press L for a legend of every map symbol.\n\nGoal: grow, spread, and outlast the rival empires."
	body_scroll.add_child(body)
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
	# Grow upward from the fixed bottom margin: the content is taller than the 172px the
	# offsets imply, and the default (grow both ways) let the extra height spill off the
	# bottom of the screen, clipping the last line (the anomaly glyph). Pinning the bottom
	# and growing up keeps every line on-screen at any line count.
	legend_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
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
		"● colony  ◆ mineral  ○ water  ⌞⌟ mine",
		"■ depot (hold)  ◉ obs-post (2× reach)  ♛ imperial (+infl., eats alloy)",
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
	var res_toggle := CheckButton.new()
	res_toggle.text = "Always show resources"
	res_toggle.button_pressed = _always_show_resources
	res_toggle.toggled.connect(func(on: bool) -> void:
		_always_show_resources = on
		queue_redraw())
	v.add_child(res_toggle)
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
	# Sit below the top stats bar's REAL bottom — a hard 40px overlapped a taller bar.
	# _dock_top_labels re-syncs this once the bar's true height settles (and on resize).
	sp.offset_top = (top_bar.size.y + 6.0) if (top_bar != null and top_bar.size.y > 0.0) \
		else 48.0
	# Dock the selection panel just under the shipyard's ACTUAL bottom, and keep it there
	# if the shipyard ever re-lays-out (font/DPI change) — no brittle hard-coded height.
	sp.resized.connect(_dock_selection_panel)
	layer.add_child(sp)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	sp.add_child(box)
	# Clickable header: collapses the shipyard so a content-heavy selection panel gets the
	# whole right column (the shipyard is a global action, unrelated to the current
	# selection, so it shouldn't permanently squeeze it). The caret shows the state.
	ship_head_btn = Button.new()
	ship_head_btn.flat = true
	ship_head_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	ship_head_btn.modulate = Color(1, 1, 1, 0.7)
	ship_head_btn.pressed.connect(_toggle_shipyard)
	box.add_child(ship_head_btn)
	# Everything below the header lives in ship_body, hidden when collapsed. Hiding it
	# shrinks the panel, whose resized signal re-docks the selection panel up (no hard-coded
	# heights) — the same runtime-dock that already keeps the two from overlapping.
	ship_body = VBoxContainer.new()
	ship_body.add_theme_constant_override("separation", 4)
	box.add_child(ship_body)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 3)
	ship_body.add_child(grid)
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
	ship_body.add_child(note)
	_apply_shipyard_collapse()   # set the header caret + body visibility


func _toggle_shipyard() -> void:
	ship_collapsed = not ship_collapsed
	_apply_shipyard_collapse()


func _apply_shipyard_collapse() -> void:
	if ship_body == null or ship_head_btn == null:
		return
	ship_body.visible = not ship_collapsed
	# ▸ collapsed / ▾ expanded — the caret advertises that the header is clickable.
	ship_head_btn.text = ("▸ Build ships" if ship_collapsed else "▾ Build ships — by tier")


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
	# Same for the top-right shipyard: keep its top under the bar's real bottom, then
	# re-dock the selection panel beneath it (its top is derived from the shipyard's).
	if ship_panel != null:
		ship_panel.offset_top = y
		_dock_selection_panel()


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


func _on_abandon() -> void:
	if selected_planet_id != -1:
		sim.toggle_abandon(player_empire_id, selected_planet_id)


func _on_move_capital() -> void:
	if selected_planet_id != -1:
		sim.move_capital(player_empire_id, selected_planet_id)


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


func _on_build_imperial() -> void:
	if view_system_id != -1:
		sim.build_imperial(player_empire_id, view_system_id)     # first build is level 1


# The dial: popup item id IS the target level (0 = demolish). set_imperial_level clamps to the
# colony-size gate, so a too-high pick is simply ignored.
func _on_imperial_level_pick(level: int) -> void:
	if view_system_id != -1:
		sim.set_imperial_level(player_empire_id, view_system_id, level)


# Rebuild the dial's popup: one radio item per level the colony's size allows (the current
# level checked), each spelling out its bonus and the alloy tier it eats, plus Demolish. Skips
# the rebuild while the popup is open so selecting an item doesn't fight a mid-frame refresh
# (what made the old up/lower buttons flicker).
func _populate_imperial_menu(sys_id: int, cur_level: int) -> void:
	var pop: PopupMenu = imperial_menu.get_popup()
	if pop.visible:
		return
	pop.clear()
	var maxl: int = sim.max_imperial_level(sys_id)
	var e: Empire = sim.empires[player_empire_id]
	for l in range(1, maxl + 1):
		var pct: int = l * int(SimConstants.IMPERIAL_BONUS_PER_LEVEL * 100.0)
		var stock: float = e.nat[l - 1]
		var red := "  (T%d in the red)" % l if stock < 0.0 else ""
		pop.add_radio_check_item("Level %d   +%d%%, eats T%d%s" % [l, pct, l, red], l)
		pop.set_item_checked(pop.get_item_index(l), l == cur_level)
	pop.add_separator()
	pop.add_item("Demolish center", 0)


func _on_build_citadel() -> void:
	if view_system_id != -1:
		sim.build_citadel(player_empire_id, view_system_id)


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
	for b in [colonize_btn, mine_btn, emigrate_btn, abandon_btn, move_capital_btn, upgrade_btn,
			spec_food_btn, spec_alloy_btn]:
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
		# A tier drained into the red (imperial over-draw) shows its NEGATIVE amount in red,
		# so the debt is visible on the stockpile itself, not hidden.
		if player.nat[t] < 0.0:
			goods_label.push_color(Color(1.0, 0.35, 0.35))
			goods_label.append_text(" %s" % _fmt_num(player.nat[t]))
			goods_label.pop()
		else:
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
	for i in speed_chevrons.size():
		var lit := i < speed_idx   # levels are 1-based; idx 0 (paused) lights none
		speed_chevrons[i].modulate = Color(0.55, 1.0, 0.70) if lit \
			else Color(1, 1, 1, 0.18)
	speed_readout.text = "Paused" if speed_idx == 0 else "%dx" % int(SPEEDS[speed_idx])
	speed_slower_btn.disabled = speed_idx == 0
	speed_faster_btn.disabled = speed_idx == SPEEDS.size() - 1
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
	for b in [colonize_btn, mine_btn, emigrate_btn, abandon_btn, move_capital_btn, upgrade_btn,
			spec_food_btn, spec_alloy_btn, depot_btn, obs_post_btn, imperial_btn,
			imperial_menu, citadel_btn]:
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
	# Imperial center (burns tier-L alloy to amplify this system's colony influence). Built:
	# a compact dial MenuButton (detail lives in the popup). Not built: a plain Build button.
	imperial_menu.visible = false
	if not live:
		imperial_btn.visible = false
	elif sysd.imperial_empire_id == player_empire_id:
		imperial_btn.visible = false
		imperial_menu.visible = true
		var lvl: int = sysd.imperial_level
		var tgt_pct: int = lvl * int(SimConstants.IMPERIAL_BONUS_PER_LEVEL * 100.0)
		var charge: float = sim.imperial_feed_at(sys_id)
		# A short winding/starved glyph; the full numbers sit in the menu.
		var glyph := ""
		if sim.empires[player_empire_id].nat[lvl - 1] < 0.0:
			glyph = "  ⚠"            # tier in the red — the center is starving
		elif charge < 0.99:
			glyph = "  ↑"            # winding up toward its target bonus
		imperial_menu.text = "⚙ Imperial  L%d  +%d%%%s ▾" % [lvl, tgt_pct, glyph]
		_populate_imperial_menu(sys_id, lvl)
	elif sysd.imperial_empire_id == -1 and sim.is_under_influence(sys_id, player_empire_id):
		imperial_btn.visible = true
		imperial_btn.text = "Build imperial center (%d alloys)" \
			% int(SimConstants.IMPERIAL_COST_ALLOYS)
		imperial_btn.disabled = not sim.can_build_imperial(player_empire_id, sys_id)
	else:
		imperial_btn.visible = false
	# Citadel (a fortress that walls the system off until bombarded down).
	if not live:
		citadel_btn.visible = false
	elif sysd.citadel_empire_id == player_empire_id:
		citadel_btn.visible = true
		citadel_btn.disabled = true
		var hp_pct: int = int(100.0 * sysd.citadel_hp / SimConstants.CITADEL_MAX_HP)
		citadel_btn.text = "Citadel: standing (%d%% hull)" % hp_pct
	elif sysd.citadel_empire_id == -1 and sim.is_under_influence(sys_id, player_empire_id):
		citadel_btn.visible = true
		citadel_btn.text = "Build citadel (%d alloys)" \
			% int(SimConstants.CITADEL_COST_ALLOYS)
		citadel_btn.disabled = not sim.can_build_citadel(player_empire_id, sys_id)
	else:
		citadel_btn.visible = false
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
		for b in [colonize_btn, mine_btn, emigrate_btn, abandon_btn, move_capital_btn, upgrade_btn,
				spec_food_btn, spec_alloy_btn]:
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
		# Water is a flow: show the empire's spare water/day and what this colony will
		# draw, so founding into a deficit is a visible, deliberate choice (and blocked).
		var surplus := sim.water_surplus_per_day(player_empire_id)
		var need := sim.new_colony_water_per_day(player_empire_id)
		var water_ok := surplus >= need
		var water_line := "\n\nWater: %+.1f/day spare · a new colony needs %.1f/day%s" \
			% [surplus, need, "" if water_ok else "  ⚠ not enough water"]
		panel_body.text = "%s%s\n\nFounding costs %d alloys; a construction vessel carries it from your capital (can't cross enemy space).%s%s" \
			% [deposit_line, influence_note, int(SimConstants.FOUND_COST_ALLOYS),
				water_line, "\n⚙ vessel inbound…" if inbound else ""]
		colonize_btn.visible = true
		colonize_btn.text = "Send colony vessel (%d alloys)" \
			% int(SimConstants.FOUND_COST_ALLOYS)
		colonize_btn.disabled = not sim.can_order_construction(
			player_empire_id, SimConstants.Build.COLONY, planet.id)
		colonize_btn.tooltip_text = "" if water_ok \
			else "Not enough spare water. Each colony draws water to survive; found more water mines (or shrink elsewhere) before expanding."
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
		var tags := ""
		if sim.empires[c.empire_id].capital_planet_id == planet.id:
			tags += "  ★ CAPITAL"
		elif not sim._is_colony_active(c):
			# Cut off from its capital: no outside supply. Over water it clings on (but
			# produces nothing); otherwise its people are dying off.
			tags += "  ⚠ DISCONNECTED (%s)" % ("clinging on — produces nothing" \
				if planet.deposit_type == SimConstants.Deposit.WATER else "dying off")
		panel_body.text = "Owner: %s%s\n%s\nPop: %.1f%s\n%s" \
			% [sim.empires[c.empire_id].name, tags, status, c.population, refine, deposit_line]
		colonize_btn.visible = false
	mine_btn.visible = planet.has_deposit() and not planet.has_mine()
	mine_btn.text = "Send mine vessel (%d alloys)" % int(SimConstants.MINE_COST_ALLOYS)
	mine_btn.disabled = not sim.can_order_construction(
		player_empire_id, SimConstants.Build.MINE, planet.id)
	var own_colony: bool = planet.colony != null \
		and planet.colony.empire_id == player_empire_id
	emigrate_btn.visible = own_colony
	abandon_btn.visible = own_colony
	if own_colony:
		emigrate_btn.text = "Immigration: ON" if planet.colony.emigrating \
			else "Immigration: off"
		abandon_btn.text = "Abandoning colony" if planet.colony.abandoning \
			else "Abandon colony"
	# Make-capital: only for one of your own colonies that isn't already the capital.
	# Disabled (can't be a seat) if it's cut off from the current capital.
	var is_capital: bool = own_colony \
		and sim.empires[player_empire_id].capital_planet_id == planet.id
	move_capital_btn.visible = own_colony and not is_capital
	if move_capital_btn.visible:
		var connected: bool = sim._is_colony_active(planet.colony)
		move_capital_btn.disabled = not connected
		move_capital_btn.text = "Make capital" if connected \
			else "Make capital (disconnected)"
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
	# Third shot: a zoomed-in view centered on home, so a review can judge label/lane
	# density and node legibility up close (the full-galaxy shot is too far out for that).
	view_system_id = -1
	selected_planet_id = -1
	_always_show_resources = true   # verify the always-on deposit glyphs + mined/untapped scheme
	_galaxy_cam_pos = home.map_pos
	_galaxy_cam_zoom = 2.5
	_apply_camera()
	_refresh_ui()
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_zoom.png")
	_always_show_resources = false
	# Fourth shot: a content-heavy OWN-city panel — the worst case for panel overflow
	# (established city + own mine + specialization + all three system structures still
	# buildable = the most action buttons at once). This is what the panel ScrollContainer
	# has to survive. The one-planet-per-node model means there's no multi-planet list to
	# stress; max button count is the real stress case. Fund the empire so the structure
	# buttons are ENABLED (not just visible), then pick a city whose system has no
	# structures yet so depot/obs/imperial all offer.
	sim.empires[player_empire_id].nat[0] = 100000.0   # T1 alloys pay for structures
	sim.empires[player_empire_id].minerals = 100000.0
	var city_sys := -1
	var city_pid := -1
	for c in sim.colonies:
		if c.empire_id != player_empire_id or not c.established:
			continue
		var sid: int = sim.planets[c.planet_id].system_id
		var s: StarSystem = sim.systems[sid]
		if s.depot_empire_id == -1 and s.obs_post_empire_id == -1 \
				and s.imperial_empire_id == -1:
			city_sys = sid
			city_pid = c.planet_id
			break
	if city_sys == -1:   # fallback: home city
		city_sys = home.id
		city_pid = home.planet_ids[0]
	selected_fleet_id = -1
	_hover_hold = false
	view_system_id = city_sys
	selected_planet_id = city_pid
	_galaxy_cam_pos = sim.systems[city_sys].map_pos
	_galaxy_cam_zoom = 1.0
	_apply_camera()
	_refresh_ui()
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_colony.png")
	# Same city, shipyard COLLAPSED: the selection panel should reclaim the whole right
	# column and show every action button without scrolling (the O7 fix). Hiding ship_body
	# fires the shipyard's resized signal, which re-docks the selection panel up under the
	# collapsed header.
	ship_collapsed = true
	_apply_shipyard_collapse()
	_refresh_ui()
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_colony_collapsed.png")
	ship_collapsed = false   # restore the expanded shipyard for the remaining poses
	_apply_shipyard_collapse()
	# Fifth shot: a LIVE FLEET BATTLE. Stage an enemy fleet in the player's home system so
	# _resolve_combat pins both sides and flags combat_at/combat_kind, then show the galaxy
	# with the player's fleet selected — the fleet panel renders the full who-vs-who battle
	# readout + verdict, and the map draws the clash marker. Combat is a design pillar, so
	# this is the highest-value coverage the harness was missing.
	var enemy_id := -1
	for eid in sim.empires:
		if eid != player_empire_id:
			enemy_id = eid
			break
	if enemy_id != -1:
		var pf := sim._fleet_at(player_empire_id, home.id)
		if pf.ship_count() == 0:
			pf.fighters[2] += 16
			pf.bombers[1] += 6
		var ef := sim._fleet_at(enemy_id, home.id)
		ef.fighters[2] += 10
		ef.bombers[1] += 3
		sim.tick(SimConstants.TICK_DAYS)   # resolves combat → combat_at/kind populate
		_recompute_borders()
		# The tick can merge/cull fleets, so re-find the player's stationary fleet at home.
		selected_fleet_id = -1
		for f in sim.fleets:
			if f.empire_id == player_empire_id and f.system_id == home.id \
					and not f.is_moving():
				selected_fleet_id = f.id
				break
		view_system_id = -1
		selected_planet_id = -1
		_galaxy_cam_pos = home.map_pos
		_galaxy_cam_zoom = 1.8
		_apply_camera()
		_refresh_ui()
		queue_redraw()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://autoshot_battle.png")
	# Sixth shot: BOMBARDMENT — the OTHER combat state (a lone fleet over an enemy colony,
	# no enemy fleet to fight). It's a distinct design pillar ("killing population is slow"),
	# with its own ☄ marker and readout, so it's worth its own coverage separate from the
	# fleet battle. Find an enemy colony whose system has no enemy fleet, drop a bomber-heavy
	# player fleet on it, tick once so _bombard runs and combat_kind flags 1.
	var bomb_sys := -1
	for c in sim.colonies:
		if c.empire_id == player_empire_id:
			continue
		var sid: int = sim.planets[c.planet_id].system_id
		if not sim._has_enemy_fleet(player_empire_id, sid):   # no defender → bombardment
			bomb_sys = sid
			break
	if bomb_sys != -1:
		var bf := sim._fleet_at(player_empire_id, bomb_sys)
		bf.bombers[2] += 12   # bomb power to grind the colony
		bf.fighters[1] += 4
		sim.tick(SimConstants.TICK_DAYS)   # _bombard runs → combat_kind[bomb_sys] = 1
		_recompute_borders()
		selected_fleet_id = -1
		for f in sim.fleets:
			if f.empire_id == player_empire_id and f.system_id == bomb_sys \
					and not f.is_moving():
				selected_fleet_id = f.id
				break
		view_system_id = -1
		selected_planet_id = -1
		_galaxy_cam_pos = sim.systems[bomb_sys].map_pos
		_galaxy_cam_zoom = 1.8
		_apply_camera()
		_refresh_ui()
		queue_redraw()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://autoshot_bombard.png")
	# Seventh shot: the map LEGEND (L). O6 leaned on "it's fine, the legend explains the
	# glyphs" — capture it to verify that claim holds (every map symbol covered, legible).
	selected_fleet_id = -1
	view_system_id = -1
	selected_planet_id = -1
	_galaxy_cam_pos = home.map_pos
	_galaxy_cam_zoom = 1.4
	_apply_camera()
	_refresh_ui()
	if legend_panel != null:
		legend_panel.visible = true
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_legend.png")
	if legend_panel != null:
		legend_panel.visible = false
	# Eighth shot: a system with ALL THREE STRUCTURES built, zoomed in. Nothing else in the
	# harness ever shows a built structure (the colony pose deliberately picks a structure-
	# free city to keep the build buttons enabled), so the depot/obs-post/imperial map
	# badges — and the mine corner-brackets on a worked deposit — had no coverage at all.
	# Pick a structures system away from any player fleet — home is the most-populated
	# city, so ships spawn there and the fleet arrow would sit on top of the badge row and
	# hide the middle badge. Prefer an established player city whose system has no player
	# fleet; fall back to home only if none exists.
	sim.empires[player_empire_id].nat[0] = 100000.0
	var struct_sys := home.id
	for c in sim.colonies:
		if c.empire_id != player_empire_id or not c.established:
			continue
		var sid: int = sim.planets[c.planet_id].system_id
		if not sim.empire_fleet_in_system(player_empire_id, sid) \
				and sim.can_build_depot(player_empire_id, sid):
			struct_sys = sid
			break
	sim.build_depot(player_empire_id, struct_sys)
	sim.build_obs_post(player_empire_id, struct_sys)
	sim.build_imperial(player_empire_id, struct_sys)
	_recompute_borders()
	_hover_hold = true
	_hover_system = struct_sys
	selected_fleet_id = -1
	view_system_id = -1
	selected_planet_id = -1
	_galaxy_cam_pos = sim.systems[struct_sys].map_pos
	_galaxy_cam_zoom = 2.5
	_apply_camera()
	_refresh_ui()
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_structures.png")
	_hover_hold = false
	# Ninth shot: the one-time intro overlay (shown on every new game). Pure UI over the
	# galaxy — verifies the welcome copy fits its opaque panel and reads cleanly.
	selected_fleet_id = -1
	view_system_id = -1
	selected_planet_id = -1
	_galaxy_cam_pos = home.map_pos
	_galaxy_cam_zoom = 1.4
	_apply_camera()
	_refresh_ui()
	if intro_overlay != null:
		intro_overlay.visible = true
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_intro.png")
	if intro_overlay != null:
		intro_overlay.visible = false
	# Tenth shot: drag-select. A static pose can't perform a live drag, so fake the
	# state the way a real drag leaves it — a world-space box around home's parked
	# fleets, box-selected — and freeze mid-drag (_dragging=true) so the selection
	# rings AND the live drag rectangle both paint. Covers the only feature the harness
	# couldn't otherwise show (Cycle 10 🟡).
	view_system_id = -1
	selected_planet_id = -1
	selected_fleet_id = -1
	_galaxy_cam_pos = home.map_pos
	_galaxy_cam_zoom = 2.0
	_apply_camera()
	var box_c: Vector2 = home.map_pos + FLEET_ICON_OFF
	_drag_start = box_c + Vector2(-70, -70)
	_drag_cur = box_c + Vector2(70, 70)
	_box_select(_drag_start, _drag_cur)   # populates selected_fleets + the rings
	_dragging = true                      # freeze mid-drag so the box draws
	_refresh_ui()
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_drag_select.png")
	_dragging = false
	# Eleventh shot: GOD VIEW of the whole galaxy — fog off, every empire's border drawn
	# (not just the player's-sight-gated ones), zoomed to fit. This is the true multi-empire
	# "red/yellow/green" contest shot: the one that shows border curves, seam contests and
	# storm placement across ALL empires at once, which the fogged galaxy pose can't. Advance
	# further first so the borders mature and rivals actually clash.
	for i in 2400:   # +240 days of expansion so the contest is well-developed
		sim.tick(SimConstants.TICK_DAYS)
	_fog_disabled = true
	selected_fleet_id = -1
	view_system_id = -1
	selected_planet_id = -1
	_hover_hold = false
	var g_span: Vector2 = (_map_hi - _map_lo) + Vector2(240, 240)
	var g_vp: Vector2 = get_viewport_rect().size
	_galaxy_cam_pos = (_map_lo + _map_hi) * 0.5
	_galaxy_cam_zoom = clampf(minf(g_vp.x / g_span.x, g_vp.y / g_span.y), ZOOM_MIN, ZOOM_MAX)
	_apply_camera()
	_recompute_borders()
	# Hide the right-column UI (shipyard + selection panel) so nothing occludes the map —
	# this pose exists purely to review the whole-galaxy border/storm contest.
	if ship_panel != null:
		ship_panel.visible = false
	if panel != null:
		panel.visible = false
	_refresh_ui()
	if ship_panel != null:
		ship_panel.visible = false   # _refresh_ui may re-show it; force hidden for the shot
	if panel != null:
		panel.visible = false
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_god.png")
	# Freeze per-frame processing for the staged poses below: no stray hover/tooltip, no
	# win/lose overlay firing on these tiny hand-built sims. We drive camera/redraw by hand.
	set_process(false)
	set_process_unhandled_input(false)
	if _tooltip_panel != null:
		_tooltip_panel.visible = false
	# --- Hand-switching verification: a contested CROSSING whose rival structures change
	#     hands the moment the player's border sweeps over it. Two poses, BEFORE and AFTER
	#     one tick, on a clean two-system scenario so it reads unambiguously:
	#       mine (CIVILIAN) flips to the player's colour; depot + obs post (MILITARY) are RAZED.
	_fog_disabled = true
	var cap_sim := Sim.new()
	var pA := cap_sim.add_empire("You", Color(0.35, 0.85, 0.45))   # player — green
	var pB := cap_sim.add_empire("Rival", Color(0.90, 0.32, 0.30)) # rival — red
	var sys_home := cap_sim.add_system("Core")
	sys_home.map_pos = Vector2(-80, 0)
	var sys_x := cap_sim.add_system("Crossing")
	sys_x.map_pos = Vector2(60, 0)
	cap_sim.add_lane(sys_home.id, sys_x.id)
	cap_sim.inject_colony(pA.id, cap_sim.add_planet(sys_home.id, "Core I").id, 5000.0, true)
	var xp := cap_sim.add_planet(sys_x.id, "Crossing I")
	xp.deposit_type = SimConstants.Deposit.MINERAL
	xp.mine_empire_id = pB.id            # rival mine (civilian) — will FLIP to green
	sys_x.depot_empire_id = pB.id        # rival depot (military) — will be RAZED
	sys_x.obs_post_empire_id = pB.id     # rival obs post (military) — will be RAZED
	# A far-off rival homeworld keeps both empires "alive" so the win/lose overlay never
	# fires over the pose (it's off-camera and its influence never reaches the Crossing).
	var sys_far := cap_sim.add_system("Rival Core")
	sys_far.map_pos = Vector2(3000, 0)
	cap_sim.inject_colony(pB.id, cap_sim.add_planet(sys_far.id, "Rival I").id, 2000.0, true)
	sim = cap_sim
	player_empire_id = pA.id
	_storm_bands.clear()
	_events.clear()            # drop the carried-over feed from the earlier poses
	_prev_pcolonies = {}       # re-seed loss detection against the new sim (no false losses)
	_seen_combat = {}
	_prev_pstructs = {}
	_alerts.clear(); _alert_idx = 0
	selected_fleet_id = -1
	selected_fleets.clear()
	view_system_id = -1
	selected_planet_id = -1
	_hover_hold = true
	_hover_system = sys_x.id
	_galaxy_cam_pos = (sys_home.map_pos + sys_x.map_pos) * 0.5
	_galaxy_cam_zoom = 2.6
	_apply_camera()
	_recompute_borders()
	_refresh_ui()
	if ship_panel != null:
		ship_panel.visible = false
	if panel != null:
		panel.visible = false
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_capture_before.png")
	print("capture BEFORE: mine=%d depot=%d obs=%d (rival id=%d)" % [
		xp.mine_empire_id, sys_x.depot_empire_id, sys_x.obs_post_empire_id, pB.id])
	# One tick: Crossing is already under the player's influence, so step 8 flips the mine
	# to the player and razes the two military structures.
	sim.tick(SimConstants.TICK_DAYS)
	_recompute_borders()
	_refresh_ui()
	if ship_panel != null:
		ship_panel.visible = false
	if panel != null:
		panel.visible = false
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_capture_after.png")
	print("capture AFTER:  mine=%d depot=%d obs=%d (player id=%d)" % [
		xp.mine_empire_id, sys_x.depot_empire_id, sys_x.obs_post_empire_id, pA.id])
	# --- Supply-range visualization: press a fleet and the SAFE systems light up green (own
	#     border + every system within a depot's supply reach). A fleet pushed outside that
	#     field is flagged red "unsupplied" — the attrition it's taking for lack of supply.
	var sup_sim := Sim.new()
	var sA := sup_sim.add_empire("You", Color(0.35, 0.85, 0.45))
	var sB := sup_sim.add_empire("Rival", Color(0.90, 0.32, 0.30))
	var home_sys := sup_sim.add_system("Home")
	home_sys.map_pos = Vector2(-200, 0)
	var front_sys := sup_sim.add_system("Front")
	front_sys.map_pos = Vector2(-120, 0)
	var mid1_sys := sup_sim.add_system("Edge")
	mid1_sys.map_pos = Vector2(-40, 0)
	var mid2_sys := sup_sim.add_system("Verge")
	mid2_sys.map_pos = Vector2(45, 0)
	var deep_sys := sup_sim.add_system("Deep")
	deep_sys.map_pos = Vector2(140, 0)
	# Home(depot) - Front - Edge - Verge - Deep : Deep is 4 hops out, past the depot's
	# 3-hop supply reach, so the green field runs out before it and the fleet there strands.
	sup_sim.add_lane(home_sys.id, front_sys.id)
	sup_sim.add_lane(front_sys.id, mid1_sys.id)
	sup_sim.add_lane(mid1_sys.id, mid2_sys.id)
	sup_sim.add_lane(mid2_sys.id, deep_sys.id)
	sup_sim.inject_colony(sA.id, sup_sim.add_planet(home_sys.id, "Home I").id, 3000.0, true)
	sup_sim.inject_colony(sB.id, sup_sim.add_planet(deep_sys.id, "Deep I").id, 6000.0, true)
	home_sys.depot_empire_id = sA.id     # a supply depot projects the safe (green) field
	var f_safe := sup_sim._fleet_at(sA.id, home_sys.id)
	f_safe.fighters[0] = 20
	var f_stranded := sup_sim._fleet_at(sA.id, deep_sys.id)   # parked in rival deep space
	f_stranded.fighters[0] = 20
	f_stranded.supply_reserve = 0.0   # reserve already spent -> red "OUT OF SUPPLY"
	sim = sup_sim
	player_empire_id = sA.id
	_storm_bands.clear()
	_events.clear()
	_prev_pcolonies = {}
	_seen_combat = {}
	_prev_pstructs = {}
	_alerts.clear(); _alert_idx = 0
	_hover_hold = false
	_hover_system = -1
	view_system_id = -1
	selected_planet_id = -1
	selected_fleet_id = -1
	selected_fleets = [f_safe.id, f_stranded.id]   # both selected -> supply overlay shows
	_galaxy_cam_pos = Vector2(-30, 0)
	_galaxy_cam_zoom = 2.0
	_apply_camera()
	_recompute_borders()
	_refresh_ui()
	if ship_panel != null:
		ship_panel.visible = false
	if panel != null:
		panel.visible = false
	queue_redraw()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_supply.png")
	_fog_disabled = false
	print("autoshots saved: ", ProjectSettings.globalize_path("user://"))
	get_tree().quit()
