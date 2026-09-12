extends Node
## Observable catalog and query-scope behavior. Fixtures use registry-shaped
## records so the same expectations apply when project registries replace the
## built-in schema adapter.

var A := AssertHelpers
var _db_dir := "user://test_type_catalog"
var _dbs: Array = []
var _prefs_backup := ""
const _PREFS_PATH := "user://docket_prefs.json"

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_db_dir)
	if FileAccess.file_exists(_PREFS_PATH):
		var prefs := FileAccess.open(_PREFS_PATH, FileAccess.READ)
		_prefs_backup = prefs.get_as_text()

func before_each() -> void:
	_cleanup_databases()

func _cleanup_databases() -> void:
	for db in _dbs: db.close()
	_dbs.clear()
	var dir := DirAccess.open(_db_dir)
	if dir:
		for name in dir.get_files(): dir.remove(name)

func teardown() -> void:
	_cleanup_databases()
	var dir := DirAccess.open(_db_dir)
	if dir:
		DirAccess.remove_absolute(_db_dir)
	if _prefs_backup.is_empty():
		if FileAccess.file_exists(_PREFS_PATH): DirAccess.remove_absolute(_PREFS_PATH)
	else:
		var prefs := FileAccess.open(_PREFS_PATH, FileAccess.WRITE)
		prefs.store_string(_prefs_backup)

func _make_db(project: String, items: Array) -> DocketDB:
	var db := DocketDB.create_new("%s/%s.dct" % [_db_dir, project])
	db.set_project_name(project)
	for i in items.size():
		var item: Dictionary = items[i]
		db.insert_item("%s-%04d" % [project.to_upper(), i + 1], {"type": item.type, "status": item.status, "title": item.title, "created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00", "tags": [], "events": [], "links": []})
	_dbs.append(db)
	return db

func _two_project_state() -> AppState:
	var state := AppState.new()
	state.schema = _schema()
	var alpha := _make_db("Alpha", [{"type": "discussion", "status": "active", "title": "Alpha thread"}, {"type": "code_review", "status": "requested", "title": "Alpha review"}])
	var beta := _make_db("Beta", [{"type": "discussion", "status": "resolved", "title": "Beta thread"}, {"type": "code_review", "status": "approved", "title": "Beta review"}, {"type": "code_review", "status": "requested", "title": "Beta requested review"}])
	state._project_dbs = {"Alpha": alpha, "Beta": beta}
	state.db = alpha
	return state


func _schema() -> Dictionary:
	return {"types": {
		"discussion": {"label": "discussion", "description": "Async decisions", "aliases": ["thread"], "states": ["active", "resolved"], "required_fields": ["title"], "optional_fields": ["priority"]},
		"code_review": {"id": "type-2", "label": "Code Review", "description": "Review a revision", "use_when": "approval is required", "states": ["requested", "approved"], "required_fields": ["title", "revision"], "optional_fields": ["reviewer"]},
		"old_review": {"label": "Code Review", "description": "Historical review", "lifecycle": "deprecated", "states": ["closed"]},
	}}


func test_catalog_is_case_insensitive_and_stably_sorted() -> Variant:
	var records := TypeCatalog.from_schema(_schema(), "Zulu", {"discussion": 4})
	var other := TypeCatalog.from_schema({"types": {"review": {"id": "type-1", "label": "Code Review", "states": []}}}, "alpha")
	records.append_array(other)
	records = TypeCatalog.sorted(records)
	var identities := []
	for record in records:
		identities.append("%s/%s/%s" % [record.label, record.project, record.id])
	return A.eq(identities, ["Code Review/alpha/type-1", "Code Review/Zulu/type-2", "Code Review/Zulu/old_review", "discussion/Zulu/discussion"], "label, project, slug/id tie-break order")


func test_search_matches_metadata_without_reordering() -> Variant:
	var records := TypeCatalog.from_schema(_schema(), "docket")
	var purpose_matches := TypeCatalog.filter(records, "APPROVAL")
	var r = A.eq(purpose_matches.size(), 1, "use-when match")
	if r != true: return r
	r = A.eq(purpose_matches[0].slug, "code_review", "metadata identifies code review")
	if r != true: return r
	var alias_matches := TypeCatalog.filter(records, "THREAD")
	r = A.eq(alias_matches.size(), 1, "alias match is case insensitive")
	if r != true: return r
	return A.eq(alias_matches[0].item_count, 0, "active zero-count type remains discoverable")

