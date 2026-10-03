extends Node

var _dir := "user://test_legacy_tags"
var _path := "user://test_legacy_tags/master.dct"
var _db: DocketDBJsonl

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(_dir)

func after_each() -> void:
	if _db != null and _db.is_open(): _db.close()
	_db = null
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
		if line.strip_edges().is_empty(): continue
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
		var ordered: Array = expected[id].duplicate()
		ordered.sort()
		var members := actual.duplicate()
		members.sort() # Cache/getter tags are sets; only parser conversion preserves order.
		if members != ordered: return "cached tags differ: " + id + " expected=" + JSON.stringify(ordered) + " actual=" + JSON.stringify(members)
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
	if before.items.size() != after.items.size(): return "mutation changed item count"
	for old: Dictionary in before.items:
		var found := false
		for item: Dictionary in after.items:
			if old.id != item.id: continue
			found = true
			var wanted := _canonical_item(old)
			var actual := _canonical_item(item)
			if item.id == changed_id:
				if item.title != "Legacy tags retained": return "target title was not updated"
				wanted.erase("title")
				actual.erase("title")
				# A real edit stamps updated_at; every other target field must survive.
				wanted.erase("updated_at")
				actual.erase("updated_at")
			if JSON.stringify(wanted, "", true, true) != JSON.stringify(actual, "", true, true):
				return "legacy item changed semantically: " + item.id + "; expected=" + JSON.stringify(wanted, "", true, true) + " actual=" + JSON.stringify(actual, "", true, true)
		if not found: return "mutation lost item: " + old.id
	# Preserve every related record, including comments, rather than projecting fields.
	for section: String in ["events", "comments", "links", "attachments", "secrets", "type_defs", "type_def_versions"]:
		if _record_set(before.get(section, [])) != _record_set(after.get(section, [])):
			return "mutation changed related records: " + section
	for line: String in FileAccess.get_file_as_string(_path).split("\n"):
		if line.strip_edges().is_empty(): continue
		var record: Variant = JSON.parse_string(line)
		if record is Dictionary and record.get("id") == changed_id and not record.get("tags") is Array:
			return "real mutation did not canonicalize tags"
	return true

func test_comma_tags_trim_drop_empty_preserve_order() -> Variant:
	var item := JSONLParser.parse_line('{"_type":"item","id":"TST-1","type":"chore","status":"open","title":"tags","created_at":"2026-01-01","updated_at":"2026-01-01","tags":" b, ,a,, c "}')
	return AssertHelpers.eq(item.get("tags"), ["b", "a", "c"], "legacy string normalization")

func test_canonical_text_escapes_survive_while_user_input_normalizes() -> Variant:
	var text := "literal \\n and \\t; actual\nnewline\ttab"
	var item := {"_type":"item", "id":"TXT-1", "type":"skill", "status":"active", "title":"Escapes", "steps":text, "created_at":"2026-01-01", "updated_at":"2026-01-01"}
	var file := FileAccess.open(_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"_type":"meta", "version":"1.0.0", "counter":1, "id_prefix":"TXT"}) + "\n" + JSON.stringify(item) + "\n")
	file.close()
	_db = DocketDBJsonl.open_jsonl(_path)
	if _db == null: return DocketDBJsonl.last_open_error
	if _db.get_item("TXT-1").get("steps") != text: return "canonical cache changed literal text escapes"
	var error := _db.update_item_fields_checked("TXT-1", {"title":"Edited"})
	if not error.is_empty(): return error
	# Ordinary insertion still accepts escaped user text with the established behavior.
	item.id = "TXT-2"
	error = _db.insert_item("TXT-2", item)
	if not error.is_empty(): return error
	if _db.get_item("TXT-2").get("steps") != text.replace("\\n", "\n").replace("\\t", "\t"):
		return "ordinary user input no longer normalizes escaped text"
	error = _db.flush_checked()
	if not error.is_empty(): return error
	_db.close()
	var parsed := JSONLParser.parse_file(_path)
	if not str(parsed.get("error", "")).is_empty(): return parsed.error
	for record: Dictionary in parsed.items:
		if record.id == "TXT-1": return AssertHelpers.eq(record.get("steps"), text, "unrelated settle preserves canonical escapes")
	return "canonical text item disappeared"

func _canonical_item(item: Dictionary) -> Dictionary:
	var result := item.duplicate(true)
	# The established serializer sorts tag sets and omits empty optional containers.
	# Retain all other keys and all nested payloads; JSON comparison sorts keys and retains full numeric precision.
	if result.get("tags") is Array: result.tags.sort()
	for key: String in ["tags", "tool_deps", "unsatisfied_deps", "optimization", "pristine_content", "fields", "extras"]:
		var value: Variant = result.get(key)
		if (value is Array or value is Dictionary) and value.is_empty(): result.erase(key)
	return result

func _record_set(records: Array) -> Array[String]:
	# Global line order changes on canonical settle; record contents and counts cannot.
	var result: Array[String] = []
	for record: Dictionary in records: result.append(JSON.stringify(record, "", true, true))
	result.sort()
	return result
