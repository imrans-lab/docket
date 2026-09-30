extends Node
## Drives the query builder's condition rows on a two-project session (one
## legacy project storing plain type/status strings, one with a dynamic type
## catalog) and checks the conditions it builds and the rows it returns against
## the core query engine. Regression coverage for docket bugs 01a0e12772e2
## (catalog-labelled type/status values), 01a0e12e0856 (project value) and
## 01a0e152a4c3 (GUI and core results diverge).

var A := AssertHelpers
var _db_dir := "user://test_query_grid_conditions"
var _dbs: Array = []


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_db_dir)


func before_each() -> void:
	_cleanup_databases()


func teardown() -> void:
	_cleanup_databases()
	DirAccess.remove_absolute(_db_dir)


func _cleanup_databases() -> void:
	for db in _dbs: db.close()
	_dbs.clear()
	var dir := DirAccess.open(_db_dir)
	if dir:
		for name in dir.get_files(): dir.remove(name)


func _legacy_db(project: String, items: Array) -> DocketDBJsonl:
	var db: DocketDBJsonl = DocketDBJsonl.create_new_jsonl("%s/%s.dct" % [_db_dir, project])
	db.set_project_name_checked(project)
	var now: String = Time.get_datetime_string_from_system(true)
	for value in items:
		var item: Dictionary = value
		var error: String = db.insert_item(db.next_uuid7_id(), {"type": item.type, "status": item.status, "title": item.title, "created_at": now, "updated_at": now})
		assert(error.is_empty(), "legacy fixture item failed: %s" % error)
	_dbs.append(db)
	return db


func _typed_db(project: String, items: Array) -> DocketDBJsonl:
	var db: DocketDBJsonl = DocketDBJsonl.create_new_jsonl("%s/%s.dct" % [_db_dir, project])
	db.set_project_name_checked(project)
	var registry: TypeRegistry = TypeRegistry.for_db(db, project)
	var definition: Dictionary = {"slug":"code_review","label":"Code Review","description":"Review a revision","use_when":"approval is required","fields":[{"key":"title","type":"string","required":true,"nullable":false}],"lifecycle":{"initial_state":"requested","states":[{"key":"requested","state_category":"queued","state_outcome":""},{"key":"approved","state_category":"terminal","state_outcome":"success"}],"terminal_states":["approved"],"transitions":{"requested":["approved"],"approved":[]},"guards":{},"enforcement":"strict"},"protected":false,"protected_behavior":{"regular_creation_allowed":true}}
	var defined: Dictionary = registry.define_type("code_review", definition, "tester", "fixture")
	assert(not defined.has("error"), "fixture definition failed: %s" % defined.get("error", ""))
	registry.activate_type("code_review", str(defined.get("type", {}).get("current_revision", "")), "tester", "fixture")
	var now: String = Time.get_datetime_string_from_system(true)
	for value in items:
		var item: Dictionary = value
		var descriptor: Dictionary = registry.get_type(str(item.type))
		var error: String = db.insert_item(db.next_uuid7_id(), {"type":item.type,"type_id":descriptor.id,"type_revision":descriptor.current_revision,"status":item.status,"title":item.title,"created_at":now,"updated_at":now,"fields":{},"extras":{}})
		assert(error.is_empty(), "typed fixture item failed: %s" % error)
	_dbs.append(db)
	return db


func _state() -> AppState:
	var state := AppState.new()
	state.load_schema()
	var legacy := _legacy_db("legacy", [
		{"type": "bug", "status": "new", "title": "L bug new"},
		{"type": "bug", "status": "resolved", "title": "L bug resolved"},
		{"type": "chore", "status": "new", "title": "L chore new"},
	])
	var typed := _typed_db("typed", [
		{"type": "bug", "status": "new", "title": "T bug new"},
		{"type": "bug", "status": "resolved", "title": "T bug resolved"},
		{"type": "code_review", "status": "requested", "title": "T review"},
	])
	state._project_dbs = {"legacy": legacy, "typed": typed}
	state._type_registries = {"legacy": TypeRegistry.for_db(legacy, "legacy"), "typed": TypeRegistry.for_db(typed, "typed")}
	state.db = legacy
	return state


