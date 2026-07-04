extends Node2D

# Render/UI layer. Reads Sim state, forwards commands. No game rules live here.

const SPEEDS: Array[float] = [0.0, 1.0, 3.0, 10.0]
# Base clock slowed (1.0 -> 0.5 -> 0.4) so the whole sim reads slower in real
# time; the speed dial multiplies this, so fast-forward is still one click away.
const DAYS_PER_REAL_SECOND := 0.4

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
const BORDER_CELL := 14.0
const BORDER_REFRESH := 0.4
const BORDER_EPS := 0.01     # tiny rival-claim floor so bubble-vs-empty edges draw
const FOG_CELL := 16.0       # sample cell for the fog texture (linearly filtered)
# VR fill. The fog must reach PAST the border (the border is your influence edge;
# the fog is your SIGHT, which sees further). VR_SIGHT_REACH is how far sight
# extends beyond influence reach — the player's fog claim is sampled with reach
# scaled by this, so the field exists (and feathers) past the border instead of
# hard-cutting at it. VR_CLAIM_FLOOR is the open-space fade threshold, tuned so the
# feather completes around the extended sight edge (no hard disc). VR_BAND is the
# feather width in claim-ratio units. Fog stays soft/organic; border sits inside it.
const VR_SIGHT_REACH := 1.5
const VR_CLAIM_FLOOR := 1.1
const VR_BAND := 0.6
const SAVE_PATH := "user://reach_save.json"
const FLEET_ICON_OFF := Vector2(0, -17)   # drawn above the system so it stays clickable
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

