extends Control

# Landing page: New Game (with map size / empires / difficulty), Continue (if a
# save exists), Quit. Sets Session.config / Session.load_path, then loads the game.

const SAVE_PATH := "user://reach_save.json"
# Planet counts (one planet per node now). -1 = use the custom slider.
const SIZES := [["Small", 60], ["Medium", 120], ["Large", 250], ["Custom", -1]]
const EMPIRES := [2, 3, 4, 5, 6]
const DIFFS := [["Easy", 0.6], ["Normal", 1.0], ["Hard", 1.5]]

var _main_box: VBoxContainer
var _settings_box: VBoxContainer
var _size_opt: OptionButton
var _size_slider: HSlider
var _size_slider_row: HBoxContainer
var _size_val_label: Label
var _empire_opt: OptionButton
var _diff_opt: OptionButton
var _stars: Array = []   # backdrop starfield [pos, radius, Color]


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
	var start := _big_button("Start")
	start.pressed.connect(_on_start)
	_settings_box.add_child(start)
	var back := _big_button("Back")
	back.pressed.connect(func() -> void:
		_settings_box.visible = false
		_main_box.visible = true)
	_settings_box.add_child(back)

	if "--menushot" in OS.get_cmdline_user_args():
		_menushot()


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
	Session.config = {
		"system_count": count,
		"empire_count": EMPIRES[_empire_opt.selected],
		"ai_efficiency": DIFFS[_diff_opt.selected][1],
		"seed": randi(),
	}
	get_tree().change_scene_to_file("res://game/main.tscn")


func _on_continue() -> void:
	Session.config = {}
	Session.load_path = SAVE_PATH
	get_tree().change_scene_to_file("res://game/main.tscn")
