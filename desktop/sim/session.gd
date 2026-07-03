class_name Session
extends RefCounted

# App-wide handoff between the main menu and the game scene (static vars persist
# across scene changes). The menu fills these, then loads game/main.tscn; Main
# reads them in _ready.

static var config: Dictionary = {}   # new-game settings passed to generate_map
static var load_path: String = ""    # if set, Main loads this save instead
