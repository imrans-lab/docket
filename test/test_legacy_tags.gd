extends Node

var _dir := "user://test_legacy_tags"
var _path := "user://test_legacy_tags/master.dct"
var _db: DocketDBJsonl

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_dir)

func teardown() -> void:
	if _db != null: _db.close()
	for suffix: String in ["", ".cache", ".cache-wal", ".cache-shm", ".lock", ".log"]:
		DirAccess.remove_absolute(_path + suffix)
	DirAccess.remove_absolute(_dir)

func test_real_master_tags_read_query_and_mutate() -> Variant:
	var original := FileAccess.get_file_as_bytes("res://test/fixtures/minerva_master.dct")
	var file := FileAccess.open(_path, FileAccess.WRITE)
	file.store_buffer(original)
	file.close()
	var expected := {}
	for line: String in original.get_string_from_utf8().split("\n"):
		var record: Variant = JSON.parse_string(line)
		if record is Dictionary and record.get("_type") == "item" and record.get("tags") is String:
			var tags: Array = []
			for part: String in record.tags.split(","):
				if not part.strip_edges().is_empty(): tags.append(part.strip_edges())
			expected[record.id] = tags
	if expected.size() != 9: return "real fixture must contain nine string-tag items"
	var before := JSONLParser.parse_file(_path)
	if not str(before.get("error", "")).is_empty(): return before.error
	for item: Dictionary in before.items:
		if expected.has(item.id) and item.get("tags") != expected[item.id]: return "parser tag order differs: " + item.id
	_db = DocketDBJsonl.open_jsonl(_path)
	if _db == null: return DocketDBJsonl.last_open_error
	for id: String in expected:
		var actual: Array = _db.get_item(id).get("tags", [])
		if actual.size() != expected[id].size(): return "missing cached tags: " + id
		for tag: String in expected[id]:
			if tag not in actual: return "missing tag: " + tag
			var found := false
			for result: Dictionary in _db.execute_query({"filter": {"tags_contains": tag}}):
				if result.id == id: found = true
			if not found: return "tag query misses " + id
	for tick in 3:
		_db.ensure_fresh()
		_db.settle_if_idle(Time.get_ticks_msec() + 60000)
	_db.close()
	if FileAccess.get_file_as_bytes(_path) != original: return "read-only open/poll/close changed bytes"
	if FileAccess.file_exists(_path + ".log"): return "read-only session created a sidecar"
	_db = DocketDBJsonl.open_jsonl(_path)
	if _db == null: return DocketDBJsonl.last_open_error
	var changed_id: String = expected.keys()[0]
	var error := _db.update_item_fields_checked(changed_id, {"title": "Legacy tags retained"})
	if not error.is_empty(): return error
	error = _db.flush_checked()
	if not error.is_empty(): return error
	_db.close()
	var after := JSONLParser.parse_file(_path)
	if not str(after.get("error", "")).is_empty(): return after.error
	for item: Dictionary in after.items:
		if not expected.has(item.id): continue
		var tags: Array = item.get("tags", [])
		for tag: String in expected[item.id]:
			if tag not in tags: return "mutation lost tag: " + item.id
		if item.id == changed_id: continue
		for old: Dictionary in before.items:
			if old.id == item.id and old != item: return "untouched legacy item changed semantically: " + item.id
	for line: String in FileAccess.get_file_as_string(_path).split("\n"):
		var record: Variant = JSON.parse_string(line)
		if record is Dictionary and record.get("id") == changed_id and not record.get("tags") is Array:
			return "real mutation did not canonicalize tags"
	return true

func test_comma_tags_trim_drop_empty_preserve_order() -> Variant:
	var item := JSONLParser.parse_line('{"_type":"item","id":"TST-1","type":"chore","status":"open","title":"tags","created_at":"2026-01-01","updated_at":"2026-01-01","tags":" b, ,a,, c "}')
	return AssertHelpers.eq(item.get("tags"), ["b", "a", "c"], "legacy string normalization")
