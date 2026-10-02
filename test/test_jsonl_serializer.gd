extends Node
## Unit tests for JSONLSerializer.

var A := AssertHelpers
var _db: DocketDB
var _test_dir := "user://test_jsonl_serializer"
var _test_file: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_test_file = _test_dir + "/test_db.dct"


func before_each() -> void:
	_cleanup_db()
	_db = DocketDB.create_new(_test_file)
	_db.set_counter(0)
	# Force known prefix
	_db.set_id_prefix("TST")
	_db.set_project_name("")


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


# -- _to_ordered_json ---------------------------------------------------------

func test_ordered_json_type_first() -> Variant:
	## _type must always be the first key.
	var d := {"z_field": "z", "_type": "item", "a_field": "a"}
	var json := JSONLSerializer._to_ordered_json(d)
	var r = A.is_true(json.begins_with('{"_type"'), "_type is first key")
	if r is String: return r
	return A.contains(json, '"z_field":"z"', "z_field present")


func test_ordered_json_string_escape() -> Variant:
	## String values are properly JSON-escaped.
	var d := {"_type": "test", "text": "hello\nworld\t\"quoted\""}
	var json := JSONLSerializer._to_ordered_json(d)
	return A.contains(json, '"hello\\nworld\\t\\"quoted\\""', "escape sequences correct")


func test_json_escape_byte_identical_to_char_loop() -> Variant:
	## _json_escape matches the original per-character escaper on every ASCII
	## code point from 0x01, mixed control/quote/backslash runs, non-ASCII, an
	## astral code point and "".
	# A Godot String cannot hold U+0000 or a lone surrogate (U+D800-U+DFFF):
	# String.chr and every UTF-32 append replace each with U+FFFD and report an
	# error, so the corpus cannot cover them. U+FFFD itself is covered. Above
	# the BMP a String holds the code point itself, never a surrogate pair.
	var c := func(code: int) -> String: return String.chr(code)
	# Each code point the corpus is built from must come back as that one code
	# point, or its entry would test U+FFFD (or "") instead.
	for code: int in range(0x01, 0x80) + [0xFFFD, 0x1F600]:
		var ch: String = c.call(code)
		if ch.length() != 1 or ch.unicode_at(0) != code: return "String.chr(0x%x) does not hold that code point" % code
	var all_ascii := ""
	var corpus: Array[String] = ["", "plain", 'a"b\\c', "\t\r\n", "\\\\\"\"",
		"é中" + c.call(0x1F600), "x" + c.call(0x7F) + "y", c.call(0xFFFD),
		c.call(0xFFFD) + c.call(0x01), c.call(0xFFFD) + "\n"]
	for code in range(0x01, 0x80):
		corpus.append(c.call(code))
		all_ascii += c.call(code)
	corpus.append(all_ascii)
	corpus.append(all_ascii + all_ascii)
	corpus.append("\\" + c.call(0x08) + '"' + c.call(0x0C) + "\n" + c.call(0x01)
		+ c.call(0x1F) + "é" + c.call(0x0B) + "\t" + c.call(0x1F600) + c.call(0x1B) + "\\u0001")
	for text: String in corpus:
		var r = A.eq(JSONLSerializer._json_escape(text), _char_loop_escape(text),
				"escape of %s" % str(text.to_utf32_buffer()))
		if r is String: return r
	# Pin the oracle itself on the classes JSON.stringify would render differently.
	return A.eq(JSONLSerializer._json_escape(c.call(0x08) + c.call(0x0C) + c.call(0x1F)),
			"\\u0008\\u000c\\u001f", "\\b \\f and 0x1f as lowercase \\u00xx")


static func _char_loop_escape(s: String) -> String:
	## The original per-character escaper, kept as the byte-identity oracle.
	var result := ""
	for i in s.length():
		var ch := s[i]
		match ch:
			'"':
				result += '\\"'
			'\\':
				result += '\\\\'
			'\n':
				result += '\\n'
			'\r':
				result += '\\r'
			'\t':
				result += '\\t'
			_:
				var code := ch.unicode_at(0)
				if code < 0x20:
					result += "\\u%04x" % code
				else:
					result += ch
	return result


