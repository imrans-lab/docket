extends Node
## The stdio MCP transport end to end, as a host runs it: a child Docket
## started with `--headless --no-header -- --serve --stdio --host-events`,
## fed requests on stdin until EOF. Its stdout must hold only JSON-RPC lines:
## the replies, and one item_changed for the item it creates (naming its
## opening, and described as the create it was); the process
## must exit 0 once stdin closes, and the item must be in the file. The item
## view the embedded UI reads crosses it whole, and an error keeps its kind.
## A launch with --quiet (which would silence every reply) must be refused.
## Run host-managed, it opens nothing it is not given: not a project in its
## working directory, not the saved session, which it also leaves unwritten;
## with none open it answers every other tool "no project", and serves again
## once a project is opened and after the last is closed. It refuses a .dct
## not given with --file, and an option with no value, exiting 1 and saying
## why rather than taking the next option as that value.
## Runs the child through bash (skipped on Windows, saying so), with its own
## HOME and XDG_DATA_HOME so it never opens the user's saved projects, and
## bounded to 120 s.

var A := AssertHelpers
var _dir := ""
var _path := ""

## A title outside ASCII, so line framing is checked on multi-byte text.
const TITLE := "Ünïcødé ✓ 日本語 — stdio"


func setup() -> void:
	_dir = OS.get_cache_dir().path_join("docket_stdio_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_dir)
	_path = _dir.path_join("stdio.dct")
	var db := DocketDBJsonl.create_new_jsonl(_path)
	db.set_project_name("stdio")
	db.close()


func teardown() -> void:
	_remove_tree(_dir)


static func _remove_tree(path: String) -> void:
	for sub in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(sub))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


## Run the child Docket with engine flags `engine_args` and `args` after
## `--`, stdin from `input_path`, in working directory `cwd` (this process's
## if empty): [exit code, stdout, stderr]. A hung child is
## stopped after 120 s, by `timeout` or else perl's alarm (macOS has no
## `timeout`); with neither, the run fails (exit 97) saying so.
func _run_child(args: String, input_path: String, engine_args: String = "", cwd: String = "") -> Array:
	var home := _dir.path_join("home")
	DirAccess.make_dir_recursive_absolute(home)
	var stderr_path := _dir.path_join("child.stderr")
	var command := ("bounded() { if command -v timeout >/dev/null; then timeout 120 \"$@\"; "
		+ "elif command -v perl >/dev/null; then perl -e 'alarm shift; exec @ARGV' 120 \"$@\"; "
		+ "else echo 'no timeout or perl to bound the child' >&2; return 97; fi; }; "
		+ ("cd %s && " % _shell_quoted(cwd) if not cwd.is_empty() else "")
		+ "HOME=%s XDG_DATA_HOME=%s bounded %s --headless --no-header %s --path %s -- %s < %s 2> %s") % [
		_shell_quoted(home), _shell_quoted(home), _shell_quoted(OS.get_executable_path()), engine_args,
		_shell_quoted(ProjectSettings.globalize_path("res://")), args, _shell_quoted(input_path),
		_shell_quoted(stderr_path)]
	# OS.execute with captured output runs through /bin/sh, which would expand
	# the "$@" above, so bash reads the command from a file instead.
	var script_path := _dir.path_join("run_child.sh")
	var file := FileAccess.open(script_path, FileAccess.WRITE)
	file.store_string(command + "\n")
	file.close()
	var output: Array = []
	var exit_code := OS.execute("bash", [script_path], output)
	return [exit_code, str(output[0]) if not output.is_empty() else "", FileAccess.get_file_as_string(stderr_path)]


## `run` (from _run_child) for a failure message: its exit code and the end
## of its stderr.
static func _described(run: Array) -> String:
	return "exit %d; stderr ends: %s" % [run[0], str(run[2]).right(600)]


