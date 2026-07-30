extends Node
## Unit tests for JSONLParser.

var A := AssertHelpers


# -- Helpers ------------------------------------------------------------------

## Build a minimal valid JSONL file as a String for testing.
static func _minimal_jsonl() -> String:
	return (
		'{"_type":"meta","version":"1.0.0","counter":3,"id_prefix":"MNV","project":"minerva"}\n'
		+ '{"_type":"item","id":"MNV-0001","type":"bug","status":"active","title":"Crash on empty config","created_at":"2026-03-15T10:30:00Z","updated_at":"2026-03-20T14:22:00Z"}\n'
		+ '{"_type":"item","id":"MNV-0002","type":"chore","status":"open","title":"Update dependencies","created_at":"2026-03-16T08:00:00Z","updated_at":"2026-03-16T08:00:00Z","created_by":"imran","tags":["maintenance"]}\n'
		+ '{"_type":"event","item_id":"MNV-0001","seq":1,"event_type":"created","actor":"imran","timestamp":"2026-03-15T10:30:00Z","note":"Item created"}\n'
		+ '{"_type":"event","item_id":"MNV-0001","seq":2,"event_type":"status_changed","actor":"imran","timestamp":"2026-03-16T09:00:00Z"}\n'
		+ '{"_type":"comment","id":1,"item_id":"MNV-0001","author":"dana","text":"I can reproduce this.","created_at":"2026-03-19T15:30:00Z"}\n'
		+ '{"_type":"comment","id":2,"item_id":"MNV-0001","author":"imran","text":"Thanks.","created_at":"2026-03-19T16:00:00Z","parent_id":1}\n'
		+ '{"_type":"link","from_id":"MNV-0002","to_id":"MNV-0001","relation":"follow_up"}\n'
		+ '{"_type":"saved_query","name":"open-bugs","query":{"filter":{"type":"bug","status__ne":"closed"}}}\n'
	)


static func _write_temp_file(content: String, filename: String) -> String:
	var dir := "user://test_jsonl_parser"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir + "/" + filename
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(content)
		f.close()
	return path


func teardown() -> void:
	var dir := DirAccess.open("user://test_jsonl_parser")
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			DirAccess.remove_absolute("user://test_jsonl_parser/" + fname)
			fname = dir.get_next()
		DirAccess.remove_absolute("user://test_jsonl_parser")


# -- parse_file: basic structure ----------------------------------------------

