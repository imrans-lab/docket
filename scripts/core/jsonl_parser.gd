extends RefCounted
class_name JSONLParser
## Reads a .dct.jsonl file and produces structured in-memory dictionaries.
## Implements the supported Docket JSONL 1.0.0 and 2.0.0 contracts.

# Unknown record kinds are refused because this writer cannot preserve them.
const KNOWN_TYPES := [
	"meta", "item", "event", "comment", "link",
	"attachment", "secret", "secret_version", "saved_query",
	"type_def", "type_def_version"
]
const SUPPORTED_VERSIONS := ["1.0.0", "2.0.0"]

# Git conflict-marker line prefixes. A valid JSONL line is always a JSON object
# starting with '{', so any line starting with one of these is unambiguously a
# merge artifact — never legitimate content.
const CONFLICT_MARKERS := ["<<<<<<<", "=======", ">>>>>>>", "|||||||"]


# -- Public API ---------------------------------------------------------------

static func parse_file(path: String) -> Dictionary:
	## Read a .dct.jsonl file and return structured data.
	## Returns meta, registry records, items, related records and diagnostics.
	## meta is a Dictionary; all others are Arrays of Dictionaries.
	var empty := _empty_result()

	if not FileAccess.file_exists(path):
		push_warning("JSONLParser: file not found: %s" % path)
		empty["error"] = "file not found: %s" % path
		return empty

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("JSONLParser: cannot open file: %s" % path)
		empty["error"] = "cannot open file: %s" % path
		return empty

	var result := _empty_result()
	var line_number := 0

	while not file.eof_reached():
		var raw_line: String = file.get_line()
		line_number += 1
		var line: String = raw_line.strip_edges()
		if line.is_empty():
			continue

		# Unresolved merge conflict: refuse the whole file rather than silently
		# dropping the markers and auto-unioning both sides. Bailing here also
		# keeps the caller from building a cache that would later be flushed
		# back over the conflicted file, erasing it.
		if _is_conflict_marker(line):
			file.close()
			var conflicted := _empty_result()
			conflicted["error"] = (
				"unresolved git conflict marker at line %d: '%s'. " % [line_number, line.substr(0, 20)]
				+ "Resolve the conflict in %s before opening it." % path
			)
			conflicted["issues"].append("line %d: conflict marker '%s'" % [line_number, line.substr(0, 20)])
			return conflicted

		# Corruption is fatal. A machine-generated file has no benign reason to
		# contain an unparseable line: it means a truncated write, a botched
		# merge, or disk damage. Skipping it looked harmless but was destructive
		# — the record never reached the cache, and close() rewrites the file
		# from the cache, so merely opening and closing the project erased it.
		#
		# Unknown record kinds are fatal for the same loss-prevention reason.
		var parsed = _parse_json_line(line, line_number)
		if parsed == null:
			file.close()
			return _corrupt(path, line_number, "not valid JSON", line)

		if not parsed is Dictionary:
			file.close()
			return _corrupt(path, line_number, "not a JSON object", line)

		var type_val = parsed.get("_type")
		if type_val == null:
			file.close()
			return _corrupt(path, line_number, "missing the _type field", line)

		var line_type: String = str(type_val)
		if line_type not in KNOWN_TYPES:
			# Fatal, despite looking like forward compatibility. The serializer
			# emits only known types, so a line this build cannot reproduce is a
			# line the next flush deletes. Tolerating it was destructive, not
			# lenient. A genuinely newer format must announce itself with a
			# higher meta.version, which is refused separately and clearly.
			file.close()
			return _corrupt(path, line_number,
				"unknown record type '%s' — written by a newer Docket?" % line_type, line)

		# A per-type parser returns {} when a required field is missing. That is
		# still a line this build cannot reproduce, so it is fatal for the same
		# reason as malformed JSON: skipping it drops the record, and the next
		# flush writes the file back without it.
		var bucket := ""
		var record := {}
		match line_type:
			"meta":
				record = _parse_meta(parsed)
				if record.is_empty():
					file.close()
					return _corrupt(path, line_number, "meta line is missing required fields", line)
				result["meta"] = record
			"item":
				bucket = "items"
				record = _parse_item(parsed)
			"event":
				bucket = "events"
				record = _parse_event(parsed)
			"comment":
				bucket = "comments"
				record = _parse_comment(parsed)
			"link":
				bucket = "links"
				record = _parse_link(parsed)
			"attachment":
				bucket = "attachments"
				record = _parse_attachment(parsed)
			"secret":
				bucket = "secrets"
				record = _parse_secret(parsed)
			"secret_version":
				bucket = "secret_versions"
				record = _parse_secret_version(parsed)
			"saved_query":
				bucket = "saved_queries"
				record = _parse_saved_query(parsed)
			"type_def":
				bucket = "type_defs"
				record = _parse_type_def(parsed)
			"type_def_version":
				bucket = "type_def_versions"
				record = _parse_type_def_version(parsed)

		if not bucket.is_empty():
			if record.is_empty():
				file.close()
				return _corrupt(path, line_number,
					"%s record is missing required fields" % line_type, line)
			result[bucket].append(record)

	file.close()
	var version := str(result.meta.get("version", ""))
	if version not in SUPPORTED_VERSIONS:
		return _corrupt(path, 0, "unsupported format version '%s'" % version, "")
	var registry_error := _validate_registry_records(result)
	if not registry_error.is_empty():
		return _corrupt(path, 0, registry_error, "")
	var dependency_error := _validate_record_dependencies(result)
	if not dependency_error.is_empty():
		return _corrupt(path, 0, dependency_error, "")
	result["registry_diagnostics"] = _item_registry_diagnostics(result)
	return result