var raw_label: Label
var goods_label: Label
var mil_label: Label
var day_label: Label
var standing_label: Label
var hint_label: Label
var event_label: Label          # top-left feed of recent autonomous events
var _events: Array = []         # [day, text] recent events, newest last
var _prev_pcolonies: Dictionary = {}  # planet_id -> system_id, player's colonies
var _seen_combat: Dictionary = {}     # system_id -> last combat day already logged
var speed_buttons: Array[Button] = []
var panel: PanelContainer
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
var overlay_title: Label
var overlay_resume: Button
var overlay_save: Button
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
		while day_accum >= SimConstants.TICK_DAYS:
			sim.tick(SimConstants.TICK_DAYS)
			day_accum -= SimConstants.TICK_DAYS
	_border_timer -= delta
	if _border_timer <= 0.0:
		_border_timer = BORDER_REFRESH
		_recompute_borders()
	_update_hover()
	_scan_events()
	_check_game_over()
	_apply_camera()
	_refresh_ui()
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
func _recompute_borders() -> void:
	_border_segments.clear()
	_system_owner.clear()
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
		if _player_vr_at(sys.map_pos, ids, pos, infl, reach_vr, pk) \
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

	# Influence-shaped fog: sample a CONTINUOUS VR value on a grid and bake it into
	# a texture (drawn with linear filtering) so the lit region reads as the smooth
	# influence shape with a feathered edge — not axis-aligned blocks, not a hard
	# reach disc. Per cell: v in [0,1] = how deep inside VR it is; v>0 marks the
	# cell explored (grey memory once it later drops out of VR).
	var flo := _map_lo - Vector2(140, 140)
	var fhi := _map_hi + Vector2(140, 140)
	var fcols: int = maxi(1, int((fhi.x - flo.x) / FOG_CELL) + 1)
	var frows: int = maxi(1, int((fhi.y - flo.y) / FOG_CELL) + 1)
	var sight: float = SimConstants.SIGHT_INFLUENCE_FACTOR
	var img := Image.create(fcols, frows, false, Image.FORMAT_RGBA8)
	for gy in frows:
		for gx in fcols:
			var c := Vector2(flo.x + (gx + 0.5) * FOG_CELL, flo.y + (gy + 0.5) * FOG_CELL)
			var v := 0.0
			if pk != -1:
				# Player claim on extended SIGHT reach so the fog reaches past the
				# border; rivals on their real reach (that's their actual presence).
				var pc := _claim_at(c, pos[pk], infl[pk], reach_vr[pk])
				if pc > 0.0:
					var rival := 0.0
					for k in ids.size():
						if k != pk:
							rival = maxf(rival, _claim_at(c, pos[k], infl[k], reach[k]))
					# Feather by claim ratio: fully lit well inside, fading to 0 at the
					# VR limit (rival dominance at borders, or the open-space floor).
					var ratio := pc * sight / maxf(rival, VR_CLAIM_FLOOR)
					v = clampf((ratio - 1.0) / VR_BAND, 0.0, 1.0)
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
	_fog_tex = ImageTexture.create_from_image(img)
	_fog_rect = Rect2(flo, fhi - flo)

	# Sample each empire's claim on a grid of POINTS (cell corners), then trace a
	# smooth marching-squares contour of every empire's dominance margin
	# (claim_E − strongest rival claim). The zero-contour is that empire's border
	# — the hostile seam AND its bubble edge against empty space — as an
	# interpolated CURVE, not an axis-aligned staircase.
	var lo := _map_lo - Vector2(140, 140)
	var hi := _map_hi + Vector2(140, 140)
	var pcols := int((hi.x - lo.x) / BORDER_CELL) + 2   # +1 cells -> +2 corners
	var prows := int((hi.y - lo.y) / BORDER_CELL) + 2
	var claims: Array = []   # claims[k] = PackedFloat32Array over all corner points
	for k in ids.size():
		var arr := PackedFloat32Array()
		arr.resize(pcols * prows)
		for gy in prows:
			for gx in pcols:
				arr[gy * pcols + gx] = _claim_at(
					Vector2(lo.x + gx * BORDER_CELL, lo.y + gy * BORDER_CELL),
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
				var p_tl := Vector2(lo.x + cx * BORDER_CELL, lo.y + cy * BORDER_CELL)
				var p_tr := p_tl + Vector2(BORDER_CELL, 0)
				var p_br := p_tl + Vector2(BORDER_CELL, BORDER_CELL)
				var p_bl := p_tl + Vector2(0, BORDER_CELL)
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
					# Only draw border the player can actually see (its own VR).
					if _player_vr_at(mid, ids, pos, infl, reach_vr, pk):
						_border_segments.append([seg[0] + off, seg[1] + off, col])


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
	var si := 0.0
	var sri := 0.0
	for j in pv.size():
		var d := p.distance_to(pv[j])
		if d <= rv[j]:
			si += iv[j]
			sri += d * iv[j]
	if si <= 0.0:
		return 0.0
	return 1.0e9 if sri <= 0.0 else (si * si) / sri


# Is a world point in the player's VR? True where the player's claim, scaled by
# SIGHT, still beats the strongest rival there — so VR fills the player's actual
# influence and reaches 1.5x in front of the contested border.
func _player_vr_at(p: Vector2, ids: Array, pos: Array, infl: Array, reach: Array,
		pk: int) -> bool:
	if pk == -1:
		return false
	var pc := _claim_at(p, pos[pk], infl[pk], reach[pk])
	if pc <= 0.0:
		return false
	var best := pc
	for k in ids.size():
		if k != pk:
			best = maxf(best, _claim_at(p, pos[k], infl[k], reach[k]))
	return pc * SimConstants.SIGHT_INFLUENCE_FACTOR >= best


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
		match event.keycode:
			KEY_SPACE:
				speed_idx = 0 if speed_idx != 0 else 1
			KEY_1:
				speed_idx = 1
			KEY_2:
				speed_idx = 2
			KEY_3:
				speed_idx = 3
			KEY_ESCAPE:
				# Close an open overlay first; otherwise deselect.
				if intro_overlay != null and intro_overlay.visible:
					intro_overlay.visible = false
					speed_idx = 1
				elif legend_panel != null and legend_panel.visible:
					legend_panel.visible = false
				else:
					view_system_id = -1
					selected_planet_id = -1
					selected_fleet_id = -1
			KEY_F5:
				save_game()
			KEY_F9:
				load_game()
			KEY_L:
				if legend_panel != null:
					legend_panel.visible = not legend_panel.visible


func _select_at(pos: Vector2) -> void:
	# 1. With a fleet selected, a click on a known system orders it there.
	if selected_fleet_id != -1:
		for sys in sim.systems.values():
			if pos.distance_to(sys.map_pos) <= 20.0 and _sys_known(sys.id):
				sim.order_fleet(selected_fleet_id, sys.id)
				selected_fleet_id = -1
				return
	# 2. Click near one of your fleets (drawn above its system) to select it.
	for f in sim.fleets:
		if f.empire_id == player_empire_id \
				and pos.distance_to(sim.fleet_position(f) + FLEET_ICON_OFF) <= 12.0:
			selected_fleet_id = f.id
			view_system_id = -1
			return
	# 3. Click a known system to open its planet-list menu (side panel).
	for sys in sim.systems.values():
		if pos.distance_to(sys.map_pos) <= 20.0 and _sys_known(sys.id):
			view_system_id = sys.id
			selected_planet_id = -1
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
	# Deep-space backdrop: faint static stars, behind everything.
	for s in _starfield:
		draw_circle(s[0], s[1], s[2])
	# Influence-shaped fog on the black background: one baked texture, drawn with
	# linear filtering (see _ready) so the feathered lit region hugs the player's
	# actual influence with a smooth edge — no blocks, no hard reach disc. Lit fades
	# to grey explored-memory to never-seen black. Baked in the border refresh.
	if _fog_tex != null:
		draw_texture_rect(_fog_tex, _fog_rect, false)
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
			if cc > 0:
				draw_string(font, sys.map_pos + Vector2(14.0, -12.0), str(cc),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.35, 1.0, 0.5))
			draw_string(font, sys.map_pos + Vector2(-60.0, 26.0), sys.name,
				HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(1, 1, 1, 0.65))
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
			var scc := 0
			for pinfo in snap.get("planets", {}).values():
				if pinfo.get("colony", false):
					scc += 1
			if scc > 0:
				draw_string(font, sys.map_pos + Vector2(14.0, -12.0), str(scc),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.5, 0.7, 0.55, 0.6))
			draw_string(font, sys.map_pos + Vector2(-60.0, 26.0), sys.name,
				HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(1, 1, 1, 0.35))

	# Combat flash: a fading red starburst on systems where a fight/bombardment
	# happened recently and the player can see it — so combat isn't silent.
	for sid in sim.combat_at:
		if not _sys_live(sid) or not sim.systems.has(sid):
			continue
		var age: float = sim.day - sim.combat_at[sid]
		if age < 0.0 or age > COMBAT_FLASH_DAYS:
			continue
		var a: float = (1.0 - age / COMBAT_FLASH_DAYS) * 0.9
		var p: Vector2 = sim.systems[sid].map_pos
		var fc := Color(1.0, 0.35, 0.2, a)
		for k in 4:
			var d := Vector2.RIGHT.rotated(k * PI / 4.0) * 11.0
			draw_line(p - d, p + d, fc, 2.0)

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
func _hover_summary(sid: int) -> String:
	var sys: StarSystem = sim.systems[sid]
	if _sys_live(sid):
		var owner: int = _system_owner.get(sid, -1)
		var oname: String = sim.empires[owner].name if owner != -1 else "unclaimed"
		var pop := 0.0
		var cc := 0
		for pid in sys.planet_ids:
			var c: Colony = sim.planets[pid].colony
			if c != null:
				pop += c.population
				cc += 1
		return "%s — %s · pop %s · %d colonies" % [sys.name, oname, _fmt_num(pop), cc]
	var snap: Dictionary = _stale.get(sid, {})
	var so: int = snap.get("owner", -1)
	var oname2: String = sim.empires[so].name if so != -1 else "unknown"
	var cc2 := 0
	for pinfo in snap.get("planets", {}).values():
		if pinfo.get("colony", false):
			cc2 += 1
	return "%s — last seen: %s · %d colonies" % [sys.name, oname2, cc2]


