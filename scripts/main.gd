extends Node
## Entry point. Routes CLI args to test runner, MCP server, or GUI.
##
## Usage (running as Godot project):
##   godot --headless --path <project> -- --test
##   godot --headless --path <project> -- --serve --file my.dct --port 3010
##   godot --path <project> -- --file my.dct
##
## Usage (exported binary):
##   docket --test
##   docket --headless --serve --file my.dct --port 3010
##   docket --file my.dct

const FrameProbe := preload("res://scripts/ui/frame_probe.gd")

var _test_runner: Node
var _http_server: Node
var _host_authority: DocketHostAuthority


func _ready() -> void:
	var opts := _parse_args()
	DocketRuntimeState.stdio = opts.stdio
	var authority := DocketHostAuthority.new()
	var auth_error := authority.configure_from_environment(opts.host_authority, opts.stdio)
	if not auth_error.is_empty():
		printerr("Docket: %s" % auth_error)
		DocketRuntimeState.quit(get_tree(), 2)
		return
	if opts.host_authority:
		_host_authority = authority
		DocketRuntimeState.hosted = true
		if not opts.files.is_empty() or opts.restore_session:
			printerr("Docket: hosted startup cannot open files or restore a session before schema declaration")
			DocketRuntimeState.quit(get_tree(), 2)
			return

	# Godot consumes --quiet before exposing cmdline args; inspect its effect.
	if opts.stdio and (opts.mode not in ["serve", "gui"] or Engine.print_to_stdout or opts.state_dir.is_empty()):
		printerr("Docket: --stdio requires --quiet and a private absolute --state-dir (add --serve for headless)")
		DocketRuntimeState.quit(get_tree(), 2)
		return

	var state_error := DocketRuntimeState.configure(opts.state_dir, opts.restore_session)
	if not state_error.is_empty():
		printerr("Docket: %s" % state_error)
		DocketRuntimeState.quit(get_tree(), 2)
		return

	match opts.mode:
		"help":
			_print_help()
		"build_info":
			var info: Dictionary = BuildInfo.read()
			info["identity"] = BuildInfo.identity()
			var initialized: Dictionary = McpHandler.new().handle({"method":"initialize", "id":1})
			info["server_version"] = initialized.result.serverInfo.version
			print(JSON.stringify(info))
			get_tree().quit()
		"test":
			await _run_tests()
		"serve":
			_start_server(opts)
		"migrate":
			_run_migration(opts)
		"migrate_jsonl":
			_run_jsonl_migration(opts)
		"validate":
			_run_validate(opts)
		_:
			_start_gui(opts)


func _parse_args() -> Dictionary:
	var args := Array(OS.get_cmdline_user_args())
	# Exported binaries may not distinguish arguments after a `--` separator.
	if args.is_empty():
		args = Array(OS.get_cmdline_args())
	return _parse_arg_values(args)


func _parse_arg_values(args: Array) -> Dictionary:
	var opts := {"mode": "gui", "file": "", "files": [], "port": 3010, "query": "", "stdio": false, "host_authority": false, "state_dir": "", "restore_session": false}

	var i := 0
	while i < args.size():
		match args[i]:
			"-?", "--help", "-h":
				opts.mode = "help"
			"--serve", "serve":
				opts.mode = "serve"
			"--host-authority":
				opts.host_authority = true
			"--stdio":
				opts.stdio = true
			"--state-dir":
				if i + 1 < args.size():
					i += 1
					opts.state_dir = str(args[i])
			"--restore-session":
				opts.restore_session = true
			"--build-info":
				opts.mode = "build_info"
			"--test", "test":
				opts.mode = "test"
			"--migrate", "migrate":
				opts.mode = "migrate"
			"--migrate-jsonl", "migrate-jsonl":
				opts.mode = "migrate_jsonl"
			"--validate", "validate":
				opts.mode = "validate"
			"--file":
				if i + 1 < args.size():
					i += 1
					opts.files.append(args[i])
					if opts.file.is_empty():
						opts.file = args[i]
			"--query":
				if i + 1 < args.size():
					i += 1
					opts.query = args[i]
			"--port":
				if i + 1 < args.size():
					i += 1
					opts.port = int(args[i])
			_:
				# Bare .dct path (backward compat)
				if str(args[i]).ends_with(".dct"):
					opts.files.append(args[i])
					if opts.file.is_empty():
						opts.file = args[i]
				elif str(args[i]).ends_with(".dcq"):
					opts.query = args[i]
		i += 1

	# If no file specified, find one in cwd (only for non-GUI modes)
	if opts.file.is_empty() and opts.mode != "gui" and not opts.stdio:
		opts.file = _find_dct_in_cwd()
	if not opts.file.is_empty() and opts.files.is_empty():
		opts.files.append(opts.file)

	return opts