static func parse_line(json_text: String) -> Dictionary:
	## Parse a single JSONL line. Returns the parsed dict with _type included,
	## or an empty dict on any error.
	var line: String = json_text.strip_edges()
	if line.is_empty():
		return {}

	var parsed = _parse_json_line(line, -1)
	if parsed == null or not parsed is Dictionary:
		return {}

	var type_val = parsed.get("_type")
	if type_val == null:
		push_warning("JSONLParser.parse_line: missing _type field")
		return {}

	var line_type: String = str(type_val)
	if line_type not in KNOWN_TYPES:
		push_warning("JSONLParser.parse_line: unknown _type '%s'" % line_type)
		return {}

	match line_type:
		"meta":
			return _parse_meta(parsed)
		"item":
			return _parse_item(parsed)
		"event":
			return _parse_event(parsed)
		"comment":
			return _parse_comment(parsed)
		"link":
			return _parse_link(parsed)
		"attachment":
			return _parse_attachment(parsed)
		"secret":
			return _parse_secret(parsed)
		"secret_version":
			return _parse_secret_version(parsed)
		"saved_query":
			return _parse_saved_query(parsed)
		"type_def":
			return _parse_type_def(parsed)
		"type_def_version":
			return _parse_type_def_version(parsed)

	return {}


static func validate_meta(meta: Dictionary) -> bool:
	## Check that required meta fields are present.
	## Required: _type, version, counter, id_prefix.
	if meta.get("_type") != "meta":
		return false
	if not meta.has("version") or str(meta["version"]).is_empty():
		return false
	if not meta.has("counter"):
		return false
	if not meta.has("id_prefix") or str(meta["id_prefix"]).is_empty():
		return false
	return true


# -- Line-type parsers --------------------------------------------------------

static func _parse_meta(d: Dictionary) -> Dictionary:
	var out := {"_type": "meta"}
	out["version"] = _str_field(d, "version", "")
	out["counter"] = _int_field(d, "counter", 0)
	out["id_prefix"] = _str_field(d, "id_prefix", "")
	# Optional fields
	_copy_str_opt(d, out, "project")
	_copy_str_opt(d, out, "vault_salt")
	_copy_str_opt(d, out, "vault_verify")
	# Preserve any extra fields for extensibility (ignore _type itself)
	for key in d:
		if key == "_type":
			continue
		if key in ["version", "counter", "id_prefix", "project", "vault_salt", "vault_verify"]:
			continue
		out[key] = d[key]
	return out