func test_child_process_answers_and_reports_on_stdout_only() -> Variant:
	if OS.get_name() == "Windows":
		print("  SKIPPED on Windows: test_stdio_transport needs bash; this is NOT coverage")
		return true
	# An item already in the file, for the item view the embedded UI reads.
	var seed_db := DocketDBJsonl.open_jsonl(_path)
	var seeding := ToolRegistry.new()
	seeding.init(TypeRegistryBootstrap.load_shipped_schema(), seed_db, {"stdio": seed_db})
	var seeded := str(seeding.call_tool("docket_create", {"type": "bug", "title": "Seeded", "project": "stdio"}).get("id", ""))
	seed_db.close()
	var r = A.is_true(not seeded.is_empty(), "the seeded item was created")
	if r is String: return r
	var requests := [
		{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26",
			"capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "docket_create",
			"arguments": {"type": "bug", "title": TITLE, "project": "stdio"}}},
		{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "docket_item_view",
			"arguments": {"id": seeded, "project": "stdio"}}},
		{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "docket_item_view",
			"arguments": {"id": "0190a0a0-0000-7000-8000-000000000000", "project": "stdio"}}},
	]
	var input := ""
	for request in requests:
		input += JSON.stringify(request) + "\n"
	var input_path := _dir.path_join("requests.jsonl")
	var file := FileAccess.open(input_path, FileAccess.WRITE)
	file.store_string(input)
	file.close()
	# stdin is the request file, so it ends (EOF) once they are read.
	var run := _run_child("--serve --stdio --host-events --file %s" % _shell_quoted(_path), input_path)
	r = A.eq(run[0], 0, "the child exits 0 once stdin ends (%s)" % _described(run))
	if r is String: return r

	var replies := {}
	var created_events: Array = []
	for line in str(run[1]).split("\n", false):
		var message = JSON.parse_string(line)
		r = A.is_true(message is Dictionary and message.get("jsonrpc") == "2.0", "stdout line is JSON-RPC: %s (%s)" % [line, _described(run)])
		if r is String: return r
		if message.has("id"):
			replies[int(message.id)] = message
		elif message.get("method") == "minerva/plugin_event" and message.params.event == "item_changed" \
				and message.params.payload.change == "created":
			created_events.append(message.params.payload)
	r = A.eq(str(replies.get(1, {}).get("result", {}).get("protocolVersion", "")), "2025-03-26", "initialize answered")
	if r is String: return r
	var created = JSON.parse_string(str(replies.get(2, {}).get("result", {}).get("content", [{}])[0].get("text", "")))
	r = A.is_true(created is Dictionary and created.has("id"), "docket_create answered with the new id: %s" % [replies.get(2)])
	if r is String: return r
	r = A.eq(created_events.size(), 1, "one item_changed created: %s" % [created_events])
	if r is String: return r
	r = A.eq([created_events[0].project, created_events[0].id], ["stdio", created.id], "the event names the new item")
	if r is String: return r
	r = A.is_true(not str(created_events[0].get("project_path", "")).is_empty() and not str(created_events[0].get("open_generation", "")).is_empty()
		and created_events[0].get("baseline") == {"kind": "created", "item_type": "bug"},
		"the event names the opening and describes the create: %s" % [created_events[0]])
	if r is String: return r
	# The item view crosses the transport whole, and a failure keeps its kind in _meta.
	var view = JSON.parse_string(str(replies.get(3, {}).get("result", {}).get("content", [{}])[0].get("text", "")))
	r = A.is_true(view is Dictionary and str(view.get("item", {}).get("id", "")) == seeded
		and not str(view.get("token", "")).is_empty() and not str(view.get("short_id", "")).is_empty()
		and view.get("resolved", {}).has("revision"), "docket_item_view answers item, token, short_id and resolution: %s" % [replies.get(3)])
	if r is String: return r
	var missing: Dictionary = replies.get(4, {}).get("result", {})
	r = A.eq([missing.get("isError", false), missing.get("_meta", {}).get("docket/result", {}).get("kind", "")], [true, "missing"],
		"a missing item is an error whose kind survives in _meta: %s" % [missing])
	if r is String: return r

	var reopened := DocketDBJsonl.open_jsonl(_path)
	var stored_title := str(reopened.get_item(created.id).get("title", ""))
	reopened.close()
	return A.eq(stored_title, TITLE, "the item and its multi-byte title are in the file")