func test_parse_file_returns_all_keys() -> Variant:
	var path := _write_temp_file(_minimal_jsonl(), "basic.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var r = A.has_key(result, "meta", "has meta")
	if r is String: return r
	r = A.has_key(result, "items", "has items")
	if r is String: return r
	r = A.has_key(result, "events", "has events")
	if r is String: return r
	r = A.has_key(result, "comments", "has comments")
	if r is String: return r
	r = A.has_key(result, "links", "has links")
	if r is String: return r
	r = A.has_key(result, "attachments", "has attachments")
	if r is String: return r
	r = A.has_key(result, "secrets", "has secrets")
	if r is String: return r
	r = A.has_key(result, "secret_versions", "has secret_versions")
	if r is String: return r
	return A.has_key(result, "saved_queries", "has saved_queries")


func test_parse_file_meta() -> Variant:
	var path := _write_temp_file(_minimal_jsonl(), "meta.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var meta: Dictionary = result["meta"]
	var r = A.eq(meta["_type"], "meta", "_type")
	if r is String: return r
	r = A.eq(meta["version"], "1.0.0", "version")
	if r is String: return r
	r = A.eq(meta["counter"], 3, "counter")
	if r is String: return r
	r = A.eq(meta["id_prefix"], "MNV", "id_prefix")
	if r is String: return r
	return A.eq(meta["project"], "minerva", "project")


func test_parse_file_items_count() -> Variant:
	var path := _write_temp_file(_minimal_jsonl(), "items.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	return A.eq(result["items"].size(), 2, "two items")


func test_parse_file_item_fields() -> Variant:
	var path := _write_temp_file(_minimal_jsonl(), "itemfields.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var item: Dictionary = result["items"][0]
	var r = A.eq(item["id"], "MNV-0001", "id")
	if r is String: return r
	r = A.eq(item["type"], "bug", "type")
	if r is String: return r
	r = A.eq(item["status"], "active", "status")
	if r is String: return r
	r = A.eq(item["title"], "Crash on empty config", "title")
	if r is String: return r
	r = A.eq(item["created_at"], "2026-03-15T10:30:00Z", "created_at")
	if r is String: return r
	return A.eq(item["updated_at"], "2026-03-20T14:22:00Z", "updated_at")


func test_parse_file_item_optional_fields() -> Variant:
	var path := _write_temp_file(_minimal_jsonl(), "itemopt.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	# Second item has created_by and tags
	var item: Dictionary = result["items"][1]
	var r = A.eq(item["created_by"], "imran", "created_by")
	if r is String: return r
	r = A.has_key(item, "tags", "has tags")
	if r is String: return r
	return A.eq(item["tags"].size(), 1, "one tag")


func test_parse_file_item_no_absent_optionals() -> Variant:
	## Fields that were omitted in the JSONL should not appear in the result dict
	## (optional fields are only copied when present and non-empty).
	var path := _write_temp_file(_minimal_jsonl(), "itemabsent.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var item: Dictionary = result["items"][0]
	# MNV-0001 has no description, created_by etc.
	return A.is_false(item.has("description"), "no description key")


func test_parse_file_events() -> Variant:
	var path := _write_temp_file(_minimal_jsonl(), "events.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var r = A.eq(result["events"].size(), 2, "two events")
	if r is String: return r
	var ev: Dictionary = result["events"][0]
	r = A.eq(ev["item_id"], "MNV-0001", "item_id")
	if r is String: return r
	r = A.eq(ev["seq"], 1, "seq")
	if r is String: return r
	r = A.eq(ev["event_type"], "created", "event_type")
	if r is String: return r
	return A.eq(ev["actor"], "imran", "actor")


func test_parse_file_event_optional_note() -> Variant:
	var path := _write_temp_file(_minimal_jsonl(), "evnote.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	# First event has note; second does not
	var ev1: Dictionary = result["events"][0]
	var r = A.eq(ev1["note"], "Item created", "note present")
	if r is String: return r
	var ev2: Dictionary = result["events"][1]
	return A.is_false(ev2.has("note"), "note absent when omitted")


func test_parse_file_comments() -> Variant:
	var path := _write_temp_file(_minimal_jsonl(), "comments.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var r = A.eq(result["comments"].size(), 2, "two comments")
	if r is String: return r
	var c: Dictionary = result["comments"][0]
	r = A.eq(c["id"], 1, "comment id")
	if r is String: return r
	r = A.eq(c["item_id"], "MNV-0001", "item_id")
	if r is String: return r
	r = A.eq(c["author"], "dana", "author")
	if r is String: return r
	return A.eq(c["created_at"], "2026-03-19T15:30:00Z", "created_at")


func test_parse_file_comment_parent_id() -> Variant:
	var path := _write_temp_file(_minimal_jsonl(), "commentparent.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var c1: Dictionary = result["comments"][0]
	var c2: Dictionary = result["comments"][1]
	var r = A.is_false(c1.has("parent_id"), "no parent_id on top-level comment")
	if r is String: return r
	return A.eq(c2["parent_id"], 1, "child has parent_id=1")


func test_parse_file_links() -> Variant:
	var path := _write_temp_file(_minimal_jsonl(), "links.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var r = A.eq(result["links"].size(), 1, "one link")
	if r is String: return r
	var lnk: Dictionary = result["links"][0]
	r = A.eq(lnk["from_id"], "MNV-0002", "from_id")
	if r is String: return r
	r = A.eq(lnk["to_id"], "MNV-0001", "to_id")
	if r is String: return r
	return A.eq(lnk["relation"], "follow_up", "relation")


func test_parse_file_saved_queries() -> Variant:
	var path := _write_temp_file(_minimal_jsonl(), "queries.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var r = A.eq(result["saved_queries"].size(), 1, "one saved query")
	if r is String: return r
	var sq: Dictionary = result["saved_queries"][0]
	r = A.eq(sq["name"], "open-bugs", "name")
	if r is String: return r
	r = A.has_key(sq, "query", "has query")
	if r is String: return r
	return A.is_true(sq["query"] is Dictionary, "query is dict")


# -- parse_file: attachments --------------------------------------------------

func test_parse_attachment_decodes_base64() -> Variant:
	# "hello" in base64 is "aGVsbG8="
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"_type":"item","id":"T-0001","type":"chore","status":"open","title":"X","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
		+ '{"_type":"attachment","id":1,"item_id":"T-0001","filename":"hello.txt","data":"aGVsbG8=","created_at":"2026-01-01T00:00:00Z"}\n'
	)
	var path := _write_temp_file(jsonl, "att.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var r = A.eq(result["attachments"].size(), 1, "one attachment")
	if r is String: return r
	var att: Dictionary = result["attachments"][0]
	r = A.eq(att["id"], 1, "att id")
	if r is String: return r
	r = A.eq(att["filename"], "hello.txt", "filename")
	if r is String: return r
	r = A.is_true(att["data"] is PackedByteArray, "data is PackedByteArray")
	if r is String: return r
	# "hello" = [104, 101, 108, 108, 111]
	var expected := PackedByteArray([104, 101, 108, 108, 111])
	return A.eq(att["data"], expected, "decoded bytes match")


# -- parse_file: secrets & versions -------------------------------------------

func test_parse_secret() -> Variant:
	# Use short base64 values
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"_type":"secret","handle":"abc123","ciphertext":"Y2lwaGVy","iv":"aXY=","mac":"bWFj","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}\n'
	)
	var path := _write_temp_file(jsonl, "secret.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var r = A.eq(result["secrets"].size(), 1, "one secret")
	if r is String: return r
	var s: Dictionary = result["secrets"][0]
	r = A.eq(s["handle"], "abc123", "handle")
	if r is String: return r
	r = A.is_true(s["ciphertext"] is PackedByteArray, "ciphertext is bytes")
	if r is String: return r
	r = A.is_false(s["requires_2fa"], "requires_2fa defaults to false")
	if r is String: return r
	return A.eq(s["ciphertext_b64"], "Y2lwaGVy", "raw b64 preserved")


func test_parse_secret_requires_2fa() -> Variant:
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"_type":"secret","handle":"s1","ciphertext":"Y2lwaGVy","iv":"aXY=","mac":"bWFj","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","requires_2fa":true}\n'
	)
	var path := _write_temp_file(jsonl, "secret2fa.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var r = A.eq(result["secrets"].size(), 1, "one secret")
	if r is String: return r
	return A.is_true(result["secrets"][0]["requires_2fa"], "requires_2fa is true")


func test_parse_secret_version() -> Variant:
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"_type":"secret_version","handle":"abc123","version":1,"ciphertext":"Y2lwaGVy","iv":"aXY=","mac":"bWFj","created_at":"2026-01-01T00:00:00Z","rotated_by":"imran"}\n'
	)
	var path := _write_temp_file(jsonl, "secver.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var r = A.eq(result["secret_versions"].size(), 1, "one version")
	if r is String: return r
	var sv: Dictionary = result["secret_versions"][0]
	r = A.eq(sv["handle"], "abc123", "handle")
	if r is String: return r
	r = A.eq(sv["version"], 1, "version")
	if r is String: return r
	return A.eq(sv["rotated_by"], "imran", "rotated_by")


# -- parse_file: error handling -----------------------------------------------

func test_parse_file_not_found() -> Variant:
	var result := JSONLParser.parse_file("user://nonexistent_file_xyz.dct.jsonl")
	var r = A.has_key(result, "meta", "has meta key")
	if r is String: return r
	r = A.is_true(result["meta"].is_empty(), "meta is empty dict")
	if r is String: return r
	return A.eq(result["items"].size(), 0, "items is empty")


func test_parse_file_skips_empty_lines() -> Variant:
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ "\n"
		+ '{"_type":"item","id":"T-0001","type":"chore","status":"open","title":"X","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
		+ "   \n"
		+ '{"_type":"item","id":"T-0002","type":"chore","status":"open","title":"Y","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
	)
	var path := _write_temp_file(jsonl, "emptylines.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	return A.eq(result["items"].size(), 2, "two items despite empty lines")


func test_parse_file_skips_malformed_json() -> Variant:
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":2,"id_prefix":"T"}\n'
		+ 'not valid json {\n'
		+ '{"_type":"item","id":"T-0001","type":"chore","status":"open","title":"X","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
	)
	var path := _write_temp_file(jsonl, "malformed.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	# Bad line is skipped, good item still parsed
	return A.eq(result["items"].size(), 1, "one item despite malformed line")


func test_parse_file_skips_unknown_type() -> Variant:
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"_type":"future_thing","data":"something"}\n'
		+ '{"_type":"item","id":"T-0001","type":"chore","status":"open","title":"X","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
	)
	var path := _write_temp_file(jsonl, "unknowntype.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	return A.eq(result["items"].size(), 1, "item parsed despite unknown _type line")


func test_parse_file_skips_missing_type_field() -> Variant:
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"id":"T-0001","title":"No type field"}\n'
		+ '{"_type":"item","id":"T-0002","type":"chore","status":"open","title":"X","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
	)
	var path := _write_temp_file(jsonl, "notype.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	return A.eq(result["items"].size(), 1, "item parsed; line-without-_type skipped")


func test_parse_file_ignores_unknown_fields() -> Variant:
	## Unknown fields in known line types should be ignored (no crash).
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"_type":"item","id":"T-0001","type":"chore","status":"open","title":"X","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","future_field":"ignored"}\n'
	)
	var path := _write_temp_file(jsonl, "unknownfield.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	return A.eq(result["items"].size(), 1, "item parsed with unknown field present")


# -- parse_line ---------------------------------------------------------------

func test_parse_line_meta() -> Variant:
	var d := JSONLParser.parse_line('{"_type":"meta","version":"1.0.0","counter":5,"id_prefix":"X"}')
	var r = A.eq(d["_type"], "meta", "_type")
	if r is String: return r
	r = A.eq(d["version"], "1.0.0", "version")
	if r is String: return r
	r = A.eq(d["counter"], 5, "counter")
	if r is String: return r
	return A.eq(d["id_prefix"], "X", "id_prefix")


func test_parse_line_item() -> Variant:
	var d := JSONLParser.parse_line('{"_type":"item","id":"X-0001","type":"bug","status":"new","title":"T","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}')
	return A.eq(d["id"], "X-0001", "id")


func test_parse_line_empty_returns_empty_dict() -> Variant:
	var d := JSONLParser.parse_line("")
	return A.is_true(d.is_empty(), "empty line gives empty dict")


func test_parse_line_invalid_json_returns_empty_dict() -> Variant:
	var d := JSONLParser.parse_line("not json")
	return A.is_true(d.is_empty(), "invalid json gives empty dict")


func test_parse_line_unknown_type_returns_empty_dict() -> Variant:
	var d := JSONLParser.parse_line('{"_type":"unknown_xyz","data":"x"}')
	return A.is_true(d.is_empty(), "unknown _type gives empty dict")


func test_parse_line_missing_type_returns_empty_dict() -> Variant:
	var d := JSONLParser.parse_line('{"id":"X-0001","title":"no type"}')
	return A.is_true(d.is_empty(), "missing _type gives empty dict")


# -- validate_meta ------------------------------------------------------------

func test_validate_meta_valid() -> Variant:
	var meta := {"_type": "meta", "version": "1.0.0", "counter": 0, "id_prefix": "MNV"}
	return A.is_true(JSONLParser.validate_meta(meta), "valid meta passes")


func test_validate_meta_missing_version() -> Variant:
	var meta := {"_type": "meta", "counter": 0, "id_prefix": "MNV"}
	return A.is_false(JSONLParser.validate_meta(meta), "missing version fails")


func test_validate_meta_missing_counter() -> Variant:
	var meta := {"_type": "meta", "version": "1.0.0", "id_prefix": "MNV"}
	return A.is_false(JSONLParser.validate_meta(meta), "missing counter fails")


func test_validate_meta_missing_id_prefix() -> Variant:
	var meta := {"_type": "meta", "version": "1.0.0", "counter": 0}
	return A.is_false(JSONLParser.validate_meta(meta), "missing id_prefix fails")


func test_validate_meta_wrong_type_field() -> Variant:
	var meta := {"_type": "item", "version": "1.0.0", "counter": 0, "id_prefix": "X"}
	return A.is_false(JSONLParser.validate_meta(meta), "wrong _type fails")


func test_validate_meta_empty_version_fails() -> Variant:
	var meta := {"_type": "meta", "version": "", "counter": 0, "id_prefix": "X"}
	return A.is_false(JSONLParser.validate_meta(meta), "empty version fails")


# -- Meta extra fields --------------------------------------------------------

func test_meta_extra_fields_preserved() -> Variant:
	## Any extra key-value pairs on the meta line are preserved for extensibility.
	var jsonl := '{"_type":"meta","version":"1.0.0","counter":0,"id_prefix":"T","custom_key":"custom_val"}\n'
	var path := _write_temp_file(jsonl, "metaextra.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var meta: Dictionary = result["meta"]
	return A.eq(meta.get("custom_key", ""), "custom_val", "extra field preserved")


# -- Item with all optional fields --------------------------------------------

func test_parse_item_all_optional_fields() -> Variant:
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"_type":"item","id":"T-0001","type":"bug","status":"active","title":"Big bug",'
		+ '"description":"desc","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",'
		+ '"created_by":"alice","assigned_to":"bob","priority":2,"severity":3,'
		+ '"tags":["a","b"],"environment":"Linux","resolution":"fixed",'
		+ '"retrieval_count":5,"research_cost":10}\n'
	)
	var path := _write_temp_file(jsonl, "itemall.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var item: Dictionary = result["items"][0]
	var r = A.eq(item["description"], "desc", "description")
	if r is String: return r
	r = A.eq(item["created_by"], "alice", "created_by")
	if r is String: return r
	r = A.eq(item["assigned_to"], "bob", "assigned_to")
	if r is String: return r
	r = A.eq(item["priority"], 2, "priority")
	if r is String: return r
	r = A.eq(item["severity"], 3, "severity")
	if r is String: return r
	r = A.eq(item["tags"].size(), 2, "two tags")
	if r is String: return r
	r = A.eq(item["environment"], "Linux", "environment")
	if r is String: return r
	r = A.eq(item["resolution"], "fixed", "resolution")
	if r is String: return r
	r = A.eq(item["retrieval_count"], 5, "retrieval_count")
	if r is String: return r
	return A.eq(item["research_cost"], 10, "research_cost")


# -- Complete example from the spec -------------------------------------------

func test_spec_complete_example() -> Variant:
	## Parse the complete example from Section 11 of jsonl_format.md.
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":3,"id_prefix":"MNV","project":"minerva"}\n'
		+ '{"_type":"item","id":"MNV-0001","type":"bug","status":"active","title":"Crash on empty config","description":"App crashes when config file is missing.","created_at":"2026-03-15T10:30:00Z","updated_at":"2026-03-20T14:22:00Z","created_by":"imran","assigned_to":"imran","priority":2,"severity":1,"tags":["crash","config"],"environment":"Linux 6.8"}\n'
		+ '{"_type":"item","id":"MNV-0002","type":"chore","status":"open","title":"Update dependencies","created_at":"2026-03-16T08:00:00Z","updated_at":"2026-03-16T08:00:00Z","created_by":"imran","tags":["maintenance"]}\n'
		+ '{"_type":"item","id":"MNV-0003","type":"hint","status":"draft","title":"Build command","created_at":"2026-03-17T12:00:00Z","updated_at":"2026-03-17T12:00:00Z","value":"scons platform=linux","component":"build","key":"run"}\n'
		+ '{"_type":"event","item_id":"MNV-0001","seq":1,"event_type":"created","actor":"imran","timestamp":"2026-03-15T10:30:00Z","note":"Item created"}\n'
		+ '{"_type":"event","item_id":"MNV-0001","seq":2,"event_type":"status_changed","actor":"imran","timestamp":"2026-03-16T09:00:00Z","note":"new -> triaged"}\n'
		+ '{"_type":"event","item_id":"MNV-0001","seq":3,"event_type":"status_changed","actor":"imran","timestamp":"2026-03-18T11:00:00Z","note":"triaged -> active"}\n'
		+ '{"_type":"event","item_id":"MNV-0001","seq":4,"event_type":"comment_added","actor":"dana","timestamp":"2026-03-19T15:30:00Z","note":"I can reproduce this on"}\n'
		+ '{"_type":"event","item_id":"MNV-0002","seq":1,"event_type":"created","actor":"imran","timestamp":"2026-03-16T08:00:00Z","note":"Item created"}\n'
		+ '{"_type":"event","item_id":"MNV-0003","seq":1,"event_type":"created","timestamp":"2026-03-17T12:00:00Z","note":"Item created"}\n'
		+ '{"_type":"comment","id":1,"item_id":"MNV-0001","author":"dana","text":"I can reproduce this on Linux 6.8 and 6.10.","created_at":"2026-03-19T15:30:00Z"}\n'
		+ '{"_type":"comment","id":2,"item_id":"MNV-0001","author":"imran","text":"Thanks, I\'ll look into it.","created_at":"2026-03-19T16:00:00Z","parent_id":1}\n'
		+ '{"_type":"link","from_id":"MNV-0002","to_id":"MNV-0001","relation":"follow_up"}\n'
		+ '{"_type":"saved_query","name":"open-bugs","query":{"filter":{"type":"bug","status__ne":"closed"},"sort":[{"field":"priority","dir":"asc"}]}}\n'
	)
	var path := _write_temp_file(jsonl, "spec_example.dct.jsonl")
	var result := JSONLParser.parse_file(path)
	var r = A.eq(result["items"].size(), 3, "3 items")
	if r is String: return r
	r = A.eq(result["events"].size(), 6, "6 events")
	if r is String: return r
	r = A.eq(result["comments"].size(), 2, "2 comments")
	if r is String: return r
	r = A.eq(result["links"].size(), 1, "1 link")
	if r is String: return r
	r = A.eq(result["saved_queries"].size(), 1, "1 saved query")
	if r is String: return r
	# Check meta
	r = A.eq(result["meta"]["counter"], 3, "meta counter=3")
	if r is String: return r
	# Check item tags
	var bug: Dictionary = result["items"][0]
	r = A.eq(bug["tags"].size(), 2, "bug has 2 tags")
	if r is String: return r
	r = A.contains(bug["tags"], "crash", "crash tag")
	if r is String: return r
	# Check seq ordering preserved
	r = A.eq(result["events"][0]["seq"], 1, "first event seq=1")
	if r is String: return r
	r = A.eq(result["events"][3]["seq"], 4, "fourth event seq=4")
	if r is String: return r
	# Check saved query structure
	var sq: Dictionary = result["saved_queries"][0]
	return A.has_key(sq["query"], "filter", "query has filter")