static func _parse_item(d: Dictionary) -> Dictionary:
	# Required fields
	if not _has_required(d, ["id", "type", "status", "title", "created_at", "updated_at"]):
		return {}
	if d.has("fields_json") or d.has("extras_json"): return {}
	var out := {"_type": "item"}
	if d.has("fields") and not d.fields is Dictionary: return {}
	if d.has("extras") and not d.extras is Dictionary: return {}
	var fields: Dictionary = d.get("fields", {})
	var extras: Dictionary = d.get("extras", {})
	for key in fields:
		if extras.has(key) or d.has(key): return {}
	for key in extras:
		if d.has(key): return {}
	out["id"] = _str_field(d, "id", "")
	out["type"] = _str_field(d, "type", "")
	out["status"] = _str_field(d, "status", "")
	out["title"] = _str_field(d, "title", "")
	out["created_at"] = _str_field(d, "created_at", "")
	out["updated_at"] = _str_field(d, "updated_at", "")
	for key in ["type_id", "type_revision"]: _copy_str_opt(d, out, key)
	if d.has("fields"): out["fields"] = fields.duplicate(true)
	if d.has("extras"): out["extras"] = extras.duplicate(true)
	# Optional string fields
	for key in ["description", "created_by", "assigned_to", "directed_to",
				"resolution", "environment", "repro_steps",
				"assumed", "corrected", "findings", "answer",
				"occurred_at", "detected_at", "reported_at",
				"why_chain", "significant_events", "contributing_factors",
				"value", "component", "key", "topic", "subtopic",
				"confidence", "surprise", "surfaced_from",
				"blocked_by", "parent",
				"test_setup", "test_steps", "expected_result",
				"last_reviewed",
				"command", "usage", "prompt_text", "preconditions",
				"summary", "article", "parameters",
				"steps", "outcome", "target",
				"source", "pristine_hash"]:
		_copy_str_opt(d, out, key)
	# Optional integer fields (omitted when 0)
	_copy_int_opt(d, out, "priority")
	_copy_int_opt(d, out, "severity")
	_copy_int_opt(d, out, "retrieval_count")
	_copy_int_opt(d, out, "research_cost")
	_copy_int_opt(d, out, "quality")
	_copy_int_opt(d, out, "customised")
	_copy_int_opt(d, out, "deprecated")
	# Array fields
	if d.has("tags") and d["tags"] is Array:
		out["tags"] = d["tags"].duplicate()
	if d.has("tool_deps") and d["tool_deps"] is Array:
		out["tool_deps"] = d["tool_deps"].duplicate()
	if d.has("unsatisfied_deps") and d["unsatisfied_deps"] is Array:
		out["unsatisfied_deps"] = d["unsatisfied_deps"].duplicate()
	# Object fields
	if d.has("optimization") and d["optimization"] is Dictionary:
		out["optimization"] = d["optimization"].duplicate(true)
	if d.has("pristine_content") and d["pristine_content"] is Dictionary:
		out["pristine_content"] = d["pristine_content"].duplicate(true)
	var known: Array = DocketDB._ITEM_COLS.duplicate()
	known.append_array(["_type", "id", "tags", "events", "links", "fields", "extras"])
	var preserved_extras: Dictionary = out.get("extras", {})
	for key in d:
		if key not in known:
			if preserved_extras.has(key): return {}
			preserved_extras[key] = d[key]
	if not preserved_extras.is_empty(): out["extras"] = preserved_extras
	return out


static func _parse_type_def(d: Dictionary) -> Dictionary:
	if not _has_required(d, ["id", "slug", "lifecycle", "current_revision", "provenance"]): return {}
	if not d.provenance is Dictionary: return {}
	return d.duplicate(true)


static func _parse_type_def_version(d: Dictionary) -> Dictionary:
	if not _has_required(d, ["id", "type_id", "definition", "author", "created_at", "reason"]): return {}
	if not d.definition is Dictionary: return {}
	for key in ["slug", "label", "description", "fields", "lifecycle", "protected", "protected_behavior"]:
		if not d.definition.has(key): return {}
	if not d.definition.fields is Array or not d.definition.lifecycle is Dictionary: return {}
	for key in ["initial_state", "states", "terminal_states", "transitions", "guards", "enforcement"]:
		if not d.definition.lifecycle.has(key): return {}
	return d.duplicate(true)


