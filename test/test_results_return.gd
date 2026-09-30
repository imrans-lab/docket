extends Node
## Returning from an open record to the query results (AppShell Back). The grid
## stays parented and keeps its rows; a change that arrives while the record is
## open makes the next showing query once.
##
## Fixture: the real AppShell over two JSONL projects built in DIR, the grid
## filtered to titles containing MATCH and sorted by title. For each entry of
## _changes(), a row is opened from the grid, the change runs while the record
## is open, and Back is pressed. The shell's 3 s poll is stopped so no settle
## lands mid-step; the external change drives the poll itself.
##
## Oracles:
##   queries  calls to AppState.execute_cross_project_query (the grid's results
##            query with two projects loaded), counted by a pass-through
##            subclass from before the record opens until after Back: 0 when
##            nothing changed, exactly 1 after a change.
##   node     the grid never emits tree_exiting and keeps its parent; when
##            nothing changed its Tree keeps the same root TreeItem (no rebuild),
##            the same scroll offset and the same selected row.
##   rows     the rows shown after Back (project, id, title, storage word, in
##            order) equal each project's DocketDB.execute_query with the same
##            condition, merged and sorted by title here.
##   files    each project's .dct sha256 and mtime are unchanged by opening the
##            record and by Back.
## To cover another kind of change, add an entry to _changes().

const A = preload("res://test/assert_helpers.gd")
const DIR := "user://fixtures/results_return"
const PROJECTS := ["alpha", "beta"]
const MATCH := "row"
const ROWS_PER_PROJECT := 40  # enough rows for the grid to scroll
const OPEN_ROW := 60  # grid row the record is opened from

## Counts results queries; everything else is AppState's own behavior.
class CountingState extends AppState:
	var results_queries := 0

	func execute_cross_project_query(query: Dictionary, detail: String = "full") -> Array:
		results_queries += 1
		return super.execute_cross_project_query(query, detail)

var _dbs: Array[DocketDB] = []
var _state: CountingState
var _shell: AppShell
var _tools: ToolRegistry
var _open_origin: Dictionary = {}
var _ephemeral: Dictionary = {}  # label -> id of an ephemeral item made by a change


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))

func before_each() -> void:
	_reset_fixtures()

func teardown() -> void:
	_reset_fixtures()

func _reset_fixtures() -> void:
	for child in get_children():
		remove_child(child)
		child.free()
	for db in _dbs:
		if db != null and db.is_open():
			db.close()
	_dbs.clear()
	_ephemeral.clear()
	_open_origin = {}
	for filename in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [DIR, filename]))


func test_back_shows_retained_results_and_requeries_once_after_a_change() -> Variant:
	var fixture_error := _open_fixture()
	if not fixture_error.is_empty():
		return fixture_error
	var grid := _shell._query_grid
	grid.set_filter(JSON.stringify({"conditions": [{"field": "title", "op": "contains", "value": MATCH}]}))
	grid._toggle_sort(grid._col_fields.find("title"))
	await get_tree().process_frame
	var r = A.eq(_shown_rows(), _expected_rows(), "fixture: the grid shows the filtered, sorted rows")
	if r is String:
		return r
	for change: Dictionary in _changes():
		r = await _open_change_and_return(change)
		if r is String:
			return "%s: %s" % [change.kind, r]
	return true


## Each change runs while a record is open. `queries` is the number of results
## queries expected from opening the record through Back.
func _changes() -> Array[Dictionary]:
	return [
		{"kind": "unchanged", "queries": 0, "apply": func() -> String: return ""},
		{"kind": "local edit", "queries": 1, "apply": _local_edit},
		{"kind": "MCP edit", "queries": 1, "apply": _mcp_edit},
		{"kind": "external edit", "queries": 1, "apply": _external_edit},
		{"kind": "ephemeral create", "queries": 1, "apply": _ephemeral_create},
		{"kind": "ephemeral update", "queries": 1, "apply": _ephemeral_update},
		{"kind": "ephemeral keep", "queries": 1, "apply": _ephemeral_keep},
		{"kind": "ephemeral drop", "queries": 1, "apply": _ephemeral_drop},
	]


