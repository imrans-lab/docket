extends Node
## Returning from an open record to the query results (AppShell Back). The grid
## stays parented and keeps its rows; a change that arrives while the record is
## open makes the next showing query once.
##
## Fixture: the real AppShell over two JSONL projects built in DIR (alpha also
## holds a hint whose title contains MATCH), the grid filtered to titles
## containing MATCH and sorted by title. For each entry of _changes(), its
## `before` step runs while the results are shown, a row is opened from the
## grid, the change runs while the record is open, and Back is pressed. The
## shell's 3 s poll timer is stopped so steps land only where a change puts
## them; the settle and one external change drive the poll themselves, another
## external change leaves it to the grid being shown.
##
## Oracles:
##   queries  calls to AppState.execute_cross_project_query (the grid's results
##            query while more than one project is loaded), counted by a
##            pass-through subclass from before the record opens until after
##            Back: 0 when nothing any results row reads changed, exactly 1
##            after a change.
##   node     the grid never emits tree_exiting and keeps its parent; when
##            nothing changed its Tree keeps the same root TreeItem (no rebuild),
##            the same scroll offset and the same selected row.
##   rows     the rows shown after Back (project, id, title, storage word and,
##            while that column is shown, retrieval count, in order) are not
##            empty and equal each loaded project's DocketDB.execute_query with
##            the same condition, merged and sorted by title here, after the
##            test brings each cache up to its canonical file on disk.
##   files    each project's .dct sha256 and mtime are unchanged by opening the
##            record and by Back.
##   landed   a settle, preference or retrieval step reports whether its write
##            happened: the canonical file changed and no append is left
##            pending, the preference is stored, or the hint's stored
##            retrieval_count went up by one.
## To cover another kind of change, add an entry to _changes().
##
## test_other_paths_back_to_the_results covers the other ways back to the
## results on the same fixture: the split view (unchanged, a save, and a
## canonical edit and a sidecar-only append by other writers while the grid
## stays visible), the Project Types screen, switching Work entries, loading a
## project and closing one. Its oracles are queries, rows and node as above,
## plus which of the views is visible and the retitled rows' literal titles.
##
## test_retrieval_reads_edited_away_without_a_query: a retrieval column hidden,
## or a retrieval condition edited, without a query before a hint read; see its
## own comment. test_external_edit_of_the_open_record_raises_the_conflict: the
## open record's item edited on disk and the split view shown with no poll;
## oracles are the shell's reload conflict dialog, the form keeping its unsaved
## title, and rows as above. test_external_type_change_reaches_the_catalogue_
## in_one_query: a type added to a project's file on disk while a record is
## open, alone and with a project loaded; oracles are queries, rows as above
## and the grid's type catalogue. test_sidecar_append_elsewhere_refreshes_on_
## back: a sidecar-only append by a Docket with its own cache, then an external
## edit with no listener on the grid, each while a record is open; oracles are
## queries, rows as above and the retitled row's literal title.
##
## A refresh reads only the item keys the grid's columns and sort need
## (ItemRows). Fixture: _open_views_fixture() builds alpha and beta with chores
## and a custom "review" type; alpha's review type is evolved with only two
## items repinned, and tags, attachments, statuses, a link, an ephemeral row,
## two alpha ids sharing ten characters and one id present in both projects are
## added. For each entry of _views() the grid's columns, filter and sort are set.
##
## Oracles:
##   values   every row's project, id, cell texts and status colour, in order,
##            equal those derived from the complete records that the
##            full-detail core query (DocketDB.execute_registry_query, detail
##            "full") returns for the view's conditions, ordered by the view's
##            sort key here. Type-field cells and colours come from the grid's
##            renderers fed those complete records outside a refresh.
##   pinned   in the tag filter view, three reviews' status, revision cells and
##            status colour equal literals the fixture sets (_pinned_cells).
##   short    each shown ID is its originating project's DocketDB.short_id (a
##            LIKE count per prefix length, independent of the refresh's bulk
##            computation) and unique among that project's rows; the id both
##            projects contain shows a different prefix in each.
##   reads    SELECT statements issued by one refresh, counted by a
##            pass-through DocketDB subclass over two SQLite projects, are the
##            same with ROWS_SMALL and 4 x ROWS_SMALL rows per project.
##   record   the record opened from a results row shows its complete record:
##            description, tags, every event of its history and its typed field
##            value; the project's copy keeps its link.
## To cover another grid configuration, add an entry to _views().
##
## test_failed_mcp_call_does_not_refresh_the_results: with events and links
## columns shown, a failing tool call while a record is open (oracles: queries
## 0, node and rows as above, an error-log row written, every project's
## results_generation(false) unchanged), then a successful MCP edit (queries 1,
## a results generation moved).
##
## test_related_columns_load_in_bulk queries one SQLite project for "rows"
## items with tags, events and links (columns only a saved query can ask for).
## Oracles: reads (SELECT statements of one query, counted by CountingDB, are
## the same with 5 and 50 matching rows), rows (only the filtered rows, in
## sort order, and a limit holds) and values (each item's tags, events and
## links, empty sets included, equal its complete record from get_item).
##
## test_saved_query_loads_its_columns_in_one_query loads .dcq files with and
## without a sort on the same fixture. Oracles: queries (exactly 1 per load)
## and cells (each shown row's description equals its record's, from a fresh
## core query).
##
## test_startup_runs_one_results_query starts the shell on the fixture with no
## saved last query and with a saved title filter. Oracles: queries (exactly 1
## from creating the state until a frame after the shell is in the tree) and
## grid rows (project, id and every cell, in order) equal to those of a grid
## built the former way: init with its own first query, then set_filter.

const A = preload("res://test/assert_helpers.gd")
const DIR := "user://fixtures/results_return"
const PROJECTS := ["alpha", "beta"]
const MATCH := "row"
const OTHER := "other"  # titles the second Work entry filters on
## Result columns that show the retrieval count, which is last.
const RETRIEVAL_COLUMNS := ["id", "project", "title", StorageBadge.FIELD, "retrieval_count"]
const ROWS_PER_PROJECT := 40  # enough rows for the grid to scroll
const OPEN_ROW := 60  # grid row the record is opened from
const ROWS_SMALL := 10  # rows per project in the reads oracle's smaller set

## Counts results queries; everything else is AppState's own behavior.
class CountingState extends AppState:
	var results_queries := 0
	## Runs once, after the next results query has read its rows.
	var after_next_query: Callable

	func execute_cross_project_query(query: Dictionary, detail: String = "full", keys: PackedStringArray = PackedStringArray()) -> Array:
		results_queries += 1
		var rows := super.execute_cross_project_query(query, detail, keys)
		if after_next_query.is_valid():
			var hook := after_next_query
			after_next_query = Callable()
			hook.call()
		return rows

## Counts SELECT statements; everything else is DocketDB's own behavior.
class CountingDB extends DocketDB:
	var selects := 0

	func _exec_select(sql: String, bindings: Array = []) -> Array:
		selects += 1
		return super._exec_select(sql, bindings)

var _dbs: Array[DocketDB] = []
var _state: CountingState
var _shell: AppShell
var _tools: ToolRegistry
var _open_origin: Dictionary = {}
var _ephemeral: Dictionary = {}  # label -> id of an ephemeral item made by a change
var _fixture_ids: Dictionary = {}  # label -> id of a views-fixture item
var _hint_id := ""
# [project, id, title] of the row a writer elsewhere last retitled.
var _written_elsewhere: Array = []
# The shell saves the session and recent files to the real prefs file when
# projects load or close; its text before the tests, or null when absent.
var _prefs_before: Variant = null
const PREFS_PATH := "user://docket_prefs.json"


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	if FileAccess.file_exists(PREFS_PATH): _prefs_before = FileAccess.get_file_as_string(PREFS_PATH)

func before_each() -> void:
	_reset_fixtures()

func teardown() -> void:
	_reset_fixtures()
	if _prefs_before is String:
		var f := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
		if f: f.store_string(str(_prefs_before))
	elif FileAccess.file_exists(PREFS_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS_PATH))

func _reset_fixtures() -> void:
	for child in get_children():
		remove_child(child)
		child.free()
	for db in _dbs:
		if db != null and db.is_open():
			db.close()
	_dbs.clear()
	_ephemeral.clear()
	_fixture_ids.clear()
	_hint_id = ""
	_written_elsewhere = []
	_open_origin = {}
	for filename in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [DIR, filename]))


