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

var _test_runner: Node
var _http_server: Node


func _ready() -> void:
	var opts := _parse_args()

	match opts.mode:
		"help":
			_print_help()
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
	var opts := {"mode": "gui", "file": "", "files": [], "port": 3010, "query": ""}

	# User args (after --) when running via `godot --path . -- ...`
	var args := Array(OS.get_cmdline_user_args())
	# Exported binary: user_args is empty, fall back to full cmdline
	if args.is_empty():
		args = Array(OS.get_cmdline_args())

	var i := 0
	while i < args.size():
		match args[i]:
			"-?", "--help", "-h":
				opts.mode = "help"
			"--serve", "serve":
				opts.mode = "serve"
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
	if opts.file.is_empty() and opts.mode != "gui":
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
	print("  docket --migrate --file <f>   Migrate a legacy JSON .dct to JSONL")
	print("  docket --migrate-jsonl -f <f> Migrate a legacy SQLite .dct to JSONL")
	print("  docket --validate --file <f>  Check a .dct for structural problems")
	print("")
	print("OPTIONS:")
	print("  --file <path.dct>   Data file to open (repeatable for multi-project)")
	print("  --query <path.dcq>  Load a .dcq query file on startup")
	print("  --serve             Run as headless MCP server (no GUI)")
	print("  --port <number>     MCP server port (default: 3010)")
	print("  --test              Run tests and exit")
	print("  --migrate           Migrate a legacy JSON .dct to JSONL and exit")
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
	print("DATA FORMAT: .dct is JSONL text (canonical, commit it); .dct.cache is a")
	print("             disposable SQLite cache. Legacy JSON/SQLite auto-migrate.")
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
	_http_server.port = opts.port
	_http_server.dct_path = opts.file
	_http_server.dct_paths = opts.get("files", [opts.file])
	add_child(_http_server)
	var file_list := ", ".join(PackedStringArray(opts.get("files", [opts.file])))
	print("Docket MCP server listening on 127.0.0.1:%d — files: %s" % [opts.port, file_list])


func _start_gui(opts: Dictionary) -> void:
	var state := AppState.new()
	state.load_schema()

	var files: Array = opts.get("files", [])

	# Create and attach shell BEFORE loading .dct files so that
	# file_changed signals reach the RecordForm (which connects in init).
	var shell := AppShell.new()
	shell.init(state)
	add_child(shell)

	if files.size() > 0:
		# Explicit --file args: load those
		print("Docket GUI — file: %s" % opts.file)
		state.load_dct(str(files[0]))
		for i in range(1, files.size()):
			state.add_project(str(files[i]))
	else:
		# No --file args: try session restore
		var session_paths := UserPrefs.load_session()
		var valid_paths := PackedStringArray()
		for p in session_paths:
			if FileAccess.file_exists(p):
				valid_paths.append(p)
		if valid_paths.size() > 0:
			print("Docket GUI — restoring %d project(s) from session" % valid_paths.size())
			state.load_dct(valid_paths[0])
			for i in range(1, valid_paths.size()):
				state.add_project(valid_paths[i])
		else:
			print("Docket GUI — empty workspace")

	# Start embedded MCP server sharing the GUI's state
	var ServerScript = load("res://scripts/mcp/http_server.gd")
	var server = ServerScript.new()
	server.port = opts.port
	server.external_state = state
	add_child(server)
	print("Embedded MCP server on 127.0.0.1:%d" % opts.port)

	# Load .dcq query file if specified (shell is already in tree and ready)
	var query_path: String = str(opts.get("query", ""))
	if not query_path.is_empty() and FileAccess.file_exists(query_path):
		shell._query_grid.load_dcq(query_path)

	if state.dct_path.is_empty():
		DisplayServer.window_set_title("Docket")
	else:
		DisplayServer.window_set_title("Docket — %s" % state.dct_path.get_file())


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