func _grid(state: AppState) -> QueryGrid:
	var grid := QueryGrid.new()
	add_child(grid)
	grid.init(state)
	return grid


func _set_field(grid: QueryGrid, row_idx: int, field_name: String) -> void:
	var row: Dictionary = grid._condition_rows[row_idx]
	for i in row.field.item_count:
		if row.field.get_item_text(i) == field_name:
			row.field.select(i)
			row.field.item_selected.emit(i)
			return
	assert(false, "field %s not offered" % field_name)


func _set_op(grid: QueryGrid, row_idx: int, label: String) -> void:
	var row: Dictionary = grid._condition_rows[row_idx]
	for i in row.op.item_count:
		if row.op.get_item_text(i) == label:
			row.op.select(i)
			row.op.item_selected.emit(i)
			return
	assert(false, "op %s not offered" % label)


func _pick(grid: QueryGrid, row_idx: int, typed: String) -> void:
	## Types into the row's value search box and presses Enter.
	var picker: EnumValuePicker = grid._condition_rows[row_idx].value_picker
	picker.set_search(typed)
	picker.choose_first_match()


func _titles(rows: Array) -> Array:
	var titles: Array = rows.map(func(row): return str(row.title))
	titles.sort()
	return titles


func _core_titles(state: AppState, conditions: Array) -> Array:
	return _titles(state.execute_cross_project_query({"filter": {"conditions": conditions}}))


func _plain(values: Array) -> bool:
	for value in values:
		if str(value).contains("—") or str(value).contains(" -- ") or str(value) != str(value).strip_edges(): return false
	return true


func test_enumerated_values_are_plain_sorted_pickers_in_every_row() -> Variant:
	var grid := _grid(_state())
	var first: Dictionary = grid._condition_rows[0]
	var r = A.is_true(first.value_picker.visible and not first.value.visible, "row 1 type value is a picker, not free text")
	if r is String: grid.queue_free(); return r
	var types: Array = first.value_picker.values()
	var sorted_types := types.duplicate(); sorted_types.sort()
	r = A.is_true(_plain(types) and types == sorted_types and types.count("bug") == 1 and types.has("code_review"), "type values are plain slugs, sorted, each once across projects: %s" % [types])
	if r is String: grid.queue_free(); return r
	grid._add_condition_row(false)
	_set_field(grid, 1, "type")
	var second: Dictionary = grid._condition_rows[1]
	r = A.is_true(second.value_picker.visible and not second.value.visible and second.value_picker.values() == types, "row 2 type value behaves exactly like row 1")
	if r is String: grid.queue_free(); return r
	_pick(grid, 1, "bug")
	r = A.eq(second.value_picker.get_value(), "bug", "typing bug and Enter selects the bug type")
	if r is String: grid.queue_free(); return r
	_set_field(grid, 1, "status")
	var statuses: Array = second.value_picker.values()
	var sorted_statuses := statuses.duplicate(); sorted_statuses.sort()
	r = A.is_true(_plain(statuses) and statuses == sorted_statuses and statuses.count("new") == 1 and statuses.has("requested"), "status values are plain states, sorted, each once: %s" % [statuses])
	if r is String: grid.queue_free(); return r
	_pick(grid, 0, "code_review")
	r = A.eq(second.value_picker.values(), ["approved", "requested"], "status values narrow to the chosen type")
	grid.queue_free(); return r


