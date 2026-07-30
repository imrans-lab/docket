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
	for suffix: String in ["", ".cache", ".cache-wal", ".cache-shm", ".lock"]:
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
