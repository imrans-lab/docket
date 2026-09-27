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
