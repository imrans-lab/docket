extends Node
## Unit tests for DocketDB (SQLite backend).

var A := AssertHelpers
var _db: DocketDB
var _test_dir := "user://test_docket_db"
var _test_file: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_test_file = _test_dir + "/test_db.dct"


func before_each() -> void:
	_cleanup_db()
	_db = DocketDB.create_new(_test_file)


func _cleanup_db() -> void:
	if _db:
		_db.close()
		_db = null
	for suffix: String in ["", "-wal", "-shm"]:
		var p: String = _test_file + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func teardown() -> void:
	_cleanup_db()
	var dir := DirAccess.open(_test_dir)
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			dir.remove(fname)
			fname = dir.get_next()
		DirAccess.remove_absolute(_test_dir)


# -- Lifecycle ----------------------------------------------------------------

func test_create_new() -> Variant:
	return A.is_true(_db.is_open(), "db is open after create_new")


func test_open_close() -> Variant:
	_db.close()
	var r = A.is_false(_db.is_open(), "closed")
	if r is String: return r
	var ok := _db.open(_test_file)
	r = A.is_true(ok, "reopened")
	if r is String: return r
	return A.is_true(_db.is_open(), "is open after reopen")


# -- ID generation ------------------------------------------------------------

func test_next_id() -> Variant:
	var prefix := _db.get_id_prefix()
	var id1 := _db.next_id()
	var r = A.eq(id1, "%s-0001" % prefix, "first id")
	if r is String: return r
	var id2 := _db.next_id()
	return A.eq(id2, "%s-0002" % prefix, "second id")


func test_counter_persistence() -> Variant:
	var prefix := _db.get_id_prefix()
	_db.next_id()
	_db.next_id()
	_db.close()
	_db = DocketDB.new()
	_db.open(_test_file)
	var id := _db.next_id()
	return A.eq(id, "%s-0003" % prefix, "counter persisted across close/open")


# -- Item CRUD ----------------------------------------------------------------

func test_insert_and_get() -> Variant:
	var item := {
		"type": "bug", "status": "new", "title": "Test bug",
		"description": "desc", "created_at": "2026-01-01T00:00:00",
		"updated_at": "2026-01-01T00:00:00", "priority": 1, "severity": 2,
		"tags": ["api", "urgent"],
		"events": [{"event_type": "created", "actor": "test", "timestamp": "2026-01-01T00:00:00", "note": "Created"}],
		"links": [],
	}
	_db.insert_item("DKT-0001", item)

	var got := _db.get_item("DKT-0001")
	var r = A.eq(got.id, "DKT-0001")
	if r is String: return r
	r = A.eq(got.type, "bug")
	if r is String: return r
	r = A.eq(got.title, "Test bug")
	if r is String: return r
	r = A.eq(got.priority, 1)
	if r is String: return r
	r = A.eq(got.tags.size(), 2, "two tags")
	if r is String: return r
	r = A.contains(got.tags, "api")
	if r is String: return r
	return A.eq(got.events.size(), 1, "one event")


func test_has_item() -> Variant:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": [], "events": [], "links": []})
	var r = A.is_true(_db.has_item("DKT-0001"), "has DKT-0001")
	if r is String: return r
	return A.is_false(_db.has_item("DKT-9999"), "doesn't have DKT-9999")


func test_update_fields() -> Variant:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "Old",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"priority": 0, "tags": ["old"], "events": [], "links": []})

	_db.update_item_fields("DKT-0001", {"title": "New", "priority": 3, "tags": ["new", "updated"]})

	var got := _db.get_item("DKT-0001")
	var r = A.eq(got.title, "New")
	if r is String: return r
	r = A.eq(got.priority, 3)
	if r is String: return r
	r = A.eq(got.tags.size(), 2)
	if r is String: return r
	return A.contains(got.tags, "updated")


func test_set_item_field() -> Variant:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": [], "events": [], "links": []})
	_db.set_item_field("DKT-0001", "status", "active")
	var got := _db.get_item("DKT-0001")
	return A.eq(got.status, "active")


# -- Events -------------------------------------------------------------------