func test_large_catalog_keeps_alphabetical_order_after_metadata_search() -> Variant:
	var schema := {"types": {}}
	for i in 350:
		var slug := "type_%03d" % i
		schema.types[slug] = {"label": "Label %03d" % (349 - i), "description": "batch-even" if i % 2 == 0 else "batch-odd", "states": []}
	var matches := TypeCatalog.filter(TypeCatalog.from_schema(schema), "batch-even")
	var r = A.eq(matches.size(), 175, "all metadata matches retained")
	if r != true: return r
	for i in range(1, matches.size()):
		if str(matches[i - 1].label).nocasecmp_to(str(matches[i].label)) > 0: return "large filtered catalog is not alphabetical"
	return true


func test_deprecated_types_require_explicit_option() -> Variant:
	var records := TypeCatalog.from_schema(_schema())
	var hidden := TypeCatalog.filter(records, "historical")
	var shown := TypeCatalog.filter(records, "historical", true)
	var r = A.eq(hidden.size(), 0, "deprecated hidden by default")
	if r != true: return r
	return A.eq(shown[0].slug, "old_review", "deprecated available for historical query")


func test_discussion_scope_only_offers_discussion_states() -> Variant:
	var catalog := TypeCatalog.from_schema(_schema())
	var groups := QueryTypeScope.statuses(catalog, {"known": true, "identities": [], "types": ["discussion"]})
	var r = A.eq(groups.size(), 1, "one selected type group")
	if r != true: return r
	return A.eq(groups[0].values, ["active", "resolved"], "discussion states")


func test_multiple_types_keep_separate_status_groups() -> Variant:
	var groups := QueryTypeScope.statuses(TypeCatalog.from_schema(_schema()), {"known": true, "identities": [], "types": ["discussion", "code_review"]})
	var values_by_type := {}
	for group in groups:
		values_by_type[group.type] = group.values
	var r = A.eq(values_by_type.discussion, ["active", "resolved"], "discussion group")
	if r != true: return r
	return A.eq(values_by_type.code_review, ["requested", "approved"], "review group")


func test_or_branches_do_not_share_type_scope() -> Variant:
	var conditions := [
		{"field": "type", "op": "eq", "value": "discussion"},
		{"field": "status", "op": "eq", "value": "active", "conj": "and"},
		{"field": "type", "op": "eq", "value": "code_review", "conj": "or"},
		{"field": "status", "op": "eq", "value": "requested", "conj": "and"},
	]
	var r = A.eq(QueryTypeScope.branch_scope(conditions, 1).types, ["discussion"], "first branch scope")
	if r != true: return r
	return A.eq(QueryTypeScope.branch_scope(conditions, 3).types, ["code_review"], "second branch scope")


func test_and_type_predicates_intersect() -> Variant:
	var conditions := [
		{"field": "type", "op": "in", "value": ["discussion", "code_review"]},
		{"field": "type", "op": "eq", "value": "discussion", "conj": "and"},
	]
	var scope := QueryTypeScope.branch_scope(conditions, 1)
	var r = A.is_true(scope.known, "positive type scope recognized")
	if r != true: return r
	return A.eq(scope.types, ["discussion"], "AND computes intersection")


func test_scope_retains_valid_and_reports_incompatible_values() -> Variant:
	var catalog := TypeCatalog.from_schema(_schema())
	var retained := QueryTypeScope.validate_value("status", "active", catalog, {"known": true, "identities": [], "types": ["discussion"]})
	var invalidated := QueryTypeScope.validate_value("status", "active", catalog, {"known": true, "identities": [], "types": ["code_review"]})
	var r = A.is_true(retained.valid, "valid state retained")
	if r != true: return r
	r = A.is_false(invalidated.valid, "incompatible state invalidated")
	if r != true: return r
	return A.is_true(str(invalidated.message).contains("active"), "message identifies retained literal")


func test_type_scoped_fields_are_a_union() -> Variant:
	var fields := QueryTypeScope.fields(TypeCatalog.from_schema(_schema()), {"known": true, "identities": [], "types": ["discussion", "code_review"]})
	var r = A.is_true(fields.has("priority"), "discussion field")
	if r != true: return r
	r = A.is_true(fields.has("revision"), "review field")
	if r != true: return r
	return A.is_true(fields.has("title"), "shared field")


