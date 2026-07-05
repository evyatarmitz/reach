extends SceneTree

# Headless smoke test for the render path: load the game, advance the sim a bit,
# then force draws at several zoom levels so _draw_galaxy actually executes (culling,
# label-gating, viewport-rect math). Any runtime error in the draw code will print
# and fail. Screenshots can't be captured under the headless dummy renderer, but
# force_draw() still runs the CanvasItem _draw callbacks.

func _init() -> void:
	Session.config = {"system_count": 120, "empire_count": 4, "ai_efficiency": 1.0,
		"seed": 42}
	Session.load_path = ""
	var main: Node = load("res://game/main.tscn").instantiate()
	get_root().add_child(main)
	# Let _ready + a few process frames run.
	for i in 5:
		await process_frame
	# Advance the sim so there are colonies/fleets/borders to draw.
	for i in 2000:
		main.sim.tick(SimConstants.TICK_DAYS)
	main._recompute_borders()
	# Exercise the async (threaded) rebake path: kick a worker, pump frames until it
	# lands, and confirm it produced a fog texture.
	main._start_rebake()
	var spins := 0
	while main._rebake_thread != null and spins < 600:
		main._poll_rebake()
		await process_frame
		spins += 1
	assert(main._rebake_thread == null, "async rebake did not finish")
	assert(main._fog_tex != null, "async rebake produced no fog texture")
	print("ASYNC REBAKE OK")
	# Exercise _draw at zoomed-out (labels off, all on screen) and zoomed-in
	# (labels on, culling active) levels.
	for z in [0.35, 0.6, 1.0, 1.8, 2.5]:
		main._galaxy_cam_zoom = z
		main._apply_camera()
		main.queue_redraw()
		RenderingServer.force_draw()
		await process_frame
	print("DRAW SMOKE OK")
	quit()
