extends Node
## Minerva's shipped master (test/fixtures/minerva/master.jsonl, pinned by its
## SHA-256), whose nine skills and prompts keep their tags as a
## comma-separated string and eight other items as a list, through what a
## host does with it:
## - installed by MasterBootstrap, opened over a cache an earlier parser
##   built (its tag rows and parse revision gone, its file hash still
##   matching): the cache is built again, and all seventeen items read with
##   their labels; one item saved in the ordinary way rewrites the file with
##   every item's tags as a list and no parse revision in it, and on reopening
##   every label is still there;
## - the original shipment applied again reports only that saved item as
##   customized; a shipment that changes another item updates that one only,
##   keeping the file's bytes from before as the original, and recording
##   the new shipment's exact bytes as the baseline; applying it again changes
##   nothing;
## - a list element "a,b" stays one label, while tags "a,,b" or ["a", 7] refuse
##   the project, leaving its file and its cache as they were;
## - over stdio, run host-managed as a host starts it: Minerva's schema is
##   declared (test/fixtures/minerva/schema.json), the master is bootstrapped
##   from its bytes, its policies and skills are listed, a string-tagged
##   skill reads with its labels, and a second project opened beside it
##   leaves the master open as it was.
## The stdio child runs through bash (skipped on Windows, saying so), with its
## own HOME and XDG_DATA_HOME, bounded to 120 s; its stdout and stderr are kept
## beside it, and its stderr must hold no script, parse or extension fault.
## The class's files are kept after it runs (the directory is printed).

var A := AssertHelpers
var _dir := ""
## What a child's stderr must not hold (as the relay's own checks).
const CHILD_FAULTS := ["SCRIPT ERROR:", "Parse Error:", "Compile Error", "GDExtension dynamic library not found",
	"Can't open GDExtension dynamic library", "Error loading extension"]

const MASTER := "res://test/fixtures/minerva/master.jsonl"
const MASTER_SHA := "07c0b10058c98388889d246aa1f82270eef56bef5e304dcb4a806f26377c3431"
const SCHEMA := "res://test/fixtures/minerva/schema.json"
const SAVED_ID := "019d5c00000000000000000000000001"
const UPDATED_ID := "019d5c00000000000000000000000002"
## The items whose tags the master writes as a comma-separated string.
const STRING_TAGGED := ["019d5c00000000000000000000000001", "019d5c00000000000000000000000002",
	"019d5c00000000000000000000000003", "019d5c00000000000000000000000004", "019d5c00000000000000000000000005",
	"019d5c00000000000000000000000006", "019d6f20000000000000000000000001", "019d5c00000000000000000000000010",
	"019d5c00000000000000000000000030"]
## The labels of every item in the master, sorted: the first nine from a
## comma-separated string, the rest from a list.
const LABELS := {
	"019d5c00000000000000000000000001": ["agent-supervision", "workflow"],
	"019d5c00000000000000000000000002": ["hints", "knowledge", "tool-usage"],
	"019d5c00000000000000000000000003": ["efficiency", "patterns", "tool-usage"],
	"019d5c00000000000000000000000004": ["docket", "tool-suite", "work-tracking"],
	"019d5c00000000000000000000000005": ["cobrowser", "tool-suite", "web-automation"],
	"019d5c00000000000000000000000006": ["documents", "tool-suite"],
	"019d6f20000000000000000000000001": ["analysis", "csv", "spreadsheet", "tables", "tool-suite"],
	"019d5c00000000000000000000000010": ["agentic", "system-prompt"],
	"019d5c00000000000000000000000030": ["amazon", "cobrowser", "comparison", "shopping", "spreadsheet"],
	"019d6120d31e781f992f65468a21ec19": ["amazon", "cobrowser", "dark-patterns", "policy", "shopping"],
	"019d6125a8437f89bf48422c6fa95fb0": ["amazon", "cobrowser", "dark-patterns", "shopping"],
	"019d6125ce387c76b4baf20f8a155e97": ["amazon", "cobrowser", "dark-patterns", "shopping"],
	"019d5c00000000000000000000000020": ["amazon", "cobrowser", "dom", "selectors"],
	"019d5c00000000000000000000000021": ["amazon", "cobrowser", "inject", "selectors"],
	"019d5c00000000000000000000000031": ["authoring", "optimization", "reference", "skills"],
	"019d8ad9047579b59256247bfc129822": ["code", "editor", "files", "text"],
	"019d8ae63d8f78c830d93591926592cf": ["authoring", "meta", "skills"],
}


