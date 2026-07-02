extends Node2D

# Render/UI layer. Reads Sim state, forwards commands. No game rules live here.

const SPEEDS: Array[float] = [0.0, 1.0, 3.0, 10.0]
# Base clock slowed (1.0 -> 0.5 -> 0.4) so the whole sim reads slower in real
# time; the speed dial multiplies this, so fast-forward is still one click away.
const DAYS_PER_REAL_SECOND := 0.4
const SYSTEM_CENTER := Vector2(510.0, 380.0)

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
const FOG_DISC := 170.0      # lit/gray halo radius around a known system
const FLEET_ICON_OFF := Vector2(0, -17)   # drawn above the system so it stays clickable
const BORDER_INSET := 3.5    # push each empire's border curve into its own territory

var cam: Camera2D
var _panning := false
var _galaxy_cam_pos := Vector2.ZERO   # persisted galaxy pan/zoom across view switches
var _galaxy_cam_zoom := 1.0
var _map_lo := Vector2.ZERO
var _map_hi := Vector2.ZERO
var _border_segments: Array = []   # [a, b, color] line segments
var _border_timer := 0.0
var _system_owner := {}     # system_id -> empire_id, cached with the border field
var _system_visible := {}   # system_id -> bool, currently in the player's VR
var _explored := {}         # system_id -> true, ever seen (gray once out of VR)
var _stale := {}            # system_id -> {owner, colonies}, last-seen snapshot

var raw_label: Label
var goods_label: Label
var day_label: Label
var hint_label: Label
var speed_buttons: Array[Button] = []
var panel: PanelContainer
var panel_title: Label
var panel_body: Label
var colonize_btn: Button
var mine_btn: Button
var emigrate_btn: Button
var fleet_btn: Button


func _ready() -> void:
	# Black space so fogged (unseen) area reads as truly dark, not grey.
	RenderingServer.set_default_clear_color(Color(0.02, 0.02, 0.03))
	sim = Sim.new_demo()
	player_empire_id = sim.empires.keys()[0]  # demo convention: first = human
	_build_ui()
	_init_camera()
	if "--autoshot" in OS.get_cmdline_user_args():
		_autoshot()


func _init_camera() -> void:
	cam = Camera2D.new()
	add_child(cam)
	cam.make_current()
	# Frame the whole galaxy: center on the map's midpoint, zoom to fit.
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for sys in sim.systems.values():
		lo = lo.min(sys.map_pos)
		hi = hi.max(sys.map_pos)
	_map_lo = lo
	_map_hi = hi
	var vp := get_viewport_rect().size
	var span := (hi - lo) + Vector2(240, 240)  # margin so edge systems aren't clipped
	_galaxy_cam_pos = (lo + hi) * 0.5
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
	if view_system_id == -1:
		_border_timer -= delta
		if _border_timer <= 0.0:
			_border_timer = BORDER_REFRESH
			_recompute_borders()
	_apply_camera()
	_refresh_ui()
	queue_redraw()


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
				rv.append(SimConstants.BORDER_A2 * f)
		if pv.size() > 0:
			ids.append(e.id)
			pos.append(pv)
			infl.append(iv)
			reach.append(rv)

	var pk := ids.find(player_empire_id)   # player's index in the arrays, or -1

	# Per-system: current owner, whether it's in the player's VR (visible), and
	# a stale snapshot for the fog memory. VR = the player reaches the point and
	# isn't yet dominated by 1.5x (so it extends past the contested border and
	# retreats as a rival grows). Once seen, a system stays "explored" (gray).
	for sys in sim.systems.values():
		var owner := _owner_at(sys.map_pos, ids, pos, infl, reach)
		_system_owner[sys.id] = owner
		var vis := false
		if pk != -1:
			var pcl := _claim_at(sys.map_pos, pos[pk], infl[pk], reach[pk])
			if pcl > 0.0:
				var bo := 0.0
				for k in ids.size():
					if k != pk:
						bo = maxf(bo, _claim_at(sys.map_pos, pos[k], infl[k], reach[k]))
				vis = pcl * SimConstants.SIGHT_INFLUENCE_FACTOR >= bo
		_system_visible[sys.id] = vis
		if vis:
			_explored[sys.id] = true
			var cc := 0
			for pid in sys.planet_ids:
				if sim.planets[pid].colony != null:
					cc += 1
			_stale[sys.id] = {"owner": owner, "colonies": cc}

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

	# VR per corner point (same rule as per-system), to fog-gate border segments.
	var vrgrid := PackedByteArray()
	vrgrid.resize(pcols * prows)
	for pi in pcols * prows:
		var vis := false
		if pk != -1:
			var pcl: float = claims[pk][pi]
			if pcl > 0.0:
				vis = pcl * SimConstants.SIGHT_INFLUENCE_FACTOR \
					>= _best_other(claims, pk, pi)
		vrgrid[pi] = 1 if vis else 0

	# Live system positions — borders are only drawn near them, so a border can't
	# float in black space far from any visible system (which happens because a
	# mature colony's raw reach can exceed the whole map — see balance note).
	var live_pos: Array = []
	for sys in sim.systems.values():
		if _sys_live(sys.id):
			live_pos.append(sys.map_pos)

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
				if vrgrid[i_tl] == 0:   # fog: only draw border where the player sees
					continue
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
					var near := false
					for lp in live_pos:
						if mid.distance_squared_to(lp) <= FOG_DISC * FOG_DISC:
							near = true
							break
					if near:
						_border_segments.append([seg[0] + off, seg[1] + off, col])


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


