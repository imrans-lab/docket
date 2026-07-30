extends Node
## Unit tests for JSONLMigration — SQLite → JSONL conversion.

var A := AssertHelpers
var _test_dir := "user://test_jsonl_migration"
var _test_file: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_test_file = _test_dir + "/migrate_test.dct"


func before_each() -> void:
	_cleanup_test_files()


func _cleanup_test_files() -> void:
	var dir := DirAccess.open(_test_dir)
	if not dir:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		DirAccess.remove_absolute(_test_dir + "/" + fname)
		fname = dir.get_next()


func teardown() -> void:
	_cleanup_test_files()
	DirAccess.remove_absolute(_test_dir)


# -- Helper: create a SQLite .dct with some data ------------------------------

func _make_sqlite_dct(path: String, item_count: int = 2) -> DocketDB:
	var db := DocketDB.create_new(path)
	db.set_id_prefix("TST")
	db.set_project_name("test_project")
	db.set_counter(item_count)
	for i in item_count:
		var id := "TST-%04d" % (i + 1)
		db.insert_item(id, {
			"type": "bug",
			"status": "new",
			"title": "Bug number %d" % (i + 1),
			"created_at": "2026-03-15T10:30:00Z",
			"updated_at": "2026-03-15T10:30:00Z",
			"tags": ["test"],
			"events": [],
			"links": [],
		})
		db.add_event(id, "created", "imran", "Item created")
	db.close()
	return db


# -- detect_format ------------------------------------------------------------

func test_detect_format_sqlite() -> Variant:
	_make_sqlite_dct(_test_file)
	return A.eq(JSONLMigration.detect_format(_test_file), "sqlite", "SQLite file detected")


func test_detect_format_jsonl() -> Variant:
	var content := '{"_type":"meta","version":"1.0.0","counter":0,"id_prefix":"TST"}\n'
	var f := FileAccess.open(_test_file, FileAccess.WRITE)
	f.store_string(content)
	f.close()
	return A.eq(JSONLMigration.detect_format(_test_file), "jsonl", "JSONL file detected")


