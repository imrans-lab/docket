extends SceneTree
## Run under Linux Xvfb with xdotool in an isolated scratch project.
## User argument: confirmed|close|escape.
## Success prints a marker and the production failure handler exits with code 2.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var occupied := TCPServer.new()
	if occupied.listen(0, "127.0.0.1") != OK:
		quit(1)
		return
	var server := DocketHttpServer.new()
	server.port = occupied.get_local_port()
	root.add_child(server)
	await process_frame
	var args := OS.get_cmdline_user_args()
	var mode := args[0] if args.size() == 1 else ""
	for child in server.get_children():
		if child is AcceptDialog and child.visible and child.dialog_text.contains("Failed to listen"):
			if server.is_serving():
				quit(1)
				return
			print("VISIBLE_FAILURE_DIALOG ", mode)
			match mode:
				"confirmed": child.confirmed.emit()
				"close": child.close_requested.emit()
				"escape":
					# Native Window Escape handling precedes Viewport.push_input.
					# Exercise the actual X11 key path rather than emitting canceled.
					await create_timer(0.25).timeout
					if OS.execute("xdotool", ["search", "--onlyvisible", "--name", "Docket", "windowfocus", "key", "Escape"]) != 0:
						quit(1)
				_: quit(1)
			await create_timer(2.0).timeout
			push_error("Startup failure dialog did not exit")
			quit(1)
			return
	quit(1)