func test_add_and_get_events() -> Variant:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": [], "events": [], "links": []})
	_db.add_event("DKT-0001", "transition", "agent", "new -> active")
	var events := _db.get_events("DKT-0001")
	var r = A.eq(events.size(), 1)
	if r is String: return r
	return A.eq(events[0].event_type, "transition")


# -- Links --------------------------------------------------------------------

func test_add_and_get_links() -> Variant:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "A",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": [], "events": [], "links": []})
	_db.insert_item("DKT-0002", {"type": "rca", "status": "detected", "title": "B",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": [], "events": [], "links": []})
	_db.add_link("DKT-0001", "DKT-0002", "caused_by")
	var links := _db.get_links("DKT-0001")
	var r = A.eq(links.size(), 1)
	if r is String: return r
	r = A.eq(links[0].to, "DKT-0002")
	if r is String: return r
	return A.eq(links[0].relation, "caused_by")


# -- Query execution ----------------------------------------------------------

func test_query_all() -> Variant:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "A",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": [], "events": [], "links": []})
	_db.insert_item("DKT-0002", {"type": "chore", "status": "open", "title": "B",
		"created_at": "2026-01-02T00:00:00", "updated_at": "2026-01-02T00:00:00",
		"tags": [], "events": [], "links": []})
	var results := _db.execute_query({})
	return A.eq(results.size(), 2, "both items")


func test_query_filter_exact() -> Variant:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "A",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": [], "events": [], "links": []})
	_db.insert_item("DKT-0002", {"type": "chore", "status": "open", "title": "B",
		"created_at": "2026-01-02T00:00:00", "updated_at": "2026-01-02T00:00:00",
		"tags": [], "events": [], "links": []})
	var results := _db.execute_query({"filter": {"type": "bug"}})
	return A.eq(results.size(), 1, "one bug")


func test_query_filter_ne() -> Variant:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "A",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": [], "events": [], "links": []})
	_db.insert_item("DKT-0002", {"type": "chore", "status": "open", "title": "B",
		"created_at": "2026-01-02T00:00:00", "updated_at": "2026-01-02T00:00:00",
		"tags": [], "events": [], "links": []})
	var results := _db.execute_query({"filter": {"type__ne": "bug"}})
	return A.eq(results.size(), 1, "one non-bug")


func test_query_filter_in() -> Variant:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "A",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": [], "events": [], "links": []})
	_db.insert_item("DKT-0002", {"type": "chore", "status": "open", "title": "B",
		"created_at": "2026-01-02T00:00:00", "updated_at": "2026-01-02T00:00:00",
		"tags": [], "events": [], "links": []})
	_db.insert_item("DKT-0003", {"type": "dcr", "status": "proposed", "title": "C",
		"created_at": "2026-01-03T00:00:00", "updated_at": "2026-01-03T00:00:00",
		"tags": [], "events": [], "links": []})
	var results := _db.execute_query({"filter": {"type__in": ["bug", "chore"]}})
	return A.eq(results.size(), 2, "bug + chore")


func test_query_filter_tags_contains() -> Variant:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "A",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": ["api", "urgent"], "events": [], "links": []})
	_db.insert_item("DKT-0002", {"type": "bug", "status": "new", "title": "B",
		"created_at": "2026-01-02T00:00:00", "updated_at": "2026-01-02T00:00:00",
		"tags": ["ui"], "events": [], "links": []})
	var results := _db.execute_query({"filter": {"tags_contains": "api"}})
	return A.eq(results.size(), 1, "one item tagged api")


func test_query_sort() -> Variant:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "Low",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"priority": 3, "tags": [], "events": [], "links": []})
	_db.insert_item("DKT-0002", {"type": "bug", "status": "new", "title": "High",
		"created_at": "2026-01-02T00:00:00", "updated_at": "2026-01-02T00:00:00",
		"priority": 1, "tags": [], "events": [], "links": []})
	var results := _db.execute_query({"sort": [{"field": "priority", "dir": "asc"}]})
	return A.eq(results[0].priority, 1, "P1 first when asc")


func test_query_limit() -> Variant:
	for i in range(5):
		_db.insert_item("DKT-%04d" % (i + 1), {"type": "bug", "status": "new", "title": "Bug %d" % i,
			"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
			"tags": [], "events": [], "links": []})
	var results := _db.execute_query({"limit": 3})
	return A.eq(results.size(), 3, "limited to 3")


