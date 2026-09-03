extends RefCounted

# Shared menu/overlay styling. Godot's default PanelContainer background is
# semi-transparent, so menu text shows through onto the busy starfield / map and is hard
# to read. These give the menus a solid, fully opaque background. Preloaded (no
# class_name) for the same headless class-cache reason as the other menu/ helpers.

# A solid dark panel background with a subtle border and comfortable padding.
static func opaque_panel() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.12)   # alpha 1.0 — not see-through
	sb.set_border_width_all(1)
	sb.border_color = Color(0.35, 0.42, 0.55, 0.8)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	return sb


# Apply the opaque panel background to a PanelContainer.
static func make_opaque(panel: Control) -> void:
	panel.add_theme_stylebox_override("panel", opaque_panel())


# A solid background for an edge-docked HUD bar (e.g. the top resource bar): square
# corners (it sits flush to the screen edge, so rounding would look wrong) and just a
# thin separating border on the inner edge. Keeps the map from bleeding through the
# small, low-contrast resource figures.
static func opaque_bar() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.12)   # matches the panels — one HUD palette
	sb.border_width_bottom = 1
	sb.border_color = Color(0.35, 0.42, 0.55, 0.8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


# Apply the opaque bar background to a PanelContainer docked to a screen edge.
static func make_opaque_bar(panel: Control) -> void:
	panel.add_theme_stylebox_override("panel", opaque_bar())