func test_back_shows_retained_results_and_requeries_once_after_a_change() -> Variant:
	var fixture_error := _open_fixture()
	if not fixture_error.is_empty():
		return fixture_error
	var grid := _shell._query_grid
	grid.set_filter(_title_filter(MATCH))
	grid._toggle_sort(grid._col_fields.find("title"))
	await get_tree().process_frame
	var r = _rows_match(MATCH, "fixture: the grid shows the filtered, sorted rows")
	if r is String:
		return r
	for change: Dictionary in _changes():
		r = await _open_change_and_return(change)
		if r is String:
			return "%s: %s" % [change.kind, r]
	return true


func test_other_paths_back_to_the_results() -> Variant:
	var fixture_error := _open_fixture()
	if not fixture_error.is_empty():
		return fixture_error
	var gamma_path := "%s/gamma.dct" % DIR
	var gamma_error := _write_project_file(gamma_path)
	if not gamma_error.is_empty(): return gamma_error
	var grid := _shell._query_grid
	var form := _shell._record_form
	grid.set_filter(_title_filter(MATCH))
	grid._toggle_sort(grid._col_fields.find("title"))
	await get_tree().process_frame
	var results_entry := _shell._grid_entry_idx
	var other_entry := _shell._add_work_entry("query", "Other", _title_filter(OTHER), "")
	var r = _rows_match(MATCH, "fixture: the grid shows the filtered, sorted rows")
	if r is String: return r

	# Split view with nothing changed: the grid stays shown beside the record.
	var held: Dictionary = await _select_row("")
	_state.results_queries = 0
	_shell._on_menu_action("view_split")
	grid._on_item_selected()
	await get_tree().process_frame
	var beside := grid.is_visible_in_tree() and form.is_visible_in_tree() and form._current_id == str(held.get("origin", {}).get("id", ""))
	_shell._on_menu_action("view_query")
	await get_tree().process_frame
	r = A.is_true(beside, "split view shows the results beside the selected record")
	if r is String: return r
	r = _after_path("split view, unchanged", 0, MATCH, held)
	if r is String: return r

	# Split view with the record saved: the shown grid re-queries once.
	await _select_row("")
	_state.results_queries = 0
	_shell._on_menu_action("view_split")
	grid._on_item_selected()
	form._title_edit.text = "row zz split edit"
	var saved: Variant = await form._save_changes()
	_shell._on_menu_action("view_query")
	await get_tree().process_frame
	if saved is String and not str(saved).is_empty(): return "split view save failed: %s" % saved
	r = _after_path("split view, record saved", 1, MATCH, {})
	if r is String: return r

	# Split view while another writer retitles a shown beta row, in the
	# canonical file and then in the sidecar only; Back with no poll driven.
	for writer: Dictionary in [{"kind": "canonical edit", "apply": _external_edit_unpolled}, {"kind": "sidecar append elsewhere", "apply": _append_sidecar_elsewhere}]:
		held = await _select_row("")
		_open_origin = held.get("origin", {})
		_state.results_queries = 0
		_shell._on_menu_action("view_split")
		grid._on_item_selected()
		var written: String = (writer.apply as Callable).call()
		if not written.is_empty(): return "split view, %s: %s" % [writer.kind, written]
		form._back_btn.pressed.emit()
		await get_tree().process_frame
		r = _after_path("split view, %s" % writer.kind, 1, MATCH, {})
		if r is String: return r
		r = _written_elsewhere_shown("split view, %s" % writer.kind)
		if r is String: return r
	_open_origin = {}

	# Project Types and back through the Work menu, with nothing changed.
	held = await _select_row("")
	_state.results_queries = 0
	_shell._on_menu_action("project_types")
	var types_shown := _shell._project_types.is_visible_in_tree() and not grid.is_visible_in_tree()
	_shell._activate_work_entry(results_entry)
	await get_tree().process_frame
	r = A.is_true(types_shown, "Project Types replaces the results")
	if r is String: return r
	r = _after_path("Project Types, unchanged", 0, MATCH, held)
	if r is String: return r

	# Project Types with a type defined while it is shown.
	_state.results_queries = 0
	_shell._on_menu_action("project_types")
	var defined: Dictionary = _state.get_type_registry("alpha").define_type("review", _review_definition(), "tester", "fixture")
	if defined.has("error"): return "type definition failed: %s" % defined.error
	_shell._activate_work_entry(results_entry)
	await get_tree().process_frame
	r = _after_path("Project Types, type defined", 1, MATCH, {})
	if r is String: return r

	# Switching Work entries applies each entry's filter once; choosing the
	# entry already shown keeps its rows.
	_state.results_queries = 0
	_shell._activate_work_entry(other_entry)
	await get_tree().process_frame
	r = _after_path("switch to another entry", 1, OTHER, {})
	if r is String: return r
	_state.results_queries = 0
	_shell._activate_work_entry(results_entry)
	await get_tree().process_frame
	r = _after_path("switch back", 1, MATCH, {})
	if r is String: return r
	held = await _select_row("")
	_state.results_queries = 0
	_shell._activate_work_entry(results_entry)
	await get_tree().process_frame
	r = _after_path("the entry already shown", 0, MATCH, held)
	if r is String: return r

	# A project loaded while a record is open, then Back.
	await _select_row("alpha")
	_state.results_queries = 0
	grid._on_item_activated()
	_shell._on_add_project_selected(gamma_path)
	var gamma: DocketDB = _state.get_db_for_project("gamma")
	if gamma == null: return "gamma did not load"
	_dbs.append(gamma)
	form._back_btn.pressed.emit()
	await get_tree().process_frame
	r = _after_path("project loaded", 1, MATCH, {})
	if r is String: return r
	r = A.is_true(_shown_rows().any(func(row: Array) -> bool: return row[0] == "gamma"), "the loaded project's rows are shown")
	if r is String: return r

	# A project closed while a record is open, then another Work entry: one
	# query, over the projects still loaded.
	await _select_row("alpha")
	_state.results_queries = 0
	grid._on_item_activated()
	_shell._on_menu_action("close_project:beta")
	if _state.get_project_dbs().has("beta"): return "beta did not close"
	_shell._activate_work_entry(other_entry)
	await get_tree().process_frame
	return _after_path("project closed, another entry", 1, OTHER, {})


func _select_row(project: String) -> Dictionary:
	## Selects and scrolls to row OPEN_ROW, or with project to that project's
	## last row. Returns what an unchanged grid keeps: its root TreeItem, scroll
	## and selected origin; {} when there is no such row.
	var grid := _shell._query_grid
	var root := grid._tree.get_root()
	if root == null or root.get_child_count() == 0: return {}
	var target: TreeItem = root.get_child(mini(OPEN_ROW, root.get_child_count() - 1)) if project.is_empty() else null
	if not project.is_empty():
		for row in root.get_children():
			if str((row.get_metadata(0) as Dictionary).project) == project: target = row
	if target == null: return {}
	target.select(0)
	grid._tree.scroll_to_item(target)
	await get_tree().process_frame
	return {"root": root, "scroll": grid._tree.get_scroll(), "origin": grid.get_selected_origin()}


func _after_path(label: String, queries: int, title_part: String, held: Dictionary) -> Variant:
	## The results are shown alone after `label`, `queries` results queries ran,
	## and the rows equal a fresh query; with held (_select_row), the grid kept
	## its root, scroll and selection.
	var grid := _shell._query_grid
	var r = A.is_true(grid.is_visible_in_tree() and not _shell._record_form.is_visible_in_tree() and not _shell._project_types.is_visible_in_tree(), "%s: the results are shown alone" % label)
	if r is String: return r
	r = A.eq(_state.results_queries, queries, "%s: results queries" % label)
	if r is String: return r
	r = _rows_match(title_part, "%s: rows shown equal a fresh query" % label)
	if r is String: return r
	if held.is_empty(): return true
	r = A.is_true((held.scroll as Vector2).y > 0.0, "%s: fixture: the grid scrolled, so scroll retention can be observed" % label)
	if r is String: return r
	r = A.is_true(grid._tree.get_root() == held.root, "%s: unchanged results are not rebuilt" % label)
	if r is String: return r
	r = A.eq(grid._tree.get_scroll(), held.scroll, "%s: scroll position is retained" % label)
	if r is String: return r
	return A.eq(grid.get_selected_origin(), held.origin, "%s: selection is retained" % label)


