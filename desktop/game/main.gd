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
var view_system_id := -1  # -1 = galaxy view, otherwise the focused system

const ZOOM_MIN := 0.35
const ZOOM_MAX := 2.5

# Border field: sampled on a world grid, refreshed on a timer (borders drift
# slowly, so per-frame recompute is wasted work). Each entry is [center, color]
# for a frontier cell — drawn as a dot at the cell's own centre so each empire's
# edge sits inside its territory and hostile seams show BOTH colours.
const BORDER_CELL := 14.0
const BORDER_REFRESH := 0.4

var cam: Camera2D
var _panning := false
var _galaxy_cam_pos := Vector2.ZERO   # persisted galaxy pan/zoom across view switches
var _galaxy_cam_zoom := 1.0
var _map_lo := Vector2.ZERO
var _map_hi := Vector2.ZERO
var _border_segments: Array = []   # [a, b, color] line segments
var _border_timer := 0.0
var _system_owner := {}   # system_id -> empire_id, cached with the border field
var _sight: Array = []   # player's sight-source world positions, refreshed per frame

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


func _ready() -> void:
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
	_sight = sim.sight_sources(player_empire_id)
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

	for sys in sim.systems.values():
		_system_owner[sys.id] = _owner_at(sys.map_pos, ids, pos, infl, reach)

	var lo := _map_lo - Vector2(140, 140)
	var hi := _map_hi + Vector2(140, 140)
	var cols := int((hi.x - lo.x) / BORDER_CELL) + 1
	var rows := int((hi.y - lo.y) / BORDER_CELL) + 1
	var owner := PackedInt32Array()
	owner.resize(cols * rows)
	for gy in rows:
		for gx in cols:
			owner[gy * cols + gx] = _owner_at(
				Vector2(lo.x + gx * BORDER_CELL, lo.y + gy * BORDER_CELL),
				ids, pos, infl, reach)

	# Emit a short line segment on each cell edge where the owner changes, inset
	# toward the cell's own centre so a hostile seam shows two thin parallel
	# lines (one per empire) instead of one colour overwriting the other.
	var h := BORDER_CELL * 0.5
	var inset := 3.0
	for gy in rows:
		for gx in cols:
			var o := owner[gy * cols + gx]
			if o == -1:
				continue
			var c := Vector2(lo.x + gx * BORDER_CELL, lo.y + gy * BORDER_CELL)
			if not _visible(c):   # fog of war: only draw border where seen
				continue
			var col: Color = sim.empires[o].color
			if gx + 1 < cols and owner[gy * cols + gx + 1] != o:
				var x := c.x + h - inset
				_border_segments.append([Vector2(x, c.y - h), Vector2(x, c.y + h), col])
			if gx - 1 >= 0 and owner[gy * cols + gx - 1] != o:
				var x2 := c.x - h + inset
				_border_segments.append([Vector2(x2, c.y - h), Vector2(x2, c.y + h), col])
			if gy + 1 < rows and owner[(gy + 1) * cols + gx] != o:
				var y := c.y + h - inset
				_border_segments.append([Vector2(c.x - h, y), Vector2(c.x + h, y), col])
			if gy - 1 >= 0 and owner[(gy - 1) * cols + gx] != o:
				var y2 := c.y - h + inset
				_border_segments.append([Vector2(c.x - h, y2), Vector2(c.x + h, y2), col])


# Owner of a world point using precomputed per-empire source arrays. Combined
# claim = (Σi)² / Σ(d·i) over sources within reach; argmax empire, -1 if none.
func _owner_at(p: Vector2, ids: Array, pos: Array, infl: Array, reach: Array) -> int:
	var best := -1
	var best_claim := 0.0
	for k in ids.size():
		var pv: PackedVector2Array = pos[k]
		var iv: PackedFloat32Array = infl[k]
		var rv: PackedFloat32Array = reach[k]
		var si := 0.0
		var sri := 0.0
		for j in pv.size():
			var d := p.distance_to(pv[j])
			if d <= rv[j]:
				si += iv[j]
				sri += d * iv[j]
		if si > 0.0:
			var claim := INF if sri <= 0.0 else (si * si) / sri
			if claim > best_claim:
				best_claim = claim
				best = ids[k]
	return best


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
		for sys in sim.systems.values():
			# Fog of war: only systems in sensor range can be inspected.
			if pos.distance_to(sys.map_pos) <= 20.0 and _visible(sys.map_pos):
				view_system_id = sys.id
				selected_planet_id = -1
				return
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


func _visible(pos: Vector2) -> bool:
	if _fog_disabled:
		return true
	for src in _sight:   # each src = [Vector2 pos, float radius]
		if pos.distance_to(src[0]) <= src[1]:
			return true
	return false


func _draw() -> void:
	if view_system_id == -1:
		_draw_galaxy()
	else:
		_draw_system(sim.systems[view_system_id])


func _draw_galaxy() -> void:
	var font := ThemeDB.fallback_font
	# Deformed influence borders: bold edge LINE in each empire's colour, under
	# the rest. Already fog-gated in _recompute_borders.
	for seg in _border_segments:
		draw_line(seg[0], seg[1], seg[2], 2.0)
	for lane in sim.lanes:
		draw_line(sim.systems[lane[0]].map_pos, sim.systems[lane[1]].map_pos,
			Color(1, 1, 1, 0.13), 1.5)
	for sys in sim.systems.values():
		# Fog of war: systems out of sight are shown as unknown (dim, no live
		# owner/colony info — you know the map layout, not the current state).
		if not _visible(sys.map_pos):
			draw_circle(sys.map_pos, 7.0, Color(0.5, 0.5, 0.55, 0.35))
			draw_string(font, sys.map_pos + Vector2(-60.0, 26.0), sys.name,
				HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(1, 1, 1, 0.2))
			continue
		draw_circle(sys.map_pos, 9.0, Color(1.0, 0.85, 0.35))
		# Live border contest result: ring in the current owner's color
		# (cached in the border recompute, not recomputed per frame).
		var owner: int = _system_owner.get(sys.id, -1)
		if owner != -1:
			draw_arc(sys.map_pos, 13.0, 0.0, TAU, 32,
				sim.empires[owner].color, 2.0)
		var colony_count := 0
		for pid in sys.planet_ids:
			if sim.planets[pid].colony != null:
				colony_count += 1
		if colony_count > 0:
			draw_string(font, sys.map_pos + Vector2(14.0, -12.0),
				str(colony_count), HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(0.35, 1.0, 0.5))
		draw_string(font, sys.map_pos + Vector2(-60.0, 26.0), sys.name,
			HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(1, 1, 1, 0.65))


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
	vbox.add_child(panel_title)
	vbox.add_child(panel_body)
	vbox.add_child(colonize_btn)
	vbox.add_child(mine_btn)


func _on_colonize() -> void:
	if selected_planet_id != -1:
		sim.found_colony(player_empire_id, selected_planet_id)


func _on_build_mine() -> void:
	if selected_planet_id != -1:
		sim.build_mine(player_empire_id, selected_planet_id)


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
	var deposit_line := "Deposit: %s%s" % [
		dep_name, " (mined)" if planet.has_mine() else ""]
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
	_fog_disabled = true   # screenshot only: reveal the full border line
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