# -- Hint helpers -------------------------------------------------------------

func test_find_hint() -> Variant:
	_db.insert_item("DKT-0001", {"type": "hint", "status": "draft", "title": "test/run",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"component": "docket", "key": "test", "value": "godot --headless -- test",
		"tags": [], "events": [], "links": []})
	var hint := _db.find_hint("docket", "test")
	var r = A.is_false(hint.is_empty(), "found hint")
	if r is String: return r
	return A.eq(hint.value, "godot --headless -- test")


func test_bump_retrieval() -> Variant:
	_db.insert_item("DKT-0001", {"type": "hint", "status": "draft", "title": "test/run",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"component": "docket", "key": "test", "value": "cmd",
		"retrieval_count": 0,
		"tags": [], "events": [], "links": []})
	_db.bump_retrieval("DKT-0001")
	_db.bump_retrieval("DKT-0001")
	var item := _db.get_item("DKT-0001")
	return A.eq(item.retrieval_count, 2, "bumped twice")


# -- Saved queries ------------------------------------------------------------

func test_saved_query_roundtrip() -> Variant:
	_db.save_query("my-query", {"filter": {"type": "bug"}, "sort": [{"field": "priority"}]})
	var q := _db.load_query("my-query")
	var r = A.has_key(q, "filter")
	if r is String: return r
	return A.eq(q.filter.type, "bug")


func test_list_queries() -> Variant:
	_db.save_query("q1", {"filter": {}})
	_db.save_query("q2", {"filter": {"type": "chore"}})
	var queries := _db.list_queries()
	return A.eq(queries.size(), 2, "two saved queries")


# -- Rich filter engine -------------------------------------------------------

func _insert_test_items() -> void:
	_db.insert_item("DKT-0001", {"type": "bug", "status": "new", "title": "Bug fix login",
		"description": "Login fails for users", "created_at": "2026-01-01T00:00:00",
		"updated_at": "2026-01-01T00:00:00", "priority": 1, "severity": 3,
		"tags": ["api", "urgent"], "events": [], "links": []})
	_db.insert_item("DKT-0002", {"type": "dcr", "status": "proposed", "title": "Add dark mode",
		"description": "Users want a cat theme", "created_at": "2026-01-02T00:00:00",
		"updated_at": "2026-01-02T00:00:00", "priority": 2, "severity": 1,
		"tags": ["ui"], "events": [], "links": []})
	_db.insert_item("DKT-0003", {"type": "bug", "status": "active", "title": "Debugging crash",
		"description": "App crashes on dog photo upload", "created_at": "2026-01-03T00:00:00",
		"updated_at": "2026-01-03T00:00:00", "priority": 3, "severity": 2,
		"tags": ["ui", "urgent"], "events": [], "links": []})
	_db.insert_item("DKT-0004", {"type": "chore", "status": "open", "title": "Update deps",
		"description": "", "created_at": "2026-01-04T00:00:00",
		"updated_at": "2026-01-04T00:00:00", "priority": 4, "severity": 0,
		"tags": [], "events": [], "links": []})


func test_condition_eq() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "type", "op": "eq", "value": "bug"}
	]}})
	return A.eq(results.size(), 2, "two bugs")


func test_condition_neq() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "type", "op": "neq", "value": "bug"}
	]}})
	return A.eq(results.size(), 2, "two non-bugs")


func test_condition_and() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "type", "op": "eq", "value": "bug"},
		{"conj": "and", "field": "status", "op": "eq", "value": "new"}
	]}})
	return A.eq(results.size(), 1, "one new bug")


func test_condition_or() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "type", "op": "eq", "value": "bug"},
		{"conj": "or", "field": "type", "op": "eq", "value": "chore"}
	]}})
	return A.eq(results.size(), 3, "two bugs + one chore")


func test_condition_and_or_precedence() -> Variant:
	_insert_test_items()
	# type=dcr OR (type=bug AND status=active)
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "type", "op": "eq", "value": "dcr"},
		{"conj": "or", "field": "type", "op": "eq", "value": "bug"},
		{"conj": "and", "field": "status", "op": "eq", "value": "active"}
	]}})
	var r = A.eq(results.size(), 2, "dcr + active bug")
	if r is String: return r
	var types: Array = []
	for item in results:
		types.append(item.type)
	types.sort()
	return A.eq(types, ["bug", "dcr"], "correct types")


