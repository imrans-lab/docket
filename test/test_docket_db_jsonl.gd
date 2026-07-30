extends Node
## Unit tests for DocketDBJsonl — verifies that mutations write through
## to both SQLite (cache) and JSONL (canonical).

var A := AssertHelpers
var _test_dir := "user://test_docket_db_jsonl"
var _jsonl_path: String
var _db: DocketDBJsonl


# -- Setup / teardown ---------------------------------------------------------

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_jsonl_path = _test_dir + "/test.dct.jsonl"


func before_each() -> void:
	_cleanup()
	_db = DocketDBJsonl.create_new_jsonl(_jsonl_path)


func _cleanup() -> void:
	if _db:
		# Suppress flush on close during cleanup
		_db._jsonl_path = ""
		_db.close()
		_db = null
	# Remove all files in test dir
	var dir := DirAccess.open(_test_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		DirAccess.remove_absolute(_test_dir + "/" + fname)
		fname = dir.get_next()


func teardown() -> void:
	_cleanup()
	DirAccess.remove_absolute(_test_dir)


# -- Helpers ------------------------------------------------------------------

func _read_jsonl() -> String:
	var f := FileAccess.open(_jsonl_path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func _parse_jsonl() -> Dictionary:
	return JSONLParser.parse_file(_jsonl_path)


func _count_lines_of_type(jsonl_text: String, type_name: String) -> int:
	var count := 0
	for line in jsonl_text.split("\n"):
		if line.begins_with('{"_type":"%s"' % type_name):
			count += 1
	return count


# -- Lifecycle ----------------------------------------------------------------

func test_create_new_jsonl_creates_file() -> Variant:
	var r = A.is_true(FileAccess.file_exists(_jsonl_path), "JSONL file exists")
	if r is String:
		return r
	r = A.is_true(_db.is_open(), "db is open")
	if r is String:
		return r
	# Check that it's valid JSONL with a meta line
	var parsed := _parse_jsonl()
	r = A.eq(parsed["meta"].get("_type"), "meta", "meta line present")
	if r is String:
		return r
	return A.is_true(_db is DocketDB, "is DocketDB subclass")


func test_create_new_jsonl_cache_exists() -> Variant:
	var cache_path := _jsonl_path + ".cache"
	return A.is_true(FileAccess.file_exists(cache_path), "cache file exists")


func test_open_existing_jsonl() -> Variant:
	# Create, close, reopen
	var project_name := _db.get_project_name()
	_db.close()
	_db = null

	_db = DocketDBJsonl.open_jsonl(_jsonl_path)
	var r = A.not_null(_db, "reopened db")
	if r is String:
		return r
	r = A.is_true(_db.is_open(), "db is open")
	if r is String:
		return r
	return A.eq(_db.get_project_name(), project_name, "project name preserved")


# -- Insert item --------------------------------------------------------------

func test_insert_item_updates_jsonl() -> Variant:
	var id := _db.next_id()
	var err := _db.insert_item(id, {
		"type": "bug", "status": "open", "title": "Test bug",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
		"tags": ["test"],
	})
	var r = A.eq(err, "", "insert succeeded")
	if r is String:
		return r

	# Verify JSONL contains the item
	var parsed := _parse_jsonl()
	r = A.eq(parsed["items"].size(), 1, "one item in JSONL")
	if r is String:
		return r
	return A.eq(parsed["items"][0]["title"], "Test bug", "title matches")


func test_insert_item_updates_sqlite() -> Variant:
	var id := _db.next_id()
	_db.insert_item(id, {
		"type": "bug", "status": "open", "title": "SQLite check",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	var item := _db.get_item(id)
	return A.eq(item.get("title"), "SQLite check", "item in SQLite")


# -- Update item fields -------------------------------------------------------

func test_update_item_fields_updates_jsonl() -> Variant:
	var id := _db.next_id()
	_db.insert_item(id, {
		"type": "bug", "status": "open", "title": "Before",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	_db.update_item_fields(id, {"title": "After", "priority": 2})

	var parsed := _parse_jsonl()
	var item: Dictionary = parsed["items"][0]
	var r = A.eq(item["title"], "After", "title updated in JSONL")
	if r is String:
		return r
	return A.eq(int(item.get("priority", 0)), 2, "priority updated in JSONL")


# -- Delete item --------------------------------------------------------------

func test_delete_item_updates_jsonl() -> Variant:
	var id := _db.next_id()
	_db.insert_item(id, {
		"type": "bug", "status": "open", "title": "To delete",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	_db.delete_item(id)

	var parsed := _parse_jsonl()
	return A.eq(parsed["items"].size(), 0, "no items in JSONL after delete")


# -- Add event ----------------------------------------------------------------

func test_add_event_updates_jsonl() -> Variant:
	var id := _db.next_id()
	_db.insert_item(id, {
		"type": "bug", "status": "open", "title": "Event test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	_db.add_event(id, "status_changed", "tester", "open -> active")

	var parsed := _parse_jsonl()
	# insert_item with no events in the dict + add_event = 1 event total
	var r = A.is_true(parsed["events"].size() >= 1, "at least one event in JSONL")
	if r is String:
		return r
	var last_event: Dictionary = parsed["events"][-1]
	return A.eq(last_event["event_type"], "status_changed", "event type matches")


# -- Add link -----------------------------------------------------------------

func test_add_link_updates_jsonl() -> Variant:
	var id1 := _db.next_id()
	var id2 := _db.next_id()
	_db.insert_item(id1, {
		"type": "bug", "status": "open", "title": "Item 1",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	_db.insert_item(id2, {
		"type": "chore", "status": "open", "title": "Item 2",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	_db.add_link(id1, id2, "blocks")

	var parsed := _parse_jsonl()
	var r = A.eq(parsed["links"].size(), 1, "one link in JSONL")
	if r is String:
		return r
	return A.eq(parsed["links"][0]["relation"], "blocks", "relation matches")


# -- Attachments --------------------------------------------------------------

func test_attach_file_updates_jsonl() -> Variant:
	var id := _db.next_id()
	_db.insert_item(id, {
		"type": "bug", "status": "open", "title": "Attach test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	var data := "hello".to_utf8_buffer()
	var result := _db.attach_file(id, "test.txt", data, "text/plain", "A test file")

	var r = A.is_false(result.has("error"), "attach succeeded")
	if r is String:
		return r

	var parsed := _parse_jsonl()
	r = A.eq(parsed["attachments"].size(), 1, "one attachment in JSONL")
	if r is String:
		return r
	return A.eq(parsed["attachments"][0]["filename"], "test.txt", "filename matches")


func test_detach_file_updates_jsonl() -> Variant:
	var id := _db.next_id()
	_db.insert_item(id, {
		"type": "bug", "status": "open", "title": "Detach test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	var data := "hello".to_utf8_buffer()
	var result := _db.attach_file(id, "test.txt", data)
	var att_id: int = result.get("id", 0)
	_db.detach_file(att_id)

	var parsed := _parse_jsonl()
	return A.eq(parsed["attachments"].size(), 0, "no attachments after detach")


# -- Comments -----------------------------------------------------------------

func test_add_comment_updates_jsonl() -> Variant:
	var id := _db.next_id()
	_db.insert_item(id, {
		"type": "bug", "status": "open", "title": "Comment test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	_db.add_comment(id, "tester", "This is a comment")

	var parsed := _parse_jsonl()
	var r = A.eq(parsed["comments"].size(), 1, "one comment in JSONL")
	if r is String:
		return r
	return A.eq(parsed["comments"][0].get("text", ""), "This is a comment", "comment text matches")


func test_resolve_comment_updates_jsonl() -> Variant:
	var id := _db.next_id()
	_db.insert_item(id, {
		"type": "bug", "status": "open", "title": "Resolve test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	var comment := _db.add_comment(id, "tester", "Review this")
	var cid: int = comment.get("id", 0)
	_db.resolve_comment(cid, "accepted", "reviewer")

	var parsed := _parse_jsonl()
	var r = A.eq(parsed["comments"].size(), 1, "one comment")
	if r is String:
		return r
	return A.eq(parsed["comments"][0].get("status", ""), "accepted", "status is accepted")


# -- Saved queries ------------------------------------------------------------

func test_save_query_updates_jsonl() -> Variant:
	_db.save_query("open-bugs", {"filter": {"type": "bug", "status__ne": "closed"}})

	var parsed := _parse_jsonl()
	var r = A.eq(parsed["saved_queries"].size(), 1, "one saved query in JSONL")
	if r is String:
		return r
	return A.eq(parsed["saved_queries"][0]["name"], "open-bugs", "query name matches")


# -- Meta mutations -----------------------------------------------------------

func test_set_project_name_updates_jsonl() -> Variant:
	_db.set_project_name("my-project")

	var parsed := _parse_jsonl()
	return A.eq(parsed["meta"].get("project", ""), "my-project", "project name in JSONL")


func test_set_id_prefix_updates_jsonl() -> Variant:
	_db.set_id_prefix("TST")

	var parsed := _parse_jsonl()
	return A.eq(parsed["meta"].get("id_prefix", ""), "TST", "id_prefix in JSONL")


func test_next_id_updates_counter_in_jsonl() -> Variant:
	var old_counter := _db.get_counter()
	var _id := _db.next_id()

	var parsed := _parse_jsonl()
	var new_counter: int = int(parsed["meta"].get("counter", 0))
	return A.is_true(new_counter > old_counter, "counter incremented in JSONL")


# -- Roundtrip: reopen from JSONL after mutations ----------------------------

func test_roundtrip_preserves_data() -> Variant:
	# Create items, events, comments, links
	var id1 := _db.next_id()
	var id2 := _db.next_id()
	_db.insert_item(id1, {
		"type": "bug", "status": "open", "title": "Bug one",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
		"tags": ["critical", "backend"],
	})
	_db.insert_item(id2, {
		"type": "chore", "status": "open", "title": "Chore two",
		"created_at": "2026-03-27T11:00:00Z", "updated_at": "2026-03-27T11:00:00Z",
	})
	_db.add_event(id1, "status_changed", "tester", "open -> active")
	_db.add_link(id1, id2, "blocks")
	_db.add_comment(id1, "reviewer", "Looks bad")
	_db.save_query("all-bugs", {"filter": {"type": "bug"}})

	# Close and delete cache, reopen from JSONL only
	_db.close()
	var cache_path := _jsonl_path + ".cache"
	for suffix: String in ["", "-wal", "-shm"]:
		DirAccess.remove_absolute(cache_path + suffix)

	_db = DocketDBJsonl.open_jsonl(_jsonl_path)
	var r = A.not_null(_db, "reopened from JSONL")
	if r is String:
		return r

	# Verify items
	var item1 := _db.get_item(id1)
	r = A.eq(item1.get("title"), "Bug one", "item 1 title")
	if r is String:
		return r
	r = A.is_true(item1.get("tags", []).has("critical"), "tag preserved")
	if r is String:
		return r

	var item2 := _db.get_item(id2)
	r = A.eq(item2.get("title"), "Chore two", "item 2 title")
	if r is String:
		return r

	# Verify links
	var links := _db.get_links(id1)
	r = A.eq(links.size(), 1, "one link")
	if r is String:
		return r

	# Verify comments
	var comments := _db.list_comments(id1)
	r = A.eq(comments.size(), 1, "one comment")
	if r is String:
		return r

	# Verify saved queries
	var queries := _db.list_queries()
	r = A.eq(queries.size(), 1, "one saved query")
	if r is String:
		return r

	return A.eq(queries[0]["name"], "all-bugs", "query name preserved")


# -- Type checking ------------------------------------------------------------

func test_is_docket_db() -> Variant:
	return A.is_true(_db is DocketDB, "DocketDBJsonl is-a DocketDB")


# -- JSONL file is valid after each mutation ----------------------------------

func test_jsonl_file_ends_with_newline() -> Variant:
	var id := _db.next_id()
	_db.insert_item(id, {
		"type": "bug", "status": "open", "title": "Newline test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	var text := _read_jsonl()
	return A.is_true(text.ends_with("\n"), "JSONL ends with newline")


func test_jsonl_meta_is_first_line() -> Variant:
	var id := _db.next_id()
	_db.insert_item(id, {
		"type": "bug", "status": "open", "title": "Meta first test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
	})
	var text := _read_jsonl()
	var first_line := text.split("\n")[0]
	return A.is_true(first_line.begins_with('{"_type":"meta"'), "first line is meta")


# -- Bump retrieval -----------------------------------------------------------

func test_bump_retrieval_updates_jsonl() -> Variant:
	var id := _db.next_id()
	_db.insert_item(id, {
		"type": "hint", "status": "draft", "title": "Hint test",
		"created_at": "2026-03-27T10:00:00Z", "updated_at": "2026-03-27T10:00:00Z",
		"retrieval_count": 0,
	})
	_db.bump_retrieval(id)

	var parsed := _parse_jsonl()
	var item: Dictionary = parsed["items"][0]
	return A.eq(int(item.get("retrieval_count", 0)), 1, "retrieval_count bumped in JSONL")
