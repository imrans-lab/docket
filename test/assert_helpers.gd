extends RefCounted
class_name AssertHelpers
## Assertion helpers for tests. Each returns true on success or an error String on failure.


static func eq(actual: Variant, expected: Variant, label: String = "") -> Variant:
	if typeof(actual) != typeof(expected):
		var msg := "type mismatch: got %s (%s), expected %s (%s)" % [
			str(actual), type_string(typeof(actual)),
			str(expected), type_string(typeof(expected))
		]
		return _fmt(msg, label)
	if actual != expected:
		return _fmt("got %s, expected %s" % [str(actual), str(expected)], label)
	return true


static func neq(actual: Variant, expected: Variant, label: String = "") -> Variant:
	if actual == expected:
		return _fmt("expected value to differ from %s" % str(expected), label)
	return true


static func is_true(value: Variant, label: String = "") -> Variant:
	if value != true:
		return _fmt("expected true, got %s" % str(value), label)
	return true


static func is_false(value: Variant, label: String = "") -> Variant:
	if value != false:
		return _fmt("expected false, got %s" % str(value), label)
	return true


static func has_key(dict: Dictionary, key: String, label: String = "") -> Variant:
	if not dict.has(key):
		return _fmt("missing key '%s' in %s" % [key, str(dict.keys())], label)
	return true


static func not_null(value: Variant, label: String = "") -> Variant:
	if value == null:
		return _fmt("expected non-null value", label)
	return true


static func is_null(value: Variant, label: String = "") -> Variant:
	if value != null:
		return _fmt("expected null, got %s" % str(value), label)
	return true


static func contains(haystack: Variant, needle: Variant, label: String = "") -> Variant:
	if haystack is String:
		if not (haystack as String).contains(str(needle)):
			return _fmt("'%s' not found in '%s'" % [str(needle), haystack], label)
		return true
	if haystack is Array:
		if not (haystack as Array).has(needle):
			return _fmt("%s not found in array %s" % [str(needle), str(haystack)], label)
		return true
	if haystack is Dictionary:
		if not (haystack as Dictionary).has(needle):
			return _fmt("key '%s' not found in dict" % str(needle), label)
		return true
	return _fmt("contains() needs String, Array, or Dictionary", label)


static func gt(actual: Variant, threshold: Variant, label: String = "") -> Variant:
	if actual <= threshold:
		return _fmt("expected %s > %s" % [str(actual), str(threshold)], label)
	return true


static func gte(actual: Variant, threshold: Variant, label: String = "") -> Variant:
	if actual < threshold:
		return _fmt("expected %s >= %s" % [str(actual), str(threshold)], label)
	return true


static func meta_only_journal(canonical_path: String, skip: int = 0) -> Variant:
	## true when the canonical's sidecar has at least one line after its first
	## `skip`, and every such line is a "wal" record whose replace set is the
	## meta line alone ([["", "meta"]]); else a failure message.
	var sidecar := canonical_path + ".log"
	var lines: PackedStringArray = FileAccess.get_file_as_string(sidecar).split("\n", false) if FileAccess.file_exists(sidecar) else PackedStringArray()
	if lines.size() <= skip: return "no sidecar record after line %d of %s" % [skip, sidecar]
	for raw: String in lines.slice(skip):
		var record: Variant = JSON.parse_string(raw)
		var row: Dictionary = record if record is Dictionary else {}
		var replace: Variant = row.get("replace")
		if row.get("_type") != "wal" or not replace is Array or replace != [["", "meta"]]:
			return "sidecar journals more than the meta line: %s" % raw
	return true


static func durable_text(canonical_path: String) -> String:
	## A canonical's content as a reader that honours its write-ahead sidecar
	## (<canonical>.log) sees it: canonical lines with each journaled record's
	## sections replaced in order. Built from the sidecar's line format alone,
	## not from the code that writes or replays it.
	var text := FileAccess.get_file_as_string(canonical_path)
	var sidecar := canonical_path + ".log"
	if not FileAccess.file_exists(sidecar): return text
	var canonical_sha := FileAccess.get_sha256(canonical_path)
	var records: Array = []
	for raw: String in FileAccess.get_file_as_string(sidecar).split("\n", false):
		var record: Variant = JSON.parse_string(raw)
		if not record is Dictionary: continue
		if record.get("_type") == "settle" and str(record.get("target")) == canonical_sha: records.clear()
		elif record.get("_type") == "wal": records.append(record)
	var lines: Array = Array(text.split("\n", false))
	for record: Dictionary in records:
		var replaced := {}
		var present := {}
		for value: Dictionary in record.records: present[_durable_key(value)] = true
		for pair: Array in record["replace"]:
			replaced["%s\t%s" % [pair[0], pair[1]]] = true
			if pair[1] == "item" and not present.has("%s\titem" % pair[0]):
				for section: String in ["events", "comments", "links", "attachments"]: replaced["%s\t%s" % [pair[0], section]] = true
		var kept: Array = []
		for line: String in lines:
			var row: Variant = JSON.parse_string(line)
			if not (row is Dictionary and replaced.has(_durable_key(row))): kept.append(line)
		for value: Dictionary in record.records: kept.append(JSON.stringify(value))
		lines = kept
	return "\n".join(PackedStringArray(lines)) + "\n"


static func _durable_key(row: Dictionary) -> String:
	match str(row.get("_type", "")):
		"meta": return "\tmeta"
		"item": return "%s\titem" % row.get("id", "")
		"event": return "%s\tevents" % row.get("item_id", "")
		"comment": return "%s\tcomments" % row.get("item_id", "")
		"link": return "%s\tlinks" % row.get("from_id", "")
		"attachment": return "%s\tattachments" % row.get("item_id", "")
	return ""


static func _fmt(msg: String, label: String) -> String:
	if label.is_empty():
		return msg
	return "%s: %s" % [label, msg]