func _write_project_file(path: String) -> String:
	## A closed JSONL project file with a few MATCH and OTHER rows.
	var db := DocketDBJsonl.create_new_jsonl(path)
	if db == null: return "fixture %s did not open: %s" % [path, DocketDBJsonl.last_open_error]
	var registry := TypeRegistry.for_db(db, db.get_project_name())
	for title: String in ["%s g00" % MATCH, "%s g01" % MATCH, "%s g02" % OTHER]:
		var made := registry.create_item({"type": "chore", "title": title}, "tester")
		if made.has("error"):
			db.close()
			return "fixture item %s: %s" % [title, made.error]
	var flushed := db.flush_checked()
	db.close()
	return "" if flushed.is_empty() else "fixture settle: %s" % flushed


## Two steps, each with a record open and Back pressed with no poll driven. A
## writer that does not share the project's cache adds a "review" type to its
## canonical file: first beta's alone, then alpha's while a third project is
## loaded, so the type catalogue is stale for that reason too. Oracles: queries
## (exactly 1 from opening the record through Back in each step), rows as
## above, and the grid's type catalogue holding that project's "review" type
## after Back.
func test_external_type_change_reaches_the_catalogue_in_one_query() -> Variant:
	var fixture_error := _open_fixture()
	if not fixture_error.is_empty():
		return fixture_error
	var gamma_path := "%s/gamma.dct" % DIR
	var gamma_error := _write_project_file(gamma_path)
	if not gamma_error.is_empty(): return gamma_error
	var grid := _shell._query_grid
	grid.set_filter(_title_filter(MATCH))
	grid._toggle_sort(grid._col_fields.find("title"))
	await get_tree().process_frame
	var edit_beta := func() -> String: return _define_type_elsewhere("beta")
	var load_and_edit_alpha := func() -> String:
		_shell._on_add_project_selected(gamma_path)
		var gamma: DocketDB = _state.get_db_for_project("gamma")
		if gamma == null: return "gamma did not load"
		_dbs.append(gamma)
		return _define_type_elsewhere("alpha")
	for step: Array in [["beta", "external type change", edit_beta], ["alpha", "external type change, project loaded", load_and_edit_alpha]]:
		var r = await _open_change_and_return({"kind": step[1], "queries": 1, "apply": step[2]})
		if r is String: return "%s: %s" % [step[1], r]
		var review := grid._type_catalog.filter(func(record: Dictionary) -> bool: return str(record.get("slug", "")) == "review" and str(record.get("project", "")) == step[0])
		r = A.eq(review.size(), 1, "%s: the grid's type catalogue holds %s's review type" % [step[1], step[0]])
		if r is String: return r
	return true


## A Docket with its own cache retitles a beta row, and only its sidecar record
## reaches beta's sidecar file (the canonical file and this process's cache are
## untouched) while a record is open; Back is pressed with no poll driven.
## Then every listener is disconnected from the grid's disk_change_found, beta's
## canonical file is edited on disk while a record is open, and Back is pressed
## with no poll driven, so the grid reloads by itself.
## Oracles: queries (exactly 1 from opening the record through Back each time),
## rows as above, which the test compares after bringing beta's cache up to its
## files, and the retitled row shown with the title the test wrote.
func test_sidecar_append_elsewhere_refreshes_on_back() -> Variant:
	var fixture_error := _open_fixture()
	if not fixture_error.is_empty():
		return fixture_error
	var grid := _shell._query_grid
	grid.set_filter(_title_filter(MATCH))
	grid._toggle_sort(grid._col_fields.find("title"))
	await get_tree().process_frame
	var r = await _open_change_and_return({"kind": "sidecar append elsewhere", "queries": 1, "apply": _append_sidecar_elsewhere})
	if r is String: return r
	r = _written_elsewhere_shown("sidecar append elsewhere")
	if r is String: return r
	for connection: Dictionary in grid.disk_change_found.get_connections():
		grid.disk_change_found.disconnect(connection.callable)
	r = await _open_change_and_return({"kind": "external edit, no listener", "queries": 1, "apply": _external_edit_unpolled})
	if r is String: return r
	return _written_elsewhere_shown("external edit, no listener")


func _written_elsewhere_shown(label: String) -> Variant:
	var shown := _shown_rows().any(func(row: Array) -> bool: return row.slice(0, 3) == _written_elsewhere)
	return A.is_true(not _written_elsewhere.is_empty() and shown, "%s: the row retitled elsewhere is shown as %s" % [label, _written_elsewhere])


func _append_sidecar_elsewhere() -> String:
	## beta is settled, its canonical file copied, a row retitled in the copy,
	## and the copy's sidecar bytes written as beta's sidecar.
	var beta := _state.get_db_for_project("beta") as DocketDBJsonl
	var flushed := beta.flush_checked()
	if not flushed.is_empty(): return "settle before the append: %s" % flushed
	var other := _other_shown_row("beta")
	if other.is_empty(): return "no beta row to retitle"
	var copy_path := "%s/beta_elsewhere.dct" % DIR
	if DirAccess.copy_absolute(ProjectSettings.globalize_path(beta.get_path()), ProjectSettings.globalize_path(copy_path)) != OK: return "copy of beta failed"
	var copy := DocketDBJsonl.open_jsonl(copy_path)
	if copy == null: return "copy did not open: %s" % DocketDBJsonl.last_open_error
	var error := copy.update_item_fields_checked(str(other[1]), {"title": "%s zz appended elsewhere" % MATCH})
	var appended := FileAccess.get_file_as_bytes(JSONLSidecar.path_for(copy_path))
	copy.close()
	if not error.is_empty(): return "retitle in the copy failed: %s" % error
	if appended.is_empty(): return "the copy's sidecar is empty"
	var out := FileAccess.open(JSONLSidecar.path_for(beta.get_path()), FileAccess.WRITE)
	out.store_buffer(appended)
	out.close()
	_written_elsewhere = ["beta", other[1], "%s zz appended elsewhere" % MATCH]
	return "" if beta.is_stale() else "fixture: beta's cache does not read as changed on disk"


func _define_type_elsewhere(project: String) -> String:
	## Writes to project's canonical file the text a Docket with its own cache
	## produces after defining a "review" type: the settled file is copied, the
	## type is defined in the copy, and the copy's text replaces the file.
	var db := _state.get_db_for_project(project) as DocketDBJsonl
	var flushed := db.flush_checked()
	if not flushed.is_empty(): return "settle before the external edit: %s" % flushed
	var path := db.get_path()
	var copy_path := "%s/%s_elsewhere.dct" % [DIR, project]
	if DirAccess.copy_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(copy_path)) != OK: return "copy of %s failed" % path
	var copy := DocketDBJsonl.open_jsonl(copy_path)
	if copy == null: return "copy did not open: %s" % DocketDBJsonl.last_open_error
	var made := TypeRegistry.for_db(copy, project).define_type("review", _review_definition(), "tester", "elsewhere")
	copy.close()
	if made.has("error"): return "type definition in the copy failed: %s" % made.error
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_string(FileAccess.get_file_as_string(copy_path))
	out.close()
	return "" if db.is_stale() else "fixture: %s's cache does not read as changed on disk" % project


## The record opened from a beta row is given an unsaved title; another writer
## edits that item's title in beta's canonical file; the split view is shown
## with no poll driven. Oracles: the shell's reload conflict dialog is shown
## naming a change on disk, the form still holds the unsaved title, and the
## grid's rows equal a fresh core query.
func test_external_edit_of_the_open_record_raises_the_conflict() -> Variant:
	var fixture_error := _open_fixture()
	if not fixture_error.is_empty():
		return fixture_error
	var grid := _shell._query_grid
	var form := _shell._record_form
	grid.set_filter(_title_filter(MATCH))
	grid._toggle_sort(grid._col_fields.find("title"))
	await get_tree().process_frame
	for db in _dbs:
		var flushed := (db as DocketDBJsonl).flush_checked()
		if not flushed.is_empty(): return "fixture settle: %s" % flushed
	var held: Dictionary = await _select_row("beta")
	if held.is_empty(): return "no beta row to open"
	grid._on_item_activated()
	var opened_title := form._title_edit.text
	form._title_edit.text = "row unsaved local title"
	var path := _state.get_db_for_project("beta").get_path()
	var text := FileAccess.get_file_as_string(path)
	var quoted := JSON.stringify(opened_title)
	if opened_title.is_empty() or not text.contains(quoted): return "fixture: title %s not found in %s" % [quoted, path]
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_string(text.replace(quoted, JSON.stringify("%s edited on disk" % opened_title)))
	out.close()
	_shell._on_menu_action("view_split")
	await get_tree().process_frame
	var dialog := _shell._confirm_reload_dialog
	var r = A.is_true(dialog.visible and dialog.dialog_text.contains("changed on disk"), "the reload conflict dialog is shown: %s" % dialog.dialog_text)
	dialog.hide()
	if r is String: return r
	r = A.eq(form._title_edit.text, "row unsaved local title", "the form keeps its unsaved title")
	if r is String: return r
	return _rows_match(MATCH, "rows shown beside the record equal a fresh query")