func test_type_chooser_keeps_selection_when_search_hides_it() -> Variant:
	var chooser := TypeChooser.new()
	add_child(chooser)
	var catalog := TypeCatalog.from_schema(_schema(), "alpha")
	chooser.configure(catalog, "chooser-test")
	var keys := [catalog[0].key, catalog[1].key]
	chooser.set_selected_values(keys)
	chooser._search.text = "approval"
	chooser._rebuild()
	var r = A.eq(chooser.selected_values(), keys, "search does not discard hidden selections")
	chooser.queue_free()
	return r

func test_type_chooser_supports_focusable_keyboard_multiselect() -> Variant:
	var catalog := TypeCatalog.from_schema(_schema(), "Alpha")
	var chooser := TypeChooser.new(); add_child(chooser); chooser.configure(catalog, "keyboard-test")
	var original_count := chooser._list.item_count
	chooser._list.select(0, false); chooser._on_selection_changed(0)
	chooser._list.select(1, false); chooser._on_selection_changed(1)
	var r = A.eq(chooser._list.select_mode, ItemList.SELECT_MULTI, "list exposes persistent multi-selection")
	if r != true: chooser.queue_free(); return r
	r = A.eq(chooser._list.focus_mode, Control.FOCUS_ALL, "catalog accepts keyboard focus")
	if r != true: chooser.queue_free(); return r
	r = A.eq(chooser.selected_values().size(), 2, "two keyboard-addressable rows remain selected")
	if r != true: chooser.queue_free(); return r
	r = A.eq(chooser._list.item_count, original_count, "successive selection does not rebuild or reposition catalog")
	if r != true: chooser.queue_free(); return r
	chooser._pinned = [catalog[0].key]; chooser._rebuild()
	r = A.eq(chooser._shortcut_box.get_child(1).focus_mode, Control.FOCUS_ALL, "shortcut action participates in keyboard focus")
	chooser.queue_free(); return r

func test_search_down_moves_focus_and_selection_to_catalog() -> Variant:
	var chooser := TypeChooser.new(); add_child(chooser); chooser.configure(TypeCatalog.from_schema(_schema(), "Alpha"), "input-test")
	chooser._search.grab_focus()
	var down := InputEventKey.new(); down.pressed = true; down.keycode = KEY_DOWN
	chooser._on_search_gui_input(down)
	var r = A.is_true(chooser._list.has_focus(), "Down transfers focus from search to results")
	if r != true: chooser.queue_free(); return r
	r = A.eq(chooser._list.get_selected_items(), PackedInt32Array([0]), "Down establishes a selectable current row")
	chooser.queue_free(); return r

func test_popup_opens_below_anchor_with_opaque_bounded_content() -> Variant:
	var chooser := TypeChooser.new(); add_child(chooser); chooser.configure(TypeCatalog.from_schema(_schema(), "Alpha"), "popup-test")
	chooser._button.pressed.emit()
	var minimum_y := roundi(chooser._button.get_screen_position().y + chooser._button.size.y)
	var r = A.is_true(chooser._popup.visible, "button activation opens popup")
	if r != true: chooser.queue_free(); return r
	r = A.is_true(chooser._popup.position.y >= minimum_y, "popup starts below invoking button")
	if r != true: chooser.queue_free(); return r
	r = A.is_false(chooser._popup.transparent_bg, "popup owns an opaque background")
	if r != true: chooser.queue_free(); return r
	r = A.is_true(chooser._popup.size.y <= 400, "popup height remains bounded")
	chooser._popup.hide(); chooser.queue_free(); return r

func test_catalog_row_separates_count_and_moves_purpose_to_tooltip() -> Variant:
	var chooser := TypeChooser.new(); add_child(chooser); chooser.configure(TypeCatalog.from_schema(_schema(), "Alpha", {"discussion": 1}), "row-test")
	var discussion_index := -1
	for i in chooser._list.item_count:
		if chooser._list.get_item_text(i).begins_with("discussion"): discussion_index = i
	var text := chooser._list.get_item_text(discussion_index)
	var r = A.is_true(text.contains("·  1 item  —  Async decisions") and not text.contains("\n"), "row visibly separates count and brief purpose")
	if r != true: chooser.queue_free(); return r
	r = A.is_true(chooser._list.get_item_tooltip(discussion_index).contains("Async decisions"), "purpose remains available as detail")
	chooser.queue_free(); return r

