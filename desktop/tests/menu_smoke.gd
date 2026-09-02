extends SceneTree

# Boot check for the main-menu scene (draw_smoke only covers the in-game scene):
# instantiate the menu, let _ready build the UI (title, buttons, Options page,
# footer/updater widget), pump a few frames, then quit. Catches any parse/runtime error
# in menu.gd or the shared components it preloads (keybinds.gd, controls_page.gd).
# Run: godot --headless --path desktop --script res://tests/menu_smoke.gd

func _init() -> void:
	var menu: Node = load("res://menu/menu.tscn").instantiate()
	get_root().add_child(menu)
	for i in 5:
		await process_frame
	# Prove the extracted pieces wired up.
	assert(menu._controls_page != null, "controls page missing")
	assert(menu._updater != null, "updater missing")
	assert(menu._update_btn != null and menu._update_status != null, "update widget missing")
	# Open/close the shared controls page once (exercises Keybinds + row build).
	menu._controls_page.open()
	assert(menu._controls_page.visible, "controls page did not open")
	menu._controls_page._close()
	assert(not menu._controls_page.visible, "controls page did not close")
	print("MENU SMOKE OK")
	quit()