func _fmt_num(v: float) -> String:
	# Compact big numbers for the status bar (21214 -> "21.2k").
	if v >= 1000.0:
		return "%.1fk" % (v / 1000.0)
	return "%.0f" % v


func _star_color(sid: int) -> Color:
	# Deterministic spectral tint per system so the map reads as varied real stars.
	match sid % 5:
		0: return Color(0.72, 0.83, 1.0)   # blue-white
		1: return Color(1.0, 1.0, 1.0)     # white
		2: return Color(1.0, 0.95, 0.82)   # warm white
		3: return Color(1.0, 0.85, 0.5)    # amber
		_: return Color(1.0, 0.62, 0.42)   # orange-red


func _draw_star(pos: Vector2, col: Color, intensity: float, scale := 1.0) -> void:
	# Soft glow (stacked low-alpha discs) under a bright near-white core. scale grows
	# the whole star with the system's population, so bigger powers read at a glance.
	var g := col
	for i in 3:
		g.a = (0.05 + i * 0.05) * intensity
		draw_circle(pos, (12.0 - i * 3.0) * scale, g)
	var core := col.lerp(Color.WHITE, 0.45)
	core.a = 0.55 + 0.45 * intensity
	draw_circle(pos, (4.2 + 0.8 * intensity) * scale, core)


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
			# Shape-coded so it reads without relying on colour: water = round
			# droplet (blue), minerals = diamond (amber).
			if p.deposit_type == SimConstants.Deposit.WATER:
				draw_circle(c, 4.6, Color(0.4, 0.85, 1.0))
				draw_circle(c + Vector2(-1.3, -1.3), 1.3, Color(1, 1, 1, 0.7))
			else:
				draw_colored_polygon(PackedVector2Array([
					c + Vector2(0, -5), c + Vector2(5, 0),
					c + Vector2(0, 5), c + Vector2(-5, 0)]), Color(0.95, 0.62, 0.3))
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


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	layer.add_child(top)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 24)
	top.add_child(bar)

	raw_label = Label.new()
	goods_label = Label.new()
	mil_label = Label.new()
	day_label = Label.new()
	standing_label = Label.new()
	standing_label.modulate = Color(1, 1, 1, 0.75)
	for l in [raw_label, goods_label, mil_label, day_label, standing_label]:
		bar.add_child(l)
	# Colour-code the groups so the eye separates raw / goods / military at a glance.
	raw_label.modulate = Color(0.6, 0.8, 1.0)     # T0 raw — cool blue
	goods_label.modulate = Color(0.6, 1.0, 0.7)   # T1 goods — green
	mil_label.modulate = Color(1.0, 0.7, 0.55)    # military — warm

	hint_label = Label.new()
	hint_label.modulate = Color(1, 1, 1, 0.5)
	hint_label.position = Vector2(16.0, 40.0)
	layer.add_child(hint_label)

	event_label = Label.new()
	event_label.position = Vector2(16.0, 64.0)
	event_label.add_theme_font_size_override("font_size", 12)
	event_label.modulate = Color(1, 0.9, 0.7, 0.85)
	layer.add_child(event_label)

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
	layer.add_child(panel)
	# Explicit anchors/offsets — the preset helpers size from the internal
	# minimum (just the stylebox) and ignore custom_minimum_size, which pushed
	# the panel off-screen. 280x240, pinned 12px inside the right edge.
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -292.0
	panel.offset_right = -12.0
	panel.offset_top = -50.0    # sits below the top-right shipyard panel
	panel.offset_bottom = 290.0
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)
	panel_title = Label.new()
	planet_list = VBoxContainer.new()   # one selectable row per planet
	planet_list.add_theme_constant_override("separation", 2)
	panel_body = Label.new()            # detail for the selected planet / fleet
	panel_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
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
	_build_intro(layer)