func test_type_and_status_query_matches_core_query() -> Variant:
	var state := _state()
	var grid := _grid(state)
	_pick(grid, 0, "bug")
	grid._add_condition_row(false)
	var r = A.eq(grid._condition_rows[1].conj.get_item_text(grid._condition_rows[1].conj.selected), "AND", "a new row joins with AND by default")
	if r is String: grid.queue_free(); return r
	_set_field(grid, 1, "status")
	_pick(grid, 1, "new")
	var expected := [{"field": "type", "op": "eq", "value": "bug"}, {"field": "status", "op": "eq", "value": "new", "conj": "and"}]
	r = A.eq(grid._condition_snapshots(), expected, "rows build plain type/status conditions")
	if r is String: grid.queue_free(); return r
	grid._run_query()
	var core := _core_titles(state, expected)
	r = A.is_true(core == ["L bug new", "T bug new"] and _titles(grid._current_results) == core, "GUI returns exactly the core query's rows: gui=%s core=%s" % [_titles(grid._current_results), core])
	if r is String: grid.queue_free(); return r
	_set_op(grid, 1, "not equals")
	grid._run_query()
	var not_new := [expected[0], {"field": "status", "op": "neq", "value": "new", "conj": "and"}]
	r = A.eq(_titles(grid._current_results), _core_titles(state, not_new), "not equals matches the core query too")
	if r is String: grid.queue_free(); return r
	_set_op(grid, 1, "equals")
	_pick(grid, 1, "new")
	var path := _db_dir + "/bugs.dcq"
	grid.save_dcq(path)
	var reopened := _grid(state)
	reopened.load_dcq(path)
	var row0: Dictionary = reopened._condition_rows[0]
	r = A.is_true(row0.value_picker.visible and not row0.value.visible and reopened._condition_snapshots() == expected, "a saved query reloads into the same pickers and conditions")
	if r is String: grid.queue_free(); reopened.queue_free(); return r
	r = A.eq(_titles(reopened._current_results), core, "the reloaded query returns the core query's rows")
	grid.queue_free(); reopened.queue_free(); return r


func test_project_value_lists_loaded_projects_and_add_selects_new_one() -> Variant:
	var state := _state()
	var grid := _grid(state)
	_set_field(grid, 0, "project")
	var picker: EnumValuePicker = grid._condition_rows[0].value_picker
	var r = A.is_true(picker.visible and not grid._condition_rows[0].value.visible and picker.values() == ["legacy", "typed"], "project value is a picker of loaded projects, sorted: %s" % [picker.values()])
	if r is String: grid.queue_free(); return r
	r = A.eq(picker.visible_entries().back(), "add…", "the list ends with an add entry")
	if r is String: grid.queue_free(); return r
	_pick(grid, 0, "typed")
	grid._run_query()
	r = A.is_true(grid._condition_snapshots() == [{"field": "project", "op": "eq", "value": "typed"}] and _titles(grid._current_results) == ["T bug new", "T bug resolved", "T review"], "project condition executes the chosen project only")
	if r is String: grid.queue_free(); return r
	var third_path := _db_dir + "/third.dct"
	var third := _legacy_db("third", [{"type": "bug", "status": "new", "title": "3 bug new"}])
	third.close(); _dbs.erase(third)
	var requests := [0]
	grid.add_project_requested.connect(func(): requests[0] += 1)
	picker.set_search("")
	picker._choose_index(picker.visible_entries().find("add…"))
	r = A.eq(requests[0], 1, "add… asks the shell to run its add-project flow")
	if r is String: grid.queue_free(); return r
	var error := state.add_project(third_path)
	_dbs.append(state.get_db_for_project("third"))
	r = A.is_true(error.is_empty() and picker.get_value() == "third" and picker.values() == ["legacy", "third", "typed"], "the newly loaded project is listed and selected: %s %s" % [error, picker.values()])
	if r is String: grid.queue_free(); return r
	grid._run_query()
	r = A.eq(_titles(grid._current_results), ["3 bug new"], "the query runs against the added project")
	if r is String: grid.queue_free(); return r
	grid.set_filter(JSON.stringify({"conditions": [{"field": "project", "op": "eq", "value": "gone"}]}))
	r = A.eq(grid._condition_rows[0].value_picker.text, "gone (not loaded)", "a saved project that is not loaded stays visible, never blank")
	if r is String: grid.queue_free(); return r
	state._project_dbs.erase("typed"); state._project_dbs.erase("third")
	grid.set_filter(JSON.stringify({"conditions": [{"field": "project", "op": "eq", "value": "legacy"}]}))
	r = A.eq(_titles(grid._current_results), ["L bug new", "L bug resolved", "L chore new"], "a project condition also runs with a single project loaded")
	grid.queue_free(); return r



