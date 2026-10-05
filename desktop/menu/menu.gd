extends Control

# Landing page: New Game (with map size / empires / difficulty), Continue (if a
# save exists), Quit. Sets Session.config / Session.load_path, then loads the game.

const SAVE_PATH := "user://reach_save.json"
# Planet counts (one planet per node now). -1 = use the custom slider.
const SIZES := [["Small", 60], ["Medium", 120], ["Large", 250], ["Custom", -1]]
const EMPIRES := [2, 3, 4, 5, 6]
const DIFFS := [["Easy", 0.6], ["Normal", 1.0], ["Hard", 1.5]]

# The rebindable controls page and self-updater are shared with the in-game HUD; the
# menu hosts the same Options page and a bottom-left version/update widget. Preloaded
# (no class_name) for the same headless class-cache reason as in updater.gd.
const ControlsPageScript := preload("res://menu/controls_page.gd")
const UpdaterScript := preload("res://game/updater.gd")

var _main_box: VBoxContainer
var _settings_box: VBoxContainer
var _size_opt: OptionButton
var _size_slider: HSlider
var _size_slider_row: HBoxContainer
var _size_val_label: Label
var _empire_opt: OptionButton
var _diff_opt: OptionButton
var _persona_box: VBoxContainer
var _persona_opts: Array = []   # one OptionButton per rival empire
var _lane_slider: HSlider
var _lane_val_label: Label
var _player_color_idx: int = 0
var _color_swatches: Array = []   # the clickable Buttons, for the selection highlight
var _stars: Array = []   # backdrop starfield [pos, radius, Color]
var _controls_page: Control
var _updater: Node
var _update_btn: Button
var _update_apply: Button
var _update_status: Label


# Deep-space backdrop behind the menu UI: a dark fill plus a seeded starfield, so
# the landing page matches the in-game look. Drawn on the Control's own canvas item
# (children — the title/buttons — draw on top).
func _draw() -> void:
	var sz := size
	draw_rect(Rect2(Vector2.ZERO, sz), Color(0.02, 0.02, 0.04))
	if _stars.is_empty() and sz.x > 1.0:
		var rng := RandomNumberGenerator.new()
		rng.seed = 424242
		for i in 260:
			var p := Vector2(rng.randf_range(0.0, sz.x), rng.randf_range(0.0, sz.y))
			var a := rng.randf_range(0.05, 0.35)
			var col := Color(1, 1, 1, a)
			var tint := rng.randf()
			if tint < 0.16:
				col = Color(0.6, 0.75, 1.0, a)
			elif tint < 0.28:
				col = Color(1.0, 0.85, 0.65, a)
			_stars.append([p, rng.randf_range(0.5, 1.7), col])
	for s in _stars:
		draw_circle(s[0], s[1], s[2])