func setup() -> void:
	_dir = OS.get_cache_dir().path_join("docket_minerva_master_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_dir)


# The class's files (projects, caches, the stdio child's requests and
# streams) are kept for whoever reads the run's verdict.
func teardown() -> void:
	print("  test files kept at %s" % _dir)


static func _sha256(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return hashing.finish().hex_encode()


static func _sorted(values: Array) -> Array:
	var copy := values.duplicate()
	copy.sort()
	return copy


# Every item of the project at `path` whose labels differ from LABELS, "" for
# none; the project is opened and closed again.
static func _wrong_labels(path: String) -> String:
	var db := DocketDBJsonl.open_jsonl(path)
	if db == null:
		return "the project did not open: %s" % DocketDBJsonl.last_open_error
	var wrong: Array = []
	for id in LABELS:
		var labels := _sorted(db.get_item(id).get("tags", []))
		if labels != LABELS[id]:
			wrong.append("%s has %s" % [id, labels])
	db.close()
	return ", ".join(PackedStringArray(wrong))


func test_the_master_keeps_its_labels_through_cache_save_and_shipments() -> Variant:
	var shipped := FileAccess.get_file_as_bytes(MASTER)
	var r = A.eq(_sha256(shipped), MASTER_SHA, "the fixture is Minerva's pinned master")
	if r is String: return r
	var path := _dir.path_join("master.dct")
	var installed := MasterBootstrap.apply(path, shipped, {})
	r = A.eq(installed.get("status"), "installed", "the master is installed: %s" % [installed])
	if r is String: return r

	# A cache as an earlier parser left it: no tags for the string-tagged
	# items, no parse revision, and the file's own hash.
	var first := DocketDBJsonl.open_jsonl(path)
	r = A.not_null(first, "the master opens: %s" % DocketDBJsonl.last_open_error)
	if r is String: return r
	first.close()
	var cache_path := JSONLCache.cache_path_for_version(path, "1.0.0")
	var cache := DocketDB.new()
	r = A.is_true(cache.open(cache_path), "its cache opens as a database")
	if r is String: return r
	var aged := cache._exec_checked("DELETE FROM item_tags WHERE item_id IN (%s);" % ",".join(
		PackedStringArray(STRING_TAGGED.map(func(id: String) -> String: return "'%s'" % id))))
	if aged.is_empty():
		aged = cache._exec_checked("DELETE FROM docket_meta WHERE key = ?;", [JSONLCache.PARSE_REVISION_META])
	var still_matching := cache.get_meta_value("jsonl_hash", "") == FileAccess.get_sha256(path)
	cache.close()
	r = A.is_true(aged.is_empty() and still_matching, "the cache looks like an earlier parser's, for the same file: %s" % aged)
	if r is String: return r
	var wrong := _wrong_labels(path)
	r = A.eq(wrong, "", "every item reads with its labels once the old cache is built again")
	if r is String: return r

	# One item saved in the ordinary way; the file is rewritten whole.
	var db := DocketDBJsonl.open_jsonl(path)
	r = A.not_null(db, "the master opens to be saved: %s" % DocketDBJsonl.last_open_error)
	if r is String: return r
	var saved := db.update_item_fields_checked(SAVED_ID, {"title": "Agent Supervision, as kept here"})
	db.close()
	r = A.eq(saved, "", "the item is saved")
	if r is String: return r
	var text := FileAccess.get_file_as_string(path)
	var lists := true
	for line in text.split("\n", false):
		var record = JSON.parse_string(line)
		if record is Dictionary and record.get("_type") == "item" and not record.get("tags") is Array:
			lists = false
	r = A.is_true(lists and not text.contains(JSONLCache.PARSE_REVISION_META),
		"the saved file holds every item's tags as a list, and no parse revision")
	if r is String: return r
	wrong = _wrong_labels(path)
	r = A.eq(wrong, "", "after the save every item still reads with its labels")
	if r is String: return r

	# The original shipment again: only the saved item is customized.
	var again := MasterBootstrap.apply(path, shipped, {})
	r = A.is_true(again.get("status") == "unchanged" and again.get("updated") == [] and again.get("inserted") == []
		and again.get("conflicts") == [{"id": SAVED_ID, "reason": "customized since it was shipped"}],
		"the original shipment finds only the saved item customized: %s" % [again])
	if r is String: return r

	# A shipment that changes another item updates that one only.
	var changed_text := ""
	for line in shipped.get_string_from_utf8().split("\n", false):
		var record = JSON.parse_string(line)
		if record is Dictionary and record.get("id") == UPDATED_ID:
			record["title"] = "Tool usage hints, as shipped again"
			line = JSON.stringify(record)
		changed_text += line + "\n"
	var changed := changed_text.to_utf8_buffer()
	var before := FileAccess.get_file_as_string(path)
	var updated := MasterBootstrap.apply(path, changed, {})
	r = A.is_true(updated.get("status") == "updated" and updated.get("updated") == [UPDATED_ID]
		and updated.get("conflicts") == [{"id": SAVED_ID, "reason": "customized since it was shipped"}]
		and updated.get("digest") == _sha256(changed),
		"a changed shipment updates the untouched item and keeps the customized one: %s" % [updated])
	if r is String: return r
	r = A.is_true(FileAccess.get_file_as_bytes(path + MasterBootstrap.BASELINE_SUFFIX) == changed
		and FileAccess.get_file_as_string(str(updated.get("original", ""))) == before,
		"the new shipment is the baseline, byte for byte, and the file's bytes before it are kept")
	if r is String: return r
	var repeated := MasterBootstrap.apply(path, changed, {})
	r = A.is_true(repeated.get("status") == "unchanged" and repeated.get("updated") == []
		and repeated.get("conflicts") == [{"id": SAVED_ID, "reason": "customized since it was shipped"}],
		"applying the same shipment again changes nothing: %s" % [repeated])
	if r is String: return r

	db = DocketDBJsonl.open_jsonl(path)
	r = A.not_null(db, "the master opens after the shipments: %s" % DocketDBJsonl.last_open_error)
	if r is String: return r
	var titles := [str(db.get_item(SAVED_ID).get("title", "")), str(db.get_item(UPDATED_ID).get("title", ""))]
	db.close()
	r = A.eq(titles, ["Agent Supervision, as kept here", "Tool usage hints, as shipped again"],
		"the saved item keeps its change and the other takes the shipment's")
	if r is String: return r
	return A.eq(_wrong_labels(path), "", "and every item still reads with its labels")


func test_a_list_element_is_one_label_and_bad_tags_refuse_the_project() -> Variant:
	var path := _dir.path_join("tags.dct")
	var db := DocketDBJsonl.create_new_jsonl(path)
	var r = A.not_null(db, "a project is created")
	if r is String: return r
	db.set_project_name("tags")
	var registry := ToolRegistry.new()
	registry.init(TypeRegistryBootstrap.load_shipped_schema(), db, {"tags": db})
	var id := str(registry.call_tool("docket_create", {"type": "bug", "title": "Tagged", "project": "tags",
		"tags": ["a,b"]}).get("id", ""))
	db.close()
	db = DocketDBJsonl.open_jsonl(path)
	var labels: Array = db.get_item(id).get("tags", []) if db != null else []
	if db != null:
		db.close()
	r = A.eq(labels, ["a,b"], "a list element holding a comma stays one label")
	if r is String: return r

	var cache_path := JSONLCache.cache_path_for_version(path, "2.0.0")
	var good := FileAccess.get_file_as_string(path)
	for bad in ['"a,,b"', '["a",7]']:
		var damaged := good.replace('"tags":["a,b"]', '"tags":%s' % bad)
		r = A.neq(damaged, good, "the item's tags are replaced by %s" % bad)
		if r is String: return r
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(damaged)
		file.close()
		var cache_before := _cache_files(cache_path)
		var refused := DocketDBJsonl.open_jsonl(path)
		if refused != null:
			refused.close()
		r = A.is_true(refused == null and DocketDBJsonl.last_open_error.contains("item %s: tags" % id),
			"tags %s refuse the project, naming the item: %s" % [bad, DocketDBJsonl.last_open_error])
		if r is String: return r
		r = A.is_true(FileAccess.get_file_as_string(path) == damaged and _cache_files(cache_path) == cache_before,
			"the refused project's file and cache are as they were (%s)" % bad)
		if r is String: return r
	return true


# The cache at `cache_path` with its -wal and -shm, each as its SHA-256 or
# "absent".
static func _cache_files(cache_path: String) -> Array:
	var files: Array = []
	for suffix in ["", "-wal", "-shm"]:
		files.append(FileAccess.get_sha256(cache_path + suffix) if FileAccess.file_exists(cache_path + suffix) else "absent")
	return files


## Runs the child Docket host-managed over stdio with DOCKET_PANEL_SECRET
## `secret`, stdin from `input_path`: [exit code, stdout, stderr].
func _run_host_managed(secret: String, input_path: String) -> Array:
	var home := _dir.path_join("home")
	DirAccess.make_dir_recursive_absolute(home)
	var stderr_path := _dir.path_join("child.stderr")
	var command := ("bounded() { if command -v timeout >/dev/null; then timeout 120 \"$@\"; "
		+ "elif command -v perl >/dev/null; then perl -e 'alarm shift; exec @ARGV' 120 \"$@\"; "
		+ "else echo 'no timeout or perl to bound the child' >&2; return 97; fi; }; "
		+ "cd %s && DOCKET_PANEL_SECRET=%s HOME=%s XDG_DATA_HOME=%s bounded %s --headless --no-header --path %s "
		+ "-- --serve --stdio --host-events --host-managed < %s 2> %s") % [
		_shell_quoted(_dir), secret, _shell_quoted(home), _shell_quoted(home), _shell_quoted(OS.get_executable_path()),
		_shell_quoted(ProjectSettings.globalize_path("res://")), _shell_quoted(input_path), _shell_quoted(stderr_path)]
	var script_path := _dir.path_join("run_child.sh")
	var file := FileAccess.open(script_path, FileAccess.WRITE)
	file.store_string(command + "\n")
	file.close()
	var output: Array = []
	var exit_code := OS.execute("bash", [script_path], output)
	var stdout := str(output[0]) if not output.is_empty() else ""
	var saved := FileAccess.open(_dir.path_join("child.stdout"), FileAccess.WRITE)
	saved.store_string(stdout)
	saved.close()
	return [exit_code, stdout, FileAccess.get_file_as_string(stderr_path)]


static func _shell_quoted(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"


# A tools/call reply's result, as the tool returned it.
static func _tool_result(reply: Dictionary) -> Dictionary:
	var content: Array = reply.get("result", {}).get("content", [{}])
	var value = JSON.parse_string(str(content[0].get("text", ""))) if not content.is_empty() else null
	return value if value is Dictionary else {}


func test_a_host_bootstraps_the_master_over_stdio_and_opens_another_project() -> Variant:
	if OS.get_name() == "Windows":
		print("  SKIPPED on Windows: this case needs bash; this is NOT coverage")
		return true
	var secret := Crypto.new().generate_random_bytes(32).hex_encode()
	var schema_text := FileAccess.get_file_as_string(SCHEMA)
	var version := "minerva-" + FileAccess.get_sha256(SCHEMA)
	var master_path := _dir.path_join("host").path_join("master.dct")
	var second_path := _dir.path_join("host").path_join("second.dct")
	DirAccess.make_dir_recursive_absolute(master_path.get_base_dir())
	var policies := {"conditions": [{"field": "type", "op": "eq", "value": "policy"},
		{"conj": "and", "field": "status", "op": "in", "value": ["proposed", "active"]}]}
	var skills := {"conditions": [{"field": "type", "op": "eq", "value": "skill"}]}
	var requests := [
		{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26",
			"capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		{"jsonrpc": "2.0", "id": 2, "method": "docket/panel/declare_schema", "params": {"panel_secret": secret,
			"schema": JSON.parse_string(schema_text), "version": version}},
		{"jsonrpc": "2.0", "id": 3, "method": "docket/panel/bootstrap_project", "params": {"panel_secret": secret,
			"path": master_path, "content": Marshalls.raw_to_base64(FileAccess.get_file_as_bytes(MASTER))}},
		{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "docket_project_list", "arguments": {}}},
		{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "docket_query",
			"arguments": {"project": "master", "filter": policies}}},
		{"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "docket_query",
			"arguments": {"project": "master", "filter": skills}}},
		{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "docket_get",
			"arguments": {"id": SAVED_ID, "project": "master"}}},
		{"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "docket_project_add",
			"arguments": {"path": second_path, "create": true}}},
		{"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "docket_project_list", "arguments": {}}},
	]
	var input := ""
	for request in requests:
		input += JSON.stringify(request) + "\n"
	var input_path := _dir.path_join("requests.jsonl")
	var file := FileAccess.open(input_path, FileAccess.WRITE)
	file.store_string(input)
	file.close()
	var run := _run_host_managed(secret, input_path)
	var described := "exit %d; stderr ends: %s" % [run[0], str(run[2]).right(600)]
	var r = A.eq(run[0], 0, "the child exits 0 once stdin ends (%s)" % described)
	if r is String: return r
	var faults: Array = CHILD_FAULTS.filter(func(fault: String) -> bool: return str(run[2]).contains(fault))
	r = A.eq(faults, [], "the child's stderr holds no script, parse or extension fault (%s)" % described)
	if r is String: return r
	var replies := {}
	for line in str(run[1]).split("\n", false):
		var message = JSON.parse_string(line)
		r = A.is_true(message is Dictionary and message.get("jsonrpc") == "2.0", "stdout line is JSON-RPC: %s" % line)
		if r is String: return r
		if message.has("id"):
			replies[int(message.id)] = message

	r = A.eq(replies.get(2, {}).get("result", {}), {"version": version}, "Minerva's schema is declared")
	if r is String: return r
	var report: Dictionary = replies.get(3, {}).get("result", {})
	var master: Dictionary = report.get("project", {})
	r = A.is_true(report.get("status") == "installed" and report.get("conflicts") == []
		and not str(master.get("path", "")).is_empty(), "the master is bootstrapped and open: %s" % [report])
	if r is String: return r
	var listed: Array = _tool_result(replies.get(4, {})).get("projects", [])
	r = A.is_true(listed.size() == 1 and listed[0].get("path") == master.path, "only the master is open: %s" % [listed])
	if r is String: return r
	r = A.eq([_tool_result(replies.get(5, {})).get("items", []).size(), _tool_result(replies.get(6, {})).get("items", []).size()],
		[3, 10], "its three policies and ten skills are listed")
	if r is String: return r
	r = A.eq(_sorted(_tool_result(replies.get(7, {})).get("tags", [])), LABELS[SAVED_ID],
		"a skill whose tags are a comma-separated string reads with its labels")
	if r is String: return r
	r = A.is_true(replies.has(8) and replies[8].get("result", {}).get("isError", false) != true
		and not _tool_result(replies[8]).has("error"), "a second project opens: %s" % [replies.get(8)])
	if r is String: return r
	var after: Array = _tool_result(replies.get(9, {})).get("projects", [])
	var kept: Array = after.filter(func(project) -> bool: return project.get("path") == master.path)
	return A.is_true(after.size() == 2 and kept.size() == 1
		and kept[0].get("open_generation") == listed[0].get("open_generation"),
		"the master stays open as it was beside the second project: %s" % [after])