func _find_dct_in_cwd() -> String:
	var dir := DirAccess.open(".")
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if fname.ends_with(".dct"):
				return fname
			fname = dir.get_next()
	return "docket.dct"


func _schema_type_list() -> String:
	## Read the types from data/schema.json rather than restating them — the
	## hardcoded list here fell eight behind the schema.
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	if f == null:
		return ""
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not parsed is Dictionary or not parsed.has("types"):
		return ""
	var names: Array = parsed["types"].keys()
	names.sort()
	return ", ".join(PackedStringArray(names))


func _print_help() -> void:
	print("")
	print("Docket — RAID-Inspired Work-Item Tracker")
	print("")
	print("USAGE:")
	print("  docket [options]              Launch GUI (default)")
	print("  docket --serve [options]      Start headless MCP server")
	print("  docket --test                 Run test suite")
	print("  docket --migrate --file <f>   Migrate a legacy JSON .dct to SQLite")
	print("  docket --migrate-jsonl --file <f>  Promote a legacy SQLite .dct to JSONL")
	print("  docket --validate --file <f>  Check a .dct for structural problems")
	print("")
	print("OPTIONS:")
	print("  --file <path.dct>   Data file to open (repeatable for multi-project)")
	print("  --query <path.dcq>  Load a .dcq query file on startup")
	print("  --serve             Run as headless MCP server (no GUI)")
	print("  --stdio             Use newline JSON-RPC (requires --quiet --state-dir)")
	print("  --host-authority    Enable private host authentication (stdio only)")
	print("  --state-dir <dir>   Private absolute state directory (required for stdio)")
	print("  --restore-session  Deliberately restore the private profile session")
	print("  --port <number>     MCP server port (default: 3010)")
	print("  --build-info        Print embedded build identity and exit")
	print("  --test              Run tests and exit")
	print("  --migrate           Migrate a legacy JSON .dct to SQLite and exit")
	print("  --migrate-jsonl     Migrate a legacy SQLite .dct to JSONL and exit")
	print("  --validate          Check .dct files for conflict markers, duplicate IDs,")
	print("                      and dangling references. Exits 1 on error.")
	print("  -?, -h, --help      Show this help and exit")
	print("")
	print("EXAMPLES:")
	print("  docket --file myproject.dct")
	print("  docket --file myproject.dct --query bugs.dcq")
	print("  docket --file minerva.dct --file services.dct")
	print("  docket --headless --serve --file myproject.dct --port 4000")
	print("  docket --test")
	print("  docket --migrate --file old_data.dct")
	print("")
	var type_line := _schema_type_list()
	if not type_line.is_empty():
		print("ITEM TYPES: %s" % type_line)
	print("MCP ENDPOINT: POST http://127.0.0.1:<port>/mcp (JSON-RPC 2.0)")
	print("DATA FORMAT: New .dct files use JSONL 2.0 with a disposable .dct.v2.cache.")
	print("             Existing JSONL 1.0 files keep .dct.cache until explicit upgrade.")
	print("             SQLite promotion uses --migrate-jsonl; registry upgrade is separate.")
	print("")
	get_tree().quit(0)


func _run_tests() -> void:
	var RunnerScript = load("res://test/test_runner.gd")
	_test_runner = RunnerScript.new()
	add_child(_test_runner)
	var exit_code: int = await _test_runner.run_all()
	get_tree().quit(exit_code)


func _start_server(opts: Dictionary) -> void:
	var ServerScript = load("res://scripts/mcp/http_server.gd")
	_http_server = ServerScript.new()
	_http_server.stdio = opts.stdio
	_http_server.host_authority = _host_authority
	_http_server.port = opts.port
	_http_server.dct_path = opts.file
	_http_server.dct_paths = opts.get("files", [opts.file])
	add_child(_http_server)
	var file_list := ", ".join(PackedStringArray(opts.get("files", [opts.file])))
	if opts.stdio:
		return
	print("Docket MCP server listening on 127.0.0.1:%d — files: %s" % [opts.port, file_list])


func _print_gui_startup(message: String, stdio: bool) -> void:
	if stdio:
		printerr(message)
	else:
		print(message)