func test_ordered_json_int() -> Variant:
	var d := {"_type": "test", "count": 42}
	var json := JSONLSerializer._to_ordered_json(d)
	return A.contains(json, '"count":42', "integer serialized without quotes")


func test_ordered_json_bool_true() -> Variant:
	var d := {"_type": "test", "flag": true}
	var json := JSONLSerializer._to_ordered_json(d)
	return A.contains(json, '"flag":true', "true serialized without quotes")


func test_ordered_json_bool_false() -> Variant:
	var d := {"_type": "test", "flag": false}
	var json := JSONLSerializer._to_ordered_json(d)
	return A.contains(json, '"flag":false', "false serialized without quotes")


func test_ordered_json_array() -> Variant:
	var d := {"_type": "test", "tags": ["a", "b"]}
	var json := JSONLSerializer._to_ordered_json(d)
	return A.contains(json, '"tags":["a","b"]', "array serialized correctly")


func test_ordered_json_empty_array() -> Variant:
	var d := {"_type": "test", "tags": []}
	var json := JSONLSerializer._to_ordered_json(d)
	return A.contains(json, '"tags":[]', "empty array serialized correctly")


func test_ordered_json_nested_dict() -> Variant:
	## Nested dicts (for saved_query.query field) are serialized inline.
	var d := {"_type": "saved_query", "name": "q1", "query": {"filter": {"type": "bug"}}}
	var json := JSONLSerializer._to_ordered_json(d)
	return A.contains(json, '"query":{"filter":{"type":"bug"}}', "nested dict serialized correctly")


# -- serialize_meta -----------------------------------------------------------

func test_meta_required_fields() -> Variant:
	var json := JSONLSerializer.serialize_meta(_db)
	var r = A.contains(json, '"_type":"meta"', "_type=meta")
	if r is String: return r
	r = A.contains(json, '"version":"1.0.0"', "version present")
	if r is String: return r
	r = A.contains(json, '"counter":0', "counter=0")
	if r is String: return r
	return A.contains(json, '"id_prefix":"TST"', "id_prefix=TST")


func test_meta_with_project() -> Variant:
	_db.set_project_name("myproject")
	var json := JSONLSerializer.serialize_meta(_db)
	return A.contains(json, '"project":"myproject"', "project field present")


func test_meta_no_project_omitted() -> Variant:
	# project name is empty — should not appear
	var json := JSONLSerializer.serialize_meta(_db)
	return A.is_false(json.contains('"project"'), "project omitted when empty")


func test_meta_counter_updates() -> Variant:
	_db.set_counter(42)
	var json := JSONLSerializer.serialize_meta(_db)
	return A.contains(json, '"counter":42', "counter reflects set value")


# -- serialize_items ----------------------------------------------------------

func test_items_empty() -> Variant:
	var s := JSONLSerializer.serialize_items(_db)
	return A.eq(s, "", "empty string when no items")


func test_items_single() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "A bug",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	var s := JSONLSerializer.serialize_items(_db)
	var r = A.contains(s, '"_type":"item"', "_type=item")
	if r is String: return r
	r = A.contains(s, '"id":"TST-0001"', "id present")
	if r is String: return r
	return A.contains(s, '"title":"A bug"', "title present")


func test_items_sorted_by_id() -> Variant:
	_db.insert_item("TST-0002", {
		"type": "chore", "status": "open", "title": "Second",
		"created_at": "2026-03-16T00:00:00Z", "updated_at": "2026-03-16T00:00:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "First",
		"created_at": "2026-03-15T00:00:00Z", "updated_at": "2026-03-15T00:00:00Z",
		"tags": [], "events": [], "links": [],
	})
	var s := JSONLSerializer.serialize_items(_db)
	var pos1 := s.find('"TST-0001"')
	var pos2 := s.find('"TST-0002"')
	return A.is_true(pos1 < pos2, "TST-0001 before TST-0002")