func _open_change_and_return(change: Dictionary) -> Variant:
	var grid := _shell._query_grid
	var root := grid._tree.get_root()
	if root == null or root.get_child_count() == 0:
		return "the grid has no rows to open"
	var target := root.get_child(mini(OPEN_ROW, root.get_child_count() - 1))
	target.select(0)
	grid._tree.scroll_to_item(target)
	await get_tree().process_frame
	var unchanged: bool = change.queries == 0
	var scroll_before := grid._tree.get_scroll()
	if unchanged and scroll_before.y <= 0.0:
		return "fixture: the grid did not scroll, so scroll retention cannot be observed"
	var parent_before := grid.get_parent()
	var exits: Array[int] = [0]
	var on_exit := func() -> void: exits[0] += 1
	grid.tree_exiting.connect(on_exit)
	_state.results_queries = 0

	var files_before := _file_stamps()
	_open_origin = grid.get_selected_origin()
	grid._on_item_activated()
	var files_opened := _file_stamps()
	var form := _shell._record_form
	var opened_ok: bool = _shell._current_mode == AppShell.ViewMode.DETAIL and not grid.is_visible_in_tree() and form._current_id == str(_open_origin.id) and form._current_project == str(_open_origin.project)
	var change_error: Variant = await (change.apply as Callable).call()
	var files_changed := _file_stamps()
	form._back_btn.pressed.emit()
	await get_tree().process_frame
	var files_back := _file_stamps()
	grid.tree_exiting.disconnect(on_exit)

	var r = A.is_true(opened_ok, "activating a row opens that record from its own project")
	if r is String: return r
	if change_error is String and not str(change_error).is_empty():
		return "the change failed: %s" % change_error
	r = A.is_true(_shell._current_mode == AppShell.ViewMode.QUERY and grid.is_visible_in_tree(), "Back shows the results")
	if r is String: return r
	r = A.eq(_state.results_queries, int(change.queries), "results queries from opening the record through Back")
	if r is String: return r
	r = A.is_true(exits[0] == 0 and grid.get_parent() == parent_before, "the grid is never reparented")
	if r is String: return r
	r = A.eq(_shown_rows(), _expected_rows(), "rows shown after Back equal a fresh query")
	if r is String: return r
	r = A.eq(files_opened, files_before, "opening a record writes no project file")
	if r is String: return r
	r = A.eq(files_back, files_changed, "Back writes no project file")
	if r is String: return r
	if unchanged:
		r = A.is_true(grid._tree.get_root() == root, "unchanged results are not rebuilt")
		if r is String: return r
		r = A.eq(grid._tree.get_scroll(), scroll_before, "scroll position is retained")
		if r is String: return r
		r = A.eq(grid.get_selected_origin(), _open_origin, "selection is retained")
		if r is String: return r
	return true


# -- Changes ----------------------------------------------------------------

func _local_edit() -> String:
	## Save Changes in the open record: the new title moves its sort position.
	var form := _shell._record_form
	form._title_edit.text = "row zz local edit"
	var error: Variant = await form._save_changes()
	return str(error) if error is String else ""


func _mcp_edit() -> String:
	## A tool call through the MCP tool registry retitles another row out of
	## the filter.
	var other := _other_shown_row("")
	if other.is_empty(): return "no other row to edit"
	var result := _tools.call_tool("docket_update", {"id": other[1], "project": other[0], "title": "gone via mcp"})
	return str(result.get("error", ""))


func _external_edit() -> String:
	## Another writer edits beta's canonical file on disk; the shell's poll
	## notices. Every project is settled first so the file holds every row.
	for db in _dbs:
		var flushed := (db as DocketDBJsonl).flush_checked()
		if not flushed.is_empty(): return flushed
	var other := _other_shown_row("beta")
	if other.is_empty(): return "no beta row to edit"
	var path := _state.get_db_for_project("beta").get_path()
	var text := FileAccess.get_file_as_string(path)
	var quoted := JSON.stringify(other[2])
	if not text.contains(quoted): return "title %s not found in %s" % [quoted, path]
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_string(text.replace(quoted, JSON.stringify("%s edited on disk" % other[2])))
	out.close()
	_shell._on_poll_external_changes()
	return ""