## Retrieval counts read by a query and then left unread by an edit that runs
## no query. Each path starts from a fresh fixture, so no retrieval change
## precedes its query. In both, a record is opened, an MCP hint read bumps the
## hint's count, and Back is pressed.
##   column     the retrieval count column is shown (its values are queried)
##              and hidden again; after Back it is shown again.
##   condition  the rows are queried with titles containing MATCH and
##              retrieval_count < 1, which the hint meets until its read; that
##              condition row is then edited to titles containing "hint".
## Oracles: queries (exactly 1 from opening the record through Back: the read
## changes what the rows' own query returns, so they cannot stand) and rows
## (column: every row's count, shown again, equals a fresh core query's;
## condition: the rows equal a fresh core query for the conditions the grid
## now holds, the only ones a query from the grid can run).
func test_retrieval_reads_edited_away_without_a_query() -> Variant:
	for path: String in ["column", "condition"]:
		_reset_fixtures()
		var fixture_error := _open_fixture()
		if not fixture_error.is_empty():
			return fixture_error
		var grid := _shell._query_grid
		grid.set_filter(_title_filter(MATCH))
		grid._toggle_sort(grid._col_fields.find("title"))
		await get_tree().process_frame
		var r: Variant = await _hidden_column_path() if path == "column" else await _edited_condition_path()
		if r is String: return "%s: %s" % [path, r]
	return true


func _hidden_column_path() -> Variant:
	var grid := _shell._query_grid
	var show_then_hide := func() -> String:
		grid.set_result_columns(RETRIEVAL_COLUMNS)
		grid.set_result_columns(RETRIEVAL_COLUMNS.slice(0, -1))
		return ""
	var r = await _open_change_and_return({"kind": "hidden retrieval column", "queries": 1, "before": show_then_hide, "apply": _hint_retrieval})
	if r is String: return r
	grid.set_result_columns(RETRIEVAL_COLUMNS)
	await get_tree().process_frame
	return _rows_match(MATCH, "the retrieval column shown again equals a fresh query")


func _edited_condition_path() -> Variant:
	var grid := _shell._query_grid
	# The value is the text a condition row holds; set_filter reads it as typed.
	var queried: Array = _title_is(MATCH) + [{"field": "retrieval_count", "op": "lt", "value": "1", "conj": "and"}]
	var edited := {"field": "title", "op": "contains", "value": "hint", "conj": "and"}
	var query_then_edit := func() -> String:
		grid.set_filter(JSON.stringify({"conditions": queried}))
		if not _shown_rows().any(func(row: Array) -> bool: return row[1] == _hint_id):
			return "the rows queried with retrieval_count < 1 do not include the hint"
		grid._apply_condition(1, edited)
		return ""
	return await _open_change_and_return({"kind": "edited retrieval condition", "queries": 1, "before": query_then_edit, "apply": _hint_retrieval, "expected": _title_is(MATCH) + [edited]})


func test_refresh_rows_match_complete_records() -> Variant:
	var fixture_error := _open_views_fixture()
	if not fixture_error.is_empty():
		return fixture_error
	var grid := _shell._query_grid
	for view: Dictionary in _views():
		_show_view(view)
		await get_tree().process_frame
		var shown := _view_rows_shown()
		var r = A.is_true(not shown.is_empty(), "%s: the grid shows rows" % view.name)
		if r is String: return r
		r = A.eq(shown, _view_rows_expected(view), "%s: rows shown equal the complete records" % view.name)
		if r is String: return r
		r = _short_ids_distinct(shown, 2 + grid._col_fields.find("id"))
		if r is String: return "%s: %s" % [view.name, r]
	var pinned: Variant = await _pinned_cells()
	if pinned is String: return pinned
	_show_view(_views()[0])
	var shared: String = _fixture_ids["shared"]
	var shown_shared: Dictionary = {}
	for cells: Array in _view_rows_shown():
		if cells[1] == shared: shown_shared[cells[0]] = cells[2 + grid._col_fields.find("id")]
	var r = A.is_true(shown_shared.size() == 2 and shown_shared.alpha != shown_shared.beta, "the id in both projects shows each project's own prefix: %s" % shown_shared)
	if r is String: return r
	return _open_complete_record()


## Saved queries (.dcq) loaded without and with a sort: a title filter and a
## column the default layout lacks (description). Oracles: queries (exactly 1
## per load) and cells (the shown rows, keyed by project and id, with their
## description cells equal each project's records for the filter from a fresh
## core query, with the records' own descriptions).
func test_saved_query_loads_its_columns_in_one_query() -> Variant:
	var fixture_error := _open_views_fixture()
	if not fixture_error.is_empty():
		return fixture_error
	var grid := _shell._query_grid
	for sort: Array in [[], [{"field": "title", "dir": "asc"}]]:
		var saved := {"ui_filter": {"conditions": _title_is(MATCH)}, "columns": ["id", "project", "title", "description"]}
		if not sort.is_empty(): saved["sort"] = sort
		var path := "%s/saved_%d.dcq" % [DIR, sort.size()]
		var out := FileAccess.open(path, FileAccess.WRITE)
		out.store_string(JSON.stringify(saved))
		out.close()
		_state.results_queries = 0
		grid.load_dcq(path)
		await get_tree().process_frame
		var label := "sorted" if not sort.is_empty() else "unsorted"
		var r = A.eq(_state.results_queries, 1, "%s: results queries from loading the saved query" % label)
		if r is String: return r
		var description_col := grid._col_fields.find("description")
		var shown := {}
		var root := grid._tree.get_root()
		if root != null and description_col >= 0:
			for row in root.get_children():
				var origin: Dictionary = row.get_metadata(0)
				shown["%s:%s" % [origin.project, origin.id]] = row.get_text(description_col)
		var expected := {}
		for project: String in _state.get_project_dbs():
			for item: Dictionary in _state.get_db_for_project(project).execute_query({"filter": {"conditions": _title_is(MATCH)}}):
				expected["%s:%s" % [project, item.id]] = str(item.get("description", ""))
		r = A.is_true(not shown.is_empty() and expected.values().any(func(text: String) -> bool: return not text.is_empty()), "%s: fixture: rows are shown and some have a description" % label)
		if r is String: return r
		r = A.eq(shown, expected, "%s: description cells equal the records" % label)
		if r is String: return r
	return true


func test_startup_runs_one_results_query() -> Variant:
	for filter: String in ["", _title_filter(MATCH)]:
		_reset_fixtures()
		# An empty filter and label read back as no saved query (All Items).
		UserPrefs.save_last_query(filter, "" if filter.is_empty() else "Startup")
		var label := "filtered" if not filter.is_empty() else "all items"
		var fixture_error := _open_fixture()
		if not fixture_error.is_empty(): return fixture_error
		await get_tree().process_frame
		var r = A.eq(_state.results_queries, 1, "%s: results queries at startup" % label)
		if r is String: return r
		var reference := QueryGrid.new()
		add_child(reference)
		reference.init(_state)
		reference.set_filter(filter)
		var shown := _grid_cells(_shell._query_grid)
		r = A.is_true(not shown.is_empty(), "%s: the grid shows rows" % label)
		if r is String: return r
		r = A.eq(shown, _grid_cells(reference), "%s: startup rows equal init then set_filter" % label)
		if r is String: return r
	return true