# One-time welcome for a new game: what this game is and the first things to do.
# Shown paused; dismissed with Begin. Not shown on a loaded save or the autoshot.
func _build_intro(layer: CanvasLayer) -> void:
	intro_overlay = PanelContainer.new()
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
	body.text = "You have no body and no direct control — you cultivate a population and it does the rest.\n\n• Click a system to open its planets. Found a colony (costs alloys) or build a mine on a deposit.\n• Colonies grow on food: water mines → food in established cities. Minerals → alloys. Population drives influence, and influence sets your borders.\n• Cluster colonies across nearby systems — neighbours boost each other. Same-system colonies compete instead.\n• Build ships (top-right) to defend and to bombard enemy worlds. Use the speed dial (top-right) to skip slow stretches.\n• Press L for a legend of every map symbol.\n\nGoal: grow, spread, and outlast the rival empires."
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
	]
	for i in lines.size():
		var l := Label.new()
		l.text = lines[i]
		l.add_theme_font_size_override("font_size", 11)
		l.modulate = Color(1, 1, 1, 0.85) if i == 0 else Color(1, 1, 1, 0.6)
		v.add_child(l)


func _build_menu_overlay(layer: CanvasLayer) -> void:
	menu_overlay = PanelContainer.new()
	menu_overlay.set_anchors_preset(Control.PRESET_CENTER)
	menu_overlay.anchor_left = 0.5
	menu_overlay.anchor_right = 0.5
	menu_overlay.anchor_top = 0.5
	menu_overlay.anchor_bottom = 0.5
	menu_overlay.offset_left = -130
	menu_overlay.offset_right = 130
	menu_overlay.offset_top = -110
	menu_overlay.offset_bottom = 110
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
	var quit := Button.new()
	quit.text = "Quit to menu"
	quit.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://menu/menu.tscn"))
	v.add_child(quit)


