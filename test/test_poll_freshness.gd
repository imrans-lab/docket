extends Node
## Real shell, cache and independent writer. Stable idle ticks must hash no
## canonical bytes; racy timestamps get one safe hash before reuse.
const A = preload("res://test/assert_helpers.gd")
const DIR := "user://fixtures/poll_freshness"
class CountingState extends AppState:
	var queries := 0
	var reload_calls := 0
	func execute_cross_project_query(query: Dictionary, detail: String = "full", keys: PackedStringArray = PackedStringArray()) -> Array:
		queries += 1
		return super.execute_cross_project_query(query, detail, keys)
	func reload_stale() -> Array:
		reload_calls += 1
		return super.reload_stale()
var state: CountingState
var shell: AppShell
var dbs: Array[DocketDBJsonl] = []

func setup() -> void: DirAccess.make_dir_recursive_absolute(DIR)
func before_each() -> void: _clean()
func teardown() -> void:
	_clean()
	DirAccess.remove_absolute(DIR)
func _clean() -> void:
	if is_instance_valid(shell):
		remove_child(shell)
		shell.free()
	for db in dbs:
		if db.is_open(): db.close()
	dbs.clear()
	for file in DirAccess.get_files_at(DIR): DirAccess.remove_absolute(DIR + "/" + file)

func _fixture(count: int) -> String:
	state = CountingState.new()
	state.schema = TypeRegistryBootstrap.load_shipped_schema()
	state.prefs = UserPrefs.new()
	for i in count:
		var name := "poll%d" % i
		var db := DocketDBJsonl.create_new_jsonl(DIR + "/" + name + ".dct")
		if db == null: return "cannot create project"
		dbs.append(db)
		state._project_dbs[name] = db
		state._type_registries[name] = TypeRegistry.for_db(db, name)
	state.db = dbs[0]
	state.dct_path = dbs[0].get_path()
	shell = AppShell.new()
	shell.init(state)
	add_child(shell)
	shell._poll_timer.stop()
	return ""

func _foreign(action: String, id: String = "", private_cache: bool = false) -> Dictionary:
	var receipt := ProjectSettings.globalize_path(DIR + "/receipt.json")
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://test/poll_writer.gd", "--", ProjectSettings.globalize_path(dbs[0].get_path()), action, id, receipt, "private" if private_cache else "shared"])
	var output: Array = []
	var code := OS.execute(OS.get_executable_path(), args, output, true)
	if code != 0: return {"error": "writer exit %d: %s" % [code, output]}
	var result = JSON.parse_string(FileAccess.get_file_as_string(receipt))
	return result if result is Dictionary else {"error": "writer omitted receipt"}

func test_stable_nine_project_idle_and_unsettled_foreign_append() -> Variant:
	var error := _fixture(9)
	if not error.is_empty(): return error
	# A cold or just-written canonical is deliberately hashed until its mtime
	# safety window expires. Warm it once, then measure only stable idle ticks.
	await get_tree().create_timer(JSONLFreshness.MTIME_WINDOW_SEC + 0.1).timeout
	shell._on_poll_external_changes()
	JSONLFreshness.hash_reads.clear()
	var started := Time.get_ticks_usec()
	for i in 5: shell._on_poll_external_changes()
	var elapsed := (Time.get_ticks_usec() - started) / 5.0
	var reads := 0
	for db in dbs: reads += int(JSONLFreshness.hash_reads.get(db.get_path(), 0))
	var r = A.is_true(reads == 0 and elapsed < 5000, "stable9project idle: %d hashes, %.0fus/tick" % [reads, elapsed])
	if r is String: return r
	var original := FileAccess.get_file_as_bytes(dbs[0].get_path())
	var result := _foreign("create", "", true)
	if result.has("error"): return result.error
	r = A.is_true(FileAccess.get_file_as_bytes(dbs[0].get_path()) == original and JSONLSidecar.has_content(dbs[0].get_path() + ".log"), "foreign writer left an unsettled append")
	if r is String: return r
	r = A.is_true(not dbs[0].has_item(str(result.id)), "private writer did not update the shell cache")
	if r is String: return r
	var before := state.reload_calls
	shell._on_poll_external_changes()
	return A.is_true(state.reload_calls == before + 1 and dbs[0].has_item(str(result.id)), "next tick reloads foreign sidecar before settle")


func test_same_size_rewrite_inside_timestamp_window_changes_next_token() -> Variant:
	var error := _fixture(2)
	if not error.is_empty(): return error
	var path := dbs[0].get_path()
	# Change one equal-length meta value without waiting for the timestamp
	# safety window. No reusable hash can have been recorded yet.
	var before := shell._get_projects_token()
	var original := FileAccess.get_file_as_string(path)
	var edited := original.replace('"poll0"', '"pollX"')
	if edited == original: return "fixture lacks project meta"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(edited)
	file.close()
	# The next check may occur after the 2s window (the shell polls every3s).
	await get_tree().create_timer(3.1).timeout
	return A.is_true(shell._get_projects_token() != before, "equal-size racy rewrite survives next3s tick")


func _shown_rows() -> Array:
	var grid := shell._query_grid
	var rows: Array = []
	var root := grid._tree.get_root()
	if root == null: return rows
	for row in root.get_children():
		var origin: Dictionary = row.get_metadata(0)
		rows.append([str(origin.project), str(origin.id), row.get_text(grid._col_fields.find("title")), row.get_text(grid._col_fields.find("status"))])
	rows.sort()
	return rows

func _expected_rows() -> Array:
	var rows: Array = []
	for project: String in state.get_project_dbs():
		for item: Dictionary in state.get_db_for_project(project).execute_query({"filter": {"conditions": [{"field": "title", "op": "contains", "value": "row"}]}}):
			rows.append([project, str(item.id), str(item.title), str(item.status)])
	rows.sort()
	return rows

func test_visible_grid_mcp_crud_in_same_and_other_process_queries_once() -> Variant:
	var error := _fixture(2)
	if not error.is_empty(): return error
	shell._query_grid.set_filter(JSON.stringify({"conditions": [{"field": "title", "op": "contains", "value": "row"}]}))
	var tools := ToolRegistry.new()
	tools.init(state.schema, state.db, state.get_project_dbs())
	for foreign in [false, true]:
		var id := ""
		for action in ["create", "update", "transition", "delete"]:
			var before := state.queries
			for i in 2: shell._on_poll_external_changes()
			var r = A.eq(state.queries, before, "idle ticks before %s foreign=%s query zero times" % [action, foreign])
			if r is String: return r
			var result: Dictionary
			if foreign: result = _foreign(action, id)
			else:
				var input := {"id": id, "project": "poll0"}
				match action:
					"create": input = {"type": "chore", "title": "row created", "project": "poll0"}
					"update": input.title = "row updated"
					"transition": input.to = "in_progress"
				result = tools.call_tool("docket_" + action, input)
			if result.has("error"): return "%s foreign=%s: %s" % [action, foreign, result.error]
			if action == "create": id = str(result.id)
			shell._on_poll_external_changes()
			r = A.eq(state.queries, before + 1, "%s foreign=%s queries once on next poll" % [action, foreign])
			if r is String: return r
			r = A.eq(_shown_rows(), _expected_rows(), "grid equals fresh core query after %s" % action)
			if r is String: return r
	return true
