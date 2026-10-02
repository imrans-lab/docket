extends Node
## Tests that query filter fields are validated before becoming SQL identifiers.
##
## Field names cannot be parameter-bound — SQLite has no placeholder for a column
## name — so they are interpolated. Without validation, a filter field of
## `title="x" OR 1=1 OR title` rewrites the WHERE clause and returns every row.
## This was reachable through docket_query over MCP.

var A := AssertHelpers
var _test_dir := "user://test_query_field_validation"
var _path: String
var _db: DocketDBJsonl

const INJECTION := 'title="zzz" OR 1=1 OR title'


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func before_each() -> void:
	_path = _test_dir + "/q.dct"
	_cleanup()
	_db = DocketDBJsonl.create_new_jsonl(_path)
	for title in ["alpha", "beta", "gamma"]:
		_db.insert_item(title, {
			"id": title, "type": "bug", "status": "new", "title": title,
			"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		})


func after_each() -> void:
	if _db:
		_db.close()
		_db = null


func _cleanup() -> void:
	for suffix: String in ["", ".cache", ".cache-wal", ".cache-shm", ".v2.cache", ".v2.cache-wal", ".v2.cache-shm", ".lock"]:
		var p := _path + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func teardown() -> void:
	_cleanup()
	DirAccess.remove_absolute(_test_dir)


# -- Legitimate queries must keep working -------------------------------------

func test_valid_field_filters_normally() -> Variant:
	var r := _db.execute_query({"filter": {"conditions": [
		{"field": "title", "op": "eq", "value": "alpha"}]}})
	return A.eq(r.size(), 1, "valid field returns the matching row")


func test_pseudo_field_tags_still_allowed() -> Variant:
	var r := _db.execute_query({"filter": {"conditions": [
		{"field": "tags", "op": "eq", "value": "nothing"}]}})
	return A.eq(r.size(), 0, "tags pseudo-field is accepted and matches nothing")


func test_unfiltered_query_returns_all() -> Variant:
	return A.eq(_db.execute_query({}).size(), 3, "no filter returns everything")


# -- Injection must be refused, not silently widened --------------------------

func test_injection_via_conditions_list_is_refused() -> Variant:
	var r := _db.execute_query({"filter": {"conditions": [
		{"field": INJECTION, "op": "eq", "value": "alpha"}]}})
	var e = A.eq(r.size(), 0, "injected field returns no rows")
	if e != true:
		return e
	return A.contains(_db.last_query_error, "unknown query field", "refusal is reported")


func test_injection_via_flat_dict_is_refused() -> Variant:
	var r := _db.execute_query({"filter": {INJECTION: "alpha"}})
	var e = A.eq(r.size(), 0, "injected key returns no rows")
	if e != true:
		return e
	return A.is_true(not _db.last_query_error.is_empty(), "refusal is reported")


func test_injection_via_tree_is_refused() -> Variant:
	var r := _db.execute_query({"filter": {"$or": [
		{"field": INJECTION, "op": "eq", "value": "alpha"}]}})
	var e = A.eq(r.size(), 0, "injected field in a tree returns no rows")
	if e != true:
		return e
	return A.is_true(not _db.last_query_error.is_empty(), "refusal is reported")


func test_injection_via_ne_suffix_is_refused() -> Variant:
	var r := _db.execute_query({"filter": {(INJECTION + "__ne"): "alpha"}})
	return A.eq(r.size(), 0, "__ne suffix path is validated too")


func test_refusal_does_not_widen_results() -> Variant:
	## The dangerous failure mode: dropping the offending condition instead of
	## refusing would return every row rather than none.
	var r := _db.execute_query({"filter": {"conditions": [
		{"field": INJECTION, "op": "eq", "value": "alpha"}]}})
	return A.is_true(r.size() < 3, "a refused filter never returns the full table")


func test_unknown_but_harmless_field_is_refused() -> Variant:
	## Not an attack, but a typo should say so rather than return everything.
	var r := _db.execute_query({"filter": {"conditions": [
		{"field": "titel", "op": "eq", "value": "alpha"}]}})
	var e = A.eq(r.size(), 0, "typo'd field returns nothing")
	if e != true:
		return e
	return A.contains(_db.last_query_error, "titel", "error names the bad field")


# -- The allowlist itself -----------------------------------------------------

func test_allowlist_is_derived_from_the_live_table() -> Variant:
	## Derived from PRAGMA rather than hand-kept, so it cannot drift as columns
	## are added. Checks a column absent from the old hardcoded sort list.
	_db.execute_query({})  # populates the allowlist
	var r = A.is_true(DocketDBFilter.is_field_allowed("title"), "known column allowed")
	if r != true:
		return r
	r = A.is_true(DocketDBFilter.is_field_allowed("tool_deps"),
		"column missing from the legacy sort list is still allowed")
	if r != true:
		return r
	return A.is_true(not DocketDBFilter.is_field_allowed(INJECTION), "injection rejected")


func test_last_query_error_clears_on_success() -> Variant:
	_db.execute_query({"filter": {"conditions": [{"field": INJECTION, "op": "eq", "value": "x"}]}})
	var r = A.is_true(not _db.last_query_error.is_empty(), "error set after refusal")
	if r != true:
		return r
	_db.execute_query({"filter": {"conditions": [{"field": "title", "op": "eq", "value": "alpha"}]}})
	return A.eq(_db.last_query_error, "", "error cleared after a good query")


func test_flat_parent_parity_and_malformed_filter_errors() -> Variant:
	var parent: String = "01a0febd44bc7fc88516167dcdc577c5"
	for pair: Array in [["alpha", parent], ["beta", "Other:" + parent], ["gamma", "Other:different"]]:
		var error: String = _db._exec_checked("UPDATE items SET parent=? WHERE id=?;", [pair[1], pair[0]])
		if not error.is_empty(): return error
	var flat: Array = _db.execute_query({"filter":{"parent":parent}, "sort":[{"field":"id"}]})
	var conditions: Array = _db.execute_query({"filter":{"conditions":[{"field":"parent", "op":"eq", "value":parent}]}, "sort":[{"field":"id"}]})
	var result: Variant = A.is_true(flat.size() == 2 and flat == conditions, "bare full parent id matches both bare and qualified parents identically")
	if result is String: return result
	var qualified: Array = _db.execute_query({"filter":{"parent":"Other:" + parent}})
	var qualified_conditions: Array = _db.execute_query({"filter":{"conditions":[{"field":"parent", "op":"eq", "value":"Other:" + parent}]}})
	result = A.is_true(qualified.size() == 1 and qualified[0].id == "beta" and qualified == qualified_conditions, "qualified parent remains exact in both forms")
	if result is String: return result
	var prefix_flat: Array = _db.execute_query({"filter":{"parent":"01a0febd"}})
	var prefix_conditions: Array = _db.execute_query({"filter":{"conditions":[{"field":"parent", "op":"eq", "value":"01a0febd"}]}})
	result = A.is_true(prefix_flat.is_empty() and prefix_conditions.is_empty(), "short parent prefix matches nothing in either form")
	if result is String: return result
	var refused: Array = _db.execute_query({"filter":{"title":{"$contains":"x"}}})
	result = A.is_true(refused.is_empty() and _db.last_query_error.contains("title") and _db.last_query_error.contains("conditions"), "flat object value explains the key and supported grammar")
	if result is String: return result
	var registry: TypeRegistry = TypeRegistry.for_db(_db, _db.get_project_name())
	for typed: bool in [false, true]:
		var valid_tree: Dictionary = {"filter":{"$and":[{"field":"title", "op":"eq", "value":"alpha"}]}}
		var valid_rows: Array = _db.execute_registry_query(valid_tree, registry) if typed else _db.execute_query(valid_tree)
		result = A.is_true(valid_rows.size() == 1 and valid_rows[0].id == "alpha" and _db.last_query_error.is_empty(), "valid boolean grammar still queries normally")
		if result is String: return result
		for filter: Dictionary in [
			{"$or":[{"parent":parent}]}, {"$and":[42]},
			{"$and":[{"field":"title", "op":"in", "value":[]}, {"parent":parent}]},
			{"$and":[{"field":"id", "op":"in", "value":[]}, {"$or":[{"parent":parent}]}]},
		]:
			refused = _db.execute_registry_query({"filter":filter}, registry) if typed else _db.execute_query({"filter":filter})
			result = A.is_true(refused.is_empty() and _db.last_query_error == "branches take condition objects {field, op, value}", "malformed branches refuse before empty-predicate shortcuts (typed=%s): %s" % [typed, _db.last_query_error])
			if result is String: return result
	var catalog: Array = TypeCatalog.from_registry(registry)
	var selected: Array[String] = []
	for entry: Dictionary in catalog:
		if entry.slug in ["bug", "work_item"]: selected.append(str(entry.key))
	if selected.size() != 2: return "binding-error fixture requires bug and work_item definitions"
	var scoped_tree: Dictionary = QueryTypeScope.compile_catalog_conditions([
		{"field":"type", "op":"catalog_in", "value":selected},
		{"field":"future_field", "op":"eq", "value":"x"},
	], catalog, false)
	refused = _db.execute_registry_query({"filter":scoped_tree}, registry)
	return A.is_true(refused.is_empty() and _db.last_query_error == "Field 'future_field' is not compatible across the selected type identities.", "GUI-generated binding error preserves its precise diagnostic: %s" % _db.last_query_error)