# Galaxy view: free pan/zoom (persisted). System view: locked so SYSTEM_CENTER
# drawing maps 1:1 to the screen (camera position = screen centre at zoom 1).
func _apply_camera() -> void:
	if view_system_id == -1:
		cam.position = _galaxy_cam_pos
		cam.zoom = Vector2(_galaxy_cam_zoom, _galaxy_cam_zoom)
	else:
		cam.position = get_viewport_rect().size * 0.5
		cam.zoom = Vector2.ONE


func _unhandled_input(event: InputEvent) -> void:
	# Galaxy view only: right-drag to pan, wheel to zoom.
	if view_system_id == -1 and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_panning = event.pressed
			return
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_galaxy_cam_zoom = clampf(_galaxy_cam_zoom * 1.1, ZOOM_MIN, ZOOM_MAX)
			return
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_galaxy_cam_zoom = clampf(_galaxy_cam_zoom / 1.1, ZOOM_MIN, ZOOM_MAX)
			return
	if view_system_id == -1 and _panning and event is InputEventMouseMotion:
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
				view_system_id = -1
				selected_planet_id = -1


func _select_at(pos: Vector2) -> void:
	if view_system_id == -1:
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
				return
		# 3. Click a known system to inspect it (never-seen ones aren't clickable).
		for sys in sim.systems.values():
			if pos.distance_to(sys.map_pos) <= 20.0 and _sys_known(sys.id):
				view_system_id = sys.id
				selected_planet_id = -1
				selected_fleet_id = -1
				return
		selected_fleet_id = -1   # clicked empty space -> deselect
		return
	selected_planet_id = -1
	for pid in sim.systems[view_system_id].planet_ids:
		var planet: Planet = sim.planets[pid]
		if pos.distance_to(_planet_pos(planet)) <= 16.0:
			selected_planet_id = planet.id
			return


func _planet_pos(planet: Planet) -> Vector2:
	return SYSTEM_CENTER + Vector2.from_angle(planet.orbit_angle) * planet.orbit_radius


var _fog_disabled := false   # debug/screenshot only


func _sys_live(sid: int) -> bool:     # currently in the player's VR
	return _fog_disabled or _system_visible.get(sid, false)


func _sys_known(sid: int) -> bool:    # visible now OR explored before (gray)
	return _fog_disabled or _system_visible.get(sid, false) or _explored.has(sid)


func _draw() -> void:
	if view_system_id == -1:
		_draw_galaxy()
	else:
		_draw_system(sim.systems[view_system_id])


