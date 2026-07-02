extends Node2D

# Render/UI layer. Reads Sim state, forwards commands. No game rules live here.

const SPEEDS: Array[float] = [0.0, 1.0, 3.0, 10.0]
const DAYS_PER_REAL_SECOND := 1.0
const SYSTEM_CENTER := Vector2(510.0, 380.0)

var sim: Sim
var speed_idx := 1
var day_accum := 0.0
var selected_planet_id := -1
var view_system_id := -1  # -1 = galaxy view, otherwise the focused system

var raw_label: Label
var goods_label: Label
var day_label: Label
var speed_buttons: Array[Button] = []
var panel: PanelContainer
var panel_title: Label
var panel_body: Label
var colonize_btn: Button
var mine_btn: Button


func _ready() -> void:
	sim = Sim.new_demo()
	_build_ui()
	if "--autoshot" in OS.get_cmdline_user_args():
		_autoshot()


func _process(delta: float) -> void:
	var speed := SPEEDS[speed_idx]
	if speed > 0.0:
		day_accum += delta * DAYS_PER_REAL_SECOND * speed
		# Fixed-size ticks regardless of speed/framerate: determinism lives in
		# the sim, the dial only changes how many ticks run per real second.
		while day_accum >= SimConstants.TICK_DAYS:
			sim.tick(SimConstants.TICK_DAYS)
			day_accum -= SimConstants.TICK_DAYS
	_refresh_ui()
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
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
			if pos.distance_to(sys.map_pos) <= 20.0:
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


func _draw() -> void:
	if view_system_id == -1:
		_draw_galaxy()
	else:
		_draw_system(sim.systems[view_system_id])


func _draw_galaxy() -> void:
	var font := ThemeDB.fallback_font
	for lane in sim.lanes:
		draw_line(sim.systems[lane[0]].map_pos, sim.systems[lane[1]].map_pos,
			Color(1, 1, 1, 0.13), 1.5)
	for sys in sim.systems.values():
		var colony_count := 0
		var established_count := 0
		for pid in sys.planet_ids:
			var c: Colony = sim.planets[pid].colony
			if c != null:
				colony_count += 1
				if c.established:
					established_count += 1
		draw_circle(sys.map_pos, 9.0, Color(1.0, 0.85, 0.35))
		if colony_count > 0:
			var ring := Color(0.35, 1.0, 0.5) if established_count > 0 \
				else Color(1.0, 0.7, 0.25)
			draw_arc(sys.map_pos, 13.0, 0.0, TAU, 32, ring, 2.0)
		draw_string(font, sys.map_pos + Vector2(-60.0, 26.0), sys.name,
			HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(1, 1, 1, 0.65))
	draw_string(font, Vector2(16.0, 52.0), "Click a system to inspect it",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.4))


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
		if planet.has_deposit:
			draw_circle(pos + Vector2(9.0, -9.0), 3.0, Color(0.4, 0.85, 1.0))
		if planet.has_mine:
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
	draw_string(font, Vector2(16.0, 52.0), "Esc — back to galaxy",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.4))


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
	colonize_btn.text = "Found colony (%d raw)" % int(SimConstants.FOUND_COST)
	colonize_btn.pressed.connect(_on_colonize)
	mine_btn = Button.new()
	mine_btn.text = "Build mine (%d raw)" % int(SimConstants.MINE_COST)
	mine_btn.pressed.connect(_on_build_mine)
	vbox.add_child(panel_title)
	vbox.add_child(panel_body)
	vbox.add_child(colonize_btn)
	vbox.add_child(mine_btn)


func _on_colonize() -> void:
	if selected_planet_id != -1:
		sim.found_colony(selected_planet_id)


func _on_build_mine() -> void:
	if selected_planet_id != -1:
		sim.build_mine(selected_planet_id)


func _refresh_ui() -> void:
	raw_label.text = "Raw: %.0f" % sim.raw
	goods_label.text = "Goods: %.1f" % sim.goods
	day_label.text = "Day %.1f" % sim.day
	for i in speed_buttons.size():
		speed_buttons[i].button_pressed = (i == speed_idx)

	var planet: Planet = sim.planets.get(selected_planet_id)
	panel.visible = planet != null and view_system_id != -1
	if not panel.visible:
		return
	panel_title.text = planet.name
	var deposit_line := "Deposit: %s%s" % [
		"yes" if planet.has_deposit else "none",
		" (mined)" if planet.has_mine else ""]
	if planet.colony == null:
		panel_body.text = "Uncolonized. %s\n\nFounding a colony costs a flat %d raw, then drains %.1f raw/day until it activates at %d population." \
			% [deposit_line, int(SimConstants.FOUND_COST),
				SimConstants.COLONY_UPKEEP_BASE, int(SimConstants.ACTIVATION_POP)]
		colonize_btn.visible = true
		colonize_btn.disabled = not sim.can_found_colony(planet.id)
	else:
		var c := planet.colony
		var status := "ESTABLISHED" if c.established \
			else "growing… %d%% to activation" % int(c.activation_progress() * 100.0)
		panel_body.text = "Status: %s\nPopulation: %.1f\nUpkeep: %.2f raw/day\nProduction: %.2f goods/day\n%s" \
			% [status, c.population, c.upkeep_per_day(), c.production_per_day(),
				deposit_line]
		colonize_btn.visible = false
	mine_btn.visible = planet.has_deposit and not planet.has_mine
	mine_btn.disabled = not sim.can_build_mine(planet.id)


# Debug hook for automated visual verification: found a colony, run fast for a
# couple of real seconds, save galaxy + system screenshots, quit.
func _autoshot() -> void:
	var home: StarSystem = sim.systems.values()[0]
	sim.found_colony(home.planet_ids[0])
	speed_idx = 3
	await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot_galaxy.png")
	view_system_id = home.id
	selected_planet_id = home.planet_ids[0]
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://autoshot.png")
	print("autoshots saved: ", ProjectSettings.globalize_path("user://"))
	get_tree().quit()
