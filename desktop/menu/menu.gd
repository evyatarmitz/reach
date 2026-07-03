extends Control

# Landing page: New Game (with map size / empires / difficulty), Continue (if a
# save exists), Quit. Sets Session.config / Session.load_path, then loads the game.

const SAVE_PATH := "user://reach_save.json"
const SIZES := [["Small", 30], ["Medium", 50], ["Large", 80]]
const EMPIRES := [2, 3, 4, 5, 6]
const DIFFS := [["Easy", 0.6], ["Normal", 1.0], ["Hard", 1.5]]

var _main_box: VBoxContainer
var _settings_box: VBoxContainer
var _size_opt: OptionButton
var _empire_opt: OptionButton
var _diff_opt: OptionButton


func _ready() -> void:
	# Screenshot/verification tool skips the menu straight into a default game.
	if "--autoshot" in OS.get_cmdline_user_args():
		get_tree().change_scene_to_file.call_deferred("res://game/main.tscn")
		return
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.02, 0.04)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

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


func _on_start() -> void:
	Session.load_path = ""
	Session.config = {
		"system_count": SIZES[_size_opt.selected][1],
		"empire_count": EMPIRES[_empire_opt.selected],
		"ai_efficiency": DIFFS[_diff_opt.selected][1],
		"seed": randi(),
	}
	get_tree().change_scene_to_file("res://game/main.tscn")


func _on_continue() -> void:
	Session.config = {}
	Session.load_path = SAVE_PATH
	get_tree().change_scene_to_file("res://game/main.tscn")