## Numeric conditions typed into the builder of a real AppShell over one project
## (chores c1..c4 with priority 1..4, hints h0..h3 retrieved 0..3 times):
## titles containing "c" with priority >= 2 (an enumerated picker) in Work entry
## P, titles containing "h" with retrieval_count >= 2 (free text) in Work entry
## R. Both are restored by switching Work entries, R through a saved .dcq, and
## P from .dcq files holding the value as a JSON integer, a JSON decimal and a
## string. P, with its own columns and a descending title sort, is also saved
## and reopened through the shell's File > Save Query and File > Open Query
## handlers. Entry E holds one retrieval_count row with nothing typed, then with
## 0 typed, each restored by a Work-entry switch and E's empty row also through
## those handlers. Oracles: after every restore the numeric row shows the text
## typed ("2", "0" or nothing) and the rows equal the rows before the restore
## and a core query with literal numbers (every fixture row for the empty row);
## the reopened P has its saved columns and descending order. Last, a file
## holding only {"filter": {}} is opened while P is shown sorted: it must show
## one empty row and every fixture row in creation order, and P keeps its own
## condition. A missing file and a non-JSON file are reported and add no entry;
## a retrieval_count bound of 2^53 restores as its integer text. Restored
## conditions are compared whole: field, operator and value text of every row.
func test_numeric_conditions_survive_save_and_restore() -> Variant:
	var state := AppState.new()
	state.load_schema()
	state.prefs = UserPrefs.new()
	var db: DocketDBJsonl = DocketDBJsonl.create_new_jsonl("%s/numbers.dct" % _db_dir)
	_dbs.append(db)
	var registry := TypeRegistry.for_db(db, "numbers")
	for i in 4:
		var chore := registry.create_item({"type": "chore", "title": "c%d" % (i + 1), "priority": i + 1}, "tester")
		if chore.has("error"): return "fixture chore: %s" % chore.error
		var hint := registry.create_item({"type": "hint", "title": "h%d" % i, "value": "v", "component": "numbers", "key": "k%d" % i}, "tester")
		if hint.has("error"): return "fixture hint: %s" % hint.error
		for n in i: db.bump_retrieval(str(hint.id))
	state._project_dbs = {"numbers": db}
	state._type_registries = {"numbers": registry}
	state.db = db
	var shell := AppShell.new()
	shell.init(state)
	add_child(shell)
	shell._poll_timer.stop()
	var grid := shell._query_grid
	var p_core := [{"field": "title", "op": "contains", "value": "c"}, {"field": "priority", "op": "gte", "value": 2, "conj": "and"}]
	var r_core := [{"field": "title", "op": "contains", "value": "h"}, {"field": "retrieval_count", "op": "gte", "value": 2, "conj": "and"}]
	var p_rows: Array = ["c2", "c3", "c4"]
	var r_rows: Array = ["h2", "h3"]
	var r = A.is_true(_core_titles(state, p_core) == p_rows and _core_titles(state, r_core) == r_rows, "fixture: the core queries return %s and %s" % [p_rows, r_rows])
	if r is String: shell.queue_free(); return r

	var p_entry := shell._current_work_idx
	grid.set_filter("")
	_type_numeric(grid, "c", "priority")
	grid._run_query()
	r = A.eq(_titles(grid._current_results), p_rows, "entry P as typed")
	if r is String: shell.queue_free(); return r
	var r_entry := shell._add_work_entry("query", "R", "", "")
	shell._activate_work_entry(r_entry)
	_type_numeric(grid, "h", "retrieval_count")
	grid._run_query()
	r = A.eq(_titles(grid._current_results), r_rows, "entry R as typed")
	if r is String: shell.queue_free(); return r

	shell._activate_work_entry(p_entry)
	r = _numeric_restored(grid, "priority", p_rows, "entry P after a Work-entry switch")
	if r is String: shell.queue_free(); return r
	shell._activate_work_entry(r_entry)
	r = _numeric_restored(grid, "retrieval_count", r_rows, "entry R after a Work-entry switch")
	if r is String: shell.queue_free(); return r

	var saved := _db_dir + "/numbers_r.dcq"
	grid.save_dcq(saved)
	var reopened := _grid(state)
	reopened.load_dcq(saved)
	r = _numeric_restored(reopened, "retrieval_count", r_rows, "entry R from a saved .dcq")
	reopened.queue_free()
	if r is String: shell.queue_free(); return r
	for form: String in ["2", "2.0", "\"2\""]:
		var path := _db_dir + "/numbers_p.dcq"
		var out := FileAccess.open(path, FileAccess.WRITE)
		out.store_string('{"ui_filter":{"conditions":[{"field":"title","op":"contains","value":"c"},{"conj":"and","field":"priority","op":"gte","value":%s}]}}' % form)
		out.close()
		var loaded := _grid(state)
		loaded.load_dcq(path)
		r = _numeric_restored(loaded, "priority", p_rows, "entry P from a .dcq holding %s" % form)
		loaded.queue_free()
		if r is String: shell.queue_free(); return r

	shell._activate_work_entry(p_entry)
	grid.set_result_columns(["id", "title", "priority"])
	grid._toggle_sort(grid._col_fields.find("title"))
	grid._toggle_sort(grid._col_fields.find("title"))
	var descending: Array = ["c4", "c3", "c2"]
	r = A.eq(_ordered(grid), descending, "fixture: entry P sorted by title, descending")
	if r is String: shell.queue_free(); return r
	var menu_path := _db_dir + "/menu_p.dcq"
	shell._on_save_query_selected(menu_path)
	shell._activate_work_entry(r_entry)
	grid.set_result_columns(["id", "title", "status"])
	# The shared sort is title, descending; one more header click clears it, so
	# the descending order below can only come from the file.
	grid._toggle_sort(grid._col_fields.find("title"))
	shell._on_open_query_selected(menu_path)
	r = _numeric_restored(grid, "priority", p_rows, "entry P from File > Open Query")
	if r is String: shell.queue_free(); return r
	r = A.eq([grid._col_fields, _ordered(grid)], [["id", "title", "priority"], descending], "entry P from File > Open Query keeps its columns and sort")
	if r is String: shell.queue_free(); return r

	var every: Array = ["c1", "c2", "c3", "c4", "h0", "h1", "h2", "h3"]
	var zero_rows: Array = ["c1", "c2", "c3", "c4", "h0"]
	r = A.eq(_core_titles(state, [{"field": "retrieval_count", "op": "eq", "value": 0}]), zero_rows, "fixture: core retrieval_count = 0")
	if r is String: shell.queue_free(); return r
	var e_entry := shell._add_work_entry("query", "E", "", "")
	for typed: String in ["", "0"]:
		shell._activate_work_entry(e_entry)
		grid.set_filter("")
		_set_field(grid, 0, "retrieval_count")
		_set_op(grid, 0, "equals")
		grid._condition_rows[0].value.text = typed
		grid._run_query()
		var expected: Array = every if typed.is_empty() else zero_rows
		r = _single_restored(grid, typed, expected, "entry E with '%s' typed" % typed)
		if r is String: shell.queue_free(); return r
		shell._activate_work_entry(p_entry)
		shell._activate_work_entry(e_entry)
		r = _single_restored(grid, typed, expected, "entry E with '%s' typed, after a Work-entry switch" % typed)
		if r is String: shell.queue_free(); return r
		if typed.is_empty():
			var empty_path := _db_dir + "/menu_e.dcq"
			shell._on_save_query_selected(empty_path)
			shell._activate_work_entry(p_entry)
			shell._on_open_query_selected(empty_path)
			r = _single_restored(grid, typed, expected, "entry E with nothing typed, from File > Open Query")
			if r is String: shell.queue_free(); return r

	# An "all items" file (no condition rows, no sort) opened from File > Open
	# Query while entry P is shown sorted by title, descending.
	shell._activate_work_entry(p_entry)
	for _click in 3:
		if grid._sort_field == "title" and grid._sort_dir == "desc": break
		grid._toggle_sort(grid._col_fields.find("title"))
	r = A.eq(_ordered(grid), descending, "fixture: entry P sorted by title, descending before the open")
	if r is String: shell.queue_free(); return r
	var all_path := _db_dir + "/all_items.dcq"
	var all_file := FileAccess.open(all_path, FileAccess.WRITE)
	all_file.store_string('{"filter": {}}')
	all_file.close()
	shell._on_open_query_selected(all_path)
	var creation_order: Array = ["c1", "h0", "c2", "h1", "c3", "h2", "c4", "h3"]
	r = A.eq([grid._condition_snapshots(), _ordered(grid)], [[{"field": "type", "op": "eq", "value": ""}], creation_order], "an all-items file opens with one empty row, every row, unsorted")
	if r is String: shell.queue_free(); return r
	shell._activate_work_entry(p_entry)
	r = _numeric_restored(grid, "priority", p_rows, "entry P after the all-items file was opened")
	if r is String: shell.queue_free(); return r

	# A missing file and a file that is not JSON: reported, no entry added, and
	# the entry shown keeps its conditions.
	var bad_path := _db_dir + "/not_json.dcq"
	var bad_file := FileAccess.open(bad_path, FileAccess.WRITE)
	bad_file.store_string("not json")
	bad_file.close()
	for failing: String in [_db_dir + "/missing.dcq", bad_path]:
		var entries_before := shell._work_entries.size()
		shell._on_open_query_selected(failing)
		var reported := shell._info_dialog.visible
		shell._info_dialog.hide()
		r = A.is_true(reported and shell._work_entries.size() == entries_before and shell._current_work_idx == p_entry, "%s: reported, no entry added, entry P still shown" % failing.get_file())
		if r is String: shell.queue_free(); return r
		r = _numeric_restored(grid, "priority", p_rows, "entry P after %s failed to open" % failing.get_file())
		if r is String: shell.queue_free(); return r

	# A whole number past 2^53 that the saved JSON still holds exactly.
	grid.set_filter('{"conditions":[{"field":"title","op":"contains","value":"h"},{"conj":"and","field":"retrieval_count","op":"lt","value":9007199254740992}]}')
	r = A.eq(grid._condition_snapshots(), [{"field": "title", "op": "contains", "value": "h"}, {"field": "retrieval_count", "op": "lt", "value": "9007199254740992", "conj": "and"}], "a large whole number restores as its integer text")
	if r is String: shell.queue_free(); return r
	r = A.eq(_titles(grid._current_results), ["h0", "h1", "h2", "h3"], "retrieval_count below 2^53 selects every hint")
	shell.queue_free()
	return r