func test_query_grid_refreshes_empty_catalog_after_loading_legacy_project() -> Variant:
	var state := AppState.new(); state.schema = _schema()
	var grid := QueryGrid.new(); add_child(grid); grid.init(state)
	grid._condition_rows[0].type_chooser._search.text = "discussion"
	var db := _make_db("Loaded", [{"type": "discussion", "status": "active", "title": "Loaded thread"}])
	db.close(); _dbs.erase(db)
	state.load_dct(_db_dir + "/Loaded.dct")
	_dbs.append(state.db)
	var chooser: TypeChooser = grid._condition_rows[0].type_chooser
	var r = A.eq(chooser._search.text, "discussion", "catalog refresh preserves active search")
	if r != true: grid.queue_free(); return r
	r = A.eq(chooser._list.item_count, 1, "loaded catalog replaces empty choices")
	if r != true: grid.queue_free(); return r
	r = A.is_true(chooser._list.get_item_text(0).contains("Loaded") and chooser._list.get_item_text(0).contains("1 item"), "loaded project and live count are shown")
	if r != true: grid.queue_free(); return r
	chooser.set_selected_values([chooser._list.get_item_metadata(0)]); grid._user_has_modified = true; grid._run_query()
	r = A.eq(grid._current_results.size(), 1, "refreshed choice executes against loaded file")
	grid.queue_free(); return r

func test_duplicate_slug_selection_uses_catalog_identity_and_human_label() -> Variant:
	var catalog := TypeCatalog.from_schema(_schema(), "Alpha")
	catalog.append_array(TypeCatalog.from_schema(_schema(), "Beta"))
	var chooser := TypeChooser.new(); add_child(chooser); chooser.configure(catalog, "duplicate-test")
	var alpha_key := ""
	for record in catalog:
		if record.project == "Alpha" and record.slug == "discussion": alpha_key = record.key
	chooser.set_selected_values([alpha_key])
	var r = A.eq(chooser._button.text, "discussion — Alpha", "duplicate label disambiguates project")
	if r != true: chooser.queue_free(); return r
	r = A.eq(chooser._list.get_selected_items().size(), 1, "same slug in other project stays unselected")
	chooser.queue_free(); return r

func test_shortcut_button_selects_type_without_reordering_catalog() -> Variant:
	var catalog := TypeCatalog.from_schema(_schema(), "Alpha")
	var chooser := TypeChooser.new(); add_child(chooser); chooser.configure(catalog, "shortcut-test")
	var key: String = str(catalog[0].key)
	chooser._pinned = [key]; chooser._rebuild()
	var before := []
	for i in chooser._list.item_count: before.append(chooser._list.get_item_metadata(i))
	chooser._activate_shortcut(key)
	var after := []
	for i in chooser._list.item_count: after.append(chooser._list.get_item_metadata(i))
	var r = A.eq(chooser.selected_values(), [key], "shortcut is actionable")
	if r != true: chooser.queue_free(); return r
	r = A.eq(after, before, "shortcut does not reorder main list")
	chooser.queue_free(); return r

func test_unknown_historical_selection_remains_visible() -> Variant:
	var chooser := TypeChooser.new(); add_child(chooser); chooser.configure([], "unknown-test")
	chooser.set_selected_values(["retired-type-id"])
	var r = A.is_true(chooser._button.text.contains("Unknown historical type"), "unknown selection is visible")
	chooser.queue_free(); return r


func test_membership_operator_translates_to_bound_in_predicate() -> Variant:
	DocketDBFilter.set_allowed_fields(["type"])
	var translated := DocketDBFilter.translate_conditions([{"field": "type", "op": "in", "value": ["discussion", "code_review"]}])
	var r = A.eq(translated.where, "type IN (?,?)", "membership SQL")
	if r != true: return r
	return A.eq(translated.bindings, ["discussion", "code_review"], "values remain bound")


