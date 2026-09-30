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
##            sort key here. Bound cells and colours come from the grid's
##            renderers fed those complete records outside a refresh.
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

const A = preload("res://test/assert_helpers.gd")
const DIR := "user://fixtures/results_return"
const PROJECTS := ["alpha", "beta"]
const MATCH := "row"
const ROWS_PER_PROJECT := 40  # enough rows for the grid to scroll
const OPEN_ROW := 60  # grid row the record is opened from
const ROWS_SMALL := 10  # rows per project in the reads oracle's smaller set

## Counts results queries; everything else is AppState's own behavior.
class CountingState extends AppState:
	var results_queries := 0

	func execute_cross_project_query(query: Dictionary, detail: String = "full", keys: PackedStringArray = PackedStringArray()) -> Array:
		results_queries += 1
		return super.execute_cross_project_query(query, detail, keys)

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
	_fixture_ids.clear()
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


func test_refresh_rows_match_complete_records() -> Variant:
	var fixture_error := _open_views_fixture()
	if not fixture_error.is_empty():
		return fixture_error
	var grid := _shell._query_grid
	for view: Dictionary in _views():
		_show_view(view)
		await get_tree().process_frame
		var shown := _view_rows_shown()
		var r = A.eq(shown, _view_rows_expected(view), "%s: rows shown equal the complete records" % view.name)
		if r is String: return r
		r = _short_ids_distinct(shown, 2 + grid._col_fields.find("id"))
		if r is String: return "%s: %s" % [view.name, r]
	_show_view(_views()[0])
	var shared: String = _fixture_ids["shared"]
	var shown_shared: Dictionary = {}
	for cells: Array in _view_rows_shown():
		if cells[1] == shared: shown_shared[cells[0]] = cells[2 + grid._col_fields.find("id")]
	var r = A.is_true(shown_shared.size() == 2 and shown_shared.alpha != shown_shared.beta, "the id in both projects shows each project's own prefix: %s" % shown_shared)
	if r is String: return r
	return _open_complete_record()


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
## condition rows hold them, and the sort column (a field or a binding).
func _views() -> Array[Dictionary]:
	var alpha_review := _state.get_type_registry("alpha").get_type("review")
	var beta_review := _state.get_type_registry("beta").get_type("review")
	var revision := {"project": "alpha", "type_id": str(alpha_review.id), "field_key": "revision", "label": "Revision"}
	var extra := {"project": "alpha", "type_id": str(alpha_review.id), "field_key": "extra", "label": "Extra"}
	var beta_revision := {"project": "beta", "type_id": str(beta_review.id), "field_key": "revision", "label": "Beta revision"}
	var typed_columns: Array = ["id", "project", "title", "status", "tags", StorageBadge.FIELD, revision, extra, beta_revision]
	return [
		{"name": "default columns", "columns": [], "conditions": [], "sort": "title"},
		{"name": "tag filter", "columns": typed_columns, "conditions": [{"field": "tags", "op": "eq", "value": "red"}], "sort": "title"},
		{"name": "attachment filter", "columns": typed_columns, "conditions": [{"field": "title", "op": "contains", "value": MATCH}, {"field": "has_attachment", "op": "eq", "value": true, "conj": "and"}], "sort": "title"},
		{"name": "sorted by a custom field", "columns": ["id", "project", "title", "priority", revision], "conditions": [], "sort": revision},
	]


func _show_view(view: Dictionary) -> void:
	var grid := _shell._query_grid
	grid._sort_field = ""
	grid._sort_dir = "asc"
	grid._sort_binding = {}
	grid.set_result_columns(view.columns)
	grid.set_filter(JSON.stringify({"conditions": view.conditions}) if not (view.conditions as Array).is_empty() else "")
	grid._toggle_sort(grid._col_fields.find(view.sort))


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
		for column: Variant in grid._col_fields: cells.append(_expected_cell(item, column, modes))
		var colour: Color = grid._pinned_state_color(item) if grid._col_fields.has("status") else Color()
		cells.append(colour if colour.a > 0.0 else Color())
		rows.append(cells)
	return rows


func _view_order(a: Dictionary, b: Dictionary, sort: Variant) -> bool:
	## Ascending by the sort value, rows without one last, then project and id.
	var values: Array = []
	for item: Dictionary in [a, b]:
		if sort is Dictionary: values.append((item.fields as Dictionary).get(sort.field_key) if str(item.type_id) == str(sort.type_id) else null)
		else: values.append(item.get(str(sort)))
	if (values[0] == null) != (values[1] == null): return values[1] == null
	if values[0] != null and values[0] != values[1]: return str(values[0]) < str(values[1])
	if a.project != b.project: return str(a.project) < str(b.project)
	return str(a.id) < str(b.id)


func _expected_cell(item: Dictionary, column: Variant, modes: Dictionary) -> String:
	if column is Dictionary: return _shell._query_grid._render_bound_column(item, column)
	match str(column):
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