# Top-right shipyard: a Fighter and Bomber build button per tier 1-5. Each click
# builds one ship at the empire's most-populated city; a button is enabled only
# when that tier's national resource can pay for it.
func _build_ship_panel(layer: CanvasLayer) -> void:
	var sp := PanelContainer.new()
	sp.anchor_left = 1.0
	sp.anchor_right = 1.0
	sp.offset_left = -232.0
	sp.offset_right = -12.0
	sp.offset_top = 40.0
	layer.add_child(sp)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	sp.add_child(box)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 3)
	box.add_child(grid)
	for s in ["Build", "Fighter", "Bomber"]:
		var h := Label.new()
		h.text = s
		grid.add_child(h)
	for t in range(1, 6):
		var lab := Label.new()
		lab.text = "Tier %d" % t
		grid.add_child(lab)
		var fb := Button.new()
		fb.text = "F%d" % t
		fb.pressed.connect(func() -> void:
			sim.build_ship(player_empire_id, SimConstants.Role.FIGHTER, t))
		grid.add_child(fb)
		ship_f_btns.append(fb)
		var bb := Button.new()
		bb.text = "B%d" % t
		bb.pressed.connect(func() -> void:
			sim.build_ship(player_empire_id, SimConstants.Role.BOMBER, t))
		grid.add_child(bb)
		ship_b_btns.append(bb)
	# Clarify what ships are paid with — the tier's military resource ("Mil T1-5"
	# in the top bar), NOT alloys. Alloys are the civilian material that feeds the
	# tier-1 military resource.
	var note := Label.new()
	note.text = "Each ship: %d of that tier's Mil (top bar)" \
		% int(SimConstants.SHIP_NAT_COST)
	note.add_theme_font_size_override("font_size", 10)
	note.modulate = Color(1, 1, 1, 0.5)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(note)


func _on_colonize() -> void:
	if selected_planet_id != -1:
		sim.found_colony(player_empire_id, selected_planet_id)