func test_cross_project_binding_preserves_or_branches() -> Variant:
	var state := AppState.new()
	var query := {"filter": {"conditions": [
		{"field": "project", "op": "eq", "value": "alpha"},
		{"field": "type", "op": "eq", "value": "discussion", "conj": "and"},
		{"field": "type", "op": "eq", "value": "code_review", "conj": "or"},
	]}}
	var alpha: Array = state._bind_project_conditions(query, "alpha").query.filter.conditions
	var beta: Array = state._bind_project_conditions(query, "beta").query.filter.conditions
	var r = A.eq(alpha[0].op, "is_not_empty", "matching project keeps first branch true")
	if r != true: return r
	r = A.eq(beta[0].value, [], "other project disables only scoped branch")
	if r != true: return r
	return A.eq(beta[2].conj, "or", "independent sibling branch is retained")

func test_cross_project_or_query_returns_database_rows_from_independent_branches() -> Variant:
	var state := _two_project_state()
	var query := {"filter": {"$or": [{"$and": [{"field": "project", "op": "eq", "value": "Alpha"}, {"field": "type", "op": "eq", "value": "discussion"}]}, {"$and": [{"field": "project", "op": "eq", "value": "Beta"}, {"field": "status", "op": "eq", "value": "approved"}]}]}}
	var rows := state.execute_cross_project_query(query)
	var titles := []
	for row in rows: titles.append(row.title)
	titles.sort()
	return A.eq(titles, ["Alpha thread", "Beta review"], "OR branches keep their own project predicates")

func test_project_in_and_empty_operators_do_not_widen_results() -> Variant:
	var state := _two_project_state()
	var in_rows := state.execute_cross_project_query({"filter": {"conditions": [{"field": "project", "op": "in", "value": ["Beta"]}]}})
	var r = A.eq(in_rows.size(), 3, "project in selects only requested database")
	if r != true: return r
	var empty_rows := state.execute_cross_project_query({"filter": {"conditions": [{"field": "project", "op": "is_empty"}]}})
	return A.eq(empty_rows.size(), 0, "named projects do not satisfy is_empty")

func test_unsupported_project_operator_reports_actionable_error() -> Variant:
	var state := _two_project_state()
	var rows := state.execute_cross_project_query({"filter": {"conditions": [{"field": "project", "op": "gt", "value": "Alpha"}]}})
	var r = A.eq(rows.size(), 0, "unsupported query refused")
	if r != true: return r
	return A.is_true(state.last_cross_project_query_error.contains("gt"), "error identifies operator")

func test_query_grid_serializes_project_identity_and_executes_only_that_project() -> Variant:
	var state := _two_project_state()
	var grid := QueryGrid.new(); add_child(grid); grid.init(state)
	var alpha_key := ""
	for record in grid._type_catalog:
		if record.project == "Alpha" and record.slug == "discussion": alpha_key = record.key
	grid._condition_rows[0].type_chooser.set_selected_values([alpha_key]); grid._user_has_modified = true
	var saved = JSON.parse_string(grid.get_filter())
	var r = A.eq(saved.conditions[0].op, "catalog_in", "saved UI filter retains stable identity")
	if r != true: grid.queue_free(); return r
	grid._run_query()
	r = A.eq(grid._current_results.size(), 1, "compiled selection returns one project row")
	if r != true: grid.queue_free(); return r
	r = A.eq(grid._current_results[0].title, "Alpha thread", "duplicate Beta slug excluded")
	grid.queue_free(); return r

func test_query_grid_multiselect_keeps_each_project_type_pair_coupled() -> Variant:
	var state := _two_project_state()
	var grid := QueryGrid.new(); add_child(grid); grid.init(state)
	var keys: Array = []
	for record in grid._type_catalog:
		if (record.project == "Alpha" and record.slug == "discussion") or (record.project == "Beta" and record.slug == "code_review"): keys.append(record.key)
	grid._condition_rows[0].type_chooser.set_selected_values(keys); grid._user_has_modified = true; grid._run_query()
	var titles: Array = []
	for item in grid._current_results: titles.append(item.title)
	titles.sort()
	var r = A.eq(titles, ["Alpha thread", "Beta requested review", "Beta review"], "multiselect retains project/type pair identity")
	grid.queue_free(); return r