func test_items_tags_embedded() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "Tagged bug",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": ["crash", "config"], "events": [], "links": [],
	})
	var s := JSONLSerializer.serialize_items(_db)
	return A.contains(s, '"tags":', "tags field present in item line")


func test_items_empty_fields_omitted() -> Variant:
	## Empty string fields like description, created_by must be omitted.
	_db.insert_item("TST-0001", {
		"type": "chore", "status": "open", "title": "Minimal",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	var s := JSONLSerializer.serialize_items(_db)
	var r = A.is_false(s.contains('"description"'), "description omitted when empty")
	if r is String: return r
	return A.is_false(s.contains('"created_by"'), "created_by omitted when empty")


func test_items_zero_priority_omitted() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "No priority",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"priority": 0, "tags": [], "events": [], "links": [],
	})
	var s := JSONLSerializer.serialize_items(_db)
	return A.is_false(s.contains('"priority"'), "priority=0 omitted")


func test_items_nonzero_priority_included() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "Has priority",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"priority": 2, "tags": [], "events": [], "links": [],
	})
	var s := JSONLSerializer.serialize_items(_db)
	return A.contains(s, '"priority":2', "priority=2 included")


func test_items_type_first_in_line() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	var s := JSONLSerializer.serialize_items(_db)
	return A.is_true(s.begins_with('{"_type"'), "_type is first key")


# -- serialize_events ---------------------------------------------------------

func test_events_empty() -> Variant:
	var s := JSONLSerializer.serialize_events(_db)
	return A.eq(s, "", "empty when no events")


func test_events_seq_numbering() -> Variant:
	## Events for the same item get sequential seq numbers starting at 1.
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_event("TST-0001", "created", "imran", "Item created")
	_db.add_event("TST-0001", "updated", "imran", "Some update")

	var s := JSONLSerializer.serialize_events(_db)
	var r = A.contains(s, '"seq":1', "first event has seq=1")
	if r is String: return r
	return A.contains(s, '"seq":2', "second event has seq=2")