func _grid_cells(grid: QueryGrid) -> Array:
	## [project, id, every column's text] of each row, top to bottom.
	var rows: Array = []
	var root := grid._tree.get_root()
	if root == null: return rows
	for row in root.get_children():
		var origin: Dictionary = row.get_metadata(0)
		var cells: Array = [str(origin.project), str(origin.id)]
		for col in grid._tree.columns: cells.append(row.get_text(col))
		rows.append(cells)
	return rows


func test_refresh_reads_do_not_grow_with_rows() -> Variant:
	_new_state()
	for project: String in PROJECTS:
		var path := "%s/%s_reads.dct" % [DIR, project]
		var created := DocketDB.create_new(path)
		if created == null: return "fixture %s was not created" % path
		created.close()
		var db := CountingDB.new()
		if not db.open(path): return "fixture %s did not open" % path
		_add_project(project, db)
		var inserted := _insert_reads_rows(db, project, 0, ROWS_SMALL)
		if not inserted.is_empty(): return inserted
	_state.db = _dbs[0]
	var grid := QueryGrid.new()
	add_child(grid)
	grid.init(_state)
	grid.set_result_columns(["id", "project", "title", "status", "tags"])
	grid._toggle_sort(grid._col_fields.find("title"))
	var small: int = await _refresh_selects(grid)
	var small_rows := grid._tree.get_root().get_child_count()
	for i in PROJECTS.size():
		var inserted := _insert_reads_rows(_dbs[i], PROJECTS[i], ROWS_SMALL, 4 * ROWS_SMALL)
		if not inserted.is_empty(): return inserted
	var large: int = await _refresh_selects(grid)
	var large_rows := grid._tree.get_root().get_child_count()
	var r = A.eq([small_rows, large_rows], [2 * ROWS_SMALL, 8 * ROWS_SMALL], "fixture: rows shown before and after adding rows")
	if r is String: return r
	return A.eq(large, small, "SELECT statements of one refresh with %d rows versus %d rows" % [large_rows, small_rows])