func test_condition_contains() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "description", "op": "contains", "value": "cat"}
	]}})
	return A.eq(results.size(), 1, "one item with 'cat' in description")


func test_condition_not_contains() -> Variant:
	_insert_test_items()
	# SQLite LIKE is case-insensitive, so "Debugging" also matches '%bug%'
	# Only "Add dark mode" and "Update deps" don't contain "bug"
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "title", "op": "not_contains", "value": "Bug"}
	]}})
	return A.eq(results.size(), 2, "two items without 'Bug' in title")


func test_condition_like_wildcards() -> Variant:
	_insert_test_items()
	# "Bug*" should match "Bug fix login" but not "Debugging crash"
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "title", "op": "like", "value": "Bug*"}
	]}})
	var r = A.eq(results.size(), 1, "one match for Bug*")
	if r is String: return r
	return A.eq(results[0].id, "DKT-0001", "correct item")


func test_condition_gt_lt() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "priority", "op": "gt", "value": 2}
	]}})
	var r = A.eq(results.size(), 2, "two items with priority > 2")
	if r is String: return r
	results = _db.execute_query({"filter": {"conditions": [
		{"field": "priority", "op": "lt", "value": 2}
	]}})
	return A.eq(results.size(), 1, "one item with priority < 2")


func test_condition_gte_lte() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "priority", "op": "gte", "value": 2}
	]}})
	var r = A.eq(results.size(), 3, "three items with priority >= 2")
	if r is String: return r
	results = _db.execute_query({"filter": {"conditions": [
		{"field": "priority", "op": "lte", "value": 2}
	]}})
	return A.eq(results.size(), 2, "two items with priority <= 2")


func test_condition_is_empty() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "description", "op": "is_empty"}
	]}})
	return A.eq(results.size(), 1, "one item with empty description")


func test_condition_is_not_empty() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "description", "op": "is_not_empty"}
	]}})
	return A.eq(results.size(), 3, "three items with non-empty description")


func test_condition_tags_eq() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "tags", "op": "eq", "value": "urgent"}
	]}})
	return A.eq(results.size(), 2, "two items tagged urgent")


func test_condition_tags_neq() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "tags", "op": "neq", "value": "urgent"}
	]}})
	return A.eq(results.size(), 2, "two items without urgent tag")


func test_condition_has_attachment() -> Variant:
	_insert_test_items()
	# Attach a file to DKT-0001
	_db.attach_file("DKT-0001", "test.txt", PackedByteArray([65, 66, 67]))
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "has_attachment", "op": "eq", "value": true}
	]}})
	var r = A.eq(results.size(), 1, "one item with attachment")
	if r is String: return r
	results = _db.execute_query({"filter": {"conditions": [
		{"field": "has_attachment", "op": "eq", "value": false}
	]}})
	return A.eq(results.size(), 3, "three items without attachment")


func test_tree_or_and() -> Variant:
	_insert_test_items()
	# $or: [type=dcr, $and: [type=bug, status=active]]
	var results := _db.execute_query({"filter": {
		"$or": [
			{"field": "type", "op": "eq", "value": "dcr"},
			{"$and": [
				{"field": "type", "op": "eq", "value": "bug"},
				{"field": "status", "op": "eq", "value": "active"}
			]}
		]
	}})
	var r = A.eq(results.size(), 2, "dcr + active bug via tree")
	if r is String: return r
	var ids: Array = []
	for item in results:
		ids.append(item.id)
	ids.sort()
	return A.eq(ids, ["DKT-0002", "DKT-0003"], "correct IDs")


func test_date_before_after() -> Variant:
	_insert_test_items()
	var results := _db.execute_query({"filter": {"conditions": [
		{"field": "created_at", "op": "before", "value": "2026-01-03T00:00:00"}
	]}})
	var r = A.eq(results.size(), 2, "two items before Jan 3")
	if r is String: return r
	results = _db.execute_query({"filter": {"conditions": [
		{"field": "created_at", "op": "after", "value": "2026-01-02T00:00:00"}
	]}})
	return A.eq(results.size(), 2, "two items after Jan 2")