func _ready() -> void:
	# Screenshot/verification tool skips the menu straight into a default game.
	if "--autoshot" in OS.get_cmdline_user_args():
		get_tree().change_scene_to_file.call_deferred("res://game/main.tscn")
		return
	# Background (deep-space fill + starfield) is painted in _draw(), behind the UI
	# children added below. queue_redraw once the size is known.
	call_deferred("queue_redraw")

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	col.custom_minimum_size = Vector2(320, 0)
	center.add_child(col)

	var title := Label.new()
	title.text = "REACH"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 64)
	col.add_child(title)
	var sub := Label.new()
	sub.text = "an indirect-control population god-game — alpha"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(1, 1, 1, 0.5)
	col.add_child(sub)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	col.add_child(spacer)

	# Main buttons.
	_main_box = VBoxContainer.new()
	_main_box.add_theme_constant_override("separation", 8)
	col.add_child(_main_box)
	var new_btn := _big_button("New Game")
	new_btn.pressed.connect(_show_settings)
	_main_box.add_child(new_btn)
	var cont := _big_button("Continue")
	cont.disabled = not FileAccess.file_exists(SAVE_PATH)
	cont.pressed.connect(_on_continue)
	_main_box.add_child(cont)
	var options := _big_button("Options")
	options.pressed.connect(func() -> void: _controls_page.open())
	_main_box.add_child(options)
	var quit := _big_button("Quit")
	quit.pressed.connect(func() -> void: get_tree().quit())
	_main_box.add_child(quit)

	# Settings (hidden until New Game).
	_settings_box = VBoxContainer.new()
	_settings_box.add_theme_constant_override("separation", 8)
	_settings_box.visible = false
	col.add_child(_settings_box)
	_size_opt = _labeled_option("Map size", SIZES.map(func(s): return s[0]), 1)
	_size_opt.item_selected.connect(_on_size_changed)
	# Custom-size slider (planets), revealed when "Custom" is picked — up to 1000.
	_size_slider_row = HBoxContainer.new()
	var slabel := Label.new()
	slabel.text = "Planets"
	slabel.custom_minimum_size = Vector2(120, 0)
	_size_slider_row.add_child(slabel)
	_size_slider = HSlider.new()
	_size_slider.min_value = 20
	_size_slider.max_value = 1000
	_size_slider.step = 10
	_size_slider.value = 300
	_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_size_slider_row.add_child(_size_slider)
	_size_val_label = Label.new()
	_size_val_label.text = "300"
	_size_val_label.custom_minimum_size = Vector2(44, 0)
	_size_slider.value_changed.connect(func(v: float) -> void:
		_size_val_label.text = str(int(v)))
	_size_slider_row.add_child(_size_val_label)
	_size_slider_row.visible = false
	_settings_box.add_child(_size_slider_row)
	_empire_opt = _labeled_option("Empires", EMPIRES.map(func(n): return str(n)), 2)
	_diff_opt = _labeled_option("Difficulty", DIFFS.map(func(d): return d[0]), 1)
	# AI personalities — one picker per rival empire. Each rival defaults to "Random";
	# "Randomize all" sets every picker back to Random. Rebuilt when the empire count
	# changes so the number of rows always matches the number of AI rivals.
	var persona_header := HBoxContainer.new()
	var ph_label := Label.new()
	ph_label.text = "AI personalities"
	ph_label.custom_minimum_size = Vector2(120, 0)
	persona_header.add_child(ph_label)
	var rand_all := Button.new()
	rand_all.text = "Randomize all"
	rand_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rand_all.pressed.connect(func() -> void:
		for o in _persona_opts:
			o.selected = 0)   # 0 = Random
	persona_header.add_child(rand_all)
	_settings_box.add_child(persona_header)
	_persona_box = VBoxContainer.new()
	_persona_box.add_theme_constant_override("separation", 4)
	_settings_box.add_child(_persona_box)
	_empire_opt.item_selected.connect(func(_i: int) -> void: _rebuild_persona_rows())
	_rebuild_persona_rows()
	_build_color_row()
	# Lane density: how many hyperlanes connect the stars. 0% = a single spanning tree
	# (one connected wire, no islands); 100% = every planar near-neighbour lane. The map
	# stays a single connected mesh at every setting.
	var lane_row := HBoxContainer.new()
	var llabel := Label.new()
	llabel.text = "Lane density"
	llabel.custom_minimum_size = Vector2(120, 0)
	lane_row.add_child(llabel)
	_lane_slider = HSlider.new()
	_lane_slider.min_value = 0
	_lane_slider.max_value = 100
	_lane_slider.step = 5
	_lane_slider.value = 35
	_lane_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lane_row.add_child(_lane_slider)
	_lane_val_label = Label.new()
	_lane_val_label.text = "35%"
	_lane_val_label.custom_minimum_size = Vector2(44, 0)
	_lane_slider.value_changed.connect(func(v: float) -> void:
		_lane_val_label.text = "%d%%" % int(v))
	lane_row.add_child(_lane_val_label)
	_settings_box.add_child(lane_row)
	var start := _big_button("Start")
	start.pressed.connect(_on_start)
	_settings_box.add_child(start)
	var back := _big_button("Back")
	back.pressed.connect(func() -> void:
		_settings_box.visible = false
		_main_box.visible = true)
	_settings_box.add_child(back)

	# Shared rebindable controls page (same component as the in-game one), hidden until
	# Options is pressed. Added last so it draws over the menu; it closes itself on Esc.
	_controls_page = ControlsPageScript.new()
	_controls_page.visible = false
	add_child(_controls_page)

	_build_footer()

	if "--menushot" in OS.get_cmdline_user_args():
		_menushot()


# Bottom-left version label + self-update controls, mirroring the pause menu's updater
# widget. Outside a real Windows build (e.g. the editor) the updater reports that updates
# only apply to the installed build, same as in-game.
func _build_footer() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.alignment = BoxContainer.ALIGNMENT_END   # hug the bottom edge
	box.anchor_top = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = 12.0
	box.offset_top = -180.0
	box.offset_bottom = -12.0
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(box)

	var ver := Label.new()
	ver.text = "Reach v%s" % UpdaterScript.CURRENT
	ver.modulate = Color(1, 1, 1, 0.5)
	ver.add_theme_font_size_override("font_size", 11)
	box.add_child(ver)

	_updater = UpdaterScript.new()
	add_child(_updater)
	_updater.check_done.connect(_on_update_check_done)
	_updater.apply_started.connect(func() -> void:
		_update_status.text = "Downloading update…"
		_update_apply.disabled = true
		_update_btn.disabled = true)
	_updater.apply_failed.connect(func(msg: String) -> void:
		_update_status.text = "Update failed: %s" % msg
		_update_btn.disabled = false)

	_update_btn = Button.new()
	_update_btn.text = "Check for updates"
	_update_btn.add_theme_font_size_override("font_size", 11)
	_update_btn.pressed.connect(func() -> void:
		_update_status.text = "Checking…"
		_update_btn.disabled = true
		_updater.check_for_update())
	box.add_child(_update_btn)

	_update_apply = Button.new()
	_update_apply.text = "Update & restart"
	_update_apply.add_theme_font_size_override("font_size", 11)
	_update_apply.visible = false
	_update_apply.pressed.connect(func() -> void: _updater.apply_update())
	box.add_child(_update_apply)

	_update_status = Label.new()
	_update_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_update_status.custom_minimum_size = Vector2(240, 0)
	_update_status.modulate = Color(1, 1, 1, 0.7)
	_update_status.add_theme_font_size_override("font_size", 11)
	box.add_child(_update_status)