func _draw_galaxy() -> void:
	var font := ThemeDB.fallback_font
	# Fog halos on the black background: a lit grey disc under LIVE systems, a
	# darker grey disc under EXPLORED (out-of-VR) systems, nothing under
	# never-seen. So the lost-VR area reads as grey, unexplored as black.
	for sys in sim.systems.values():
		if _sys_live(sys.id):
			draw_circle(sys.map_pos, FOG_DISC, Color(0.13, 0.13, 0.15))
		elif _sys_known(sys.id):
			draw_circle(sys.map_pos, FOG_DISC, Color(0.07, 0.07, 0.08))
	# Deformed influence borders (already fog-gated to VR in _recompute_borders).
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
			# Live: bright, current owner ring + current colony count.
			draw_circle(sys.map_pos, 9.0, Color(1.0, 0.85, 0.35))
			var owner: int = _system_owner.get(sys.id, -1)
			if owner != -1:
				draw_arc(sys.map_pos, 13.0, 0.0, TAU, 32,
					sim.empires[owner].color, 2.0)
			var cc := 0
			for pid in sys.planet_ids:
				if sim.planets[pid].colony != null:
					cc += 1
			if cc > 0:
				draw_string(font, sys.map_pos + Vector2(14.0, -12.0), str(cc),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.35, 1.0, 0.5))
			draw_string(font, sys.map_pos + Vector2(-60.0, 26.0), sys.name,
				HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(1, 1, 1, 0.65))
		else:
			# Explored but out of VR: grey, with the STALE last-seen snapshot.
			draw_circle(sys.map_pos, 7.0, Color(0.45, 0.45, 0.5))
			var snap: Dictionary = _stale.get(sys.id, {})
			var sowner: int = snap.get("owner", -1)
			if sowner != -1:
				var gc: Color = sim.empires[sowner].color
				gc.a = 0.4
				draw_arc(sys.map_pos, 13.0, 0.0, TAU, 32, gc, 1.5)
			var scc: int = snap.get("colonies", 0)
			if scc > 0:
				draw_string(font, sys.map_pos + Vector2(14.0, -12.0), str(scc),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.5, 0.7, 0.55, 0.6))
			draw_string(font, sys.map_pos + Vector2(-60.0, 26.0), sys.name,
				HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(1, 1, 1, 0.35))

	# Fleets: your own always visible; a rival's only while it sits in your VR.
	# Drawn as a diamond in the empire's colour; a selected fleet gets a ring and
	# a dashed line to its destination.
	for f in sim.fleets:
		var own := f.empire_id == player_empire_id
		if not (own or _sys_live(f.system_id)):
			continue
		var fp := sim.fleet_position(f) + FLEET_ICON_OFF   # above the system node
		var col: Color = sim.empires[f.empire_id].color
		draw_colored_polygon(PackedVector2Array([
			fp + Vector2(0, -6), fp + Vector2(6, 0),
			fp + Vector2(0, 6), fp + Vector2(-6, 0)]), col)
		if f.id == selected_fleet_id:
			draw_arc(fp, 10.0, 0.0, TAU, 24, Color.WHITE, 1.5)
			if f.is_moving():
				draw_line(fp, sim.systems[f.path[f.path.size() - 1]].map_pos,
					Color(1, 1, 1, 0.4), 1.0)


func _draw_system(sys: StarSystem) -> void:
	var font := ThemeDB.fallback_font
	draw_circle(SYSTEM_CENTER, 18.0, Color(1.0, 0.85, 0.35))
	draw_string(font, SYSTEM_CENTER + Vector2(-60.0, -30.0), sys.name,
		HORIZONTAL_ALIGNMENT_CENTER, 120, 13, Color(1, 1, 1, 0.5))
	for pid in sys.planet_ids:
		var planet: Planet = sim.planets[pid]
		draw_arc(SYSTEM_CENTER, planet.orbit_radius, 0.0, TAU, 96,
			Color(1, 1, 1, 0.08), 1.0)
		var pos := _planet_pos(planet)
		draw_circle(pos, 7.0, Color(0.55, 0.6, 0.7))
		if planet.has_deposit():
			var dep_col := Color(0.4, 0.85, 1.0) \
				if planet.deposit_type == SimConstants.Deposit.WATER \
				else Color(0.9, 0.6, 0.35)
			draw_circle(pos + Vector2(9.0, -9.0), 3.0, dep_col)
		if planet.has_mine():
			draw_rect(Rect2(pos + Vector2(-14.0, -14.0), Vector2(6.0, 6.0)),
				Color(0.95, 0.8, 0.35))
		if planet.colony != null:
			var ring := Color(0.35, 1.0, 0.5) if planet.colony.established \
				else Color(1.0, 0.7, 0.25)
			draw_arc(pos, 11.0, 0.0, TAU, 32, ring, 2.0)
		if planet.id == selected_planet_id:
			draw_arc(pos, 14.5, 0.0, TAU, 32, Color.WHITE, 1.2)
		draw_string(font, pos + Vector2(-60.0, 26.0), planet.name,
			HORIZONTAL_ALIGNMENT_CENTER, 120, 11, Color(1, 1, 1, 0.65))


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
	day_label = Label.new()
	for l in [raw_label, goods_label, day_label]:
		bar.add_child(l)

	hint_label = Label.new()
	hint_label.modulate = Color(1, 1, 1, 0.5)
	hint_label.position = Vector2(16.0, 40.0)
	layer.add_child(hint_label)

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
	panel.offset_top = -120.0
	panel.offset_bottom = 120.0
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)
	panel_title = Label.new()
	panel_body = Label.new()
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
	fleet_btn = Button.new()
	fleet_btn.text = "Build fleet (%d alloys)" % int(SimConstants.FLEET_COST_ALLOYS)
	fleet_btn.pressed.connect(_on_build_fleet)
	vbox.add_child(panel_title)
	vbox.add_child(panel_body)
	vbox.add_child(colonize_btn)
	vbox.add_child(mine_btn)
	vbox.add_child(emigrate_btn)
	vbox.add_child(fleet_btn)