static func _validate_registry_records(result: Dictionary) -> String:
	var ids := {}
	var slugs := {}
	var revisions := {}
	for value in result.type_defs:
		var record: Dictionary = value
		if ids.has(record.id): return "duplicate type_def id '%s'" % record.id
		if slugs.has(record.slug): return "duplicate type_def slug '%s'" % record.slug
		ids[record.id] = record
		slugs[record.slug] = true
	for value in result.type_def_versions:
		var revision: Dictionary = value
		if revisions.has(revision.id): return "duplicate type_def_version id '%s'" % revision.id
		var expected_id: String = "%s@%s" % [revision.type_id, TypeRegistryBootstrap._definition_hash(revision.definition)]
		if str(revision.id) != expected_id: return "revision '%s' does not match its canonical definition digest" % revision.id
		revisions[revision.id] = revision
	for type_id in ids:
		var definition: Dictionary = ids[type_id]
		if str(definition.lifecycle) not in ["draft", "active", "deprecated"]: return "type '%s' has invalid lifecycle" % definition.slug
		if not revisions.has(definition.current_revision): return "type '%s' points to missing current revision '%s'" % [definition.slug, definition.current_revision]
		if revisions[definition.current_revision].type_id != type_id: return "type '%s' points to another type's revision" % definition.slug
		if str(revisions[definition.current_revision].definition.slug) != str(definition.slug): return "type '%s' current revision changes immutable slug" % definition.slug
	for revision_id in revisions:
		var revision: Dictionary = revisions[revision_id]
		if not ids.has(revision.type_id): return "revision '%s' refers to missing type '%s'" % [revision_id, revision.type_id]
		var parent_value: Variant = revision.get("parent_revision")
		var parent: String = "" if parent_value == null else str(parent_value)
		if not parent.is_empty() and (not revisions.has(parent) or revisions[parent].type_id != revision.type_id): return "revision '%s' has invalid parent '%s'" % [revision_id, parent]
	return ""


static func _item_registry_diagnostics(result: Dictionary) -> Array:
	var diagnostics: Array = []
	if str(result.meta.get("version", "")) != "2.0.0": return diagnostics
	var definitions := {}
	var revisions := {}
	for value in result.type_defs: definitions[value.id] = value
	for value in result.type_def_versions: revisions[value.id] = value
	for value in result.type_defs:
		if not revisions.has(value.current_revision): diagnostics.append({"type_id": value.id, "reason": "missing current revision '%s'" % value.current_revision})
	for value in result.items:
		var item: Dictionary = value
		var type_id := str(item.get("type_id", ""))
		var revision_id := str(item.get("type_revision", ""))
		var reason := ""
		if not definitions.has(type_id): reason = "missing type definition '%s'" % type_id
		elif not revisions.has(revision_id): reason = "missing type revision '%s'" % revision_id
		elif revisions[revision_id].type_id != type_id: reason = "revision belongs to another type"
		elif definitions[type_id].slug != item.type: reason = "legacy slug does not match pinned type"
		else:
			var states: Array = []
			for state in revisions[revision_id].definition.lifecycle.states: states.append(state.key)
			if not states.has(item.status): reason = "status '%s' is absent from pinned revision" % item.status
		if not reason.is_empty(): diagnostics.append({"item_id": item.id, "reason": reason})
	return diagnostics


static func _validate_record_dependencies(result: Dictionary) -> String:
	var item_ids := {}
	for item in result.items: item_ids[item.id] = true
	for bucket in ["events", "comments", "attachments"]:
		for record in result[bucket]:
			if not item_ids.has(record.item_id): return "orphaned %s record for missing item '%s'" % [str(record._type), str(record.item_id)]
	for link in result.links:
		if not item_ids.has(link.from_id): return "orphaned link record for missing source item '%s'" % link.from_id
	return ""


static func _parse_event(d: Dictionary) -> Dictionary:
	# Required fields
	if not _has_required(d, ["item_id", "seq", "event_type", "timestamp"]):
		return {}
	var out := {"_type": "event"}
	out["item_id"] = _str_field(d, "item_id", "")
	out["seq"] = _int_field(d, "seq", 0)
	out["event_type"] = _str_field(d, "event_type", "")
	out["timestamp"] = _str_field(d, "timestamp", "")
	_copy_str_opt(d, out, "actor")
	_copy_str_opt(d, out, "note")
	# Project event id and changed fields (ProjectEvents); both optional.
	if d.get("eid") is int or d.get("eid") is float: out["eid"] = int(d.eid)
	if d.get("fields") is Array:
		var fields: Array[String] = []
		for field in d.fields: fields.append(str(field))
		out["fields"] = fields
	return out