func _start_gui(opts: Dictionary) -> void:
	var state := AppState.new()
	state.load_schema()

	var files: Array = opts.get("files", [])

	# Owner records written while this GUI loads files name it as the GUI host.
	SessionProject.role = "gui"
	# Background settles read a project's cache in per-frame slices.
	DocketDBJsonl.snapshot_slice_ms = 12

	# Create and attach shell BEFORE loading .dct files so that
	# file_changed signals reach the RecordForm (which connects in init).
	var shell := AppShell.new()
	shell.init(state)
	# Startup loads restore workspace state; only later user opens affect recents.
	state.project_opened.disconnect(shell._add_to_recent)
	add_child(shell)

	if files.size() > 0:
		# Explicit --file args: load those
		_print_gui_startup("Docket GUI — file: %s" % opts.file, opts.stdio)
		state.load_projects(files)
	else:
		# No --file args: try session restore
		var session_paths := UserPrefs.load_session() if DocketRuntimeState.may_restore_session() else PackedStringArray()
		var valid_paths := PackedStringArray()
		for p in session_paths:
			if FileAccess.file_exists(p):
				valid_paths.append(p)
		if valid_paths.size() > 0:
			_print_gui_startup("Docket GUI — restoring %d project(s) from session" % valid_paths.size(), opts.stdio)
			state.load_projects(Array(valid_paths))
		else:
			_print_gui_startup("Docket GUI — empty workspace", opts.stdio)

	state.project_opened.connect(shell._add_to_recent)

	# Measurement hook for File → Save; absent unless its environment variable is set.
	if FrameProbe.enabled():
		var probe := FrameProbe.new()
		add_child(probe)
		probe.watch(shell.menu_builder())

	# Load .dcq query file if specified (shell is already in tree and ready)
	var query_path: String = str(opts.get("query", ""))
	if not query_path.is_empty() and FileAccess.file_exists(query_path):
		shell._query_grid.load_dcq(query_path)

	if state.dct_path.is_empty():
		DisplayServer.window_set_title("Docket")
	else:
		DisplayServer.window_set_title("Docket — %s" % state.dct_path.get_file())

	# Start embedded MCP server sharing the GUI's state
	var ServerScript = load("res://scripts/mcp/http_server.gd")
	var server = ServerScript.new()
	server.port = opts.port
	server.stdio = opts.stdio
	server.host_authority = _host_authority
	server.external_state = state
	add_child(server)
	if not opts.stdio:
		print("Embedded MCP server on 127.0.0.1:%d" % opts.port)


func _run_validate(opts: Dictionary) -> void:
	## Structural check on .dct files. Exits 1 if any file has errors, so it can
	## gate a commit after a hand-resolved merge conflict.
	var files: Array = opts.get("files", [])
	if files.is_empty() and not opts.file.is_empty():
		files = [opts.file]
	if files.is_empty():
		print("Error: --file required for validate")
		get_tree().quit(1)
		return

	var all_ok := true
	for path: String in files:
		var report := JSONLValidator.validate_file(path)
		print(JSONLValidator.format_report(report))
		if not report["ok"]:
			all_ok = false

	get_tree().quit(0 if all_ok else 1)


func _run_jsonl_migration(opts: Dictionary) -> void:
	var files: Array = opts.get("files", [])
	if files.is_empty() and not opts.file.is_empty():
		files = [opts.file]
	if files.is_empty():
		print("Error: --file required for --migrate-jsonl")
		get_tree().quit(1)
		return
	var all_ok := true
	for path: String in files:
		if not FileAccess.file_exists(path):
			print("Error: file not found: %s" % path)
			all_ok = false
			continue
		var fmt := JSONLMigration.detect_format(path)
		if fmt == "jsonl":
			print("Already JSONL: %s" % path)
			continue
		if fmt != "sqlite":
			print("Error: not a SQLite .dct file: %s (detected: %s)" % [path, fmt])
			all_ok = false
			continue
		var result := JSONLMigration.migrate_to_jsonl(path)
		if result["success"]:
			print("OK: %s — %d items, backup: %s" % [path, result["item_count"], result["backup_path"]])
		else:
			print("FAILED: %s — %s" % [path, result["error"]])
			all_ok = false
	get_tree().quit(0 if all_ok else 1)


func _run_migration(opts: Dictionary) -> void:
	var path: String = opts.file
	if path.is_empty():
		print("Error: --file required for --migrate")
		get_tree().quit(1)
		return
	if not FileAccess.file_exists(path):
		print("Error: file not found: %s" % path)
		get_tree().quit(1)
		return
	if not DocketMigration.is_json_dct(path):
		print("File is already SQLite format: %s" % path)
		get_tree().quit(0)
		return
	var db := DocketMigration.migrate(path)
	if db:
		db.close()
		print("Migration complete: %s" % path)
		get_tree().quit(0)
	else:
		print("Migration failed")
		get_tree().quit(1)