func _on_colonize() -> void:
	if selected_planet_id != -1:
		sim.found_colony(player_empire_id, selected_planet_id)


func _on_build_mine() -> void:
	if selected_planet_id != -1:
		sim.build_mine(player_empire_id, selected_planet_id)


func _on_emigrate() -> void:
	if selected_planet_id != -1:
		sim.toggle_emigration(player_empire_id, selected_planet_id)


func _on_build_fleet() -> void:
	if view_system_id != -1:
		sim.build_fleet(player_empire_id, view_system_id)


func _refresh_ui() -> void:
	var player: Empire = sim.empires[player_empire_id]
	raw_label.text = "Water %.0f · Minerals %.0f" % [player.water, player.minerals]
	goods_label.text = "Food %.0f · Alloys %.0f" % [player.food, player.alloys]
	day_label.text = "Day %.1f" % sim.day
	hint_label.text = "Right-drag pan · wheel zoom · click a system" \
		if view_system_id == -1 else "Esc — back to galaxy"
	for i in speed_buttons.size():
		speed_buttons[i].button_pressed = (i == speed_idx)

	var planet: Planet = sim.planets.get(selected_planet_id)
	panel.visible = planet != null and view_system_id != -1
	if not panel.visible:
		return
	panel_title.text = planet.name
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
		panel_body.text = "Uncolonized. %s%s\n\nFounding a colony costs %d alloys. It eats food (a drain) until it grows to %d population and becomes a city that refines resources." \
			% [deposit_line, influence_note, int(SimConstants.FOUND_COST_ALLOYS),
				int(SimConstants.ACTIVATION_POP)]
		colonize_btn.visible = true
		colonize_btn.disabled = not sim.can_found_colony(player_empire_id, planet.id)
	else:
		var c := planet.colony
		var status := "ESTABLISHED CITY" if c.established \
			else "growing… %d%% to activation" % int(c.activation_progress() * 100.0)
		var neighbor_mult := sim.neighbor_growth_multiplier(c)
		var refine := ""
		if c.established:
			refine = "\nRefines ≤%.1f food/day, ≤%.1f alloys/day (if input)" \
				% [c.food_capacity(), c.alloy_capacity()]
		panel_body.text = "Owner: %s\nStatus: %s\nPopulation: %.1f\nNeighbor bonus: +%d%% growth%s\n%s" \
			% [sim.empires[c.empire_id].name, status, c.population,
				int((neighbor_mult - 1.0) * 100.0), refine, deposit_line]
		colonize_btn.visible = false
	mine_btn.visible = planet.has_deposit() and not planet.has_mine()
	mine_btn.disabled = not sim.can_build_mine(player_empire_id, planet.id)
	# Emigration toggle: only for the player's own colonies.
	var own_colony: bool = planet.colony != null \
		and planet.colony.empire_id == player_empire_id
	emigrate_btn.visible = own_colony
	if own_colony:
		emigrate_btn.text = "Encourage immigration: ON" if planet.colony.emigrating \
			else "Encourage immigration: off"
	# Build fleet: available when the player has any colony in this system.
	fleet_btn.visible = sim._empire_has_colony_in(player_empire_id, view_system_id)
	fleet_btn.disabled = not sim.can_build_fleet(player_empire_id, view_system_id)


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
	# Build a fleet at home and send it to a neighbour so a fleet marker + its
	# move line show in the galaxy shot.
	var home_sys: int = sim.systems.values()[0].id
	var fl := sim.build_fleet(player_empire_id, home_sys)
	if fl != null:
		var nbrs := sim.lane_neighbors(home_sys)
		if not nbrs.is_empty():
			sim.order_fleet(fl.id, nbrs[0])
		selected_fleet_id = fl.id
	# Fog stays ON for the galaxy shot so the live / gray-explored / black states
	# and the border inside the player's VR all show.
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