func test_old_flat_dict_still_works() -> Variant:
	_insert_test_items()
	# Old format should still work unchanged
	var results := _db.execute_query({"filter": {"type": "bug", "status__ne": "active"}})
	var r = A.eq(results.size(), 1, "one non-active bug via old format")
	if r is String: return r
	return A.eq(results[0].id, "DKT-0001")


func test_wildcard_translation() -> Variant:
	# Unit test for _translate_wildcards
	var r = A.eq(DocketDBFilter._translate_wildcards("Bug*"), "Bug%", "* -> %")
	if r is String: return r
	r = A.eq(DocketDBFilter._translate_wildcards("B.g"), "B_g", ". -> _")
	if r is String: return r
	r = A.eq(DocketDBFilter._translate_wildcards("100%"), "100\\%", "literal % escaped")
	if r is String: return r
	return A.eq(DocketDBFilter._translate_wildcards("a_b"), "a\\_b", "literal _ escaped")


# -- Project meta -------------------------------------------------------------

func test_project_name() -> Variant:
	# create_new defaults project name from filename
	var name := _db.get_project_name()
	var r = A.eq(name, "test_db", "default project name from filename")
	if r is String: return r
	_db.set_project_name("myproject")
	return A.eq(_db.get_project_name(), "myproject", "set project name")


func test_meta_value() -> Variant:
	_db.set_meta_value("ui_scale", "1.15")
	var r = A.eq(_db.get_meta_value("ui_scale"), "1.15", "meta value roundtrip")
	if r is String: return r
	return A.eq(_db.get_meta_value("nonexistent", "fallback"), "fallback", "meta default")


# -- UUID7 --------------------------------------------------------------------

func test_uuid7_generation() -> Variant:
	var id1 := DocketDB.generate_uuid7()
	var r = A.eq(id1.length(), 32, "uuid7 is 32 hex chars")
	if r is String: return r
	r = A.is_true(id1.is_valid_hex_number(false), "uuid7 is valid hex")
	if r is String: return r
	# Second ID timestamp prefix (first 12 hex = 6 bytes) should be >= first
	var id2 := DocketDB.generate_uuid7()
	r = A.eq(id2.length(), 32, "second uuid7 is 32 hex chars")
	if r is String: return r
	var ts1 := id1.substr(0, 12)
	var ts2 := id2.substr(0, 12)
	return A.is_true(ts2 >= ts1, "uuid7 timestamp is non-decreasing")


func test_resolve_short_id() -> Variant:
	var id := _db.next_uuid7_id()
	_db.insert_item(id, {"type": "bug", "status": "new", "title": "UUID7 item",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": [], "events": [], "links": []})
	# 7-char prefix should resolve
	var short := id.substr(0, 7)
	var resolved := _db.resolve_short_id(short)
	var r = A.eq(resolved, id, "7-char prefix resolves")
	if r is String: return r
	# Exact match resolves
	resolved = _db.resolve_short_id(id)
	r = A.eq(resolved, id, "exact match resolves")
	if r is String: return r
	# Missing returns ""
	resolved = _db.resolve_short_id("deadbeef")
	return A.eq(resolved, "", "missing returns empty")


func test_short_id_display() -> Variant:
	var id := _db.next_uuid7_id()
	_db.insert_item(id, {"type": "bug", "status": "new", "title": "Display test",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
		"tags": [], "events": [], "links": []})
	var short := _db.short_id(id)
	var r = A.is_true(short.length() >= 7, "short_id is at least 7 chars")
	if r is String: return r
	return A.is_true(id.begins_with(short), "full ID starts with short_id")


func test_is_uuid7() -> Variant:
	var uuid := DocketDB.generate_uuid7()
	var r = A.is_true(DocketDB._is_uuid7(uuid), "detects UUID7")
	if r is String: return r
	r = A.is_false(DocketDB._is_uuid7("DKT-0001"), "rejects legacy")
	if r is String: return r
	return A.is_false(DocketDB._is_uuid7("abc"), "rejects short strings")
