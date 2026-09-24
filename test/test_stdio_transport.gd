extends Node
## The stdio MCP transport end to end, as a host runs it: a child Docket
## started with `--headless --no-header -- --serve --stdio --host-events`,
## fed requests on stdin until EOF. Its stdout must hold only JSON-RPC lines:
## the replies, and one item_changed for the item it creates; the process
## must exit 0 once stdin closes, and the item must be in the file. A launch
## with --quiet (which would silence every reply) must be refused.
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
## `--`, stdin from `input_path`: [exit code, stdout, stderr]. A hung child is
## stopped after 120 s, by `timeout` or else perl's alarm (macOS has no
## `timeout`); with neither, the run fails (exit 97) saying so.
func _run_child(args: String, input_path: String, engine_args: String = "") -> Array:
	var home := _dir.path_join("home")
	DirAccess.make_dir_recursive_absolute(home)
	var stderr_path := _dir.path_join("child.stderr")
	var command := ("bounded() { if command -v timeout >/dev/null; then timeout 120 \"$@\"; "
		+ "elif command -v perl >/dev/null; then perl -e 'alarm shift; exec @ARGV' 120 \"$@\"; "
		+ "else echo 'no timeout or perl to bound the child' >&2; return 97; fi; }; "
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
	var requests := [
		{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26",
			"capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "docket_create",
			"arguments": {"type": "bug", "title": TITLE, "project": "stdio"}}},
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
	var r = A.eq(run[0], 0, "the child exits 0 once stdin ends (%s)" % _described(run))
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


static func _shell_quoted(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"