func _on_update_check_done(available: bool, latest: String, note: String) -> void:
	_update_btn.disabled = false
	_update_apply.visible = available
	if available:
		_update_status.text = "Update available: v%s" % latest
	else:
		_update_status.text = note


func _menushot() -> void:
	_show_settings()   # capture the settings panel (the interesting bit)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://menushot.png")
	get_tree().quit()


func _big_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	return b


func _labeled_option(label: String, items: Array, default_idx: int) -> OptionButton:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(120, 0)
	row.add_child(l)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for it in items:
		opt.add_item(it)
	opt.selected = default_idx
	row.add_child(opt)
	_settings_box.add_child(row)
	return opt


# A "Your colour" row: one swatch per empire hue (kept in sync with the sim's palette).
# Clicking one picks the player's colour; the picked swatch gets a bright outline.
func _build_color_row() -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = "Your colour"
	l.custom_minimum_size = Vector2(120, 0)
	row.add_child(l)
	var swatches := HBoxContainer.new()
	swatches.add_theme_constant_override("separation", 6)
	swatches.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(swatches)
	_color_swatches.clear()
	for i in Sim._EMPIRE_COLORS.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(30, 26)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Sim._EMPIRE_COLORS[i]
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.add_theme_stylebox_override("pressed", sb)
		b.pressed.connect(func() -> void: _select_color(i))
		swatches.add_child(b)
		_color_swatches.append(b)
	_settings_box.add_child(row)
	_select_color(0)


# Rebuild the per-rival personality pickers to match the current empire count.
# Option 0 is "Random"; options 1.. map to SimConstants.PERSONALITY_NAMES.
func _rebuild_persona_rows() -> void:
	for c in _persona_box.get_children():
		_persona_box.remove_child(c)
		c.queue_free()
	_persona_opts.clear()
	var rivals: int = EMPIRES[_empire_opt.selected] - 1   # player is one of the empires
	var items: Array = ["Random"]
	items.append_array(SimConstants.PERSONALITY_NAMES)
	for r in rivals:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = "  Rival %d" % (r + 1)
		l.custom_minimum_size = Vector2(120, 0)
		row.add_child(l)
		var opt := OptionButton.new()
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for it in items:
			opt.add_item(it)
		opt.selected = 0   # Random by default
		row.add_child(opt)
		_persona_box.add_child(row)
		_persona_opts.append(opt)


func _select_color(idx: int) -> void:
	_player_color_idx = idx
	for i in _color_swatches.size():
		var b: Button = _color_swatches[i]
		var sb: StyleBoxFlat = b.get_theme_stylebox("normal")
		sb.border_color = Color.WHITE if i == idx else Color(0, 0, 0, 0)
		sb.set_border_width_all(3 if i == idx else 0)


func _show_settings() -> void:
	_main_box.visible = false
	_settings_box.visible = true


func _on_size_changed(idx: int) -> void:
	_size_slider_row.visible = SIZES[idx][1] == -1   # show the slider for "Custom"


func _on_start() -> void:
	Session.load_path = ""
	var count: int = SIZES[_size_opt.selected][1]
	if count == -1:
		count = int(_size_slider.value)
	var personas: Array = []
	for o in _persona_opts:
		personas.append(o.selected - 1)   # 0 -> -1 (random), i -> personality i-1
	Session.config = {
		"system_count": count,
		"empire_count": EMPIRES[_empire_opt.selected],
		"ai_efficiency": DIFFS[_diff_opt.selected][1],
		"ai_personalities": personas,
		"lane_density": _lane_slider.value / 100.0,
		"player_color_idx": _player_color_idx,
		"seed": randi(),
	}
	get_tree().change_scene_to_file("res://game/main.tscn")


func _on_continue() -> void:
	Session.config = {}
	Session.load_path = SAVE_PATH
	get_tree().change_scene_to_file("res://game/main.tscn")
