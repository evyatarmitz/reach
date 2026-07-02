class_name Empire
extends RefCounted

# An empire is any population-driving actor — human or AI, same rules, same
# code paths (multiplayer-shaped by design; no player-only special cases).

var id: int = -1
var name: String = ""
var color: Color = Color.WHITE
var raw: float = SimConstants.START_RAW
var goods: float = 0.0