func test_related_columns_load_in_bulk() -> Variant:
	_new_state()
	var path := "%s/related_reads.dct" % DIR
	var created := DocketDB.create_new(path)
	if created == null: return "fixture %s was not created" % path
	created.close()
	var db := CountingDB.new()
	if not db.open(path): return "fixture %s did not open" % path
	var registry := _add_project("alpha", db)
	# A row outside the filter, with events and a link, must not be returned.
	var outside := db.insert_item(DocketDB.generate_uuid7(), {"type": "chore", "status": "open", "title": "outside", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z", "events": [{"event_type": "note", "actor": "x", "timestamp": "2026-01-01T00:00:00Z", "note": "outside"}], "links": [{"to": "other:outside", "relation": "relates"}]})
	if not outside.is_empty(): return "fixture row: %s" % outside
	var keys := PackedStringArray(["title", "tags", "events", "links"])
	var sort := [{"field": "title", "dir": "asc"}]
	# Warm-up: the first query on a connection also reads the items columns
	# once (DocketDB._item_columns), which no later query repeats.
	db.execute_query({"filter": {"conditions": _title_is(MATCH)}}, "rows", keys)
	var counts: Array[int] = []
	var present := 0
	for size: int in [5, 50]:
		var inserted := _insert_related_rows(db, present, size)
		if not inserted.is_empty(): return inserted
		present = size
		for variant: String in ["query", "registry query", "limited query"]:
			var label := "%s, %d rows" % [variant, size]
			var query := {"filter": {"conditions": _title_is(MATCH)}, "sort": sort}
			if variant == "limited query": query["limit"] = 3
			db.selects = 0
			var rows: Array = db.execute_registry_query(query, registry, "rows", keys) if variant == "registry query" else db.execute_query(query, "rows", keys)
			if variant == "query": counts.append(db.selects)
			var titles: Array = rows.map(func(item: Dictionary) -> String: return str(item.title))
			var expected_titles: Array = []
			for i in (3 if variant == "limited query" else size): expected_titles.append("%s r%03d" % [MATCH, i])
			var r = A.eq(titles, expected_titles, "%s: rows returned" % label)
			if r is String: return r
			for item: Dictionary in rows:
				var complete := db.get_item(str(item.id))
				r = A.eq([item.tags, item.events, item.links], [complete.tags, complete.events, complete.links], "%s: related values of %s" % [label, item.title])
				if r is String: return r
	# Allowance 0: after the warm-up every statement is per query or per related table, none per row.
	return A.is_true(counts[1] <= counts[0], "SELECT statements of one query with 50 rows (%d) at most those with 5 rows (%d)" % [counts[1], counts[0]])


func _insert_related_rows(db: DocketDB, from: int, to: int) -> String:
	## Chores titled MATCH rNNN. Every third has no events, the rest two
	## same-second events after an earlier one (their order is the rowid
	## tiebreak); every other has tags; all but the first have two links, the
	## first to the row before.
	var previous := ""
	for i in range(from, to):
		var id := DocketDB.generate_uuid7()
		var events: Array = [] if i % 3 == 0 else [
			{"event_type": "note", "actor": "b", "timestamp": "2026-01-02T00:00:00Z", "note": "second %d" % i},
			{"event_type": "note", "actor": "a", "timestamp": "2026-01-01T00:00:00Z", "note": "first %d" % i},
			{"event_type": "note", "actor": "c", "timestamp": "2026-01-02T00:00:00Z", "note": "third %d" % i},
		]
		var links: Array = [] if previous.is_empty() else [{"to": previous, "relation": "relates"}, {"to": "other:%d" % i, "relation": "blocks"}]
		var error := db.insert_item(id, {"type": "chore", "status": "open", "title": "%s r%03d" % [MATCH, i], "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z", "tags": ["red", "blue"] if i % 2 == 0 else [], "events": events, "links": links})
		if not error.is_empty(): return "fixture row: %s" % error
		previous = id
	return ""


## A failed MCP call writes the error log but leaves every project's results
## generation alone, so Back shows the retained rows with no query; a
## successful MCP write after it moves a generation and re-queries once. The
## grid shows events and links columns, loaded with the rows.
func test_failed_mcp_call_does_not_refresh_the_results() -> Variant:
	var fixture_error := _open_fixture()
	if not fixture_error.is_empty(): return fixture_error
	var grid := _shell._query_grid
	# The rows oracle reads the storage column.
	grid.set_result_columns(["id", "project", "title", StorageBadge.FIELD, "events", "links"])
	grid.set_filter(_title_filter(MATCH))
	grid._toggle_sort(grid._col_fields.find("title"))
	await get_tree().process_frame
	var r = A.is_true(grid._col_fields.has("events") and grid._col_fields.has("links"), "fixture: the grid shows events and links columns")
	if r is String: return r
	r = _rows_match(MATCH, "fixture: the grid shows the filtered, sorted rows")
	if r is String: return r
	var successful_write := func() -> String:
		var before := _results_generations()
		var error := _mcp_edit()
		if error.is_empty() and _results_generations() == before: return "a successful MCP write left every results generation unchanged"
		return error
	for change: Dictionary in [
		{"kind": "failed MCP call", "queries": 0, "apply": _failed_mcp_call},
		{"kind": "MCP edit", "queries": 1, "apply": successful_write},
	]:
		r = await _open_change_and_return(change)
		if r is String: return "%s: %s" % [change.kind, r]
	return true


func _failed_mcp_call() -> String:
	## An update of an id no project holds fails; the primary's error log gains
	## its row and no project's results generation moves.
	var before := _results_generations()
	var logged := _logged_errors("docket_update")
	var result := _tools.call_tool("docket_update", {"id": DocketDB.generate_uuid7(), "project": PROJECTS[0], "title": "never"})
	if not result.has("error"): return "the call did not fail: %s" % result
	if _logged_errors("docket_update") != logged + 1: return "the error log did not gain the failed call"
	if _results_generations() != before: return "a failed call moved a results generation: %s -> %s" % [before, _results_generations()]
	return ""


func _results_generations() -> Array:
	return _dbs.map(func(db: DocketDB) -> Array: return db.results_generation(false))


func _logged_errors(tool_name: String) -> int:
	## The primary's error-log rows for tool_name, over every message.
	var total := 0
	for row: Dictionary in _state.db.get_error_report():
		if row.tool_name == tool_name: total += int(row.count)
	return total


## Each change runs while a record is open; its optional `before` runs first,
## while the results are shown, and its optional `expected` holds the
## conditions the rows after Back must match (titles containing MATCH if absent). `queries` is the number of results queries
## expected from opening the record through Back. Entries run in order and
## build on each other: the settle lands the local edit's append.
func _changes() -> Array[Dictionary]:
	var nothing := func() -> String: return ""
	return [
		{"kind": "unchanged", "queries": 0, "apply": nothing},
		{"kind": "local edit", "queries": 1, "apply": _local_edit},
		{"kind": "settle after a save", "queries": 0, "before": _land_settle, "apply": nothing},
		{"kind": "zoom preference", "queries": 0, "apply": _zoom_preference},
		{"kind": "hint retrieval", "queries": 0, "apply": _hint_retrieval},
		{"kind": "MCP edit", "queries": 1, "apply": _mcp_edit},
		{"kind": "external edit", "queries": 1, "apply": _external_edit},
		{"kind": "external edit, no poll", "queries": 1, "apply": _external_edit_unpolled},
		{"kind": "commit during the query", "queries": 1, "before": _commit_during_query, "apply": nothing},
		{"kind": "ephemeral create", "queries": 1, "apply": _ephemeral_create},
		{"kind": "ephemeral update", "queries": 1, "apply": _ephemeral_update},
		{"kind": "ephemeral keep", "queries": 1, "apply": _ephemeral_keep},
		{"kind": "ephemeral drop", "queries": 1, "apply": _ephemeral_drop},
		{"kind": "hint retrieval shown", "queries": 1, "before": _show_retrieval_column, "apply": _hint_retrieval},
	]


func _open_change_and_return(change: Dictionary) -> Variant:
	var grid := _shell._query_grid
	if change.has("before"):
		var before_error: Variant = await (change.before as Callable).call()
		if before_error is String and not str(before_error).is_empty():
			return "the step before the record opened failed: %s" % before_error
		await get_tree().process_frame
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
	r = _rows_match_conditions(change.get("expected", _title_is(MATCH)), "rows shown after Back equal a fresh query")
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
	## notices.
	var error := _external_edit_unpolled()
	if error.is_empty(): _shell._on_poll_external_changes()
	return error


func _external_edit_unpolled() -> String:
	## Another writer edits beta's canonical file on disk and no poll runs
	## before Back. Every project is settled first so the file holds every row.
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
	_written_elsewhere = ["beta", other[1], "%s edited on disk" % other[2]]
	return ""


func _commit_during_query() -> String:
	## The shown grid refreshes, and right after its query has read the rows
	## another connection to beta's cache commits a new title for a beta row, as
	## another process sharing the cache would.
	var other_row := _other_shown_row("beta")
	if other_row.is_empty(): return "no beta row to retitle"
	var errors: Array[String] = []
	_state.after_next_query = func() -> void:
		var other := DocketDB.new()
		if not other.open(JSONLCache.cache_path_for(_state.get_db_for_project("beta").get_path()), false):
			errors.append("the second connection did not open")
			return
		errors.append(other.update_item_fields_checked(str(other_row[1]), {"title": "%s zz another process" % MATCH}))
		other.close()
	_shell._query_grid.refresh()
	if errors.is_empty(): return "the grid ran no results query"
	return errors[0]


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
	var result := _tools.call_tool("docket_promote", {"items": [_ephemeral.get("one", "")], "source_project": "alpha", "promoted_by": "tester"})
	return str(result.get("error", ""))


func _ephemeral_drop() -> String:
	## What the quit / close dialog's Drop does for one item.
	return ItemStorage.drop(_state.get_db_for_project("alpha"), str(_ephemeral.get("two", "")))


func _land_settle() -> String:
	## The idle settle of the saved record's sidecar append lands while the
	## results are shown: the debounce tick runs as if its idle window had
	## passed, the shell's frame loop commits it, and the shell's poll runs.
	var before := _file_stamps()
	var idle_now := Time.get_ticks_msec() + DocketDBJsonl.SETTLE_IDLE_MS
	var started := 0
	for db in _dbs:
		var jsonl := db as DocketDBJsonl
		if jsonl == null or not jsonl.is_open() or not jsonl.has_pending_sidecar(): continue
		var error := jsonl.settle_if_idle(idle_now)
		if not error.is_empty(): return error
		started += 1
	_shell._on_poll_external_changes()
	for _frame in 600:
		if not _dbs.any(func(db: DocketDB) -> bool: return db is DocketDBJsonl and (db as DocketDBJsonl).is_settling()): break
		await get_tree().process_frame
	_shell._on_poll_external_changes()
	var pending := _dbs.any(func(db: DocketDB) -> bool: return db is DocketDBJsonl and db.is_open() and ((db as DocketDBJsonl).has_pending_sidecar() or (db as DocketDBJsonl).is_settling()))
	if started == 0 or pending or _file_stamps() == before:
		return "no settle landed (started %d, still pending %s)" % [started, pending]
	return ""


func _zoom_preference() -> String:
	## View > Reset Zoom stores the scale preference in the primary project.
	var stored_before := _state.db.get_meta_value("ui_scale", "")
	_shell._on_menu_action("zoom_reset")
	var stored := _state.db.get_meta_value("ui_scale", "")
	return "" if stored != stored_before else "the zoom preference was not stored (%s)" % stored


func _hint_retrieval() -> String:
	## An MCP hint read, which bumps the hint's retrieval_count.
	var db := _state.get_db_for_project("alpha")
	var count_before := int(db.get_item(_hint_id).get("retrieval_count", 0))
	var result := _tools.call_tool("docket_hint_get", {"component": "results", "key": "retrieval", "project": "alpha"})
	if result.has("error"): return str(result.error)
	var count_after := int(db.get_item(_hint_id).get("retrieval_count", 0))
	return "" if count_after == count_before + 1 else "retrieval_count went from %d to %d" % [count_before, count_after]


func _show_retrieval_column() -> String:
	_shell._query_grid.set_result_columns(RETRIEVAL_COLUMNS)
	return ""


# -- Fixture and observations -------------------------------------------------

func _open_fixture() -> String:
	_new_state()
	for project: String in PROJECTS:
		var path := "%s/%s.dct" % [DIR, project]
		var db := DocketDBJsonl.create_new_jsonl(path)
		if db == null: return "fixture %s did not open: %s" % [path, DocketDBJsonl.last_open_error]
		var registry := _add_project(project, db)
		var titles: Array[String] = []
		for i in ROWS_PER_PROJECT: titles.append("%s %s%02d" % [MATCH, project.left(1), i])
		for i in 3: titles.append("other %s%02d" % [project.left(1), i])
		for title in titles:
			var made := registry.create_item({"type": "chore", "title": title}, "tester")
			if made.has("error"): return "fixture item %s: %s" % [title, made.error]
		if project == "alpha":
			var hint := registry.create_item({"type": "hint", "title": "%s hint" % MATCH, "value": "v", "component": "results", "key": "retrieval"}, "tester")
			if hint.has("error"): return "fixture hint: %s" % hint.error
			_hint_id = str(hint.id)
		var flushed := db.flush_checked()
		if not flushed.is_empty(): return "fixture settle: %s" % flushed
	_start_shell()
	return ""


func _new_state() -> void:
	_state = CountingState.new()
	_state.schema = TypeRegistryBootstrap.load_shipped_schema()
	_state.prefs = UserPrefs.new()


func _add_project(project: String, db: DocketDB) -> TypeRegistry:
	_dbs.append(db)
	var registry := TypeRegistry.for_db(db, project)
	_state._project_dbs[project] = db
	_state._type_registries[project] = registry
	return registry


func _start_shell() -> void:
	## The primary is the first project; the shell's poll is stopped.
	_state.db = _dbs[0]
	_state.dct_path = _dbs[0].get_path()
	_tools = ToolRegistry.new()
	_tools.init(_state.schema, _state.db, _state.get_project_dbs())
	_shell = AppShell.new()
	_shell.init(_state)
	add_child(_shell)
	_shell._poll_timer.stop()


func _shown_rows() -> Array:
	## [project, id, title, storage word] of each grid row, top to bottom, plus
	## the retrieval count cell while that column is shown.
	var grid := _shell._query_grid
	var title_col := grid._col_fields.find("title")
	var storage_col := grid._col_fields.find(StorageBadge.FIELD)
	var retrieval_col := grid._col_fields.find("retrieval_count")
	var rows: Array = []
	var root := grid._tree.get_root()
	if root == null: return rows
	for row in root.get_children():
		var origin: Dictionary = row.get_metadata(0)
		var cells: Array = [str(origin.project), str(origin.id), row.get_text(title_col), row.get_text(storage_col)]
		if retrieval_col >= 0: cells.append(row.get_text(retrieval_col))
		rows.append(cells)
	return rows


func _expected_rows(conditions: Array) -> Array:
	## The rows for `conditions` straight from each loaded project's cache,
	## merged and sorted by title (the fixture's titles are unique).
	var modes := StorageBadge.project_modes(_state.get_project_dbs())
	var retrieval_shown := _shell._query_grid._col_fields.has("retrieval_count")
	var rows: Array = []
	for project: String in _state.get_project_dbs():
		var db: DocketDB = _state.get_db_for_project(project)
		# The cache first catches up with a canonical file changed on disk.
		if db is DocketDBJsonl: (db as DocketDBJsonl).ensure_fresh()
		for item: Dictionary in db.execute_query({"filter": {"conditions": conditions}}):
			var cells: Array = [project, str(item.id), str(item.title), StorageBadge.word(str(modes[project]), str(item.get("storage", "")))]
			# Of this fixture's types only the hint declares retrieval_count.
			if retrieval_shown: cells.append(str(int(item.get("retrieval_count", 0))) if str(item.type) == "hint" else "")
			rows.append(cells)
	rows.sort_custom(func(a: Array, b: Array) -> bool: return str(a[2]) < str(b[2]))
	return rows


func _rows_match(title_part: String, message: String) -> Variant:
	return _rows_match_conditions(_title_is(title_part), message)


func _rows_match_conditions(conditions: Array, message: String) -> Variant:
	## The grid shows rows, and they equal _expected_rows(conditions).
	var shown := _shown_rows()
	var r = A.is_true(not shown.is_empty(), "%s: the grid shows rows" % message)
	if r is String: return r
	return A.eq(shown, _expected_rows(conditions), message)


func _title_is(title_part: String) -> Array:
	return [{"field": "title", "op": "contains", "value": title_part}]


func _title_filter(title_part: String) -> String:
	return JSON.stringify({"conditions": _title_is(title_part)})


func _other_shown_row(project: String) -> Array:
	## The first shown row other than the open record, of `project` if given.
	for row: Array in _shown_rows():
		if row[1] == str(_open_origin.get("id", "")) and row[0] == str(_open_origin.get("project", "")): continue
		if project.is_empty() or row[0] == project: return row
	return []


func _file_stamps() -> Dictionary:
	## Loaded project -> [sha256, mtime] of its canonical .dct.
	var stamps := {}
	for project: String in _state.get_project_dbs():
		var path := _state.get_db_for_project(project).get_path()
		stamps[project] = [FileAccess.get_sha256(path), FileAccess.get_modified_time(path)]
	return stamps


# -- Refresh content and cost --------------------------------------------------

const RECORD_DESCRIPTION := "review body a00"

func _open_views_fixture() -> String:
	_new_state()
	for project: String in PROJECTS:
		var path := "%s/%s.dct" % [DIR, project]
		var db := DocketDBJsonl.create_new_jsonl(path)
		if db == null: return "fixture %s did not open: %s" % [path, DocketDBJsonl.last_open_error]
		var registry := _add_project(project, db)
		var made: Dictionary = registry.define_type("review", _review_definition(), "tester", "fixture")
		if made.has("error"): return "fixture review type: %s" % made.error
		var activated := registry.activate_type("review", str(made.type.current_revision), "tester", "fixture")
		if not activated.is_empty(): return "fixture review activation: %s" % activated
		for i in 12:
			var fields := {"type": "chore", "title": "%s %s%02d" % [MATCH, project.left(1), i], "description": "chore %d" % i, "tags": [["red"], ["blue", "red"], []][i % 3]}
			if i % 5 != 0: fields["priority"] = i % 5
			var chore := registry.create_item(fields, "tester")
			if chore.has("error"): return "fixture chore: %s" % chore.error
			var steps: Array = [["in_progress"], ["in_progress", "done"]][i % 2] if i % 3 == 0 else []
			for step: String in steps:
				var moved := registry.transition_item(str(chore.id), step, "tester")
				if not moved.is_empty(): return "fixture chore transition: %s" % moved
			if i % 4 == 0:
				var attached := db.attach_file(str(chore.id), "note.txt", "attached".to_utf8_buffer())
				if attached.has("error"): return "fixture attachment: %s" % attached.error
		for i in 6:
			var description := RECORD_DESCRIPTION if project == "alpha" and i == 0 else "review %d" % i
			var review := registry.create_item({"type": "review", "title": "%s %s review %02d" % [MATCH, project.left(1), i], "description": description, "tags": ["red"] if i % 2 == 0 else [], "revision": "r%02d" % (5 - i)}, "tester")
			if review.has("error"): return "fixture review: %s" % review.error
			_fixture_ids["%s review %d" % [project, i]] = str(review.id)
			if i % 3 == 0:
				var approved := registry.transition_item(str(review.id), "approved", "tester")
				if not approved.is_empty(): return "fixture review transition: %s" % approved
	var alpha_error := _pin_and_link_alpha()
	if not alpha_error.is_empty(): return alpha_error
	var collision_error := _insert_collisions()
	if not collision_error.is_empty(): return collision_error
	for db in _dbs:
		var flushed := (db as DocketDBJsonl).flush_checked()
		if not flushed.is_empty(): return "fixture settle: %s" % flushed
	_start_shell()
	var ephemeral := _tools.call_tool("docket_create", {"type": "chore", "title": "%s ephemeral" % MATCH, "project": "alpha", "storage": ItemStorage.EPHEMERAL, "tags": ["red"]})
	return str(ephemeral.get("error", ""))


func _pin_and_link_alpha() -> String:
	## Evolves alpha's review type with an "extra" field and repins only
	## reviews 0 and 1, sets extra on review 1 and links review 0 to review 1.
	var registry := _state.get_type_registry("alpha")
	var current := registry.get_type("review")
	var evolved: Dictionary = (current.definition as Dictionary).duplicate(true)
	evolved.fields.append({"key": "extra", "label": "Extra", "type": "string", "required": false, "nullable": true, "mutable": true})
	var repinned := [_fixture_ids["alpha review 0"], _fixture_ids["alpha review 1"]]
	var preview := registry.preview_evolution("review", evolved, str(current.current_revision), repinned)
	if preview.has("error"): return "fixture evolution: %s" % preview.error
	var applied := registry.apply_evolution(preview, "tester", "fixture")
	if not applied.is_empty(): return "fixture evolution: %s" % applied
	var updated := registry.update_item(repinned[1], {"extra": "x1"}, "tester")
	if not updated.is_empty(): return "fixture extra: %s" % updated
	_fixture_ids["record"] = repinned[0]
	return (_state.get_db_for_project("alpha") as DocketDBJsonl).add_link_checked(repinned[0], repinned[1], "relates")


func _insert_collisions() -> String:
	## Two alpha ids sharing their first ten characters, and the first of them
	## also in beta, away from every generated id's time prefix.
	var shared := "0f0f0f0f0f" + DocketDB.generate_uuid7().substr(10)
	var twin := shared.left(10) + ("1" if shared[10] == "0" else "0") + DocketDB.generate_uuid7().substr(11)
	_fixture_ids["shared"] = shared
	for entry: Array in [["alpha", shared], ["alpha", twin], ["beta", shared]]:
		var registry := _state.get_type_registry(entry[0])
		var chore := registry.get_type("chore")
		var error: String = _state.get_db_for_project(entry[0]).insert_item(entry[1], {"type": "chore", "type_id": str(chore.id), "type_revision": str(chore.current_revision), "status": str(chore.definition.lifecycle.initial_state), "title": "%s collide %s %s" % [MATCH, entry[0], entry[1].left(11)], "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z", "tags": ["red"]})
		if not error.is_empty(): return "fixture collision row: %s" % error
	return ""


func _review_definition() -> Dictionary:
	return {"slug": "review", "label": "Review", "description": "Review a revision", "use_when": "a revision needs approval", "protected": false, "protected_behavior": {"regular_creation_allowed": true},
		"fields": [{"key": "revision", "label": "Revision", "type": "string", "required": true, "nullable": false, "mutable": true}],
		"lifecycle": {"initial_state": "requested", "states": [{"key": "requested", "label": "Requested", "state_category": "queued", "state_outcome": ""}, {"key": "approved", "label": "Approved", "state_category": "terminal", "state_outcome": "success"}],
			"terminal_states": ["approved"], "transitions": {"requested": ["approved"], "approved": []}, "guards": {}, "enforcement": "strict"}}


## Grid configurations: columns ([] for the default layout), conditions as the
## condition rows hold them, and the sort column's field key.
func _views() -> Array[Dictionary]:
	var typed_columns: Array = ["id", "project", "title", "status", "tags", StorageBadge.FIELD, "revision", "extra"]
	return [
		{"name": "default columns", "columns": [], "conditions": [], "sort": "title"},
		{"name": "tag filter", "columns": typed_columns, "conditions": [{"field": "tags", "op": "eq", "value": "red"}], "sort": "title"},
		{"name": "attachment filter", "columns": typed_columns, "conditions": [{"field": "title", "op": "contains", "value": MATCH}, {"field": "has_attachment", "op": "eq", "value": true, "conj": "and"}], "sort": "title"},
		{"name": "sorted by a custom field", "columns": ["id", "project", "title", "priority", "revision"], "conditions": [], "sort": "revision"},
	]


func _show_view(view: Dictionary) -> void:
	var grid := _shell._query_grid
	grid._sort_field = ""
	grid._sort_dir = "asc"
	grid.set_result_columns(view.columns)
	grid.set_filter(JSON.stringify({"conditions": view.conditions}) if not (view.conditions as Array).is_empty() else "")
	grid._toggle_sort(grid._col_fields.find(view.sort))


func _pinned_cells() -> Variant:
	## The tag filter view's cells for three reviews of both projects, against
	## values the fixture sets: revision "r%02d" % (5 - i), approved for review 0 and
	## requested for review 2, and the grid's status colours for a terminal
	## and a queued state.
	var grid := _shell._query_grid
	_show_view(_views()[1])
	await get_tree().process_frame
	var terminal := Color(0.55, 0.55, 0.6)
	var queued := Color(0.65, 0.7, 0.85)
	var pins := {
		_fixture_ids["alpha review 0"]: ["alpha", "approved", "r05", terminal],
		_fixture_ids["alpha review 2"]: ["alpha", "requested", "r03", queued],
		_fixture_ids["beta review 0"]: ["beta", "approved", "r05", terminal],
	}
	var status_col := grid._col_fields.find("status")
	var revision_col := grid._col_fields.find("revision")
	var found := 0
	for cells: Array in _view_rows_shown():
		if not pins.has(cells[1]) or cells[0] != (pins[cells[1]] as Array)[0]: continue
		found += 1
		var actual := [cells[0], cells[2 + status_col], cells[2 + revision_col], cells[cells.size() - 1]]
		var r = A.eq(actual, pins[cells[1]], "pinned cells of %s" % cells[1])
		if r is String: return r
	return A.eq(found, pins.size(), "pinned reviews shown in the tag filter view")


func _view_rows_shown() -> Array:
	## [project, id, each cell's text..., status cell colour] per grid row.
	var grid := _shell._query_grid
	var status_col := grid._col_fields.find("status")
	var rows: Array = []
	var root := grid._tree.get_root()
	if root == null: return rows
	for row in root.get_children():
		var origin: Dictionary = row.get_metadata(0)
		var cells: Array = [str(origin.project), str(origin.id)]
		for col in grid._col_fields.size(): cells.append(row.get_text(col))
		cells.append(row.get_custom_color(status_col) if status_col >= 0 else Color())
		rows.append(cells)
	return rows


func _view_rows_expected(view: Dictionary) -> Array:
	## _view_rows_shown's shape, from the complete records.
	var grid := _shell._query_grid
	var modes := StorageBadge.project_modes(_state.get_project_dbs())
	var items: Array = []
	for project: String in PROJECTS:
		var query := {"filter": {"conditions": view.conditions}} if not (view.conditions as Array).is_empty() else {}
		for item: Dictionary in _state.get_db_for_project(project).execute_registry_query(query, _state.get_type_registry(project)):
			item["project"] = project
			items.append(item)
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _view_order(a, b, view.sort))
	var rows: Array = []
	for item: Dictionary in items:
		var cells: Array = [str(item.project), str(item.id)]
		for column: String in grid._col_fields: cells.append(_expected_cell(item, column, modes))
		var colour: Color = grid._pinned_state_color(item) if grid._col_fields.has("status") else Color()
		cells.append(colour if colour.a > 0.0 else Color())
		rows.append(cells)
	return rows


func _view_order(a: Dictionary, b: Dictionary, sort: String) -> bool:
	## Ascending by the sort value, rows without one last, then project and id.
	## A type field's value is in the fields envelope of the rows that have it
	## (the fixture's custom review type).
	var values: Array = []
	for item: Dictionary in [a, b]:
		values.append((item.fields as Dictionary).get(sort) if ColumnBinding.is_typed(sort) else item.get(sort))
	if (values[0] == null) != (values[1] == null): return values[1] == null
	if values[0] != null and values[0] != values[1]: return str(values[0]) < str(values[1])
	if a.project != b.project: return str(a.project) < str(b.project)
	return str(a.id) < str(b.id)


func _expected_cell(item: Dictionary, column: String, modes: Dictionary) -> String:
	if ColumnBinding.is_typed(column): return _shell._query_grid._render_typed_column(item, column)
	match column:
		"id": return _state.get_db_for_project(str(item.project)).short_id(str(item.id))
		"priority": return str(item.priority) if int(item.priority) != 0 else ""
		StorageBadge.FIELD: return StorageBadge.word(str(modes[item.project]), str(item.get("storage", "")))
	return str(item.get(str(column), ""))


func _short_ids_distinct(shown: Array, id_cell: int) -> Variant:
	## Each shown ID is a prefix of its full id and unique within its project.
	var seen := {}
	for cells: Array in shown:
		var short := str(cells[id_cell])
		if not str(cells[1]).begins_with(short): return "shown ID %s is not a prefix of %s" % [short, cells[1]]
		var key := "%s:%s" % [cells[0], short]
		if seen.has(key): return "shown ID %s repeats within %s" % [short, cells[0]]
		seen[key] = true
	return true


func _open_complete_record() -> Variant:
	## Opens the fixture's record row from the results.
	var grid := _shell._query_grid
	var record_id: String = _fixture_ids["record"]
	var target: TreeItem = null
	for row in grid._tree.get_root().get_children():
		var origin: Dictionary = row.get_metadata(0)
		if origin.id == record_id and origin.project == "alpha": target = row
	if target == null: return "the record row is not shown"
	target.select(0)
	grid._on_item_activated()
	var form := _shell._record_form
	var db := _state.get_db_for_project("alpha")
	var events := db.get_events(record_id)
	var r = A.is_true(form._current_id == record_id and form._current_project == "alpha", "the activated row opens its record")
	if r is String: return r
	r = A.eq([form._desc_edit.text, form._tags_edit.text], [RECORD_DESCRIPTION, "red"], "the record shows its description and tags")
	if r is String: return r
	r = A.is_true(events.size() >= 3 and form._events_list.item_count == events.size(), "the record shows its whole history (%d of %d events)" % [form._events_list.item_count, events.size()])
	if r is String: return r
	r = A.eq((form._dynamic_fields._rows["revision"].editor as LineEdit).text, "r05", "the record shows its typed field")
	if r is String: return r
	return A.eq(db.get_item(record_id).links, [{"to": _fixture_ids["alpha review 1"], "relation": "relates"}], "the record keeps its link")


func _insert_reads_rows(db: DocketDB, project: String, from: int, to: int) -> String:
	for i in range(from, to):
		var error := db.insert_item(DocketDB.generate_uuid7(), {"type": "chore", "status": "open", "title": "%s %s%03d" % [MATCH, project.left(1), i], "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z", "tags": ["red"] if i % 2 == 0 else []})
		if not error.is_empty(): return "fixture row: %s" % error
	return ""


func _refresh_selects(grid: QueryGrid) -> int:
	## SELECT statements across the projects while the visible grid refreshes
	## once, starting on a fresh frame so per-frame registry checks run in each.
	await get_tree().process_frame
	for db in _dbs: (db as CountingDB).selects = 0
	grid.refresh()
	var total := 0
	for db in _dbs: total += (db as CountingDB).selects
	return total