func _ordered(grid: QueryGrid) -> Array:
	return grid._current_results.map(func(row: Dictionary) -> String: return str(row.title))


func _single_restored(grid: QueryGrid, typed: String, rows: Array, label: String) -> Variant:
	## Row 1 is retrieval_count equals `typed`, and the rows are `rows`.
	var row: Dictionary = grid._condition_rows[0]
	var r = A.eq([row.field.get_item_text(row.field.selected), row.value.text], ["retrieval_count", typed], "%s: the row shows what was typed" % label)
	if r is String: return r
	return A.eq(_titles(grid._current_results), rows, "%s: rows" % label)


func _type_numeric(grid: QueryGrid, title_part: String, field_name: String) -> void:
	## Row 1: title contains title_part; row 2: field_name >= 2, chosen or typed
	## as a user would.
	_set_field(grid, 0, "title")
	_set_op(grid, 0, "contains")
	grid._condition_rows[0].value.text = title_part
	grid._add_condition_row(false)
	_set_field(grid, 1, field_name)
	_set_op(grid, 1, ">=")
	if grid._condition_rows[1].value_picker.visible: _pick(grid, 1, "2")
	else: grid._condition_rows[1].value.text = "2"


func _numeric_restored(grid: QueryGrid, field_name: String, rows: Array, label: String) -> Variant:
	## The rows hold exactly what _type_numeric typed for field_name (title
	## contains "c" for priority, "h" for retrieval_count; field_name >= "2"),
	## and the results are `rows`.
	var title_part := "c" if field_name == "priority" else "h"
	var typed := [{"field": "title", "op": "contains", "value": title_part}, {"field": field_name, "op": "gte", "value": "2", "conj": "and"}]
	var r = A.eq(grid._condition_snapshots(), typed, "%s: the rows show what was typed" % label)
	if r is String: return r
	return A.eq(_titles(grid._current_results), rows, "%s: rows" % label)