static func _parse_comment(d: Dictionary) -> Dictionary:
	# Required: id, item_id, created_at
	if not _has_required(d, ["id", "item_id", "created_at"]):
		return {}
	var out := {"_type": "comment"}
	out["id"] = _int_field(d, "id", 0)
	out["item_id"] = _str_field(d, "item_id", "")
	out["created_at"] = _str_field(d, "created_at", "")
	_copy_str_opt(d, out, "author")
	_copy_str_opt(d, out, "text")
	# status: omitted in JSONL when "open", but we keep it if present
	_copy_str_opt(d, out, "status")
	# parent_id: omitted when 0
	if d.has("parent_id"):
		out["parent_id"] = _int_field(d, "parent_id", 0)
	_copy_str_opt(d, out, "resolved_at")
	_copy_str_opt(d, out, "resolved_by")
	return out


static func _parse_link(d: Dictionary) -> Dictionary:
	# Required: from_id, to_id, relation
	if not _has_required(d, ["from_id", "to_id", "relation"]):
		return {}
	var out := {"_type": "link"}
	out["from_id"] = _str_field(d, "from_id", "")
	out["to_id"] = _str_field(d, "to_id", "")
	out["relation"] = _str_field(d, "relation", "")
	return out


static func _parse_attachment(d: Dictionary) -> Dictionary:
	# Required: id, item_id, filename, data, created_at
	if not _has_required(d, ["id", "item_id", "filename", "data", "created_at"]):
		return {}
	var out := {"_type": "attachment"}
	out["id"] = _int_field(d, "id", 0)
	out["item_id"] = _str_field(d, "item_id", "")
	out["filename"] = _str_field(d, "filename", "")
	out["created_at"] = _str_field(d, "created_at", "")
	# Decode base64 data to PackedByteArray
	var b64_str: String = _str_field(d, "data", "")
	out["data"] = _decode_base64(b64_str)
	out["data_b64"] = b64_str  # keep raw b64 for roundtrip
	# Optional
	_copy_str_opt(d, out, "mime_type")
	_copy_int_opt(d, out, "size_bytes")
	_copy_str_opt(d, out, "description")
	_copy_str_opt(d, out, "encoding")
	return out


static func _parse_secret(d: Dictionary) -> Dictionary:
	# Required: handle, ciphertext, iv, mac, created_at, updated_at
	if not _has_required(d, ["handle", "ciphertext", "iv", "mac", "created_at", "updated_at"]):
		return {}
	var out := {"_type": "secret"}
	out["handle"] = _str_field(d, "handle", "")
	out["created_at"] = _str_field(d, "created_at", "")
	out["updated_at"] = _str_field(d, "updated_at", "")
	# Decode binary fields
	out["ciphertext"] = _decode_base64(_str_field(d, "ciphertext", ""))
	out["iv"] = _decode_base64(_str_field(d, "iv", ""))
	out["mac"] = _decode_base64(_str_field(d, "mac", ""))
	# Keep raw b64 strings for roundtrip / inspection
	out["ciphertext_b64"] = _str_field(d, "ciphertext", "")
	out["iv_b64"] = _str_field(d, "iv", "")
	out["mac_b64"] = _str_field(d, "mac", "")
	# Optional
	if d.has("requires_2fa"):
		out["requires_2fa"] = bool(d["requires_2fa"])
	else:
		out["requires_2fa"] = false
	out["owner_item_id"] = _str_field(d, "owner_item_id", "")

	# Preserve anything this version does not recognise, as _parse_meta already
	# does. Without it, a file written by a newer Docket loses its unknown fields
	# the moment an older one opens and flushes — the same silent truncation as
	# dropping a whole line, one level finer.
	const KNOWN := ["_type", "handle", "ciphertext", "iv", "mac",
		"created_at", "updated_at", "requires_2fa", "owner_item_id"]
	for key in d:
		if key not in KNOWN and not out.has(key):
			out[key] = d[key]
	return out


static func _parse_secret_version(d: Dictionary) -> Dictionary:
	# Required: handle, version, ciphertext, iv, mac, created_at
	if not _has_required(d, ["handle", "version", "ciphertext", "iv", "mac", "created_at"]):
		return {}
	var out := {"_type": "secret_version"}
	out["handle"] = _str_field(d, "handle", "")
	out["version"] = _int_field(d, "version", 0)
	out["created_at"] = _str_field(d, "created_at", "")
	out["ciphertext"] = _decode_base64(_str_field(d, "ciphertext", ""))
	out["iv"] = _decode_base64(_str_field(d, "iv", ""))
	out["mac"] = _decode_base64(_str_field(d, "mac", ""))
	out["ciphertext_b64"] = _str_field(d, "ciphertext", "")
	out["iv_b64"] = _str_field(d, "iv", "")
	out["mac_b64"] = _str_field(d, "mac", "")
	_copy_str_opt(d, out, "rotated_by")
	return out