func test_shortcut_actions_enforce_caps_and_persist_recency_order() -> Variant:
	var schema := {"types": {}}
	for i in 55: schema.types["kind_%02d" % i] = {"label": "Kind %02d" % i, "states": []}
	var catalog := TypeCatalog.from_schema(schema, "Alpha")
	var chooser := TypeChooser.new(); add_child(chooser); chooser.configure(catalog, "shortcut-boundary")
	for i in 14:
		chooser._list.deselect_all(); chooser._list.select(i); chooser._on_selection_changed(i)
	var r = A.eq(chooser._recent.size(), UserPrefs.MAX_QUERY_TYPE_RECENTS, "normal selection caps recents")
	if r != true: chooser.queue_free(); return r
	chooser._activate_shortcut(catalog[5].key)
	r = A.eq(chooser._recent[0], catalog[5].key, "shortcut activation moves entry to front")
	if r != true: chooser.queue_free(); return r
	r = A.eq(UserPrefs.load_type_shortcuts("shortcut-boundary").recent, chooser._recent, "action order persists")
	if r != true: chooser.queue_free(); return r
	chooser._pinned = []
	for i in UserPrefs.MAX_QUERY_TYPE_PINS: chooser._pinned.append(catalog[i].key)
	var before := chooser._pinned.duplicate()
	chooser._on_item_clicked(UserPrefs.MAX_QUERY_TYPE_PINS, Vector2.ZERO, MOUSE_BUTTON_RIGHT)
	r = A.eq(chooser._pinned, before, "pin cap does not displace an existing pin")
	if r != true: chooser.queue_free(); return r
	r = A.is_true(chooser._shortcut_error.visible and chooser._shortcut_error.text.contains("50"), "pin cap is visibly explained")
	chooser.queue_free(); return r

func test_legacy_unqualified_filter_round_trips_without_rebinding() -> Variant:
	var state := _two_project_state()
	var grid := QueryGrid.new(); add_child(grid); grid.init(state)
	var original := {"conditions": [{"field": "type", "op": "eq", "value": "discussion"}]}
	grid.set_filter(JSON.stringify(original))
	var path := _db_dir + "/legacy.dcq"
	grid.save_dcq(path)
	var reopened := QueryGrid.new(); add_child(reopened); reopened.init(state); reopened.load_dcq(path)
	var saved = JSON.parse_string(reopened.get_filter())
	var r = A.eq(saved, original, "legacy literal survives dcq save and load")
	grid.queue_free(); reopened.queue_free(); return r

func test_grouped_status_roundtrip_keeps_exact_project_identity() -> Variant:
	var state := _two_project_state()
	var grid := QueryGrid.new(); add_child(grid); grid.init(state)
	var alpha_key := ""
	for record in grid._type_catalog:
		if record.project == "Alpha" and record.slug == "code_review": alpha_key = record.key
	var original := {"conditions": [{"field": "status", "op": "catalog_status", "value": {"key": alpha_key, "status": "requested"}}]}
	grid.set_filter(JSON.stringify(original))
	var path := _db_dir + "/grouped-status.dcq"
	grid.save_dcq(path)
	var reopened := QueryGrid.new(); add_child(reopened); reopened.init(state); reopened.load_dcq(path)
	var saved = JSON.parse_string(reopened.get_filter())
	var r = A.eq(saved, original, "group identity survives UI and dcq round trip")
	if r != true: grid.queue_free(); reopened.queue_free(); return r
	r = A.eq(reopened._current_results.size(), 1, "same literal in another project remains excluded")
	if r != true: grid.queue_free(); reopened.queue_free(); return r
	r = A.eq(reopened._current_results[0].title, "Alpha review", "reloaded query executes against original group")
	grid.queue_free(); reopened.queue_free(); return r

func test_incompatible_status_remains_visible_in_query_grid() -> Variant:
	var state := _two_project_state()
	var grid := QueryGrid.new(); add_child(grid); grid.init(state)
	grid.set_filter(JSON.stringify({"conditions": [{"field": "type", "op": "eq", "value": "code_review"}, {"field": "status", "op": "eq", "value": "active", "conj": "and"}]}))
	var row: Dictionary = grid._condition_rows[1]
	var r = A.is_true(row.validation.visible, "incompatible condition is visibly invalid")
	if r != true: grid.queue_free(); return r
	r = A.eq(grid._dropdown_stored_value(row.value_dropdown), "active", "literal selection retained")
	grid.queue_free(); return r
