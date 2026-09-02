extends RefCounted

# Single source of truth for the game's rebindable key map, shared between the main-menu
# Options page and the in-game controls page. Uses static vars (like Session) so the map
# persists across the menu -> game scene change, and is reached via preload rather than a
# class_name so it resolves even when the global class cache is stale in a headless build
# (same reasoning as updater.gd). Persisted to user://controls.cfg.

const PATH := "user://controls.cfg"

# Ordered [action_id, label, default_keycode]. Esc is deliberately NOT here — it's the
# universal cancel / pause key and must never be rebound away.
const DEFS := [
	["pan_up", "Pan up", KEY_W],
	["pan_left", "Pan left", KEY_A],
	["pan_down", "Pan down", KEY_S],
	["pan_right", "Pan right", KEY_D],
	["pause", "Pause / resume", KEY_SPACE],
	["speed_up", "Speed up", KEY_EQUAL],
	["speed_down", "Speed down", KEY_MINUS],
	["ship_1", "Build Fighter T1", KEY_1],
	["ship_2", "Build Fighter T2", KEY_2],
	["ship_3", "Build Fighter T3", KEY_3],
	["ship_4", "Build Fighter T4", KEY_4],
	["ship_5", "Build Fighter T5", KEY_5],
	["ship_6", "Build Bomber T1", KEY_6],
	["ship_7", "Build Bomber T2", KEY_7],
	["ship_8", "Build Bomber T3", KEY_8],
	["ship_9", "Build Bomber T4", KEY_9],
	["ship_10", "Build Bomber T5", KEY_0],
	["legend", "Toggle legend", KEY_L],
	["controls", "Toggle controls", KEY_K],
	["save", "Save game", KEY_F5],
	["load", "Load game", KEY_F9],
]

static var map := {}          # action_id -> keycode (0 = unbound)
static var _loaded := false


# Populate the map once (defaults, then any saved overrides). Idempotent.
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	reset_defaults(false)
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for d in DEFS:
			var id: String = d[0]
			if cfg.has_section_key("binds", id):
				map[id] = int(cfg.get_value("binds", id))


static func reset_defaults(persist := true) -> void:
	map.clear()
	for d in DEFS:
		map[d[0]] = d[2]
	if persist:
		save()


static func save() -> void:
	var cfg := ConfigFile.new()
	for id in map:
		cfg.set_value("binds", id, map[id])
	cfg.save(PATH)


static func keycode(action: String) -> int:
	return int(map.get(action, 0))


# Which action (if any) is currently bound to this keycode; "" if none.
static func action_for(keycode_: int) -> String:
	if keycode_ == 0:
		return ""
	for id in map:
		if map[id] == keycode_:
			return id
	return ""


# Assign a key to an action, stealing it from any previous owner. Persists.
static func rebind(action: String, keycode_: int) -> void:
	for id in map:
		if id != action and map[id] == keycode_:
			map[id] = 0
	map[action] = keycode_
	save()


static func label_for(action: String) -> String:
	for d in DEFS:
		if d[0] == action:
			return d[1]
	return action


static func key_name(keycode_: int) -> String:
	if keycode_ == 0:
		return "—"
	var s := OS.get_keycode_string(keycode_)
	return s if s != "" else "Key %d" % keycode_
