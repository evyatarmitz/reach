extends PanelContainer

# Reusable rebindable key-binding page, used from BOTH the main-menu Options button and
# the in-game pause menu (K). Action label on the LEFT, a clickable key button on the
# RIGHT — click a key, then press the new one (it's stolen from any prior owner). Reads
# and writes the shared Keybinds store, so a change made in either place takes effect
# everywhere. Self-contained: it captures keys and handles its own Esc/close, and emits
# `closed` when dismissed. Reached via preload (no class_name) for the same headless
# class-cache reason as updater.gd / keybinds.gd.

signal closed

const Keybinds := preload("res://menu/keybinds.gd")
const UiStyle := preload("res://menu/ui_style.gd")

var _listening := ""     # action currently capturing a key ("" = none)
var _rows := {}          # action_id -> its key Button


func _ready() -> void:
	Keybinds.ensure_loaded()
	UiStyle.make_opaque(self)
	set_anchors_preset(Control.PRESET_CENTER)
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -240
	offset_right = 240
	offset_top = -250
	offset_bottom = 250
	z_index = 150
	_build()
	_refresh()


func open() -> void:
	visible = true
	_listening = ""
	_refresh()


func _close() -> void:
	_listening = ""
	visible = false
	_refresh()
	closed.emit()


func _build() -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var title := Label.new()
	title.text = "Controls"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	v.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 400)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 3)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)

	_rows.clear()
	# Ordered layout: which action ids sit under each heading, with a few fixed
	# (non-rebindable) reference rows mixed in as [label, key] string pairs.
	var sections := [
		["— Map —", ["pan_up", "pan_left", "pan_down", "pan_right"],
			[["Pan the map", "Right-drag"], ["Zoom in / out", "Mouse wheel"],
			 ["Select / give orders", "Left-click"]]],
		["— Speed —", ["pause", "speed_up", "speed_down"], []],
		["— Build ships —", ["ship_1", "ship_2", "ship_3", "ship_4", "ship_5",
			"ship_6", "ship_7", "ship_8", "ship_9", "ship_10"],
			[["Build ×10", "Shift + key/click"], ["Build ×100", "Ctrl + key/click"]]],
		["— Other —", ["legend", "controls", "save", "load"],
			[["Close panel / deselect", "Esc"]]],
	]
	for sec in sections:
		_add_heading(grid, sec[0])
		for id in sec[1]:
			_add_bind_row(grid, id)
		for fixed in sec[2]:
			_add_fixed_row(grid, fixed[0], fixed[1])

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	v.add_child(buttons)
	var reset_btn := Button.new()
	reset_btn.text = "Reset to defaults"
	reset_btn.pressed.connect(func() -> void:
		Keybinds.reset_defaults()
		_listening = ""
		_refresh())
	buttons.add_child(reset_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(_close)
	buttons.add_child(close_btn)

	var hint := Label.new()
	hint.text = "Click a key to rebind it • K or Esc to close"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 10)
	hint.modulate = Color(1, 1, 1, 0.4)
	v.add_child(hint)


# A full-width section heading inside the 2-column grid.
func _add_heading(grid: GridContainer, text: String) -> void:
	grid.add_child(Control.new())
	var h := Label.new()
	h.text = text
	h.add_theme_font_size_override("font_size", 12)
	h.modulate = Color(0.7, 0.85, 1.0, 0.9)
	grid.add_child(h)


# A rebindable row: action label on the LEFT, clickable key button on the RIGHT.
func _add_bind_row(grid: GridContainer, action_id: String) -> void:
	var lbl := Label.new()
	lbl.text = Keybinds.label_for(action_id)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.modulate = Color(1, 1, 1, 0.85)
	grid.add_child(lbl)
	var btn := Button.new()
	btn.add_theme_font_size_override("font_size", 12)
	btn.custom_minimum_size = Vector2(140, 0)
	btn.pressed.connect(_begin_listen.bind(action_id))
	grid.add_child(btn)
	_rows[action_id] = btn


# A fixed reference row (label left, key text right) — not rebindable.
func _add_fixed_row(grid: GridContainer, label_text: String, key_text: String) -> void:
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.modulate = Color(1, 1, 1, 0.55)
	grid.add_child(lbl)
	var k := Label.new()
	k.text = key_text
	k.add_theme_font_size_override("font_size", 12)
	k.modulate = Color(1, 1, 1, 0.4)
	grid.add_child(k)


# Click a key button: clear the binding and start listening for the replacement.
func _begin_listen(action: String) -> void:
	Keybinds.map[action] = 0
	_listening = action
	get_viewport().gui_release_focus()
	_refresh()


# Repaint every key button's caption from the live Keybinds state.
func _refresh() -> void:
	for id in _rows:
		var btn: Button = _rows[id]
		btn.text = "press a key…" if id == _listening else Keybinds.key_name(Keybinds.keycode(id))


# Capture happens here (before _unhandled_input), so the host scene never sees the key we
# consume. When idle, Esc or the "controls" key closes the page; other keys fall through
# (the host guards its own hotkeys while this page is visible).
func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if _listening != "":
		if event.keycode == KEY_ESCAPE:
			_listening = ""
			_refresh()
		elif event.keycode not in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
			Keybinds.rebind(_listening, event.keycode)
			_listening = ""
			_refresh()
		accept_event()
	elif event.keycode == KEY_ESCAPE or event.keycode == Keybinds.keycode("controls"):
		_close()
		accept_event()
