extends Node
## End-to-end tests for the JSONL storage lifecycle.
##
## Covers: fresh docket lifecycle, cache rebuild, cache staleness detection,
## SQLite→JSONL migration roundtrip, JSONL determinism, multi-type coverage,
## comment threading, and concurrent-file parsing.

var A := AssertHelpers
var _test_dir := "user://test_jsonl_e2e"


# -- Setup / teardown ---------------------------------------------------------

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func teardown() -> void:
	_cleanup_dir(_test_dir)
	DirAccess.remove_absolute(_test_dir)


func _cleanup_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var full := dir_path + "/" + fname
		if dir.current_is_dir():
			_cleanup_dir(full)
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
		fname = dir.get_next()


func _cleanup_test_files() -> void:
	_cleanup_dir(_test_dir)


func before_each() -> void:
	_cleanup_test_files()


# -- Helpers ------------------------------------------------------------------

func _read_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func _write_file(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(content)
		f.close()


func _count_lines_of_type(jsonl_text: String, type_name: String) -> int:
	var count := 0
	for line in jsonl_text.split("\n"):
		if line.begins_with('{"_type":"%s"' % type_name):
			count += 1
	return count


func _close_and_silence(db: DocketDBJsonl) -> void:
	## Close a DocketDBJsonl without triggering a flush (for teardown).
	if db:
		db._jsonl_path = ""
		db.close()


func _delete_files(base: String) -> void:
	for suffix: String in ["", ".cache", ".cache-wal", ".cache-shm", ".tmp"]:
		DirAccess.remove_absolute(base + suffix)


# =========================================================================
# 1. FRESH DOCKET LIFECYCLE
# =========================================================================

func test_fresh_lifecycle_jsonl_is_text() -> Variant:
	## After create_new_jsonl: the .dct.jsonl file must be valid JSONL text (not SQLite).
	var jsonl_path := _test_dir + "/fresh.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	var r = A.not_null(db, "db created")
	if r is String:
		_close_and_silence(db)
		return r

	var text := _read_file(jsonl_path)
	_close_and_silence(db)

	# Must start with a JSON meta line (not SQLite binary magic)
	r = A.is_false(text.begins_with("SQLite format 3"), "not SQLite binary")
	if r is String:
		return r
	return A.is_true(text.begins_with('{"_type":"meta"'), "starts with meta line")


func test_fresh_lifecycle_cache_is_sqlite() -> Variant:
	## The .dct.jsonl.cache must be a SQLite file.
	var jsonl_path := _test_dir + "/fresh.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	_close_and_silence(db)

	var cache_path := jsonl_path + ".cache"
	return A.is_true(JSONLMigration.is_sqlite_dct(cache_path), "cache is SQLite")


func test_fresh_lifecycle_items_appear_in_jsonl() -> Variant:
	## Creating items/comments/events via DB methods → JSONL auto-updates each time.
	var jsonl_path := _test_dir + "/fresh.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("E2E")

	var id := db.next_id()
	db.insert_item(id, {
		"type": "bug", "status": "open", "title": "E2E fresh bug",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
		"tags": ["e2e", "fresh"],
	})
	db.add_event(id, "status_changed", "tester", "open -> active")
	db.add_comment(id, "alice", "Looks bad")
	_close_and_silence(db)

	var parsed := JSONLParser.parse_file(jsonl_path)
	var r = A.eq(parsed["items"].size(), 1, "1 item in JSONL")
	if r is String:
		return r
	r = A.eq(parsed["items"][0]["title"], "E2E fresh bug", "title correct")
	if r is String:
		return r
	r = A.is_true(parsed["events"].size() >= 1, "at least 1 event")
	if r is String:
		return r
	return A.eq(parsed["comments"].size(), 1, "1 comment")


func test_fresh_lifecycle_reopen_preserves_data() -> Variant:
	## Close and reopen from cache → all data intact.
	var jsonl_path := _test_dir + "/fresh.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("E2E")
	db.set_project_name("e2e-test")

	var id1 := db.next_id()
	var id2 := db.next_id()
	db.insert_item(id1, {
		"type": "bug", "status": "open", "title": "Bug alpha",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
		"tags": ["alpha"],
	})
	db.insert_item(id2, {
		"type": "chore", "status": "open", "title": "Chore beta",
		"created_at": "2026-03-27T11:00:00Z", "updated_at": "2026-03-27T11:00:00Z",
	})
	db.add_event(id1, "status_changed", "dev", "open -> active")
	db.add_link(id1, id2, "blocks")
	db.add_comment(id1, "reviewer", "LGTM")
	db.save_query("alpha-bugs", {"filter": {"tags": ["alpha"]}})
	# Close (will flush to JSONL)
	db.close()

	# Reopen from the same JSONL (cache should still be valid)
	var db2 := DocketDBJsonl.open_jsonl(jsonl_path)
	var r = A.not_null(db2, "reopened db")
	if r is String:
		return r

	r = A.eq(db2.get_project_name(), "e2e-test", "project name preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(db2.get_item(id1).get("title"), "Bug alpha", "item 1 title preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(db2.get_item(id2).get("title"), "Chore beta", "item 2 title preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(db2.get_links(id1).size(), 1, "link preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(db2.list_comments(id1).size(), 1, "comment preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(db2.list_queries().size(), 1, "saved query preserved")
	if r is String:
		db2.close()
		return r
	var item1 := db2.get_item(id1)
	r = A.is_true(item1.get("tags", []).has("alpha"), "tag preserved")
	db2.close()
	return r


# =========================================================================
# 2. CACHE REBUILD
# =========================================================================

func test_cache_rebuild_from_scratch() -> Variant:
	## Delete .dct.jsonl.cache → reopen → cache is rebuilt and all data queryable.
	var jsonl_path := _test_dir + "/rebuild.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("RBL")

	var id := db.next_id()
	db.insert_item(id, {
		"type": "dcr", "status": "open", "title": "DCR for rebuild test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
		"tags": ["rebuild"],
	})
	db.add_event(id, "created", "tester", "Item created")
	db.close()

	# Delete the cache so reopen must rebuild
	var cache_path := jsonl_path + ".cache"
	for suffix: String in ["", "-wal", "-shm"]:
		DirAccess.remove_absolute(cache_path + suffix)

	var r = A.is_false(FileAccess.file_exists(cache_path), "cache deleted")
	if r is String:
		return r

	# Reopen → should rebuild cache from JSONL
	var db2 := DocketDBJsonl.open_jsonl(jsonl_path)
	r = A.not_null(db2, "db2 opened after cache delete")
	if r is String:
		return r

	r = A.is_true(db2.is_open(), "db2 is open")
	if r is String:
		db2.close()
		return r

	r = A.is_true(db2.has_item(id), "item queryable after cache rebuild")
	if r is String:
		db2.close()
		return r

	var item := db2.get_item(id)
	r = A.eq(item.get("title"), "DCR for rebuild test", "title correct after rebuild")
	if r is String:
		db2.close()
		return r

	r = A.is_true(item.get("tags", []).has("rebuild"), "tag present after rebuild")
	if r is String:
		db2.close()
		return r

	# Verify cache file was recreated
	r = A.is_true(FileAccess.file_exists(cache_path), "cache file recreated")
	db2.close()
	return r


func test_cache_rebuild_preserves_events() -> Variant:
	## Events are accessible after a full cache rebuild.
	var jsonl_path := _test_dir + "/rebuild_events.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("RBE")

	var id := db.next_id()
	db.insert_item(id, {
		"type": "bug", "status": "open", "title": "Event rebuild check",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	db.add_event(id, "status_changed", "dev", "open -> active")
	db.add_event(id, "status_changed", "dev", "active -> closed")
	db.close()

	# Delete cache
	var cache_path := jsonl_path + ".cache"
	DirAccess.remove_absolute(cache_path)

	var db2 := DocketDBJsonl.open_jsonl(jsonl_path)
	var r = A.not_null(db2, "reopened after cache delete")
	if r is String:
		return r

	# Count events via JSONL parse (authoritative)
	var parsed := JSONLParser.parse_file(jsonl_path)
	# Each item gets events; we expect at least 2 status_changed events
	var event_count := 0
	for ev in parsed["events"]:
		if ev.get("item_id") == id:
			event_count += 1

	r = A.gte(event_count, 2, "at least 2 events for item after rebuild")
	db2.close()
	return r


func test_cache_rebuild_preserves_comments() -> Variant:
	## Comments with threading are preserved after cache rebuild.
	var jsonl_path := _test_dir + "/rebuild_comments.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("RBC")

	var id := db.next_id()
	db.insert_item(id, {
		"type": "discussion", "status": "open", "title": "Discussion rebuild",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	var c1 := db.add_comment(id, "alice", "Top-level comment")
	var c1_id: int = c1.get("id", 0)
	db.add_comment(id, "bob", "Reply to alice", c1_id)
	db.close()

	# Delete cache
	var cache_path := jsonl_path + ".cache"
	DirAccess.remove_absolute(cache_path)

	var db2 := DocketDBJsonl.open_jsonl(jsonl_path)
	var r = A.not_null(db2, "reopened")
	if r is String:
		return r

	var comments := db2.list_comments(id)
	r = A.eq(comments.size(), 2, "2 comments after rebuild")
	if r is String:
		db2.close()
		return r

	# Verify parent_id threading
	var parsed := JSONLParser.parse_file(jsonl_path)
	var reply: Dictionary = {}
	for c in parsed["comments"]:
		if c.get("author", "") == "bob":
			reply = c
			break
	r = A.is_false(reply.is_empty(), "reply comment found in JSONL")
	if r is String:
		db2.close()
		return r
	r = A.eq(int(reply.get("parent_id", 0)), c1_id, "parent_id preserved in JSONL")
	db2.close()
	return r


func test_cache_rebuild_preserves_saved_queries() -> Variant:
	## Saved queries are accessible after a full cache rebuild.
	var jsonl_path := _test_dir + "/rebuild_queries.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("RBQ")
	db.save_query("open-bugs", {"filter": {"type": "bug", "status__ne": "closed"}})
	db.save_query("all-dcr", {"filter": {"type": "dcr"}})
	db.close()

	var cache_path := jsonl_path + ".cache"
	DirAccess.remove_absolute(cache_path)

	var db2 := DocketDBJsonl.open_jsonl(jsonl_path)
	var r = A.not_null(db2, "reopened")
	if r is String:
		return r

	var queries := db2.list_queries()
	r = A.eq(queries.size(), 2, "2 saved queries after rebuild")
	db2.close()
	return r


# =========================================================================
# 3. CACHE STALENESS DETECTION
# =========================================================================

func test_staleness_manual_append_detected() -> Variant:
	## Manually append an item line to the JSONL file →
	## reopen detects staleness and rebuilds → new item appears in queries.
	var jsonl_path := _test_dir + "/stale.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("STL")

	var id1 := db.next_id()
	db.insert_item(id1, {
		"type": "bug", "status": "open", "title": "Original bug",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	db.close()

	# Read current JSONL, append a new item line manually
	var current_text := _read_file(jsonl_path)
	# The manually-added item uses a hand-crafted ID outside the counter sequence
	var manual_item_id := "STL-9999"
	var manual_line := (
		'{"_type":"item","id":"%s","type":"chore","status":"open","title":"Manually added chore",'
		+ '"created_at":"2026-03-27T12:00:00Z","updated_at":"2026-03-27T12:00:00Z"}'
	) % manual_item_id

	_write_file(jsonl_path, current_text.rstrip("\n") + "\n" + manual_line + "\n")

	# Reopen → cache should detect JSONL changed (size differs) and rebuild
	var db2 := DocketDBJsonl.open_jsonl(jsonl_path)
	var r = A.not_null(db2, "db2 opened")
	if r is String:
		return r

	# Original item must still be there
	r = A.is_true(db2.has_item(id1), "original item still present")
	if r is String:
		db2.close()
		return r

	# Manually-added item must also be queryable
	r = A.is_true(db2.has_item(manual_item_id), "manually-added item present after stale rebuild")
	if r is String:
		db2.close()
		return r

	var manual_item := db2.get_item(manual_item_id)
	r = A.eq(manual_item.get("title"), "Manually added chore", "manual item title correct")
	db2.close()
	return r


func test_staleness_cache_valid_when_unchanged() -> Variant:
	## If the JSONL file is unchanged, is_cache_valid returns true.
	var jsonl_path := _test_dir + "/stale_valid.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.close()  # triggers final flush

	var cache_path := jsonl_path + ".cache"
	return A.is_true(JSONLCache.is_cache_valid(jsonl_path, cache_path), "cache is valid when file unchanged")


func test_staleness_cache_invalid_after_file_change() -> Variant:
	## Modifying the JSONL file invalidates the cache.
	var jsonl_path := _test_dir + "/stale_invalid.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.close()

	var cache_path := jsonl_path + ".cache"
	var before_valid := JSONLCache.is_cache_valid(jsonl_path, cache_path)
	var r = A.is_true(before_valid, "cache valid before modification")
	if r is String:
		return r

	# Append a comment to the JSONL (changes size + mtime)
	var current := _read_file(jsonl_path)
	_write_file(jsonl_path, current + "# extra line to invalidate\n")

	return A.is_false(JSONLCache.is_cache_valid(jsonl_path, cache_path), "cache invalid after file change")


# =========================================================================
# 4. SQLITE → JSONL MIGRATION ROUNDTRIP
# =========================================================================

func test_migration_roundtrip_all_data_preserved() -> Variant:
	## Create a SQLite .dct, populate with items/events/comments/tags/links/saved queries,
	## migrate to JSONL, open via DocketDBJsonl, verify all data preserved.
	var sqlite_path := _test_dir + "/migrate_full.dct"

	# Build a rich SQLite docket
	var db := DocketDB.create_new(sqlite_path)
	db.set_id_prefix("MGR")
	db.set_project_name("migration-roundtrip-test")
	db.set_counter(3)

	# Three items with different types
	db.insert_item("MGR-0001", {
		"type": "bug", "status": "new", "title": "Migration bug",
		"created_at": "2026-03-15T10:00:00Z", "updated_at": "2026-03-15T10:00:00Z",
		"tags": ["critical", "migration"],
		"events": [], "links": [],
	})
	db.insert_item("MGR-0002", {
		"type": "dcr", "status": "open", "title": "Migration DCR",
		"created_at": "2026-03-15T11:00:00Z", "updated_at": "2026-03-15T11:00:00Z",
		"tags": ["feature"],
		"events": [], "links": [],
	})
	db.insert_item("MGR-0003", {
		"type": "hint", "status": "draft", "title": "A useful hint",
		"created_at": "2026-03-15T12:00:00Z", "updated_at": "2026-03-15T12:00:00Z",
		"value": "use the force", "component": "core", "key": "approach",
		"events": [], "links": [],
	})

	# Events
	db.add_event("MGR-0001", "created", "imran", "Item created")
	db.add_event("MGR-0001", "status_changed", "imran", "new -> triaged")

	# Comments (one top-level + one reply)
	var c1 := db.add_comment("MGR-0001", "alice", "Found root cause")
	var c1_id: int = c1.get("id", 0)
	db.add_comment("MGR-0001", "imran", "Confirmed", c1_id)

	# Link between items
	db.add_link("MGR-0002", "MGR-0001", "follow_up")

	# Saved queries
	db.save_query("new-bugs", {"filter": {"type": "bug", "status": "new"}})
	db.save_query("all-hints", {"filter": {"type": "hint"}})

	db.close()

	# Run migration: SQLite → JSONL (in place, at sqlite_path)
	var migration_result := JSONLMigration.migrate_to_jsonl(sqlite_path)
	var r = A.is_true(migration_result["success"], "migration succeeded: " + str(migration_result.get("error", "")))
	if r is String:
		return r
	r = A.eq(migration_result["item_count"], 3, "migration reports 3 items")
	if r is String:
		return r

	# Now open the JSONL result via DocketDBJsonl (need .dct.jsonl path, but migration
	# wrote JSONL to sqlite_path itself; create a .cache alongside it)
	# The migration wrote to sqlite_path (now JSONL), so we can parse it directly.
	var parsed := JSONLParser.parse_file(sqlite_path)

	r = A.eq(parsed["items"].size(), 3, "3 items preserved")
	if r is String:
		return r
	r = A.gte(parsed["events"].size(), 2, "at least 2 events preserved")
	if r is String:
		return r
	r = A.eq(parsed["comments"].size(), 2, "2 comments preserved")
	if r is String:
		return r
	r = A.eq(parsed["links"].size(), 1, "1 link preserved")
	if r is String:
		return r
	r = A.eq(parsed["saved_queries"].size(), 2, "2 saved queries preserved")
	if r is String:
		return r

	# Verify tag preservation
	var bug_item: Dictionary = {}
	for item in parsed["items"]:
		if item.get("id") == "MGR-0001":
			bug_item = item
			break
	r = A.is_false(bug_item.is_empty(), "MGR-0001 found in parsed items")
	if r is String:
		return r
	r = A.is_true(bug_item.get("tags", []).has("critical"), "tag 'critical' preserved")
	if r is String:
		return r

	# Verify comment threading survived migration
	var reply_comment: Dictionary = {}
	for c in parsed["comments"]:
		if c.get("author", "") == "imran":
			reply_comment = c
			break
	r = A.is_false(reply_comment.is_empty(), "reply comment found")
	if r is String:
		return r
	return A.eq(int(reply_comment.get("parent_id", 0)), c1_id, "parent_id preserved through migration")


func test_migration_roundtrip_openable_as_jsonl_db() -> Variant:
	## After migration, the file can be opened as DocketDBJsonl and queried.
	var sqlite_path := _test_dir + "/migrate_open.dct"
	var jsonl_path := sqlite_path  # migration rewrites in place

	var db := DocketDB.create_new(sqlite_path)
	db.set_id_prefix("MOP")
	db.insert_item("MOP-0001", {
		"type": "work_item", "status": "open", "title": "Work to migrate",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
		"events": [], "links": [],
	})
	db.close()

	JSONLMigration.migrate_to_jsonl(sqlite_path)

	# sqlite_path now contains JSONL; create a cache for it to open via DocketDBJsonl
	var cache_path := jsonl_path + ".cache"
	var rebuilt_db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(rebuilt_db, "cache rebuilt from migrated JSONL")
	if r is String:
		return r

	r = A.is_true(rebuilt_db.has_item("MOP-0001"), "item queryable from migrated JSONL")
	rebuilt_db.close()
	return r


func test_migration_roundtrip_meta_preserved() -> Variant:
	## Counter, id_prefix, and project name survive migration.
	var sqlite_path := _test_dir + "/migrate_meta.dct"

	var db := DocketDB.create_new(sqlite_path)
	db.set_id_prefix("MTM")
	db.set_project_name("meta-test-project")
	db.set_counter(42)
	db.close()

	JSONLMigration.migrate_to_jsonl(sqlite_path)

	var parsed := JSONLParser.parse_file(sqlite_path)
	var meta: Dictionary = parsed.get("meta", {})
	var r = A.eq(meta.get("id_prefix", ""), "MTM", "id_prefix preserved")
	if r is String:
		return r
	r = A.eq(meta.get("project", ""), "meta-test-project", "project name preserved")
	if r is String:
		return r
	return A.eq(int(meta.get("counter", -1)), 42, "counter preserved")


# =========================================================================
# 5. JSONL DETERMINISM
# =========================================================================

func test_determinism_identical_data_produces_identical_output() -> Variant:
	## Two dockets with the same logical data must produce byte-identical JSONL.
	var path_a := _test_dir + "/det_a.dct.jsonl"
	var path_b := _test_dir + "/det_b.dct.jsonl"

	# Build docket A
	var db_a := DocketDBJsonl.create_new_jsonl(path_a)
	db_a.set_id_prefix("DET")
	db_a.set_project_name("determinism-test")
	db_a.set_counter(0)

	var id_a := "DET-0001"
	db_a.insert_item(id_a, {
		"type": "bug", "status": "open", "title": "Deterministic bug",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
		"tags": ["beta", "alpha"],  # intentionally unordered to test tag sorting
	})
	db_a.add_event(id_a, "created", "tester", "Item created")
	db_a.save_query("open-bugs", {"filter": {"type": "bug"}})
	_close_and_silence(db_a)

	# Build docket B with identical data
	var db_b := DocketDBJsonl.create_new_jsonl(path_b)
	db_b.set_id_prefix("DET")
	db_b.set_project_name("determinism-test")
	db_b.set_counter(0)

	db_b.insert_item(id_a, {
		"type": "bug", "status": "open", "title": "Deterministic bug",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
		"tags": ["beta", "alpha"],
	})
	db_b.add_event(id_a, "created", "tester", "Item created")
	db_b.save_query("open-bugs", {"filter": {"type": "bug"}})
	_close_and_silence(db_b)

	var text_a := _read_file(path_a)
	var text_b := _read_file(path_b)

	# Remove the jsonl_hash meta value difference — it's an internal cache key
	# and is NOT serialized to JSONL (it's only in SQLite docket_meta). So both
	# JSONL outputs should be identical.
	return A.eq(text_a, text_b, "identical data → identical JSONL output")


func test_determinism_line_order_meta_first() -> Variant:
	## Lines appear in spec order: meta → items → events → comments → links → saved_queries.
	var jsonl_path := _test_dir + "/det_order.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("ORD")

	var id1 := "ORD-0001"
	var id2 := "ORD-0002"
	db.insert_item(id1, {
		"type": "bug", "status": "open", "title": "Item 1",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	db.insert_item(id2, {
		"type": "chore", "status": "open", "title": "Item 2",
		"created_at": "2026-03-27T11:00:00Z", "updated_at": "2026-03-27T11:00:00Z",
	})
	db.add_event(id1, "created", "dev", "Item created")
	db.add_comment(id1, "alice", "A comment")
	db.add_link(id1, id2, "blocks")
	db.save_query("all", {"filter": {}})
	_close_and_silence(db)

	var text := _read_file(jsonl_path)
	var lines := text.split("\n")
	# Remove trailing empty line from split
	var non_empty: Array = []
	for line in lines:
		if not line.is_empty():
			non_empty.append(line)

	var r = A.is_true(non_empty.size() >= 7, "expected at least 7 non-empty lines")
	if r is String:
		return r

	# Extract _type sequence
	var types: Array = []
	for line in non_empty:
		var parsed = JSON.parse_string(line)
		if parsed is Dictionary:
			types.append(parsed.get("_type", "?"))

	# Verify spec ordering: meta before item before event before comment before link before saved_query
	var meta_idx := types.find("meta")
	var item_idx := types.find("item")
	var event_idx := types.find("event")
	var comment_idx := types.find("comment")
	var link_idx := types.find("link")
	var query_idx := types.find("saved_query")

	r = A.eq(meta_idx, 0, "meta is first line")
	if r is String:
		return r
	r = A.is_true(meta_idx < item_idx, "meta before items")
	if r is String:
		return r
	r = A.is_true(item_idx < event_idx, "items before events")
	if r is String:
		return r
	r = A.is_true(event_idx < comment_idx, "events before comments")
	if r is String:
		return r
	r = A.is_true(comment_idx < link_idx, "comments before links")
	if r is String:
		return r
	return A.is_true(link_idx < query_idx, "links before saved_queries")


func test_determinism_items_sorted_by_id() -> Variant:
	## Items in JSONL are sorted ascending by id.
	var jsonl_path := _test_dir + "/det_sort.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("SRT")
	# Insert in reverse order
	db.insert_item("SRT-0003", {
		"type": "bug", "status": "open", "title": "C",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	db.insert_item("SRT-0001", {
		"type": "bug", "status": "open", "title": "A",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	db.insert_item("SRT-0002", {
		"type": "bug", "status": "open", "title": "B",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	_close_and_silence(db)

	var parsed := JSONLParser.parse_file(jsonl_path)
	var items: Array = parsed["items"]
	var r = A.eq(items.size(), 3, "3 items")
	if r is String:
		return r
	r = A.eq(items[0]["id"], "SRT-0001", "first item id = SRT-0001")
	if r is String:
		return r
	r = A.eq(items[1]["id"], "SRT-0002", "second item id = SRT-0002")
	if r is String:
		return r
	return A.eq(items[2]["id"], "SRT-0003", "third item id = SRT-0003")


# =========================================================================
# 6. MULTI-TYPE COVERAGE
# =========================================================================

func test_multi_type_all_item_types_roundtrip() -> Variant:
	## Create one item of each recognized type and verify they survive a
	## JSONL roundtrip (close → reopen from rebuilt cache).
	var jsonl_path := _test_dir + "/multi_type.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("MTP")

	var item_types := [
		"bug", "dcr", "work_item", "discussion", "chore",
		"hint", "insight", "question", "rca", "test",
	]
	var ids: Array = []
	var idx := 0
	for itype in item_types:
		idx += 1
		var id := "MTP-%04d" % idx
		ids.append(id)
		db.insert_item(id, {
			"type": itype,
			"status": "open",
			"title": "Test %s item" % itype,
			"created_at": "2026-03-27T10:00:00Z",
			"updated_at": "2026-03-27T10:00:00Z",
		})

	db.close()

	# Delete cache to force rebuild
	var cache_path := jsonl_path + ".cache"
	DirAccess.remove_absolute(cache_path)

	var db2 := DocketDBJsonl.open_jsonl(jsonl_path)
	var r = A.not_null(db2, "reopened")
	if r is String:
		return r

	for i in item_types.size():
		var itype: String = item_types[i]
		var id: String = ids[i]
		var item := db2.get_item(id)
		r = A.eq(item.get("type"), itype, "type '%s' preserved" % itype)
		if r is String:
			db2.close()
			return r
		r = A.eq(item.get("title"), "Test %s item" % itype, "title for %s preserved" % itype)
		if r is String:
			db2.close()
			return r

	db2.close()
	return true


func test_multi_type_jsonl_line_count_matches() -> Variant:
	## JSONL file has exactly one item line per created item.
	var jsonl_path := _test_dir + "/multi_type_count.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("MTC")

	for i in 5:
		db.insert_item("MTC-%04d" % (i + 1), {
			"type": "bug", "status": "open", "title": "Bug %d" % (i + 1),
			"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
		})
	_close_and_silence(db)

	var text := _read_file(jsonl_path)
	return A.eq(_count_lines_of_type(text, "item"), 5, "5 item lines in JSONL")


# =========================================================================
# 7. COMMENT THREADING
# =========================================================================

func test_comment_threading_parent_id_preserved() -> Variant:
	## parent_id threading structure survives a full JSONL roundtrip.
	var jsonl_path := _test_dir + "/threading.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("THR")

	var id := db.next_id()
	db.insert_item(id, {
		"type": "discussion", "status": "open", "title": "Threaded discussion",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})

	# Build a thread: root → reply1 → reply2 (nested)
	var root := db.add_comment(id, "alice", "Root comment")
	var root_id: int = root.get("id", 0)
	var reply1 := db.add_comment(id, "bob", "Reply to root", root_id)
	var reply1_id: int = reply1.get("id", 0)
	var reply2 := db.add_comment(id, "alice", "Nested reply", reply1_id)
	var reply2_id: int = reply2.get("id", 0)
	db.close()

	# Delete cache and reopen (forces full rebuild)
	var cache_path := jsonl_path + ".cache"
	DirAccess.remove_absolute(cache_path)

	var db2 := DocketDBJsonl.open_jsonl(jsonl_path)
	var r = A.not_null(db2, "reopened")
	if r is String:
		return r

	var comments := db2.list_comments(id)
	r = A.eq(comments.size(), 3, "3 comments after roundtrip")
	if r is String:
		db2.close()
		return r

	# Verify JSONL directly for parent_id correctness
	var parsed := JSONLParser.parse_file(jsonl_path)
	var comment_map: Dictionary = {}
	for c in parsed["comments"]:
		comment_map[int(c.get("id", 0))] = c

	r = A.is_true(comment_map.has(root_id), "root comment in JSONL")
	if r is String:
		db2.close()
		return r
	r = A.is_true(comment_map.has(reply1_id), "reply1 in JSONL")
	if r is String:
		db2.close()
		return r
	r = A.is_true(comment_map.has(reply2_id), "reply2 in JSONL")
	if r is String:
		db2.close()
		return r

	# root has no parent_id
	r = A.is_false(comment_map[root_id].has("parent_id"), "root has no parent_id")
	if r is String:
		db2.close()
		return r

	# reply1 references root
	r = A.eq(int(comment_map[reply1_id].get("parent_id", 0)), root_id, "reply1.parent_id = root_id")
	if r is String:
		db2.close()
		return r

	# reply2 references reply1
	r = A.eq(int(comment_map[reply2_id].get("parent_id", 0)), reply1_id, "reply2.parent_id = reply1_id")
	db2.close()
	return r


func test_comment_threading_ids_stable_across_roundtrip() -> Variant:
	## Comment IDs are the same before and after a cache rebuild (stable autoincrement).
	var jsonl_path := _test_dir + "/threading_ids.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("TID")

	var item_id := db.next_id()
	db.insert_item(item_id, {
		"type": "bug", "status": "open", "title": "ID stability test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	var c1 := db.add_comment(item_id, "alice", "First comment")
	var c2 := db.add_comment(item_id, "bob", "Second comment", c1.get("id", 0))
	var c1_id: int = c1.get("id", 0)
	var c2_id: int = c2.get("id", 0)
	db.close()

	# Force cache rebuild
	var cache_path := jsonl_path + ".cache"
	DirAccess.remove_absolute(cache_path)

	var db2 := DocketDBJsonl.open_jsonl(jsonl_path)
	var r = A.not_null(db2, "reopened")
	if r is String:
		return r

	var comments := db2.list_comments(item_id)
	r = A.eq(comments.size(), 2, "2 comments")
	if r is String:
		db2.close()
		return r

	# Build id map from rebuilt DB
	var rebuilt_ids: Array = []
	for c in comments:
		rebuilt_ids.append(int(c.get("id", 0)))

	r = A.is_true(rebuilt_ids.has(c1_id), "c1_id stable after rebuild")
	if r is String:
		db2.close()
		return r
	r = A.is_true(rebuilt_ids.has(c2_id), "c2_id stable after rebuild")
	db2.close()
	return r


# =========================================================================
# 8. CONCURRENT SIMULATION (FORMAT ROBUSTNESS)
# =========================================================================

func test_concurrent_simulation_two_independent_files_parse() -> Variant:
	## Write two separate JSONL files (simulating concurrent agent writes).
	## Both must parse correctly and independently.
	var path_a := _test_dir + "/concurrent_a.dct.jsonl"
	var path_b := _test_dir + "/concurrent_b.dct.jsonl"

	# File A: items 1,2,3
	var content_a := (
		'{"_type":"meta","version":"1.0.0","counter":3,"id_prefix":"CCR"}\n'
		+ '{"_type":"item","id":"CCR-0001","type":"bug","status":"open","title":"Item 1 from A","created_at":"2026-03-27T10:00:00Z","updated_at":"2026-03-27T10:00:00Z"}\n'
		+ '{"_type":"item","id":"CCR-0002","type":"bug","status":"open","title":"Item 2 from A","created_at":"2026-03-27T10:01:00Z","updated_at":"2026-03-27T10:01:00Z"}\n'
		+ '{"_type":"item","id":"CCR-0003","type":"bug","status":"open","title":"Item 3 from A","created_at":"2026-03-27T10:02:00Z","updated_at":"2026-03-27T10:02:00Z"}\n'
	)
	# File B: items 1,2,4 (item 4 added, same items 1 and 2 as A)
	var content_b := (
		'{"_type":"meta","version":"1.0.0","counter":4,"id_prefix":"CCR"}\n'
		+ '{"_type":"item","id":"CCR-0001","type":"bug","status":"open","title":"Item 1 from A","created_at":"2026-03-27T10:00:00Z","updated_at":"2026-03-27T10:00:00Z"}\n'
		+ '{"_type":"item","id":"CCR-0002","type":"bug","status":"open","title":"Item 2 from A","created_at":"2026-03-27T10:01:00Z","updated_at":"2026-03-27T10:01:00Z"}\n'
		+ '{"_type":"item","id":"CCR-0004","type":"chore","status":"open","title":"Item 4 added by B","created_at":"2026-03-27T10:03:00Z","updated_at":"2026-03-27T10:03:00Z"}\n'
	)

	_write_file(path_a, content_a)
	_write_file(path_b, content_b)

	var parsed_a := JSONLParser.parse_file(path_a)
	var parsed_b := JSONLParser.parse_file(path_b)

	# Both files parse without error
	var r = A.eq(parsed_a["items"].size(), 3, "file A has 3 items")
	if r is String:
		return r
	r = A.eq(parsed_b["items"].size(), 3, "file B has 3 items")
	if r is String:
		return r

	# File A has items 1,2,3; File B has items 1,2,4
	var a_ids: Array = []
	for item in parsed_a["items"]:
		a_ids.append(item.get("id"))
	var b_ids: Array = []
	for item in parsed_b["items"]:
		b_ids.append(item.get("id"))

	r = A.is_true(a_ids.has("CCR-0003"), "A has CCR-0003")
	if r is String:
		return r
	r = A.is_false(a_ids.has("CCR-0004"), "A does not have CCR-0004")
	if r is String:
		return r
	r = A.is_true(b_ids.has("CCR-0004"), "B has CCR-0004")
	if r is String:
		return r
	return A.is_false(b_ids.has("CCR-0003"), "B does not have CCR-0003")


func test_concurrent_simulation_shared_items_consistent() -> Variant:
	## Items 1 and 2 present in both files A and B have identical line content.
	var path_a := _test_dir + "/concurrent_shared_a.dct.jsonl"
	var path_b := _test_dir + "/concurrent_shared_b.dct.jsonl"

	# Create both via DocketDBJsonl with identical item data for items 1 & 2
	var db_a := DocketDBJsonl.create_new_jsonl(path_a)
	db_a.set_id_prefix("SHR")
	db_a.set_counter(0)
	db_a.insert_item("SHR-0001", {
		"type": "bug", "status": "open", "title": "Shared item 1",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	db_a.insert_item("SHR-0002", {
		"type": "chore", "status": "open", "title": "Shared item 2",
		"created_at": "2026-03-27T10:01:00Z", "updated_at": "2026-03-27T10:01:00Z",
	})
	db_a.insert_item("SHR-0003", {
		"type": "hint", "status": "draft", "title": "Item only in A",
		"created_at": "2026-03-27T10:02:00Z", "updated_at": "2026-03-27T10:02:00Z",
	})
	_close_and_silence(db_a)

	var db_b := DocketDBJsonl.create_new_jsonl(path_b)
	db_b.set_id_prefix("SHR")
	db_b.set_counter(0)
	db_b.insert_item("SHR-0001", {
		"type": "bug", "status": "open", "title": "Shared item 1",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	db_b.insert_item("SHR-0002", {
		"type": "chore", "status": "open", "title": "Shared item 2",
		"created_at": "2026-03-27T10:01:00Z", "updated_at": "2026-03-27T10:01:00Z",
	})
	db_b.insert_item("SHR-0004", {
		"type": "discussion", "status": "open", "title": "Item only in B",
		"created_at": "2026-03-27T10:03:00Z", "updated_at": "2026-03-27T10:03:00Z",
	})
	_close_and_silence(db_b)

	# Parse both and find shared items
	var parsed_a := JSONLParser.parse_file(path_a)
	var parsed_b := JSONLParser.parse_file(path_b)

	# Build line maps indexed by item id
	var a_item_lines: Dictionary = {}
	for line in _read_file(path_a).split("\n"):
		if line.begins_with('{"_type":"item"'):
			var p = JSON.parse_string(line)
			if p is Dictionary:
				a_item_lines[p.get("id", "")] = line

	var b_item_lines: Dictionary = {}
	for line in _read_file(path_b).split("\n"):
		if line.begins_with('{"_type":"item"'):
			var p = JSON.parse_string(line)
			if p is Dictionary:
				b_item_lines[p.get("id", "")] = line

	# The shared items should have byte-identical lines (deterministic serialization)
	var r = A.eq(a_item_lines.get("SHR-0001", "X"), b_item_lines.get("SHR-0001", "Y"), "SHR-0001 line identical in both files")
	if r is String:
		return r
	return A.eq(a_item_lines.get("SHR-0002", "X"), b_item_lines.get("SHR-0002", "Y"), "SHR-0002 line identical in both files")


# =========================================================================
# 9. ADDITIONAL E2E COVERAGE
# =========================================================================

func test_e2e_jsonl_file_structure_valid_after_many_mutations() -> Variant:
	## After many sequential mutations, every line must be valid JSON.
	var jsonl_path := _test_dir + "/many_mutations.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("MUT")

	# Create 10 items, add events and comments to each
	for i in 5:
		var id := "MUT-%04d" % (i + 1)
		db.insert_item(id, {
			"type": "bug", "status": "open", "title": "Mutation bug %d" % (i + 1),
			"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
			"tags": ["tag%d" % i],
		})
		db.add_event(id, "created", "dev", "")
		db.add_comment(id, "alice", "Comment on item %d" % (i + 1))

	# Add some links
	db.add_link("MUT-0001", "MUT-0002", "blocks")
	db.add_link("MUT-0002", "MUT-0003", "follow_up")

	# Save some queries
	db.save_query("all-bugs", {"filter": {"type": "bug"}})
	db.save_query("open", {"filter": {"status": "open"}})

	_close_and_silence(db)

	var text := _read_file(jsonl_path)
	var r = A.is_true(text.ends_with("\n"), "file ends with newline")
	if r is String:
		return r

	# Every non-empty line must parse as JSON
	for line in text.split("\n"):
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if parsed == null:
			return "invalid JSON line: %s" % line.left(80)
		if not parsed is Dictionary:
			return "non-object JSON line: %s" % line.left(80)
		if not parsed.has("_type"):
			return "line missing _type: %s" % line.left(80)

	return true


func test_e2e_empty_optional_fields_omitted() -> Variant:
	## Items with no optional fields should omit those fields from JSONL.
	var jsonl_path := _test_dir + "/minimal_item.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("MIN")

	db.insert_item("MIN-0001", {
		"type": "chore", "status": "open", "title": "Minimal chore",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
		# No description, no tags, no priority, no severity, etc.
	})
	_close_and_silence(db)

	var text := _read_file(jsonl_path)
	var item_line := ""
	for line in text.split("\n"):
		if line.begins_with('{"_type":"item"'):
			item_line = line
			break

	var r = A.is_false(item_line.is_empty(), "item line found")
	if r is String:
		return r

	# These optional fields must not appear when empty/zero
	r = A.is_false(item_line.contains('"description"'), "description omitted when empty")
	if r is String:
		return r
	r = A.is_false(item_line.contains('"tags"'), "tags omitted when empty")
	if r is String:
		return r
	r = A.is_false(item_line.contains('"priority"'), "priority omitted when 0")
	if r is String:
		return r
	return A.is_false(item_line.contains('"severity"'), "severity omitted when 0")


func test_e2e_comment_open_status_omitted() -> Variant:
	## Comments with status "open" (default) must omit the status field per spec.
	var jsonl_path := _test_dir + "/comment_status.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("CST")

	var id := db.next_id()
	db.insert_item(id, {
		"type": "bug", "status": "open", "title": "Comment status test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	db.add_comment(id, "alice", "Open comment (default status)")
	_close_and_silence(db)

	var text := _read_file(jsonl_path)
	var comment_line := ""
	for line in text.split("\n"):
		if line.begins_with('{"_type":"comment"'):
			comment_line = line
			break

	var r = A.is_false(comment_line.is_empty(), "comment line found")
	if r is String:
		return r
	return A.is_false(comment_line.contains('"status"'), "status omitted for open comments")


func test_e2e_resolved_comment_status_present() -> Variant:
	## Resolved comments must have status field in JSONL.
	var jsonl_path := _test_dir + "/comment_resolved.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("CRS")

	var id := db.next_id()
	db.insert_item(id, {
		"type": "discussion", "status": "open", "title": "Resolve comment test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	var comment := db.add_comment(id, "alice", "Needs resolution")
	var cid: int = comment.get("id", 0)
	db.resolve_comment(cid, "accepted", "reviewer")
	_close_and_silence(db)

	var text := _read_file(jsonl_path)
	var comment_line := ""
	for line in text.split("\n"):
		if line.begins_with('{"_type":"comment"'):
			comment_line = line
			break

	var r = A.is_false(comment_line.is_empty(), "comment line found")
	if r is String:
		return r
	return A.is_true(comment_line.contains('"status":"accepted"'), "accepted status present in JSONL")


func test_e2e_full_roundtrip_with_links_and_attachments() -> Variant:
	## Full lifecycle including attachments: create → close → rebuild → verify.
	var jsonl_path := _test_dir + "/full_roundtrip.dct.jsonl"
	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	db.set_id_prefix("FRT")

	var id1 := "FRT-0001"
	var id2 := "FRT-0002"
	db.set_counter(2)
	db.insert_item(id1, {
		"type": "bug", "status": "open", "title": "Bug with attachment",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	db.insert_item(id2, {
		"type": "chore", "status": "open", "title": "Related chore",
		"created_at": "2026-03-27T10:01:00Z", "updated_at": "2026-03-27T10:01:00Z",
	})

	# Attach a file to id1
	var file_data := "Hello attachment!".to_utf8_buffer()
	var att_result := db.attach_file(id1, "notes.txt", file_data, "text/plain", "Test notes")
	var att_id: int = att_result.get("id", 0)

	# Link id2 to id1
	db.add_link(id2, id1, "blocks")
	db.close()

	# Delete cache → force rebuild
	var cache_path := jsonl_path + ".cache"
	DirAccess.remove_absolute(cache_path)

	var db2 := DocketDBJsonl.open_jsonl(jsonl_path)
	var r = A.not_null(db2, "reopened after cache delete")
	if r is String:
		return r

	# Verify attachment in JSONL
	var parsed := JSONLParser.parse_file(jsonl_path)
	r = A.eq(parsed["attachments"].size(), 1, "1 attachment in JSONL")
	if r is String:
		db2.close()
		return r
	r = A.eq(parsed["attachments"][0]["filename"], "notes.txt", "attachment filename preserved")
	if r is String:
		db2.close()
		return r

	# Verify attachment data roundtrip
	var att_b64: String = parsed["attachments"][0].get("data_b64", parsed["attachments"][0].get("data", ""))
	var decoded := Marshalls.base64_to_raw(att_b64)
	r = A.eq(decoded.get_string_from_utf8(), "Hello attachment!", "attachment data correct")
	if r is String:
		db2.close()
		return r

	# Verify link
	r = A.eq(parsed["links"].size(), 1, "1 link in JSONL")
	if r is String:
		db2.close()
		return r
	r = A.eq(parsed["links"][0]["relation"], "blocks", "link relation correct")
	db2.close()
	return r