func _ephemeral_create() -> String:
	for label in ["one", "two"]:
		var result := _tools.call_tool("docket_create", {"type": "chore", "title": "row ephemeral %s" % label, "project": "alpha", "storage": ItemStorage.EPHEMERAL})
		if result.has("error"): return str(result.error)
		_ephemeral[label] = str(result.id)
	return ""


func _ephemeral_update() -> String:
	var result := _tools.call_tool("docket_update", {"id": _ephemeral.get("one", ""), "project": "alpha", "title": "row ephemeral one updated"})
	return str(result.get("error", ""))


func _ephemeral_keep() -> String:
	var result := _tools.call_tool("docket_promote", {"items": [_ephemeral.get("one", "")], "source_project": "alpha"})
	return str(result.get("error", ""))


func _ephemeral_drop() -> String:
	## What the quit / close dialog's Drop does for one item.
	return ItemStorage.drop(_state.get_db_for_project("alpha"), str(_ephemeral.get("two", "")))


# -- Fixture and observations -------------------------------------------------

func _open_fixture() -> String:
	_state = CountingState.new()
	_state.schema = TypeRegistryBootstrap.load_shipped_schema()
	_state.prefs = UserPrefs.new()
	for project: String in PROJECTS:
		var path := "%s/%s.dct" % [DIR, project]
		var db := DocketDBJsonl.create_new_jsonl(path)
		if db == null: return "fixture %s did not open: %s" % [path, DocketDBJsonl.last_open_error]
		_dbs.append(db)
		var registry := TypeRegistry.for_db(db, project)
		_state._project_dbs[project] = db
		_state._type_registries[project] = registry
		var titles: Array[String] = []
		for i in ROWS_PER_PROJECT: titles.append("%s %s%02d" % [MATCH, project.left(1), i])
		for i in 3: titles.append("other %s%02d" % [project.left(1), i])
		for title in titles:
			var made := registry.create_item({"type": "chore", "title": title}, "tester")
			if made.has("error"): return "fixture item %s: %s" % [title, made.error]
		var flushed := db.flush_checked()
		if not flushed.is_empty(): return "fixture settle: %s" % flushed
	_state.db = _dbs[0]
	_state.dct_path = _dbs[0].get_path()
	_tools = ToolRegistry.new()
	_tools.init(_state.schema, _state.db, _state.get_project_dbs())
	_shell = AppShell.new()
	_shell.init(_state)
	add_child(_shell)
	_shell._poll_timer.stop()
	return ""


func _shown_rows() -> Array:
	## [project, id, title, storage word] of each grid row, top to bottom.
	var grid := _shell._query_grid
	var title_col := grid._col_fields.find("title")
	var storage_col := grid._col_fields.find(StorageBadge.FIELD)
	var rows: Array = []
	var root := grid._tree.get_root()
	if root == null: return rows
	for row in root.get_children():
		var origin: Dictionary = row.get_metadata(0)
		rows.append([str(origin.project), str(origin.id), row.get_text(title_col), row.get_text(storage_col)])
	return rows


func _expected_rows() -> Array:
	## The same rows straight from each project's cache, merged and sorted by
	## title (the fixture's titles are unique).
	var modes := StorageBadge.project_modes(_state.get_project_dbs())
	var rows: Array = []
	for project: String in PROJECTS:
		var db: DocketDB = _state.get_db_for_project(project)
		for item: Dictionary in db.execute_query({"filter": {"conditions": [{"field": "title", "op": "contains", "value": MATCH}]}}):
			rows.append([project, str(item.id), str(item.title), StorageBadge.word(str(modes[project]), str(item.get("storage", "")))])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return str(a[2]) < str(b[2]))
	return rows


func _other_shown_row(project: String) -> Array:
	## The first shown row other than the open record, of `project` if given.
	for row: Array in _shown_rows():
		if row[1] == str(_open_origin.get("id", "")) and row[0] == str(_open_origin.get("project", "")): continue
		if project.is_empty() or row[0] == project: return row
	return []


func _file_stamps() -> Dictionary:
	## Project -> [sha256, mtime] of its canonical .dct.
	var stamps := {}
	for project: String in PROJECTS:
		var path := _state.get_db_for_project(project).get_path()
		stamps[project] = [FileAccess.get_sha256(path), FileAccess.get_modified_time(path)]
	return stamps