func test_quiet_is_refused() -> Variant:
	if OS.get_name() == "Windows":
		print("  SKIPPED on Windows: test_stdio_transport needs bash; this is NOT coverage")
		return true
	var input_path := _dir.path_join("empty.jsonl")
	FileAccess.open(input_path, FileAccess.WRITE).close()
	var run := _run_child("--serve --stdio --file %s" % _shell_quoted(_path), input_path, "--quiet")
	return A.is_true(run[0] == 1 and str(run[1]).is_empty() and str(run[2]).contains("cannot run with --quiet"),
		"--quiet would silence the replies, so stdio exits 1 saying why (%s)" % _described(run))


func test_host_managed_opens_only_what_it_is_given() -> Variant:
	if OS.get_name() == "Windows":
		print("  SKIPPED on Windows: test_stdio_transport needs bash; this is NOT coverage")
		return true
	var main := preload("res://scripts/main.gd").new()
	var managed: Dictionary = main._parse_arg_values(["--serve", "--stdio", "--host-events", "--host-managed"])
	var standalone: Dictionary = main._parse_arg_values(["--serve", "--stdio"])
	var refused: Array = [
		main._parse_arg_values(["--serve", "--host-managed"]),
		main._parse_arg_values(["--serve", "--stdio", "--host-managed", "bare.dct"]),
		main._parse_arg_values(["bare.dct", "--serve", "--stdio", "--host-managed"]),
		main._parse_arg_values(["--serve", "--stdio", "--host-managed", "--file"]),
		main._parse_arg_values(["--serve", "--stdio", "--file", "--host-managed"]),
		main._parse_arg_values(["--serve", "--stdio", "--host-managed", "--file", ""]),
		main._parse_arg_values(["--serve", "--stdio", "--host-managed", "--file", "-h"]),
		main._parse_arg_values(["--serve", "--stdio", "--query", "--host-managed"]),
		main._parse_arg_values(["--serve", "--stdio", "--port", "--host-managed"]),
	].map(func(opts: Dictionary) -> String: return "%s: %s" % [opts.mode, opts.get("error", "")])
	var standalone_bare: Dictionary = main._parse_arg_values(["--serve", "--stdio", "bare.dct"])
	main.free()
	var r = A.eq([managed.mode, managed.file, managed.files, standalone.file.is_empty(), refused, standalone_bare.files],
		["serve", "", [], false, ["invalid: --host-managed needs --serve --stdio",
			"invalid: --host-managed opens only projects named with --file",
			"invalid: --host-managed opens only projects named with --file",
			"invalid: --file needs a value", "invalid: --file needs a value",
			"invalid: --file needs a value",
			# -h is read as the help option, so this is no longer a stdio server.
			"invalid: --host-managed needs --serve --stdio",
			"invalid: --query needs a value", "invalid: --port needs a value"], ["bare.dct"]],
		"host-managed looks for no file and refuses one given without --file (in any order), an option with no value (never taking the next option as it), or no stdio; standalone is unchanged")
	if r is String: return r

	# What a standalone run would open: a project in the working directory and
	# the saved session (the child's user:// under its own HOME).
	var cwd := _dir.path_join("cwd")
	DirAccess.make_dir_recursive_absolute(cwd)
	var in_cwd := cwd.path_join("found.dct")
	DocketDBJsonl.create_new_jsonl(in_cwd).close()
	# Godot's user:// for this project under the child's HOME (and
	# XDG_DATA_HOME, set to it).
	var prefs_dir := _dir.path_join("home/Library/Application Support/Godot/app_userdata/Docket"
		if OS.get_name() == "macOS" else "home/godot/app_userdata/Docket")
	DirAccess.make_dir_recursive_absolute(prefs_dir)
	var prefs := prefs_dir.path_join("docket_prefs.json")
	var prefs_file := FileAccess.open(prefs, FileAccess.WRITE)
	prefs_file.store_string(JSON.stringify({"session_paths": [_path]}))
	prefs_file.close()
	var before := [FileAccess.get_sha256(in_cwd), FileAccess.get_sha256(prefs), FileAccess.get_sha256(_path)]

	var opened := _dir.path_join("opened.dct")
	var requests := [
		{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26",
			"capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		_tool_call(2, "docket_project_list", {}),
		_tool_call(3, "docket_get", {"id": "0190a0a0-0000-7000-8000-000000000000"}),
		_tool_call(4, "docket_project_add", {"path": opened, "create": true}),
		_tool_call(5, "docket_project_add", {"path": opened}),
		_tool_call(6, "docket_project_list", {}),
		_tool_call(7, "docket_project_remove", {"name": "opened"}),
		_tool_call(8, "docket_project_list", {}),
		_tool_call(9, "docket_project_add", {"path": opened}),
		_tool_call(10, "docket_create", {"type": "bug", "title": "After reopening", "project": "opened"}),
	]
	var input := ""
	for request in requests:
		input += JSON.stringify(request) + "\n"
	var input_path := _dir.path_join("managed.jsonl")
	var file := FileAccess.open(input_path, FileAccess.WRITE)
	file.store_string(input)
	file.close()
	var run := _run_child("--serve --stdio --host-events --host-managed", input_path, "", cwd)
	r = A.eq(run[0], 0, "the host-managed child exits 0 once stdin ends (%s)" % _described(run))
	if r is String: return r
	var replies := {}
	for line in str(run[1]).split("\n", false):
		var message = JSON.parse_string(line)
		if message is Dictionary and message.has("id"):
			replies[int(message.id)] = message
	# A tool's answer, or {} when the request failed outright (a JSON-RPC
	# error has no result).
	var answer := func(id: int) -> Dictionary: return replies.get(id, {}).get("result", {})
	var paths := func(reply: Dictionary) -> Array:
		var listed = JSON.parse_string(str(reply.get("content", [{}])[0].get("text", "")))
		return listed.get("projects", []).map(func(project: Dictionary) -> String: return str(project.path)) \
			if listed is Dictionary else ["unreadable: %s" % [reply]]
	r = A.eq([paths.call(answer.call(2)), answer.call(3).get("_meta", {}).get("docket/result", {}).get("kind", "")],
		[[], "no_project"], "it starts with no project, and a tool that needs one says so: %s" % [replies])
	if r is String: return r
	# No answer, a JSON-RPC error, or a tool error: a failure.
	var failed := func(id: int) -> bool:
		return not replies.has(id) or replies[id].has("error") or not replies[id].has("result") \
			or bool(replies[id].result.get("isError", false))
	# The tool answering the project already open, not opening it again.
	var already_open := func(id: int) -> bool:
		var added = JSON.parse_string(str(answer.call(id).get("content", [{}])[0].get("text", "")))
		return not failed.call(id) and added is Dictionary and added.get("already_open") == true and added.get("name") == "opened"
	var created = JSON.parse_string(str(answer.call(10).get("content", [{}])[0].get("text", "")))
	r = A.eq([failed.call(4), already_open.call(5), paths.call(answer.call(6)), failed.call(7),
		paths.call(answer.call(8)), failed.call(9), failed.call(10), created is Dictionary and created.has("id")],
		[false, true, [opened], false, [], false, false, true],
		"a project opens once (adding it again answers it, still open once); closing the last leaves an empty server, which opens it again and works in it: %s" % [replies])
	if r is String: return r
	return A.eq([[FileAccess.get_sha256(in_cwd), FileAccess.get_sha256(prefs), FileAccess.get_sha256(_path)],
		FileAccess.file_exists(cwd.path_join("docket.dct"))], [before, false],
		"the working directory's project, the saved session and its project are untouched, and nothing was created")


func test_host_managed_refusal_exits_saying_why() -> Variant:
	if OS.get_name() == "Windows":
		print("  SKIPPED on Windows: test_stdio_transport needs bash; this is NOT coverage")
		return true
	var input_path := _dir.path_join("nothing.jsonl")
	FileAccess.open(input_path, FileAccess.WRITE).close()
	# --query given no value must not take --host-managed as it (which would
	# run a standalone server, restoring and saving the session).
	var run := _run_child("--serve --stdio --query --host-managed", input_path)
	return A.is_true(run[0] == 1 and str(run[1]).is_empty() and str(run[2]).contains("--query needs a value"),
		"a host-managed run with an option missing its value exits 1 with nothing on stdout, saying why (%s)" % _described(run))


static func _tool_call(id: int, name: String, arguments: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": name, "arguments": arguments}}


static func _shell_quoted(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"