func test_detect_format_json_v1() -> Variant:
	var data := {"version": "1.0.0", "counter": 0, "items": {}, "queries": {}}
	var f := FileAccess.open(_test_file, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	return A.eq(JSONLMigration.detect_format(_test_file), "json_v1", "JSON v1 file detected")


func test_detect_format_missing_file() -> Variant:
	return A.eq(JSONLMigration.detect_format(_test_dir + "/nonexistent.dct"), "unknown", "missing file → unknown")


# -- is_sqlite_dct ------------------------------------------------------------

func test_is_sqlite_dct_true() -> Variant:
	_make_sqlite_dct(_test_file)
	return A.is_true(JSONLMigration.is_sqlite_dct(_test_file), "SQLite file recognized")


func test_is_sqlite_dct_false_for_jsonl() -> Variant:
	var content := '{"_type":"meta","version":"1.0.0","counter":0,"id_prefix":"TST"}\n'
	var f := FileAccess.open(_test_file, FileAccess.WRITE)
	f.store_string(content)
	f.close()
	return A.is_false(JSONLMigration.is_sqlite_dct(_test_file), "JSONL not reported as SQLite")


func test_is_sqlite_dct_missing_file() -> Variant:
	return A.is_false(JSONLMigration.is_sqlite_dct(_test_dir + "/no_such.dct"), "missing file → false")


# -- is_jsonl_dct -------------------------------------------------------------

func test_is_jsonl_dct_true() -> Variant:
	var content := '{"_type":"meta","version":"1.0.0","counter":5,"id_prefix":"MNV"}\n'
	var f := FileAccess.open(_test_file, FileAccess.WRITE)
	f.store_string(content)
	f.close()
	return A.is_true(JSONLMigration.is_jsonl_dct(_test_file), "JSONL file recognized")


func test_is_jsonl_dct_false_for_sqlite() -> Variant:
	_make_sqlite_dct(_test_file)
	return A.is_false(JSONLMigration.is_jsonl_dct(_test_file), "SQLite not reported as JSONL")


func test_is_jsonl_dct_false_for_wrong_type() -> Variant:
	# First line is valid JSON but _type != "meta"
	var content := '{"_type":"item","id":"X-0001","type":"bug","status":"new","title":"x","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
	var f := FileAccess.open(_test_file, FileAccess.WRITE)
	f.store_string(content)
	f.close()
	return A.is_false(JSONLMigration.is_jsonl_dct(_test_file), "non-meta first line → false")


func test_is_jsonl_dct_false_for_missing_file() -> Variant:
	return A.is_false(JSONLMigration.is_jsonl_dct(_test_dir + "/no_such.dct"), "missing file → false")


# -- migrate_to_jsonl ---------------------------------------------------------

func test_migrate_basic_success() -> Variant:
	_make_sqlite_dct(_test_file, 3)
	var result := JSONLMigration.migrate_to_jsonl(_test_file)
	var r = A.is_true(result["success"], "migration succeeded: " + str(result.get("error", "")))
	if r is String: return r
	r = A.eq(result["item_count"], 3, "item_count=3")
	if r is String: return r
	return A.is_false(result["backup_path"].is_empty(), "backup_path set")


func test_migrate_backup_created() -> Variant:
	_make_sqlite_dct(_test_file)
	JSONLMigration.migrate_to_jsonl(_test_file)
	return A.is_true(FileAccess.file_exists(_test_file + ".sqlite.bak"), "backup file exists")


func test_migrate_backup_is_sqlite() -> Variant:
	## The backup should still be a valid SQLite file.
	_make_sqlite_dct(_test_file)
	JSONLMigration.migrate_to_jsonl(_test_file)
	return A.is_true(JSONLMigration.is_sqlite_dct(_test_file + ".sqlite.bak"), "backup is SQLite")


func test_migrate_output_is_jsonl() -> Variant:
	## After migration, the original path should contain JSONL.
	_make_sqlite_dct(_test_file)
	JSONLMigration.migrate_to_jsonl(_test_file)
	return A.is_true(JSONLMigration.is_jsonl_dct(_test_file), "output file is JSONL")


func test_migrate_output_not_sqlite() -> Variant:
	_make_sqlite_dct(_test_file)
	JSONLMigration.migrate_to_jsonl(_test_file)
	return A.is_false(JSONLMigration.is_sqlite_dct(_test_file), "output file is not SQLite")


func test_migrate_output_parses_correctly() -> Variant:
	_make_sqlite_dct(_test_file, 2)
	JSONLMigration.migrate_to_jsonl(_test_file)

	var parsed := JSONLParser.parse_file(_test_file)
	var r = A.eq(parsed["items"].size(), 2, "2 items in parsed output")
	if r is String: return r

	var meta: Dictionary = parsed.get("meta", {})
	r = A.is_true(JSONLParser.validate_meta(meta), "meta is valid")
	if r is String: return r

	return A.eq(meta.get("id_prefix", ""), "TST", "id_prefix preserved")


func test_migrate_preserves_item_fields() -> Variant:
	## Verify that item fields survive the SQLite → JSONL conversion.
	_make_sqlite_dct(_test_file, 1)
	JSONLMigration.migrate_to_jsonl(_test_file)

	var parsed := JSONLParser.parse_file(_test_file)
	var r = A.eq(parsed["items"].size(), 1, "1 item")
	if r is String: return r

	var item: Dictionary = parsed["items"][0]
	r = A.eq(item.get("id", ""), "TST-0001", "id preserved")
	if r is String: return r
	r = A.eq(item.get("type", ""), "bug", "type preserved")
	if r is String: return r
	r = A.eq(item.get("title", ""), "Bug number 1", "title preserved")
	if r is String: return r
	return A.eq(item.get("status", ""), "new", "status preserved")


func test_migrate_preserves_events() -> Variant:
	_make_sqlite_dct(_test_file, 1)  # _make_sqlite_dct adds one event per item
	JSONLMigration.migrate_to_jsonl(_test_file)

	var parsed := JSONLParser.parse_file(_test_file)
	var r = A.eq(parsed["events"].size(), 1, "1 event in parsed output")
	if r is String: return r

	var ev: Dictionary = parsed["events"][0]
	return A.eq(ev.get("seq", 0), 1, "event seq=1")


func test_migrate_preserves_counter() -> Variant:
	_make_sqlite_dct(_test_file, 5)
	JSONLMigration.migrate_to_jsonl(_test_file)

	var parsed := JSONLParser.parse_file(_test_file)
	var meta: Dictionary = parsed.get("meta", {})
	return A.eq(meta.get("counter", -1), 5, "counter preserved")


func test_migrate_preserves_project_name() -> Variant:
	_make_sqlite_dct(_test_file)
	JSONLMigration.migrate_to_jsonl(_test_file)

	var parsed := JSONLParser.parse_file(_test_file)
	var meta: Dictionary = parsed.get("meta", {})
	return A.eq(meta.get("project", ""), "test_project", "project name preserved")


func test_migrate_output_each_line_valid_json() -> Variant:
	## Every non-empty line in the JSONL output must parse as a JSON object.
	_make_sqlite_dct(_test_file, 2)
	JSONLMigration.migrate_to_jsonl(_test_file)

	var f := FileAccess.open(_test_file, FileAccess.READ)
	if not f:
		return "could not open migrated file"
	var content := f.get_as_text()
	f.close()

	for line in content.split("\n"):
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if parsed == null:
			return "line is not valid JSON: %s" % line.left(120)
	return true


func test_migrate_output_ends_with_newline() -> Variant:
	_make_sqlite_dct(_test_file)
	JSONLMigration.migrate_to_jsonl(_test_file)

	var f := FileAccess.open(_test_file, FileAccess.READ)
	if not f:
		return "could not open migrated file"
	var content := f.get_as_text()
	f.close()
	return A.is_true(content.ends_with("\n"), "output ends with newline")


func test_migrate_empty_db() -> Variant:
	## An empty SQLite DB (no items) should still produce a valid JSONL file with a meta line.
	_make_sqlite_dct(_test_file, 0)
	var result := JSONLMigration.migrate_to_jsonl(_test_file)
	var r = A.is_true(result["success"], "empty DB migration succeeded: " + str(result.get("error", "")))
	if r is String: return r

	r = A.eq(result["item_count"], 0, "item_count=0")
	if r is String: return r

	return A.is_true(JSONLMigration.is_jsonl_dct(_test_file), "output is JSONL")


func test_migrate_fails_for_non_sqlite() -> Variant:
	## Passing a non-SQLite file should return success=false.
	var content := '{"_type":"meta","version":"1.0.0","counter":0,"id_prefix":"TST"}\n'
	var f := FileAccess.open(_test_file, FileAccess.WRITE)
	f.store_string(content)
	f.close()

	var result := JSONLMigration.migrate_to_jsonl(_test_file)
	return A.is_false(result["success"], "migration of non-SQLite file returns failure")


func test_migrate_fails_for_missing_file() -> Variant:
	var result := JSONLMigration.migrate_to_jsonl(_test_dir + "/no_such.dct")
	var r = A.is_false(result["success"], "migration of missing file returns failure")
	if r is String: return r
	return A.is_false(result["error"].is_empty(), "error message set")


func test_migrate_with_saved_query() -> Variant:
	## Ensure saved queries survive the migration.
	var db := DocketDB.create_new(_test_file)
	db.set_id_prefix("TST")
	db.set_counter(0)
	db.save_query("open-bugs", {"filter": {"type": "bug", "status__ne": "closed"}})
	db.close()

	JSONLMigration.migrate_to_jsonl(_test_file)

	var parsed := JSONLParser.parse_file(_test_file)
	var r = A.eq(parsed["saved_queries"].size(), 1, "1 saved query preserved")
	if r is String: return r

	var sq: Dictionary = parsed["saved_queries"][0]
	return A.eq(sq.get("name", ""), "open-bugs", "query name preserved")


func test_migrate_with_comment() -> Variant:
	var db := DocketDB.create_new(_test_file)
	db.set_id_prefix("TST")
	db.set_counter(1)
	db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "A bug",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	db.add_comment("TST-0001", "imran", "This is a comment")
	db.close()

	JSONLMigration.migrate_to_jsonl(_test_file)

	var parsed := JSONLParser.parse_file(_test_file)
	var r = A.eq(parsed["comments"].size(), 1, "1 comment preserved")
	if r is String: return r

	var c: Dictionary = parsed["comments"][0]
	return A.eq(c.get("text", ""), "This is a comment", "comment text preserved")


func test_detect_format_after_migration() -> Variant:
	## After migration, detect_format should return "jsonl".
	_make_sqlite_dct(_test_file)
	JSONLMigration.migrate_to_jsonl(_test_file)
	return A.eq(JSONLMigration.detect_format(_test_file), "jsonl", "detect_format returns jsonl after migration")