func test_events_seq_resets_per_item() -> Variant:
	## seq resets to 1 for each new item_id.
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "A",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.insert_item("TST-0002", {
		"type": "chore", "status": "open", "title": "B",
		"created_at": "2026-03-16T10:30:00Z", "updated_at": "2026-03-16T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_event("TST-0001", "created", "imran", "Created")
	_db.add_event("TST-0001", "updated", "imran", "Updated")
	_db.add_event("TST-0002", "created", "dana", "Created")

	var s := JSONLSerializer.serialize_events(_db)
	# TST-0002 event should have seq=1
	var pos_item2 := s.find('"TST-0002"')
	var substr_after_item2 := s.substr(pos_item2)
	return A.contains(substr_after_item2, '"seq":1', "TST-0002 event has seq=1")


func test_events_sorted_by_item_id_then_seq() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "A",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.insert_item("TST-0002", {
		"type": "chore", "status": "open", "title": "B",
		"created_at": "2026-03-16T10:30:00Z", "updated_at": "2026-03-16T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_event("TST-0002", "created", "dana", "Created B")
	_db.add_event("TST-0001", "created", "imran", "Created A")

	var s := JSONLSerializer.serialize_events(_db)
	var pos1 := s.find('"TST-0001"')
	var pos2 := s.find('"TST-0002"')
	return A.is_true(pos1 < pos2, "TST-0001 events before TST-0002 events")


func test_events_actor_omitted_when_empty() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "hint", "status": "draft", "title": "H",
		"created_at": "2026-03-17T12:00:00Z", "updated_at": "2026-03-17T12:00:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_event("TST-0001", "created", "", "Item created")
	var s := JSONLSerializer.serialize_events(_db)
	return A.is_false(s.contains('"actor"'), "actor omitted when empty")


func test_events_type_first() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_event("TST-0001", "created", "imran", "Created")
	var s := JSONLSerializer.serialize_events(_db)
	return A.is_true(s.begins_with('{"_type"'), "_type is first key in event line")


# -- serialize_comments -------------------------------------------------------

func test_comments_empty() -> Variant:
	var s := JSONLSerializer.serialize_comments(_db)
	return A.eq(s, "", "empty when no comments")


func test_comments_basic() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_comment("TST-0001", "imran", "Hello world")
	var s := JSONLSerializer.serialize_comments(_db)
	var r = A.contains(s, '"_type":"comment"', "_type=comment")
	if r is String: return r
	r = A.contains(s, '"item_id":"TST-0001"', "item_id present")
	if r is String: return r
	return A.contains(s, '"author":"imran"', "author present")


func test_comments_status_open_omitted() -> Variant:
	## status="open" must be omitted.
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_comment("TST-0001", "imran", "A comment")
	var s := JSONLSerializer.serialize_comments(_db)
	return A.is_false(s.contains('"status"'), "status=open omitted")


func test_comments_status_accepted_included() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	var c := _db.add_comment("TST-0001", "imran", "Good catch")
	_db.resolve_comment(c.id, "accepted", "dana")
	var s := JSONLSerializer.serialize_comments(_db)
	return A.contains(s, '"status":"accepted"', "status=accepted included")


func test_comments_parent_id_zero_omitted() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_comment("TST-0001", "imran", "Top-level comment")
	var s := JSONLSerializer.serialize_comments(_db)
	return A.is_false(s.contains('"parent_id"'), "parent_id=0 omitted")


func test_comments_parent_id_included() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	var parent := _db.add_comment("TST-0001", "imran", "Parent comment")
	_db.add_comment("TST-0001", "dana", "Reply", parent.id)
	var s := JSONLSerializer.serialize_comments(_db)
	return A.contains(s, '"parent_id":%d' % parent.id, "parent_id included for reply")


# -- serialize_links ----------------------------------------------------------

func test_links_empty() -> Variant:
	var s := JSONLSerializer.serialize_links(_db)
	return A.eq(s, "", "empty when no links")


func test_links_basic() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "A",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.insert_item("TST-0002", {
		"type": "chore", "status": "open", "title": "B",
		"created_at": "2026-03-16T10:30:00Z", "updated_at": "2026-03-16T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_link("TST-0002", "TST-0001", "follow_up")
	var s := JSONLSerializer.serialize_links(_db)
	var r = A.contains(s, '"_type":"link"', "_type=link")
	if r is String: return r
	r = A.contains(s, '"from_id":"TST-0002"', "from_id present")
	if r is String: return r
	r = A.contains(s, '"to_id":"TST-0001"', "to_id present")
	if r is String: return r
	return A.contains(s, '"relation":"follow_up"', "relation present")


func test_links_sorted() -> Variant:
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "A",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.insert_item("TST-0002", {
		"type": "chore", "status": "open", "title": "B",
		"created_at": "2026-03-16T10:30:00Z", "updated_at": "2026-03-16T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_link("TST-0002", "TST-0001", "follow_up")
	_db.add_link("TST-0001", "TST-0002", "blocks")
	var s := JSONLSerializer.serialize_links(_db)
	var pos1 := s.find('"from_id":"TST-0001"')
	var pos2 := s.find('"from_id":"TST-0002"')
	return A.is_true(pos1 < pos2, "TST-0001 links before TST-0002 links")


# -- serialize_saved_queries --------------------------------------------------

func test_saved_queries_empty() -> Variant:
	var s := JSONLSerializer.serialize_saved_queries(_db)
	return A.eq(s, "", "empty when no saved queries")


func test_saved_queries_basic() -> Variant:
	_db.save_query("open-bugs", {"filter": {"type": "bug", "status__ne": "closed"}})
	var s := JSONLSerializer.serialize_saved_queries(_db)
	var r = A.contains(s, '"_type":"saved_query"', "_type=saved_query")
	if r is String: return r
	r = A.contains(s, '"name":"open-bugs"', "name present")
	if r is String: return r
	return A.contains(s, '"query":', "query field present")


func test_saved_queries_sorted_by_name() -> Variant:
	_db.save_query("z-query", {"filter": {"type": "chore"}})
	_db.save_query("a-query", {"filter": {"type": "bug"}})
	var s := JSONLSerializer.serialize_saved_queries(_db)
	var pos_a := s.find('"a-query"')
	var pos_z := s.find('"z-query"')
	return A.is_true(pos_a < pos_z, "a-query before z-query")


func test_saved_queries_query_is_object() -> Variant:
	## The query field must be a JSON object, not a string.
	_db.save_query("my-query", {"filter": {"type": "bug"}})
	var s := JSONLSerializer.serialize_saved_queries(_db)
	# If query were a string, it would look like: "query":"{\"filter\":..."
	# As an object it should look like: "query":{"filter":...
	return A.contains(s, '"query":{"filter":', "query is embedded object not string")


# -- serialize_all ------------------------------------------------------------

func test_serialize_all_empty_db() -> Variant:
	## Even with no items, serialize_all must produce a meta line.
	var s := JSONLSerializer.serialize_all(_db)
	var r = A.is_false(s.is_empty(), "output is not empty")
	if r is String: return r
	r = A.contains(s, '"_type":"meta"', "meta line present")
	if r is String: return r
	# File must end with \n
	return A.is_true(s.ends_with("\n"), "file ends with newline")


func test_serialize_all_line_order() -> Variant:
	## meta must come before items, items before events, events before comments, etc.
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "A Bug",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_event("TST-0001", "created", "imran", "Created")
	_db.add_comment("TST-0001", "dana", "A comment")
	_db.insert_item("TST-0002", {
		"type": "chore", "status": "open", "title": "B",
		"created_at": "2026-03-16T10:30:00Z", "updated_at": "2026-03-16T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	_db.add_link("TST-0002", "TST-0001", "follow_up")
	_db.save_query("open-bugs", {"filter": {"type": "bug"}})

	var s := JSONLSerializer.serialize_all(_db)
	var pos_meta := s.find('"_type":"meta"')
	var pos_item := s.find('"_type":"item"')
	var pos_event := s.find('"_type":"event"')
	var pos_comment := s.find('"_type":"comment"')
	var pos_link := s.find('"_type":"link"')
	var pos_query := s.find('"_type":"saved_query"')

	var r = A.is_true(pos_meta < pos_item, "meta before item")
	if r is String: return r
	r = A.is_true(pos_item < pos_event, "item before event")
	if r is String: return r
	r = A.is_true(pos_event < pos_comment, "event before comment")
	if r is String: return r
	r = A.is_true(pos_comment < pos_link, "comment before link")
	if r is String: return r
	return A.is_true(pos_link < pos_query, "link before saved_query")


func test_serialize_all_each_line_valid_json() -> Variant:
	## Every non-empty line in the output must parse as a JSON object.
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "Line\"break test\nand tab\there",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": ["a", "b"], "events": [], "links": [],
	})
	_db.add_event("TST-0001", "created", "imran", "Note with\nnewline")
	_db.add_comment("TST-0001", "dana", "Comment with \"quotes\"")

	var s := JSONLSerializer.serialize_all(_db)
	var lines := s.split("\n")
	for line in lines:
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if parsed == null:
			return "line is not valid JSON: %s" % line.left(120)
	return true


func test_serialize_all_ends_with_newline() -> Variant:
	var s := JSONLSerializer.serialize_all(_db)
	return A.is_true(s.ends_with("\n"), "file ends with \\n")


func test_serialize_all_no_empty_lines_in_middle() -> Variant:
	## There must be no empty lines except possibly the last one.
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "new", "title": "X",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-15T10:30:00Z",
		"tags": [], "events": [], "links": [],
	})
	var s := JSONLSerializer.serialize_all(_db)
	var lines := s.split("\n")
	# The last element after the final \n is an empty string — that's fine
	for i in lines.size() - 1:
		if lines[i].is_empty():
			return "empty line at index %d (not the last)" % i
	return true


# -- Roundtrip sanity ---------------------------------------------------------

func test_roundtrip_meta_values() -> Variant:
	## After parsing the meta line, values should match the DB state.
	_db.set_counter(7)
	_db.set_id_prefix("MNV")
	_db.set_project_name("minerva")
	var s := JSONLSerializer.serialize_meta(_db)
	var parsed = JSON.parse_string(s)
	if parsed == null:
		return "meta line is not valid JSON"
	var r = A.eq(str(parsed.get("_type", "")), "meta", "_type=meta")
	if r is String: return r
	r = A.eq(int(parsed.get("counter", -1)), 7, "counter=7")
	if r is String: return r
	r = A.eq(str(parsed.get("id_prefix", "")), "MNV", "id_prefix=MNV")
	if r is String: return r
	return A.eq(str(parsed.get("project", "")), "minerva", "project=minerva")


func test_roundtrip_item_fields() -> Variant:
	## Serialize an item and parse the line back, verifying all fields.
	_db.insert_item("TST-0001", {
		"type": "bug", "status": "active", "title": "A crash bug",
		"description": "Steps to reproduce...",
		"created_at": "2026-03-15T10:30:00Z", "updated_at": "2026-03-20T14:22:00Z",
		"created_by": "imran", "assigned_to": "imran",
		"priority": 2, "severity": 1,
		"tags": ["crash", "config"],
		"environment": "Linux 6.8",
		"events": [], "links": [],
	})
	var s := JSONLSerializer.serialize_items(_db)
	var parsed = JSON.parse_string(s)
	if parsed == null:
		return "item line is not valid JSON"
	var r = A.eq(str(parsed.get("_type", "")), "item", "_type=item")
	if r is String: return r
	r = A.eq(str(parsed.get("id", "")), "TST-0001", "id")
	if r is String: return r
	r = A.eq(str(parsed.get("type", "")), "bug", "type")
	if r is String: return r
	r = A.eq(str(parsed.get("status", "")), "active", "status")
	if r is String: return r
	r = A.eq(str(parsed.get("title", "")), "A crash bug", "title")
	if r is String: return r
	r = A.eq(int(parsed.get("priority", 0)), 2, "priority")
	if r is String: return r
	r = A.eq(int(parsed.get("severity", 0)), 1, "severity")
	if r is String: return r
	var tags: Array = parsed.get("tags", [])
	r = A.eq(tags.size(), 2, "tags count")
	if r is String: return r
	return A.eq(str(parsed.get("environment", "")), "Linux 6.8", "environment")


func test_event_unknown_keys_survive_cache_round_trip() -> Variant:
	var source_path: String = _test_dir + "/event_extras.dct"
	var source := '{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"TST"}\n'
	source += '{"_type":"item","id":"TST-0001","type":"bug","status":"open","title":"Future event","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
	var event := {"_type": "event", "item_id": "TST-0001", "seq": 1,
		"event_type": "created", "timestamp": "2026-01-01T00:00:00Z",
		"x_future": 1, "x_payload": {"null": null, "false": false, "zero": 0, "empty": [], "text": ""}}
	source += JSON.stringify(event) + "\n"
	var file := FileAccess.open(source_path, FileAccess.WRITE)
	if file == null: return "cannot write event round-trip fixture"
	file.store_string(source)
	file.close()
	var cache: DocketDB = JSONLCache.rebuild_cache(source_path, source_path + ".cache")
	if cache == null: return "event cache rebuild failed: " + JSONLCache.last_error
	var serialized: String = JSONLSerializer.serialize_events(cache)
	cache.close()
	var output: Variant = JSON.parse_string(serialized)
	if not output is Dictionary: return "serialized event is not an object"
	# JSON parses every number as float, including nested integral values.
	var expected: Dictionary = JSON.parse_string(JSON.stringify(event))
	var result: Variant = A.eq(output.get("x_future"), expected.x_future, "future event key survives cache")
	if result is String: return result
	result = A.eq(output.get("x_payload"), expected.x_payload, "nested empty and false values survive")
	if result is String: return result
	return A.eq(JSONLParser.parse_line(serialized).get("extras", {}),
		{"x_future": expected.x_future, "x_payload": expected.x_payload}, "serialized event reparses with extras")