## A results query whose only condition is typed to a bool or an integer, over
## one project: chores c1 (priority 1, severity 2, attached), c2 (2, 3) and c3
## (3, 3, attached); hints h1 (retrieved once, research cost 5) and h2. Each
## condition is chosen or typed in the builder, then restored through
## set_filter. Oracles: the rows equal the literal rows listed here and a core
## query with the same literal condition; an eq row with nothing typed and a
## row left at (any) return every fixture row. A script error in the grid's
## filter building returns every row, which the row oracle catches.
func test_single_typed_condition_returns_the_matching_rows() -> Variant:
	var state := AppState.new()
	state.load_schema()
	var db: DocketDBJsonl = DocketDBJsonl.create_new_jsonl("%s/single.dct" % _db_dir)
	_dbs.append(db)
	var registry := TypeRegistry.for_db(db, "single")
	for spec: Array in [["c1", 1, 2, true], ["c2", 2, 3, false], ["c3", 3, 3, true]]:
		var chore := registry.create_item({"type": "chore", "title": spec[0], "priority": spec[1], "severity": spec[2]}, "tester")
		if chore.has("error"): return "fixture chore: %s" % chore.error
		if spec[3] and db.attach_file(str(chore.id), "note.txt", "attached".to_utf8_buffer()).has("error"): return "fixture attachment failed"
	var h1 := registry.create_item({"type": "hint", "title": "h1", "value": "v", "component": "single", "key": "k1", "research_cost": 5}, "tester")
	var h2 := registry.create_item({"type": "hint", "title": "h2", "value": "v", "component": "single", "key": "k2"}, "tester")
	if h1.has("error") or h2.has("error"): return "fixture hints failed"
	db.bump_retrieval(str(h1.id))
	state._project_dbs = {"single": db}
	state._type_registries = {"single": registry}
	state.db = db
	var every: Array = ["c1", "c2", "c3", "h1", "h2"]
	var cases: Array = [
		["has_attachment", "equals", "true", true, ["c1", "c3"]],
		["has_attachment", "equals", "false", false, ["c2", "h1", "h2"]],
		["priority", "equals", "2", 2, ["c2"]],
		["severity", "equals", "3", 3, ["c2", "c3"]],
		["retrieval_count", "equals", "1", 1, ["h1"]],
		["research_cost", "equals", "5", 5, ["h1"]],
		["priority", "not equals", "2", 2, ["c1", "c3", "h1", "h2"]],
		["priority", ">", "1", 1, ["c2", "c3"]],
	]
	var grid := _grid(state)
	for case: Array in cases:
		var core: Array = _core_titles(state, [{"field": case[0], "op": grid._op_label_to_key(case[1]), "value": case[3]}])
		var r = A.eq(core, case[4], "fixture: core %s %s %s" % [case[0], case[1], case[2]])
		if r is String: grid.queue_free(); return r
		grid.set_filter("")
		_set_field(grid, 0, case[0])
		_set_op(grid, 0, case[1])
		if grid._condition_rows[0].value_picker.visible: _pick(grid, 0, case[2])
		else: grid._condition_rows[0].value.text = case[2]
		grid._run_query()
		r = A.eq(_titles(grid._current_results), case[4], "typed %s %s %s" % [case[0], case[1], case[2]])
		if r is String: grid.queue_free(); return r
		grid.set_filter(JSON.stringify({"conditions": [{"field": case[0], "op": grid._op_label_to_key(case[1]), "value": case[3]}]}))
		r = A.eq(_titles(grid._current_results), case[4], "restored %s %s %s" % [case[0], case[1], case[2]])
		if r is String: grid.queue_free(); return r
	grid.set_filter("")
	_set_field(grid, 0, "retrieval_count")
	_set_op(grid, 0, "equals")
	grid._condition_rows[0].value.text = ""
	grid._run_query()
	var r = A.eq(_titles(grid._current_results), every, "an eq row with nothing typed returns every row")
	if r is String: grid.queue_free(); return r
	_set_field(grid, 0, "priority")
	grid._condition_rows[0].value_picker.set_value("")
	grid._run_query()
	r = A.eq(_titles(grid._current_results), every, "a row left at (any) returns every row")
	grid.queue_free()
	return r