func _on_build_mine() -> void:
	if selected_planet_id != -1:
		sim.build_mine(player_empire_id, selected_planet_id)


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
	raw_label.text = "Water %.0f · Minerals %.0f" % [player.water, player.minerals]
	goods_label.text = "Food %.0f · Alloys %.0f" % [player.food, player.alloys]
	mil_label.text = "Mil T1-5: %.0f·%.0f·%.0f·%.0f·%.0f" % \
		[player.nat[0], player.nat[1], player.nat[2], player.nat[3], player.nat[4]]
	day_label.text = "Day %.1f" % sim.day
	# Player's own standing (no fog concern — it's your empire): systems / pop /
	# colonies, so you can gauge where you stand without counting the map.
	var psys := 0
	for sys in sim.systems.values():
		if sim.system_owner(sys.id) == player_empire_id:
			psys += 1
	var ppop := 0.0
	var pcol := 0
	for c in sim.colonies:
		if c.empire_id == player_empire_id:
			ppop += c.population
			pcol += 1
	standing_label.text = "◆ Systems %d · Pop %s · Colonies %d" \
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
		hint_label.text = "Click a system to send the fleet · Esc to deselect"
		_show_fleet_panel(fleet)
		return
	if view_system_id != -1 and sim.systems.has(view_system_id):
		hint_label.text = "Pick a planet · Esc to close"
		_show_system_panel(view_system_id)
		return
	if _hover_system != -1 and _sys_known(_hover_system):
		hint_label.text = _hover_summary(_hover_system)
	else:
		hint_label.text = "Right-drag pan · wheel zoom · click a system or fleet · L: legend"
	panel.visible = false
	_panel_system = -1


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
	panel_body.text = "At: %s%s\nCombat %.0f · Bomb %.0f\n%s" % [loc,
		"  → moving" if fleet.is_moving() else "",
		fleet.combat_power(), fleet.bomb_power(), comp]
	for b in [colonize_btn, mine_btn, emigrate_btn, upgrade_btn, spec_food_btn,
			spec_alloy_btn, depot_btn]:
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
	planet_list.visible = true
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
	if planet.colony == null:
		panel_body.text = "%s%s\n\nFounding costs %d alloys; the colony eats food until it reaches %d pop and becomes a refining city." \
			% [deposit_line, influence_note, int(SimConstants.FOUND_COST_ALLOYS),
				int(SimConstants.ACTIVATION_POP)]
		colonize_btn.visible = true
		colonize_btn.disabled = not sim.can_found_colony(player_empire_id, planet.id)
	else:
		var c := planet.colony
		var status := "ESTABLISHED CITY" if c.established \
			else "growing… %d%% to activation" % int(c.activation_progress() * 100.0)
		var nb := sim.neighbor_growth_multiplier(c)
		var refine := ""
		if c.established:
			refine = "\nRefines ≤%.1f food, ≤%.1f alloys /day" \
				% [c.food_capacity(), c.alloy_capacity()]
		panel_body.text = "Owner: %s\n%s\nPop: %.1f · neighbor +%d%%%s\n%s" \
			% [sim.empires[c.empire_id].name, status, c.population,
				int((nb - 1.0) * 100.0), refine, deposit_line]
		colonize_btn.visible = false
	mine_btn.visible = planet.has_deposit() and not planet.has_mine()
	mine_btn.disabled = not sim.can_build_mine(player_empire_id, planet.id)
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
	spec_food_btn.visible = can_spec
	spec_alloy_btn.visible = can_spec
	if can_spec:
		var sp: int = planet.colony.spec
		spec_food_btn.text = ("◆ " if sp == SimConstants.Spec.FOOD else "") \
			+ "Specialize food"
		spec_alloy_btn.text = ("◆ " if sp == SimConstants.Spec.ALLOY else "") \
			+ "Specialize alloys"


# Debug hook for automated visual verification: found a colony, run fast for a
# couple of real seconds, save galaxy + system screenshots, quit.
func _autoshot() -> void:
	var home: StarSystem = sim.systems.values()[0]
	sim.build_mine(player_empire_id, home.planet_ids[0])
	sim.found_colony(player_empire_id, home.planet_ids[1])
	# For the screenshot only: let the player expand too (via the same AI), so it
	# meets the rival and the border falls inside player sight — otherwise fog
	# correctly hides it. Not part of normal play.
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
	_hover_system = home.id
	_recompute_borders()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_galaxy.png")
	view_system_id = home.id
	selected_planet_id = home.planet_ids[0]
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot.png")
	print("autoshots saved: ", ProjectSettings.globalize_path("user://"))
	get_tree().quit()