static func _parse_saved_query(d: Dictionary) -> Dictionary:
	# Required: name, query
	if not _has_required(d, ["name", "query"]):
		return {}
	var out := {"_type": "saved_query"}
	out["name"] = _str_field(d, "name", "")
	# query is an embedded JSON object (Dictionary), not a string
	var query_val = d.get("query")
	if query_val is Dictionary:
		out["query"] = query_val.duplicate(true)
	else:
		out["query"] = {}
	return out


# -- Internal helpers ---------------------------------------------------------

static func _empty_result() -> Dictionary:
	return {
		"meta": {},
		"items": [],
		"events": [],
		"comments": [],
		"links": [],
		"attachments": [],
		"secrets": [],
		"secret_versions": [],
		"saved_queries": [],
		"type_defs": [],
		"type_def_versions": [],
		# "" when the file parsed. Non-empty means the file must NOT be opened,
		# cached, or written back — see parse_file.
		"error": "",
		# Non-fatal per-line problems, for `validate` reporting.
		"issues": [],
		"registry_diagnostics": [],
	}


static func _corrupt(path: String, line_number: int, why: String, line: String) -> Dictionary:
	## Abort the parse: the file is damaged and must not be opened.
	##
	## Refusing is the whole point. Docket rewrites the entire file from cache on
	## the next flush, so any line the parser drops is destroyed on close — even
	## with no edit. Failing here keeps the damaged file intact for repair.
	var out := _empty_result()
	out["error"] = (
		"malformed JSONL at line %d: %s. " % [line_number, why]
		+ "Refusing to open %s — opening it would discard that line permanently. " % path
		+ "Repair the line or restore the file from git."
	)
	out["issues"].append("line %d: %s — %s" % [line_number, why, line.substr(0, 60)])
	return out


static func _is_conflict_marker(line: String) -> bool:
	for marker: String in CONFLICT_MARKERS:
		if line.begins_with(marker):
			return true
	return false


static func _parse_json_line(line: String, line_number: int) -> Variant:
	## Parse a JSON string. Returns the parsed value or null on error.
	var result = JSON.parse_string(line)
	if result == null:
		if line_number >= 0:
			push_warning("JSONLParser: line %d is not valid JSON and is rejected: %s" % [line_number, line.substr(0, 80)])
		else:
			push_warning("JSONLParser: invalid JSON: %s" % line.substr(0, 80))
		return null
	return result


static func _has_required(d: Dictionary, keys: Array) -> bool:
	for key in keys:
		if not d.has(key):
			push_warning("JSONLParser: missing required field '%s' in %s line" % [key, str(d.get("_type", "?"))])
			return false
	return true


static func _str_field(d: Dictionary, key: String, default_val: String) -> String:
	var val = d.get(key)
	if val == null:
		return default_val
	return str(val)


static func _int_field(d: Dictionary, key: String, default_val: int) -> int:
	var val = d.get(key)
	if val == null:
		return default_val
	if val is int:
		return val
	if val is float:
		return int(val)
	return int(str(val))


static func _copy_str_opt(src: Dictionary, dst: Dictionary, key: String) -> void:
	## Copy a string field from src to dst only if it is present and non-empty.
	if src.has(key):
		var val = src[key]
		if val != null and str(val) != "":
			dst[key] = str(val)


static func _copy_int_opt(src: Dictionary, dst: Dictionary, key: String) -> void:
	## Copy an integer field from src to dst only if it is present and non-zero.
	if src.has(key):
		var val = src[key]
		var ival: int
		if val is int:
			ival = val
		elif val is float:
			ival = int(val)
		else:
			ival = int(str(val))
		if ival != 0:
			dst[key] = ival


static func _decode_base64(b64: String) -> PackedByteArray:
	## Decode a standard base64 string to a PackedByteArray.
	## Returns empty array on empty input or decode failure.
	if b64.is_empty():
		return PackedByteArray()
	var result := Marshalls.base64_to_raw(b64)
	return result
