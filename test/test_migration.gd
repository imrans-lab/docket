extends Node
## Tests for JSON→SQLite migration.

var A := AssertHelpers
var _test_dir := "user://test_migration"
var _json_file: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_json_file = _test_dir + "/migrate_test.dct"


func before_each() -> void:
	# Clean up any existing files
	var dir := DirAccess.open(_test_dir)
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			dir.remove(fname)
			fname = dir.get_next()


func teardown() -> void:
	var dir := DirAccess.open(_test_dir)
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			dir.remove(fname)
			fname = dir.get_next()
		DirAccess.remove_absolute(_test_dir)


func test_is_json_dct() -> Variant:
	# Create a JSON .dct file
	var data := {"version": "1.0.0", "counter": 0, "items": {}, "queries": {}}
	var f := FileAccess.open(_json_file, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

	var r = A.is_true(DocketMigration.is_json_dct(_json_file), "detects JSON")
	if r is String: return r
	return A.is_false(DocketMigration.is_sqlite_dct(_json_file), "not SQLite")


func test_is_sqlite_dct() -> Variant:
	var db := DocketDB.create_new(_json_file)
	db.close()

	var r = A.is_false(DocketMigration.is_json_dct(_json_file), "not JSON")
	if r is String: return r
	return A.is_true(DocketMigration.is_sqlite_dct(_json_file), "detects SQLite")


func test_migrate_items() -> Variant:
	# Create a JSON .dct with some items
	var data := {
		"version": "1.0.0",
		"counter": 3,
		"items": {
			"DKT-0001": {
				"type": "bug", "status": "new", "title": "Test bug",
				"description": "A bug", "created_at": "2026-01-01T00:00:00",
				"updated_at": "2026-01-01T00:00:00", "priority": 1,
				"tags": ["api", "urgent"],
				"events": [{"event_type": "created", "actor": "test", "timestamp": "2026-01-01T00:00:00", "note": "Created"}],
				"links": [],
			},
			"DKT-0002": {
				"type": "chore", "status": "open", "title": "Update deps",
				"description": "", "created_at": "2026-01-02T00:00:00",
				"updated_at": "2026-01-02T00:00:00",
				"tags": ["infra"],
				"events": [{"event_type": "created", "actor": "test", "timestamp": "2026-01-02T00:00:00", "note": "Created"}],
				"links": [],
			},
			"DKT-0003": {
				"type": "hint", "status": "draft", "title": "test/run",
				"created_at": "2026-01-03T00:00:00", "updated_at": "2026-01-03T00:00:00",
				"component": "docket", "key": "test", "value": "godot -- test",
				"tags": [], "events": [], "links": [],
			},
		},
		"queries": {
			"open-bugs": {"filter": {"type": "bug", "status": "new"}},
		},
	}
	FileManager.save(_json_file, data)

	# Migrate
	var db := DocketMigration.migrate(_json_file)
	var r = A.not_null(db, "migration succeeded")
	if r is String: return r

	# Check backup exists
	r = A.is_true(FileAccess.file_exists(_json_file + ".json.bak"), "backup created")
	if r is String: return r

	# Check items migrated
	r = A.is_true(db.has_item("DKT-0001"), "DKT-0001 exists")
	if r is String: return r
	r = A.is_true(db.has_item("DKT-0002"), "DKT-0002 exists")
	if r is String: return r
	r = A.is_true(db.has_item("DKT-0003"), "DKT-0003 exists")
	if r is String: return r

	# Check item fields
	var bug := db.get_item("DKT-0001")
	r = A.eq(bug.type, "bug")
	if r is String:
		db.close()
		return r
	r = A.eq(bug.title, "Test bug")
	if r is String:
		db.close()
		return r
	r = A.eq(bug.priority, 1)
	if r is String:
		db.close()
		return r
	r = A.eq(bug.tags.size(), 2, "tags preserved")
	if r is String:
		db.close()
		return r
	r = A.eq(bug.events.size(), 1, "events preserved")
	if r is String:
		db.close()
		return r

	# Check counter
	r = A.eq(db.get_counter(), 3, "counter preserved")
	if r is String:
		db.close()
		return r

	# Check saved query
	var sq := db.load_query("open-bugs")
	r = A.has_key(sq, "filter")
	if r is String:
		db.close()
		return r

	# Check hint fields
	var hint := db.get_item("DKT-0003")
	r = A.eq(hint.component, "docket")
	if r is String:
		db.close()
		return r
	r = A.eq(hint.value, "godot -- test")

	db.close()
	if r is String: return r
	return true
