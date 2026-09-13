extends Node

var A := AssertHelpers
var schema: Dictionary
var db: DocketDB
var tool: RefCounted


func setup() -> void:
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	schema = JSON.parse_string(f.get_as_text())

	var path := "user://test_quality_%d.dct" % Time.get_ticks_msec()
	db = DocketDB.create_new(path)
	tool = preload("res://scripts/tools/docket_quality.gd").new()


func teardown() -> void:
	if db:
		var path := db.get_path()
		db.close()
		DirAccess.remove_absolute(path)


func test_quality_score_hint() -> Variant:
	var item = DataModel.create_item(schema, "hint", {"title": "Test hint", "value": "test"})
	var item_id := db.next_uuid7_id()
	db.insert_item(item_id, item)

	var result = tool.execute({"id": item_id, "score": 3, "reason": "accurate"}, schema, db)
	var r = A.eq(result.get("error", ""), "", "no error on valid score")
	if r is String: return r
	r = A.eq(result.quality, 3, "quality is 3")
	if r is String: return r
	return A.is_true(str(result.get("last_reviewed", "")).ends_with("Z"), "new quality timestamps are explicit UTC")


func test_quality_audit_failure_rolls_back_value_and_canonical_file() -> Variant:
	var path: String = "user://test_quality_atomic_%d.dct" % Time.get_ticks_msec()
	var json_db: DocketDBJsonl = DocketDBJsonl.create_new_jsonl(path)
	var registry: TypeRegistry = TypeRegistry.for_db(json_db, json_db.get_project_name())
	var made: Dictionary = registry.create_item({"type":"hint","title":"Atomic quality","value":"v"}, "tester")
	if made.has("error"):
		json_db.close()
		_remove_jsonl_family(path)
		return "quality fixture creation failed: %s" % made.error
	var before: String = FileAccess.get_file_as_string(path)
	json_db._exec("CREATE TRIGGER reject_quality_event BEFORE INSERT ON item_events WHEN NEW.event_type='quality_scored' BEGIN SELECT RAISE(FAIL, 'quality audit rejected'); END;")
	var result: Dictionary = tool.execute({"id":made.id,"score":4,"reason":"must audit"}, schema, json_db)
	var item: Dictionary = json_db.get_item(made.id)
	var unchanged: bool = result.has("error") and int(item.get("quality", 0)) == 0
	unchanged = unchanged and str(item.get("last_reviewed", "")).is_empty()
	unchanged = unchanged and FileAccess.get_file_as_string(path) == before
	json_db.close()
	_remove_jsonl_family(path)
	return A.is_true(unchanged, "quality audit storage failure rolls back typed values and canonical publication")


func _remove_jsonl_family(path: String) -> void:
	for suffix in ["", ".v2.cache", ".v2.cache-wal", ".v2.cache-shm", ".lock"]:
		DirAccess.remove_absolute(path + suffix)


func test_quality_score_insight() -> Variant:
	var item = DataModel.create_item(schema, "insight", {
		"title": "Test insight",
		"assumed": "Old assumption",
		"corrected": "New understanding",
	})
	var item_id := db.next_uuid7_id()
	db.insert_item(item_id, item)

	var result = tool.execute({"id": item_id, "score": 4, "reason": "well validated"}, schema, db)
	var r = A.eq(result.get("error", ""), "", "no error on insight score")
	if r is String: return r
	r = A.eq(result.quality, 4, "quality is 4")
	if r is String: return r
	return A.is_true(not result.get("last_reviewed", "").is_empty(), "last_reviewed is set")


func test_quality_score_skill() -> Variant:
	var item = DataModel.create_item(schema, "skill", {"title": "Deploy to staging"})
	var item_id := db.next_uuid7_id()
	db.insert_item(item_id, item)

	var result = tool.execute({"id": item_id, "score": 2, "reason": "reliable"}, schema, db)
	var r = A.eq(result.get("error", ""), "", "no error on skill score")
	if r is String: return r
	r = A.eq(result.quality, 2, "quality is 2")
	if r is String: return r
	return A.is_true(not result.get("last_reviewed", "").is_empty(), "last_reviewed is set")


func test_quality_reject_bug() -> Variant:
	var item = DataModel.create_item(schema, "bug", {"title": "Crash on startup"})
	var item_id := db.next_uuid7_id()
	db.insert_item(item_id, item)

	var result = tool.execute({"id": item_id, "score": 3}, schema, db)
	return A.has_key(result, "error", "bug should be rejected")


func test_quality_reject_work_item() -> Variant:
	var item = DataModel.create_item(schema, "work_item", {"title": "Refactor auth module"})
	var item_id := db.next_uuid7_id()
	db.insert_item(item_id, item)

	var result = tool.execute({"id": item_id, "score": 1}, schema, db)
	return A.has_key(result, "error", "work_item should be rejected")


func test_quality_range_too_high() -> Variant:
	var item = DataModel.create_item(schema, "hint", {"title": "Range test hint", "value": "v"})
	var item_id := db.next_uuid7_id()
	db.insert_item(item_id, item)

	var result = tool.execute({"id": item_id, "score": 6}, schema, db)
	return A.has_key(result, "error", "score 6 out of range")


func test_quality_range_too_low() -> Variant:
	var item = DataModel.create_item(schema, "hint", {"title": "Range test hint low", "value": "v"})
	var item_id := db.next_uuid7_id()
	db.insert_item(item_id, item)

	var result = tool.execute({"id": item_id, "score": -6}, schema, db)
	return A.has_key(result, "error", "score -6 out of range")


func test_quality_overwrites() -> Variant:
	var item = DataModel.create_item(schema, "hint", {"title": "Overwrite test hint", "value": "v"})
	var item_id := db.next_uuid7_id()
	db.insert_item(item_id, item)

	var first = tool.execute({"id": item_id, "score": 2, "reason": "initial review"}, schema, db)
	var r = A.eq(first.get("error", ""), "", "first score no error")
	if r is String: return r
	r = A.eq(first.quality, 2, "first score is 2")
	if r is String: return r

	var second = tool.execute({"id": item_id, "score": -1, "reason": "stale"}, schema, db)
	r = A.eq(second.get("error", ""), "", "second score no error")
	if r is String: return r
	r = A.eq(second.quality, -1, "second score is -1")
	if r is String: return r

	var stored = db.get_item(item_id)
	return A.eq(int(stored.get("quality", 0)), -1, "db reflects overwritten score")


func test_quality_default_zero() -> Variant:
	var item = DataModel.create_item(schema, "hint", {"title": "Default quality hint", "value": "v"})
	var item_id := db.next_uuid7_id()
	db.insert_item(item_id, item)

	var stored = db.get_item(item_id)
	return A.eq(int(stored.get("quality", 0)), 0, "default quality is 0")


func test_quality_reason_in_result() -> Variant:
	var item = DataModel.create_item(schema, "hint", {"title": "Reason test hint", "value": "v"})
	var item_id := db.next_uuid7_id()
	db.insert_item(item_id, item)

	var result = tool.execute({"id": item_id, "score": -2, "reason": "stale API reference"}, schema, db)
	var r = A.eq(result.get("error", ""), "", "no error when reason provided")
	if r is String: return r
	return A.eq(result.quality, -2, "score stored correctly")


func test_quality_not_found() -> Variant:
	var result = tool.execute({"id": "nonexistent_id_abc123", "score": 3}, schema, db)
	return A.has_key(result, "error", "missing item returns error")
