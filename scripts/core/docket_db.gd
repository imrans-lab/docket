extends RefCounted
class_name DocketDB
## SQLite-backed storage replacing FileManager + QueryEngine + IdGenerator.
## Returns Dictionaries in the same format as the old in-memory dicts.

var _db: SQLite
var _path: String
var _is_open: bool = false
var _last_sql_error: String = ""
# Item changes waiting for the open transaction to commit (items_changed).
var _pending_changes: Array = []
var _transaction_open := false
# The thread that opened the connection. A connection, its transaction state
# and its result buffers are used from that thread only; a call from any
# other is refused before it touches them.
var _owner_thread: int = 0

## Emitted once item changes are durable, in order: [{id, event}], `event`
## being the item event recorded (e.g. "created", "transition",
## "comment_added"), "deleted", or "references_updated" for an item whose
## references were rewritten. Outside a transaction a change is reported at
## once; inside one, when it commits (nothing if it rolls back or its commit
## fails). DocketDBJsonl reports only once its file is saved.
signal items_changed(changes: Array)

func item_columns() -> Array:
	var result: Array = []
	for value in _ITEM_COLS: result.append(str(value))
	return result


# -- Lifecycle ----------------------------------------------------------------

func open(path: String) -> bool:
	_path = path
	_db = SQLite.new()
	_db.path = path
	_db.verbosity_level = SQLite.QUIET
	_owner_thread = OS.get_thread_caller_id()
	if not _db.open_db():
		push_error("DocketDB: failed to open %s" % path)
		return false
	_exec("PRAGMA journal_mode=WAL;")
	_exec("PRAGMA foreign_keys=ON;")
	_exec("PRAGMA busy_timeout=15000;")
	_is_open = true
	DocketDBSchema.migrate_schema(self)

	# Auto-derive project name and ID prefix from filename if still defaults
	var basename := path.get_file().get_basename()
	if get_project_name().is_empty() and not basename.is_empty():
		set_project_name(basename)
	if get_id_prefix() == "DKT" and not basename.is_empty() and basename != "docket":
		set_id_prefix(_derive_prefix(basename))

	return true


func close() -> void:
	if not _on_owner_thread(): return
	if _db:
		_exec("PRAGMA wal_checkpoint(TRUNCATE);")
		_db.close_db()
	_is_open = false


func checkpoint() -> void:
	## Flush WAL to main database file so other processes can see all data.
	if _db and _is_open and _on_owner_thread():
		_exec("PRAGMA wal_checkpoint(PASSIVE);")


func is_open() -> bool:
	return _is_open


static func create_new(path: String) -> DocketDB:
	var db := DocketDB.new()
	db._path = path
	db._db = SQLite.new()
	db._db.path = path
	db._db.verbosity_level = SQLite.QUIET
	db._owner_thread = OS.get_thread_caller_id()
	if not db._db.open_db():
		push_error("DocketDB: failed to create %s" % path)
		return null
	db._exec("PRAGMA journal_mode=WAL;")
	db._exec("PRAGMA foreign_keys=ON;")
	db._exec("PRAGMA busy_timeout=15000;")
	db._init_schema()
	db._is_open = true

	# Default project name and ID prefix from filename
	var basename := path.get_file().get_basename()
	if db.get_project_name().is_empty() and not basename.is_empty():
		db.set_project_name(basename)
	if db.get_id_prefix() == "DKT" and not basename.is_empty():
		db.set_id_prefix(_derive_prefix(basename))

	return db


func get_path() -> String:
	return _path


# -- Schema creation ----------------------------------------------------------

func _init_schema() -> void:
	DocketDBSchema.init_schema(self)

# -- ID generation ------------------------------------------------------------

func next_id() -> String:
	var rows := _exec_select("SELECT value FROM docket_meta WHERE key='counter';")
	var counter: int = int(rows[0].value) if rows.size() > 0 else 0
	counter += 1
	_exec("UPDATE docket_meta SET value=? WHERE key='counter';", [str(counter)])
	var prefix := get_id_prefix()
	if counter <= 9999:
		return "%s-%04d" % [prefix, counter]
	else:
		return "%s-%d" % [prefix, counter]


func get_id_prefix() -> String:
	return get_meta_value("id_prefix", "DKT")


func set_id_prefix(prefix: String) -> void:
	set_meta_value("id_prefix", prefix)


static func _derive_prefix(name: String) -> String:
	## Derive a 3-letter uppercase prefix from a project name.
	## Prefers consonant-leading characters, falls back to first 3 chars.
	if name.is_empty():
		return "DKT"
	var upper := name.to_upper()
	var consonants := "BCDFGHJKLMNPQRSTVWXYZ"
	var result := ""
	# First pass: take consonant-leading chars
	for c in upper:
		if consonants.contains(c):
			result += c
			if result.length() >= 3:
				return result
	# Fallback: take first 3 alphanumeric chars
	result = ""
	for c in upper:
		if c >= "A" and c <= "Z":
			result += c
			if result.length() >= 3:
				return result
	# Ultra-fallback: pad with X
	while result.length() < 3:
		result += "X"
	return result


func get_counter() -> int:
	var rows := _exec_select("SELECT value FROM docket_meta WHERE key='counter';")
	return int(rows[0].value) if rows.size() > 0 else 0


func set_counter(val: int) -> void:
	_exec("UPDATE docket_meta SET value=? WHERE key='counter';", [str(val)])


# -- UUID7 generation ---------------------------------------------------------

static func generate_uuid7() -> String:
	## Build a UUID v7: 6 bytes ms-timestamp (big-endian), 10 random bytes,
	## version nibble 0x7 in byte 6, variant bits 0b10 in byte 8.
	## Returns 32-char lowercase hex (no dashes).
	var ms: int = int(Time.get_unix_time_from_system() * 1000.0)
	var buf := PackedByteArray()
	buf.resize(16)
	# 6 bytes big-endian millisecond timestamp
	buf[0] = (ms >> 40) & 0xFF
	buf[1] = (ms >> 32) & 0xFF
	buf[2] = (ms >> 24) & 0xFF
	buf[3] = (ms >> 16) & 0xFF
	buf[4] = (ms >> 8) & 0xFF
	buf[5] = ms & 0xFF
	# 10 random bytes
	var rand_bytes := Crypto.new().generate_random_bytes(10)
	for i in 10:
		buf[6 + i] = rand_bytes[i]
	# Stamp version 7 in byte 6 high nibble
	buf[6] = (buf[6] & 0x0F) | 0x70
	# Stamp variant 0b10 in byte 8 high 2 bits
	buf[8] = (buf[8] & 0x3F) | 0x80
	return buf.hex_encode()


func next_uuid7_id() -> String:
	## Generate a new UUID7 ID for this DB instance.
	return generate_uuid7()


func resolve_short_id(prefix: String) -> String:
	## Resolve a short hex prefix (min 4 chars) to a full UUID7 ID.
	## Returns "" if ambiguous or not found.
	if prefix.length() < 4:
		return ""
	# Exact match first
	if has_item(prefix):
		return prefix
	# Prefix match via LIKE
	var rows := _exec_select("SELECT id FROM items WHERE id LIKE ? LIMIT 2;", [prefix + "%"])
	if rows.size() == 1:
		return str(rows[0].id)
	return ""


func short_id(full_id: String) -> String:
	## Return the shortest unique prefix for display (min 7 chars for UUID7).
	## Legacy IDs are returned as-is.
	if not _is_uuid7(full_id):
		return full_id
	for length in range(7, full_id.length() + 1):
		var candidate := full_id.substr(0, length)
		var rows := _exec_select("SELECT COUNT(*) AS cnt FROM items WHERE id LIKE ? ;", [candidate + "%"])
		var cnt: int = int(rows[0].cnt) if rows.size() > 0 else 0
		if cnt <= 1:
			return candidate
	return full_id


static func _is_uuid7(id: String) -> bool:
	return DocketFields.is_uuid7(id)


# -- Meta helpers -------------------------------------------------------------

func get_meta_value(meta_key: String, default: String = "") -> String:
	var rows := _exec_select("SELECT value FROM docket_meta WHERE key=?;", [meta_key])
	return str(rows[0].value) if rows.size() > 0 else default


func set_meta_value(meta_key: String, val: String) -> void:
	_exec("INSERT OR REPLACE INTO docket_meta (key, value) VALUES (?, ?);", [meta_key, val])


func get_all_meta() -> Dictionary:
	## Every docket_meta key/value. Exists so serialization can persist whatever
	## is actually stored rather than a hardcoded list — that list silently
	## dropped project lifecycle fields, and nearly stranded every vault when the
	## KDF iteration count was added.
	var out := {}
	for row in _exec_select("SELECT key, value FROM docket_meta;"):
		var k := str(row.get("key", ""))
		if not k.is_empty():
			out[k] = str(row.get("value", ""))
	return out


func get_project_name() -> String:
	return get_meta_value("project", "")


func set_project_name(name: String) -> void:
	set_meta_value("project", name)


func get_project_meta() -> Dictionary:
	## Return all project lifecycle metadata as a dict.
	var d := {}
	var stage := get_meta_value("project_stage", "")
	if not stage.is_empty():
		d["stage"] = stage
	var hyp := get_meta_value("project_hypothesis", "")
	if not hyp.is_empty():
		d["hypothesis"] = hyp
	var sc := get_meta_value("project_success_criteria", "")
	if not sc.is_empty():
		d["success_criteria"] = sc
	var pt := get_meta_value("project_promoted_to", "")
	if not pt.is_empty():
		d["promoted_to"] = pt
	return d


func set_project_meta(meta: Dictionary) -> void:
	## Update project lifecycle metadata. Only writes non-empty values.
	if meta.has("stage"):
		set_meta_value("project_stage", str(meta["stage"]))
	if meta.has("hypothesis"):
		set_meta_value("project_hypothesis", str(meta["hypothesis"]))
	if meta.has("success_criteria"):
		set_meta_value("project_success_criteria", str(meta["success_criteria"]))
	if meta.has("promoted_to"):
		set_meta_value("project_promoted_to", str(meta["promoted_to"]))


# -- Qualified reference helpers ----------------------------------------------

static func parse_qualified_ref(ref: String) -> Dictionary:
	## Parse "project:ID" into {"project": "...", "id": "..."}. Bare IDs return empty project.
	var colon_pos := ref.find(":")
	if colon_pos > 0:
		return {"project": ref.substr(0, colon_pos), "id": ref.substr(colon_pos + 1)}
	return {"project": "", "id": ref}


# -- Text normalization -------------------------------------------------------

## Replace literal \n and \t escape sequences with real characters.
## Defends against MCP clients that pass escaped text instead of actual newlines.
static func _normalize_text(val) -> Variant:
	if val is Array or val is Dictionary:
		return JSON.stringify(val)
	if val is String:
		var s: String = val
		s = s.replace("\\n", "\n")
		s = s.replace("\\t", "\t")
		return s
	return val


# -- Item CRUD ----------------------------------------------------------------

## Column names for the items table (excluding id which is PRIMARY KEY).
const _ITEM_COLS: Array = [
	"type", "status", "title", "description",
	"created_at", "updated_at", "created_by", "assigned_to", "directed_to",
	"priority", "severity",
	"resolution", "environment", "repro_steps",
	"assumed", "corrected", "findings", "answer",
	"occurred_at", "detected_at", "reported_at",
	"why_chain", "significant_events", "contributing_factors",
	"value", "component", "key",
	"topic", "subtopic", "confidence",
	"surprise", "surfaced_from",
	"retrieval_count", "research_cost",
	"blocked_by", "parent",
	"test_setup", "test_steps", "expected_result",
	"quality", "last_reviewed",
	"command", "usage", "prompt_text", "preconditions",
	"summary", "article", "parameters",
	"steps", "outcome", "tool_deps",
	"target", "optimization",
	# Plugin-shipped skills metadata (Minerva DCR 019df57b)
	"source", "customised", "pristine_hash", "pristine_content",
	"unsatisfied_deps", "deprecated",
	"type_id", "type_revision", "fields_json", "extras_json",
]


func insert_item(id: String, item: Dictionary) -> String:
	## Inserts an item into the database. Returns "" on success, error message on failure.
	# Insert main row
	if item.has("fields_json") or item.has("extras_json"): return "internal envelope columns are not accepted as item input"
	var stored_item := item.duplicate(true)
	var fields: Dictionary = stored_item.get("fields", {}) if stored_item.get("fields", {}) is Dictionary else {}
	var extras: Dictionary = stored_item.get("extras", {}) if stored_item.get("extras", {}) is Dictionary else {}
	if stored_item.has("fields") and not stored_item.fields is Dictionary: return "fields must be an object"
	if stored_item.has("extras") and not stored_item.extras is Dictionary: return "extras must be an object"
	for key in fields:
		if extras.has(key) or (stored_item.has(key) and key not in ["fields", "extras"]): return "ambiguous item key '%s'" % key
	for key in extras:
		if stored_item.has(key) and key not in ["fields", "extras"]: return "ambiguous item key '%s'" % key
	for key in stored_item.keys():
		if key not in _ITEM_COLS and key not in ["_type", "id", "tags", "events", "links", "fields", "extras"]:
			if extras.has(key): return "ambiguous item key '%s'" % key
			extras[key] = stored_item[key]
			stored_item.erase(key)
	if not extras.is_empty(): stored_item["extras"] = extras
	stored_item.erase("_type")
	for envelope in ["fields", "extras"]:
		if stored_item.has(envelope):
			if not stored_item[envelope] is Dictionary: return "%s must be an object" % envelope
			stored_item["%s_json" % envelope] = JSON.stringify(stored_item[envelope], "", true, true)
	var cols := PackedStringArray(["id"])
	var placeholders := PackedStringArray(["?"])
	var bindings: Array = [id]
	for col in _ITEM_COLS:
		if stored_item.has(col):
			cols.append(col)
			placeholders.append("?")
			bindings.append(stored_item[col] if col in ["fields_json", "extras_json"] else _normalize_text(stored_item[col]))
	var sql := "INSERT INTO items (%s) VALUES (%s);" % [",".join(cols), ",".join(placeholders)]
	var err := _exec_checked(sql, bindings)
	if not err.is_empty():
		return err

	# Tags — ensure it's an Array
	var tags_raw = item.get("tags", [])
	var tags: Array = tags_raw if tags_raw is Array else []
	for tag in tags:
		_exec("INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?);", [id, str(tag)])

	# Events
	var events: Array = item.get("events", [])
	for ev in events:
		_exec("INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
			[id, str(ev.get("event_type", "")), str(ev.get("actor", "")),
			 str(ev.get("timestamp", "")), str(ev.get("note", ""))])

	# Links
	var links: Array = item.get("links", [])
	for link in links:
		var to_id: String = str(link.get("to", ""))
		var relation: String = str(link.get("relation", ""))
		if not to_id.is_empty() and not relation.is_empty():
			_exec("INSERT INTO item_links (from_id, to_id, relation) VALUES (?, ?, ?);",
				[id, to_id, relation])

	return ""


func get_item(id: String) -> Dictionary:
	var rows := _exec_select("SELECT * FROM items WHERE id=?;", [id])
	if rows.is_empty():
		return {}
	return _build_item_dict(rows[0])


func has_item(id: String) -> bool:
	var rows := _exec_select("SELECT 1 FROM items WHERE id=? LIMIT 1;", [id])
	return rows.size() > 0


func update_item_fields(id: String, changes: Dictionary) -> void:
	update_item_fields_checked(id, changes)


func update_item_fields_checked(id: String, changes: Dictionary) -> String:
	if changes.is_empty():
		return ""
	if changes.has("fields_json") or changes.has("extras_json"): return "internal envelope columns are not accepted as item input"
	var field_changes = changes.get("fields", {})
	var extra_changes = changes.get("extras", {})
	if changes.has("fields") and not field_changes is Dictionary: return "fields must be an object"
	if changes.has("extras") and not extra_changes is Dictionary: return "extras must be an object"
	for key in field_changes:
		if extra_changes.has(key) or changes.has(key): return "ambiguous item key '%s'" % key
	for key in extra_changes:
		if changes.has(key): return "ambiguous item key '%s'" % key
	var unset_fields_value = changes.get("unset_fields", [])
	var unset_extras_value = changes.get("unset_extras", [])
	if not unset_fields_value is Array: return "unset_fields must be an array"
	if not unset_extras_value is Array: return "unset_extras must be an array"
	var unset_fields: Array = unset_fields_value
	var unset_extras: Array = unset_extras_value
	for key in unset_fields:
		if not key is String: return "unset_fields entries must be strings"
	for key in unset_extras:
		if not key is String: return "unset_extras entries must be strings"
	for key in unset_fields:
		if field_changes.has(key) or extra_changes.has(key) or unset_extras.has(key): return "ambiguous set/unset item key '%s'" % key
	for key in unset_extras:
		if extra_changes.has(key) or field_changes.has(key): return "ambiguous set/unset item key '%s'" % key
	var envelope_rows := _exec_select("SELECT fields_json,extras_json FROM items WHERE id=?;", [id])
	if envelope_rows.is_empty(): return "item '%s' does not exist" % id
	var existing_fields = JSON.parse_string(str(envelope_rows[0].get("fields_json", "{}")))
	var existing_extras = JSON.parse_string(str(envelope_rows[0].get("extras_json", "{}")))
	if not existing_fields is Dictionary or not existing_extras is Dictionary: return "stored item envelopes are malformed"
	for key in existing_fields:
		if existing_extras.has(key): return "stored item envelopes contain ambiguous key '%s'" % key
		if extra_changes.has(key) or (changes.has(key) and key not in ["fields", "unset_fields"]): return "item key '%s' belongs to fields" % key
	for key in existing_extras:
		if field_changes.has(key): return "item key '%s' belongs to extras" % key
	var sets := PackedStringArray()
	var bindings: Array = []
	var stored_changes := changes.duplicate(true)
	var unknown_changes := {}
	for key in stored_changes.keys():
		if key not in _ITEM_COLS and key not in ["tags", "events", "links", "id", "fields", "extras", "unset_fields", "unset_extras"]:
			unknown_changes[key] = stored_changes[key]
			stored_changes.erase(key)
	if not unknown_changes.is_empty():
		var combined_extras: Dictionary = stored_changes.get("extras", {}).duplicate(true)
		combined_extras.merge(unknown_changes, true)
		stored_changes["extras"] = combined_extras
	for envelope in ["fields", "extras"]:
		if (stored_changes.has(envelope) and stored_changes[envelope] is Dictionary) or stored_changes.has("unset_%s" % envelope):
			var merged: Dictionary = (existing_fields if envelope == "fields" else existing_extras).duplicate(true)
			merged.merge(stored_changes.get(envelope, {}), true)
			for key in changes.get("unset_%s" % envelope, []): merged.erase(key)
			stored_changes["%s_json" % envelope] = JSON.stringify(merged, "", true, true)
	for col in stored_changes:
		if col in ["tags", "events", "links", "id"]:
			continue
		if col in ["fields", "extras", "unset_fields", "unset_extras"]: continue
		if col not in _ITEM_COLS: continue
		sets.append("%s=?" % col)
		bindings.append(stored_changes[col] if col in ["fields_json", "extras_json"] else _normalize_text(stored_changes[col]))
	if sets.size() > 0:
		bindings.append(id)
		var error := _exec_checked("UPDATE items SET %s WHERE id=?;" % ",".join(sets), bindings)
		if not error.is_empty(): return error

	# Handle tags replacement
	if changes.has("tags"):
		var error := _exec_checked("DELETE FROM item_tags WHERE item_id=?;", [id])
		if not error.is_empty(): return error
		var tags: Array = changes["tags"]
		for tag in tags:
			error = _exec_checked("INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?);", [id, str(tag)])
			if not error.is_empty(): return error
	return ""


func set_item_field(id: String, field: String, val) -> void:
	if field == "tags":
		update_item_fields(id, {"tags": val})
	else:
		_exec("UPDATE items SET %s=? WHERE id=?;" % field, [_normalize_text(val), id])


# -- Full item export/import/delete (for cross-project moves) -----------------

func export_item_full(id: String) -> Dictionary:
	## Export an item with all related data (tags, events, links, comments, attachments).
	var rows := _exec_select("SELECT * FROM items WHERE id=?;", [id])
	if rows.is_empty():
		return {}
	var row: Dictionary = rows[0]

	# Scalar fields
	var exported := {}
	exported["item"] = {}
	for col in _ITEM_COLS:
		var val = row.get(col)
		exported["item"][col] = val if val != null else ""
	for envelope in ["fields", "extras"]:
		var raw_key := "%s_json" % envelope
		var decoded = JSON.parse_string(str(row.get(raw_key, "{}")))
		exported.item.erase(raw_key)
		if not decoded is Dictionary: return {"_error":"malformed %s envelope for item %s" % [envelope,id]}
		exported.item[envelope] = decoded
	exported["item"]["title"] = str(row.get("title", ""))

	# Tags
	var tag_rows := _exec_select("SELECT tag FROM item_tags WHERE item_id=?;", [id])
	var tags: Array = []
	for tag_row in tag_rows:
		tags.append(str(tag_row.tag))
	exported["tags"] = tags

	# Events
	var event_rows := _exec_select("SELECT event_type, actor, timestamp, note FROM item_events WHERE item_id=? ORDER BY id ASC;", [id])
	var events: Array = []
	for er in event_rows:
		events.append({
			"event_type": str(er.get("event_type", "")),
			"actor": str(er.get("actor", "")),
			"timestamp": str(er.get("timestamp", "")),
			"note": str(er.get("note", "")),
		})
	exported["events"] = events

	# Links
	var link_rows := _exec_select("SELECT to_id, relation FROM item_links WHERE from_id=?;", [id])
	var links: Array = []
	for lr in link_rows:
		links.append({
			"to": str(lr.get("to_id", "")),
			"relation": str(lr.get("relation", "")),
		})
	exported["links"] = links
	var incoming_rows := _exec_select("SELECT from_id,relation FROM item_links WHERE to_id=? OR to_id LIKE ?;", [id,"%:" + id])
	var incoming: Array = []
	for incoming_row in incoming_rows: incoming.append({"from":str(incoming_row.get("from_id", "")),"relation":str(incoming_row.get("relation", ""))})
	exported["incoming_links"] = incoming

	# Comments
	var comment_rows := _exec_select("SELECT * FROM comments WHERE item_id=? ORDER BY id ASC;", [id])
	var comments: Array = []
	for cr in comment_rows:
		comments.append({
			"id": int(cr.get("id", 0)),
			"parent_id": int(cr.get("parent_id", 0)),
			"author": str(cr.get("author", "")),
			"text": str(cr.get("text", "")),
			"status": str(cr.get("status", "open")),
			"created_at": str(cr.get("created_at", "")),
			"resolved_at": str(cr.get("resolved_at", "")),
			"resolved_by": str(cr.get("resolved_by", "")),
		})
	exported["comments"] = comments

	# Attachments (with binary data)
	var att_rows: Array = _exec_select("SELECT * FROM attachments WHERE item_id=?;", [id])
	var attachments: Array = []
	for ar in att_rows:
		attachments.append({
			"filename": str(ar.get("filename", "")),
			"mime_type": str(ar.get("mime_type", "")),
			"data": ar.get("data", PackedByteArray()),
			"created_at": str(ar.get("created_at", "")),
			"description": str(ar.get("description", "")),
		})
	exported["attachments"] = attachments

	return exported

func export_item_full_checked(id: String) -> Dictionary:
	## A move may delete its source only after every related collection was read.
	_last_sql_error = ""
	var exported: Dictionary = export_item_full(id)
	if not _last_sql_error.is_empty(): return {"error":_last_sql_error}
	if exported.has("_error"): return {"error":exported._error}
	if exported.is_empty(): return {"error":"item not found: %s" % id}
	return {"export":exported}


func import_item_full(new_id: String, exported: Dictionary) -> void:
	## Import a full item export under a new ID. Adds a "moved" event.
	var item_data: Dictionary = exported.get("item", {})
	item_data["id"] = new_id
	for envelope in ["fields", "extras"]:
		if item_data.get(envelope, {}) is Dictionary:
			item_data["%s_json" % envelope] = JSON.stringify(item_data[envelope], "", true, true)

	# Insert main item
	var cols := PackedStringArray(["id"])
	var placeholders := PackedStringArray(["?"])
	var bindings: Array = [new_id]
	for col in _ITEM_COLS:
		if item_data.has(col):
			cols.append(col)
			placeholders.append("?")
			bindings.append(item_data[col])
	var title: String = str(item_data.get("title", ""))
	if not item_data.has("title"):
		cols.append("title")
		placeholders.append("?")
		bindings.append(title)
	var sql := "INSERT INTO items (%s) VALUES (%s);" % [",".join(cols), ",".join(placeholders)]
	if _exec_checked(sql, bindings).is_empty():
		_record_change(new_id, "created")

	# Tags
	var tags: Array = exported.get("tags", [])
	for tag in tags:
		_exec("INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?);", [new_id, str(tag)])

	# Events (preserve existing + add moved event)
	var events: Array = exported.get("events", [])
	for ev in events:
		_exec("INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
			[new_id, str(ev.get("event_type", "")), str(ev.get("actor", "")),
			 str(ev.get("timestamp", "")), str(ev.get("note", ""))])
	# Add "moved" event
	var ts := Time.get_datetime_string_from_system(true)
	_exec("INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
		[new_id, "moved", "", ts, "Moved to this project as %s" % new_id])

	# Links
	var links: Array = exported.get("links", [])
	for link in links:
		var to_id: String = str(link.get("to", ""))
		var relation: String = str(link.get("relation", ""))
		if not to_id.is_empty() and not relation.is_empty():
			_exec("INSERT INTO item_links (from_id, to_id, relation) VALUES (?, ?, ?);",
				[new_id, to_id, relation])

	# Comments
	var comments: Array = exported.get("comments", [])
	var comment_ids := {}
	var pending_comments: Array = comments.duplicate(true)
	while not pending_comments.is_empty():
		var progressed: bool = false
		for index in range(pending_comments.size() - 1, -1, -1):
			var c: Dictionary = pending_comments[index]
			var old_id: int = int(c.get("id", 0)); var old_parent: int = int(c.get("parent_id", 0))
			if old_parent != 0 and not comment_ids.has(old_parent): continue
			var mapped_parent: int = int(comment_ids.get(old_parent, 0))
			var comment_error := _exec_checked("INSERT INTO comments (item_id, parent_id, author, text, status, created_at, resolved_at, resolved_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?);", [new_id,mapped_parent,str(c.get("author", "")),str(c.get("text", "")),str(c.get("status", "open")),str(c.get("created_at", "")),str(c.get("resolved_at", "")),str(c.get("resolved_by", ""))])
			if not comment_error.is_empty(): return
			var inserted: Array = _exec_select("SELECT last_insert_rowid() AS id;")
			if old_id > 0 and not inserted.is_empty(): comment_ids[old_id] = int(inserted[0].id)
			pending_comments.remove_at(index); progressed = true
		if not progressed:
			if _last_sql_error.is_empty(): _last_sql_error = "comment thread contains an unresolved parent"
			return

	# Attachments
	var attachments: Array = exported.get("attachments", [])
	for att in attachments:
		var att_data = att.get("data", PackedByteArray())
		var size_bytes: int = att_data.size() if att_data is PackedByteArray else 0
		_exec_checked(
			"INSERT INTO attachments (item_id, filename, mime_type, size_bytes, data, created_at, description) VALUES (?, ?, ?, ?, ?, ?, ?);",
			[new_id, str(att.get("filename", "")), str(att.get("mime_type", "")),
			 size_bytes, att_data, str(att.get("created_at", "")),
			 str(att.get("description", ""))])

	# Update timestamp
	_exec("UPDATE items SET updated_at=? WHERE id=?;", [ts, new_id])


func delete_item(id: String) -> void:
	## Cascading delete of an item and all related data (tags, events, links, comments, attachments, secrets).
	## Foreign keys with ON DELETE CASCADE handle most of this, but we do it explicitly for safety.
	_exec("DELETE FROM item_tags WHERE item_id=?;", [id])
	_exec("DELETE FROM item_events WHERE item_id=?;", [id])
	_exec("DELETE FROM item_links WHERE from_id=? OR to_id=?;", [id, id])
	_exec("DELETE FROM comments WHERE item_id=?;", [id])
	_exec("DELETE FROM attachments WHERE item_id=?;", [id])
	# Clean up vault entries (secret value + encrypted notes + versions).
	# Delete by recorded ownership as well as by convention: an entry attached to
	# this item under some other handle would otherwise be left orphaned, with no
	# item to reach it through and no listing that shows it.
	for owned_handle in list_secrets_owned_by(id):
		delete_secret(owned_handle)
		_exec("DELETE FROM docket_secret_versions WHERE handle=?;", [owned_handle])
	delete_secret(id)
	delete_secret(id + ":notes")
	_exec("DELETE FROM docket_secret_versions WHERE handle=?;", [id])
	_exec("DELETE FROM docket_secret_versions WHERE handle=?;", [id + ":notes"])
	if _exec_checked("DELETE FROM items WHERE id=?;", [id]).is_empty():
		_record_change(id, "deleted")


func rewrite_refs(old_qualified: String, new_qualified: String, old_bare_id: String, new_qualified_for_bare: String, rewrite_bare: bool = true) -> int:
	## Rewrite parent and blocked_by references from old to new.
	## Returns the total number of rows updated.
	var count := 0
	var referencing: Array[String] = []
	for ref in [old_qualified, old_bare_id] if rewrite_bare else [old_qualified]:
		for row in _exec_select("SELECT id FROM items WHERE parent=? OR blocked_by=? UNION SELECT from_id FROM item_links WHERE to_id=?;", [ref, ref, ref]):
			if not str(row.id) in referencing:
				referencing.append(str(row.id))

	# Rewrite qualified parent refs
	_exec("UPDATE items SET parent=? WHERE parent=?;", [new_qualified, old_qualified])
	count += _get_changes_count()

	# Rewrite bare parent refs (backwards compat)
	if rewrite_bare:
		_exec("UPDATE items SET parent=? WHERE parent=?;", [new_qualified_for_bare, old_bare_id])
		count += _get_changes_count()

	# Rewrite qualified blocked_by refs
	_exec("UPDATE items SET blocked_by=? WHERE blocked_by=?;", [new_qualified, old_qualified])
	count += _get_changes_count()

	# Rewrite bare blocked_by refs
	if rewrite_bare:
		_exec("UPDATE items SET blocked_by=? WHERE blocked_by=?;", [new_qualified_for_bare, old_bare_id])
		count += _get_changes_count()
	_exec("UPDATE item_links SET to_id=? WHERE to_id=?;", [new_qualified, old_qualified])
	count += _get_changes_count()
	if rewrite_bare:
		_exec("UPDATE item_links SET to_id=? WHERE to_id=?;", [new_qualified_for_bare, old_bare_id])
		count += _get_changes_count()
	for id in referencing:
		_record_change(id, "references_updated")
	return count


func _get_changes_count() -> int:
	## Get the number of rows modified by the last UPDATE/INSERT/DELETE.
	var rows := _exec_select("SELECT changes() as cnt;")
	return int(rows[0].cnt) if rows.size() > 0 else 0


# -- Events -------------------------------------------------------------------

func add_event(item_id: String, event_type: String, actor: String, note: String = "") -> void:
	var ts := Time.get_datetime_string_from_system(true)
	var error := _exec_checked("INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
		[item_id, event_type, actor, ts, note])
	if error.is_empty():
		error = _exec_checked("UPDATE items SET updated_at=? WHERE id=?;", [ts, item_id])
	if error.is_empty():
		_record_change(item_id, event_type)


func get_events(item_id: String) -> Array:
	# Order by timestamp, not rowid: after a git merge the rowid order reflects
	# how the merge interleaved lines ("ours" before "theirs"), not chronology.
	# Rowid remains the tiebreak for same-second events.
	var rows := _exec_select("SELECT event_type, actor, timestamp, note FROM item_events WHERE item_id=? ORDER BY timestamp ASC, id ASC;", [item_id])
	var result: Array = []
	for row in rows:
		result.append({
			"event_type": str(row.get("event_type", "")),
			"actor": str(row.get("actor", "")),
			"timestamp": str(row.get("timestamp", "")),
			"note": str(row.get("note", "")),
		})
	return result


# -- Transition log -----------------------------------------------------------

func log_transition(item_type: String, from_state: String, attempted_to: String, succeeded: bool, valid_transitions: Array = []) -> void:
	var ts := Time.get_datetime_string_from_system(true)
	_exec("INSERT INTO transition_log (timestamp, item_type, from_state, attempted_to, succeeded, valid_transitions) VALUES (?, ?, ?, ?, ?, ?);",
		[ts, item_type, from_state, attempted_to, 1 if succeeded else 0, ",".join(valid_transitions)])


func get_transition_report() -> Array:
	## Returns failed transition attempts grouped by (item_type, from_state, attempted_to), sorted by frequency.
	var rows := _exec_select("""
		SELECT item_type, from_state, attempted_to, valid_transitions, COUNT(*) as count
		FROM transition_log WHERE succeeded = 0
		GROUP BY item_type, from_state, attempted_to
		ORDER BY count DESC;
	""")
	var result: Array = []
	for row in rows:
		result.append({
			"item_type": str(row.get("item_type", "")),
			"from_state": str(row.get("from_state", "")),
			"attempted_to": str(row.get("attempted_to", "")),
			"valid_transitions": str(row.get("valid_transitions", "")),
			"count": int(row.get("count", 0)),
		})
	return result


# -- MCP error log ------------------------------------------------------------

func log_mcp_error(tool_name: String, error_message: String, arg_keys: String = "") -> void:
	var ts := Time.get_datetime_string_from_system(true)
	_exec("INSERT INTO mcp_error_log (timestamp, tool_name, error_message, arg_keys) VALUES (?, ?, ?, ?);",
		[ts, tool_name, error_message, arg_keys])


func get_error_report() -> Array:
	## Returns MCP errors grouped by (tool_name, error_message), sorted by frequency.
	var rows := _exec_select("""
		SELECT tool_name, error_message, COUNT(*) as count
		FROM mcp_error_log
		GROUP BY tool_name, error_message
		ORDER BY count DESC;
	""")
	var result: Array = []
	for row in rows:
		result.append({
			"tool_name": str(row.get("tool_name", "")),
			"error_message": str(row.get("error_message", "")),
			"count": int(row.get("count", 0)),
		})
	return result


# -- Links --------------------------------------------------------------------

func add_link(from_id: String, to_id: String, relation: String) -> void:
	_exec("INSERT INTO item_links (from_id, to_id, relation) VALUES (?, ?, ?);",
		[from_id, to_id, relation])


func get_links(item_id: String) -> Array:
	var rows := _exec_select("SELECT to_id, relation FROM item_links WHERE from_id=?;", [item_id])
	var result: Array = []
	for row in rows:
		result.append({
			"to": str(row.get("to_id", "")),
			"relation": str(row.get("relation", "")),
		})
	return result


# -- Query execution ----------------------------------------------------------

## Reason the most recent execute_query returned [] without running. Read it
## immediately after an empty result to distinguish "no matches" from "refused".
var last_query_error: String = ""

## Cached column names of the items table, for filter/sort field validation.
var _items_columns_cache: Array = []


func _item_columns() -> Array:
	## Column names of the items table, read once per connection.
	if not _items_columns_cache.is_empty():
		return _items_columns_cache
	var cols: Array = []
	for row in _exec_select("PRAGMA table_info(items);"):
		var n := str(row.get("name", ""))
		if not n.is_empty():
			cols.append(n)
	_items_columns_cache = cols
	return cols


func execute_query(query: Dictionary, detail: String = "full") -> Array:
	var filter = query.get("filter", {})
	var sort_spec: Array = query.get("sort", [])
	var limit: int = int(query.get("limit", 0))

	# Field names become SQL identifiers and cannot be bound as parameters, so
	# the translator has to check them against the real columns. Derived from the
	# live table rather than a hand-kept list, which would drift as columns are
	# added and quietly start rejecting valid queries.
	DocketDBFilter.set_allowed_fields(_item_columns())

	var translated: Dictionary
	if filter is Dictionary and filter.has("conditions"):
		translated = DocketDBFilter.translate_conditions(filter.conditions)
	elif filter is Dictionary and (filter.has("$or") or filter.has("$and")):
		translated = DocketDBFilter.translate_tree(filter)
	else:
		translated = DocketDBFilter.translate_filter(filter if filter is Dictionary else {})

	if translated.has("error"):
		# Refuse rather than run a weakened query: silently dropping the offending
		# condition would return MORE rows than the caller asked for.
		push_error("DocketDB.execute_query: %s" % translated["error"])
		last_query_error = str(translated["error"])
		return []
	last_query_error = ""

	var where_clause: String = translated.where
	var bindings: Array = translated.bindings

	var sql := "SELECT * FROM items"
	if not where_clause.is_empty():
		sql += " WHERE " + where_clause

	# Sort — validate field names against the items table columns
	const SORTABLE_FIELDS := [
		"id", "type", "status", "title", "description",
		"created_at", "updated_at", "created_by", "assigned_to", "directed_to",
		"priority", "severity", "resolution", "environment", "repro_steps",
		"assumed", "corrected", "findings", "answer",
		"occurred_at", "detected_at", "reported_at",
		"why_chain", "significant_events", "contributing_factors",
		"value", "component", "key", "topic", "subtopic", "confidence",
		"surprise", "surfaced_from", "retrieval_count", "research_cost",
		"blocked_by", "parent",
		"test_setup", "test_steps", "expected_result",
		"quality", "last_reviewed",
		"command", "usage", "prompt_text", "preconditions",
		"summary", "article", "parameters",
		"steps", "outcome", "target",
	]
	if sort_spec.size() > 0:
		var order_parts := PackedStringArray()
		for spec in sort_spec:
			var field: String = str(spec.get("field", ""))
			var dir: String = str(spec.get("dir", "asc")).to_upper()
			if dir != "DESC":
				dir = "ASC"
			if field.is_empty():
				continue
			if field not in SORTABLE_FIELDS:
				return [{"_error": "Invalid sort field: '%s'. Valid fields: %s" % [field, ", ".join(SORTABLE_FIELDS)]}]
			order_parts.append("%s %s" % [field, dir])
		if order_parts.size() > 0:
			sql += " ORDER BY " + ",".join(order_parts)

	# Limit
	if limit > 0:
		sql += " LIMIT %d" % limit

	sql += ";"
	var rows := _exec_select(sql, bindings)

	# Propagate validation errors from sort check
	if rows.size() == 1 and rows[0] is Dictionary and rows[0].has("_error"):
		return rows

	if detail == "lean":
		return _build_lean_rows(rows)

	var results: Array = []
	for row in rows:
		var item := _build_item_dict(row)
		if detail == "full_stripped":
			item = _strip_empty(item)
		results.append(item)
	return results

func execute_registry_query(query: Dictionary, registry: TypeRegistry, detail: String = "full") -> Array:
	## Typed bindings are compiled separately so legacy literal filters keep their
	## historical meaning and cannot be widened by partial translation.
	var compiled: Dictionary = RegistryQuery.compile(query, registry, _item_columns())
	if compiled.has("error"):
		last_query_error = str(compiled.error)
		return []
	last_query_error = ""
	var sql := "SELECT * FROM items"
	if not str(compiled.where).is_empty(): sql += " WHERE " + str(compiled.where)
	var bindings: Array = compiled.bindings.duplicate()
	if not str(compiled.order).is_empty():
		sql += " ORDER BY " + str(compiled.order)
		bindings.append_array(compiled.order_bindings)
	var limit: int = int(query.get("limit", 0))
	if limit > 0: sql += " LIMIT %d" % limit
	_last_sql_error = ""
	var rows: Array = _exec_select(sql + ";", bindings)
	if not _last_sql_error.is_empty():
		last_query_error = _last_sql_error
		return []
	if detail == "lean": return _build_lean_rows(rows)
	var results: Array = []
	for row in rows:
		var item: Dictionary = _build_item_dict(row)
		var semantics: Dictionary = registry.resolve_item(item)
		if not semantics.has("error"):
			item["state_category"] = semantics.state_category
			item["state_outcome"] = semantics.state_outcome
			item["is_terminal"] = semantics.is_terminal
		else:
			item["type_diagnostic"] = semantics.error
		if detail == "full_stripped": item = _strip_empty(item)
		results.append(item)
	return results


# -- Hint helpers -------------------------------------------------------------

func find_hint(component: String, key_val: String) -> Dictionary:
	var rows := _exec_select(
		"SELECT * FROM items WHERE type='hint' AND component=? AND key=? LIMIT 1;",
		[component, key_val])
	if rows.is_empty():
		return {}
	return _build_item_dict(rows[0])


func query_hints(args: Dictionary, detail: String = "full") -> Array:
	var hints_only: bool = args.get("_hints_only", false)
	var conditions := PackedStringArray()
	if hints_only:
		conditions.append("type='hint'")
	else:
		conditions.append("type IN ('hint','insight')")
	var bindings: Array = []

	if args.has("component") and not str(args.component).is_empty():
		conditions.append("component=?")
		bindings.append(str(args.component))
	if args.has("key") and not str(args.key).is_empty():
		conditions.append("key=?")
		bindings.append(str(args.key))
	if args.get("promoted_only", false):
		conditions.append("status='promoted'")
	if args.has("min_retrievals"):
		conditions.append("retrieval_count>=?")
		bindings.append(int(args.min_retrievals))
	if args.has("min_research_cost"):
		conditions.append("research_cost>=?")
		bindings.append(int(args.min_research_cost))

	# Tag filtering (all tags must match)
	var tag_filter: Array = args.get("tags", [])
	for tag in tag_filter:
		conditions.append("EXISTS (SELECT 1 FROM item_tags WHERE item_tags.item_id=items.id AND item_tags.tag=?)")
		bindings.append(str(tag))

	var sql := "SELECT * FROM items WHERE " + " AND ".join(conditions)
	var limit: int = int(args.get("limit", 0))
	if limit > 0:
		sql += " LIMIT %d" % limit
	sql += ";"

	var rows := _exec_select(sql, bindings)

	if detail == "lean":
		return _build_lean_hint_rows(rows)

	var results: Array = []
	for row in rows:
		var item := _build_item_dict(row)
		if detail == "full_stripped":
			item = _strip_empty(item)
		results.append(item)
	return results


func bump_retrieval(id: String) -> void:
	## Retrieval is a READ. It records usage in retrieval_count and deliberately
	## does NOT touch updated_at: that field means "when this record last
	## changed", and stamping it on every lookup destroys the only signal that
	## says when a hint's CONTENT was last revised. (Observed 2026-08-16: one
	## unfiltered hint query rewrote updated_at on all 276 hints in a store,
	## flattening months of history to a single date.)
	_exec("UPDATE items SET retrieval_count=retrieval_count+1 WHERE id=?;", [id])


func bump_retrieval_many(ids: Array) -> void:
	## Batch form of bump_retrieval. Exists so a backend that persists on every
	## mutation can persist ONCE for the whole batch — see
	## DocketDBJsonl.bump_retrieval_many. Callers that bump more than one item
	## (any query returning a result set) must use this, not a loop over
	## bump_retrieval.
	for id in ids:
		var s := str(id)
		if not s.is_empty():
			bump_retrieval(s)


# -- Context ------------------------------------------------------------------

func query_context(tags: Array, include_types: Array = [], detail: String = "full") -> Array:
	if tags.is_empty():
		return []

	# Items that have ANY of the requested tags
	var tag_placeholders := PackedStringArray()
	var bindings: Array = []
	for tag in tags:
		tag_placeholders.append("?")
		bindings.append(str(tag))

	var sql := "SELECT DISTINCT items.* FROM items INNER JOIN item_tags ON item_tags.item_id=items.id WHERE item_tags.tag IN (%s)" % ",".join(tag_placeholders)

	if include_types.size() > 0:
		var type_placeholders := PackedStringArray()
		for t in include_types:
			type_placeholders.append("?")
			bindings.append(str(t))
		sql += " AND items.type IN (%s)" % ",".join(type_placeholders)

	sql += ";"
	var rows := _exec_select(sql, bindings)

	if detail == "lean":
		return _build_lean_rows(rows)

	var results: Array = []
	for row in rows:
		var item := _build_item_dict(row)
		if detail == "full_stripped":
			item = _strip_empty(item)
		results.append(item)
	return results


# -- Saved queries ------------------------------------------------------------

func save_query(name: String, query_dict: Dictionary) -> void:
	var json_str := JSON.stringify(query_dict)
	_exec("INSERT OR REPLACE INTO saved_queries (name, query_json) VALUES (?, ?);", [name, json_str])


func load_query(name: String) -> Dictionary:
	var rows := _exec_select("SELECT query_json FROM saved_queries WHERE name=?;", [name])
	if rows.is_empty():
		return {}
	var parsed = JSON.parse_string(str(rows[0].query_json))
	if parsed == null:
		return {}
	return parsed


func list_queries() -> Array:
	var rows := _exec_select("SELECT name, query_json FROM saved_queries;")
	var result: Array = []
	for row in rows:
		var parsed = JSON.parse_string(str(row.query_json))
		if parsed:
			result.append({"name": str(row.name), "query": parsed})
		else:
			result.append({"name": str(row.name), "query": {}})
	return result


# -- Attachments --------------------------------------------------------------

const MAX_ATTACHMENT_BYTES: int = 5 * 1024 * 1024  # 5 MB

func attach_file(item_id: String, filename: String, data: PackedByteArray, mime: String = "application/octet-stream", desc: String = "") -> Dictionary:
	var size_bytes: int = data.size()
	if size_bytes > MAX_ATTACHMENT_BYTES:
		push_error("DocketDB: attachment too large: %d bytes (max %d)" % [size_bytes, MAX_ATTACHMENT_BYTES])
		return {"error": "File too large: %d bytes (max 5 MB)" % size_bytes}
	var ts := Time.get_datetime_string_from_system(true)

	var insert_error := _exec_checked(
		"INSERT INTO attachments (item_id, filename, mime_type, size_bytes, data, created_at, description) VALUES (?, ?, ?, ?, ?, ?, ?);",
		[item_id, filename, mime, size_bytes, data, ts, desc])
	if not insert_error.is_empty(): return {"error": insert_error}

	# Get the inserted row id
	var rows := _exec_select("SELECT last_insert_rowid() as lid;")
	var att_id: int = int(rows[0].lid) if rows.size() > 0 else 0

	return {
		"id": att_id,
		"item_id": item_id,
		"filename": filename,
		"mime_type": mime,
		"size_bytes": size_bytes,
		"created_at": ts,
		"description": desc,
	}


func get_attachment(att_id: int) -> Dictionary:
	var rows := _exec_select("SELECT * FROM attachments WHERE id=?;", [att_id])
	if rows.is_empty():
		return {}
	var row: Dictionary = rows[0]
	return {
		"id": int(row.get("id", 0)),
		"item_id": str(row.get("item_id", "")),
		"filename": str(row.get("filename", "")),
		"mime_type": str(row.get("mime_type", "")),
		"size_bytes": int(row.get("size_bytes", 0)),
		"data": row.get("data", PackedByteArray()),
		"created_at": str(row.get("created_at", "")),
		"description": str(row.get("description", "")),
	}


func list_attachments(item_id: String) -> Array:
	var rows := _exec_select(
		"SELECT id, item_id, filename, mime_type, size_bytes, created_at, description FROM attachments WHERE item_id=?;",
		[item_id])
	var result: Array = []
	for row in rows:
		result.append({
			"id": int(row.get("id", 0)),
			"item_id": str(row.get("item_id", "")),
			"filename": str(row.get("filename", "")),
			"mime_type": str(row.get("mime_type", "")),
			"size_bytes": int(row.get("size_bytes", 0)),
			"created_at": str(row.get("created_at", "")),
			"description": str(row.get("description", "")),
		})
	return result


func detach_file(att_id: int) -> void:
	_exec("DELETE FROM attachments WHERE id=?;", [att_id])


# -- Comments -----------------------------------------------------------------

func add_comment(item_id: String, author: String, text: String, parent_id: int = 0) -> Dictionary:
	var ts := Time.get_datetime_string_from_system(true)
	var clean_text: String = _normalize_text(text)
	_exec("INSERT INTO comments (item_id, parent_id, author, text, status, created_at) VALUES (?, ?, ?, ?, 'open', ?);",
		[item_id, parent_id, author, clean_text, ts])
	var rows := _exec_select("SELECT last_insert_rowid() as lid;")
	var cid: int = int(rows[0].lid) if rows.size() > 0 else 0
	if parent_id > 0:
		add_event(item_id, "comment_reply", author, text.substr(0, 80))
	else:
		add_event(item_id, "comment_added", author, text.substr(0, 80))
	return {"id": cid, "item_id": item_id, "parent_id": parent_id, "author": author, "text": text, "status": "open", "created_at": ts}


func list_comments(item_id: String) -> Array:
	var rows := _exec_select("SELECT * FROM comments WHERE item_id=? ORDER BY id ASC;", [item_id])
	var result: Array = []
	for row in rows:
		result.append(_build_comment_dict(row))
	return result


func resolve_comment(comment_id: int, resolution: String, resolved_by: String) -> Dictionary:
	if resolution not in ["accepted", "rejected"]:
		return {"error": "Resolution must be 'accepted' or 'rejected'"}
	var ts := Time.get_datetime_string_from_system(true)
	_exec("UPDATE comments SET status=?, resolved_at=?, resolved_by=? WHERE id=?;",
		[resolution, ts, resolved_by, comment_id])
	var rows := _exec_select("SELECT * FROM comments WHERE id=?;", [comment_id])
	if rows.is_empty():
		return {"error": "Comment not found"}
	var row: Dictionary = rows[0]
	var item_id: String = str(row.get("item_id", ""))
	add_event(item_id, "comment_" + resolution, resolved_by, str(row.get("text", "")).substr(0, 80))
	return _build_comment_dict(row)


func get_comment(comment_id: int) -> Dictionary:
	var rows := _exec_select("SELECT * FROM comments WHERE id=?;", [comment_id])
	if rows.is_empty():
		return {}
	return _build_comment_dict(rows[0])


func _build_comment_dict(row: Dictionary) -> Dictionary:
	return {
		"id": int(row.get("id", 0)),
		"item_id": str(row.get("item_id", "")),
		"parent_id": int(row.get("parent_id", 0)),
		"author": str(row.get("author", "")),
		"text": str(row.get("text", "")),
		"status": str(row.get("status", "open")),
		"created_at": str(row.get("created_at", "")),
		"resolved_at": str(row.get("resolved_at", "")),
		"resolved_by": str(row.get("resolved_by", "")),
	}


# -- Vault / Secret storage ---------------------------------------------------

func has_vault() -> bool:
	## True if this docket has a vault salt (i.e. secrets have been initialized).
	var rows := _exec_select("SELECT value FROM docket_meta WHERE key='vault_salt';")
	return rows.size() > 0 and not str(rows[0].value).is_empty()


func init_vault(key: PackedByteArray, salt: PackedByteArray, iterations: int = VaultCrypto.PBKDF2_ITERATIONS) -> void:
	## Store vault salt, verification hash, and the KDF cost this vault uses.
	## Call once when creating the first secret.
	set_meta_value("vault_salt", Marshalls.raw_to_base64(salt))
	set_meta_value("vault_verify", Marshalls.raw_to_base64(VaultCrypto.compute_verify_hash(key)))
	set_meta_value("vault_kdf_iterations", str(iterations))


func get_vault_iterations() -> int:
	## PBKDF2 iteration count for this vault.
	##
	## Absent means the vault predates the parameter being recorded, so it must
	## keep deriving at the legacy cost — the stored ciphertext was produced with
	## that key and no other. New vaults record the current count explicitly, so
	## raising the default later cannot strand them.
	var stored := get_meta_value("vault_kdf_iterations", "")
	if stored.is_empty():
		return VaultCrypto.LEGACY_PBKDF2_ITERATIONS
	var n := int(stored)
	return n if n > 0 else VaultCrypto.LEGACY_PBKDF2_ITERATIONS


func get_vault_salt() -> PackedByteArray:
	var b64 := get_meta_value("vault_salt", "")
	if b64.is_empty():
		return PackedByteArray()
	return Marshalls.base64_to_raw(b64)


func verify_vault(key: PackedByteArray) -> bool:
	## Check if the given derived key matches the stored verification hash.
	var stored_b64 := get_meta_value("vault_verify", "")
	if stored_b64.is_empty():
		return false
	var stored := Marshalls.base64_to_raw(stored_b64)
	var computed := VaultCrypto.compute_verify_hash(key)
	return stored == computed


func set_secret(handle: String, ciphertext: PackedByteArray, iv: PackedByteArray, mac: PackedByteArray, requires_2fa: bool = false, owner_item_id: String = "") -> void:
	## Insert or update an encrypted secret.
	##
	## owner_item_id names the work item this secret belongs to, or "" for a
	## standalone entry (typically created by an agent over MCP). On update it is
	## only written when supplied, so callers that do not care about ownership
	## cannot accidentally orphan an item's payload.
	var now := Time.get_datetime_string_from_system(true)
	var flag := 1 if requires_2fa else 0
	var existing := _exec_select("SELECT handle FROM docket_secrets WHERE handle=?;", [handle])
	if existing.size() > 0:
		if owner_item_id.is_empty():
			_exec("UPDATE docket_secrets SET ciphertext=?, iv=?, mac=?, updated_at=?, requires_2fa=? WHERE handle=?;",
				[ciphertext, iv, mac, now, flag, handle])
		else:
			_exec("UPDATE docket_secrets SET ciphertext=?, iv=?, mac=?, updated_at=?, requires_2fa=?, owner_item_id=? WHERE handle=?;",
				[ciphertext, iv, mac, now, flag, owner_item_id, handle])
	else:
		_exec("INSERT INTO docket_secrets (handle, ciphertext, iv, mac, created_at, updated_at, requires_2fa, owner_item_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
			[handle, ciphertext, iv, mac, now, now, flag, owner_item_id])


func get_secret_owner(handle: String) -> String:
	## Item this secret belongs to, or "" if it is standalone.
	var rows := _exec_select("SELECT owner_item_id FROM docket_secrets WHERE handle=?;", [handle])
	return str(rows[0].get("owner_item_id", "")) if rows.size() > 0 else ""


func set_secret_owner(handle: String, owner_item_id: String) -> void:
	## Attach an existing vault entry to a work item without touching ciphertext.
	## This is what "promote to Secret item" does — no decrypt, no re-encrypt, so
	## it needs no vault password.
	_exec("UPDATE docket_secrets SET owner_item_id=? WHERE handle=?;", [owner_item_id, handle])


func rekey_secret(old_handle: String, new_handle: String) -> String:
	## Move a vault entry to a different handle. Returns "" on success.
	##
	## A pure rename: the handle is never part of the encryption (see
	## VaultCrypto), so no vault password, decryption or re-encryption is needed.
	## Version history moves with it, or rotating a promoted secret would strand
	## its archived values under the old key.
	##
	## This exists so a promoted secret ends up under the handle every consumer
	## already looks for — item payloads live under handle == item_id. Recording
	## ownership while leaving the ciphertext elsewhere makes the metadata and
	## the behaviour disagree, which is exactly how a promoted item became
	## unreadable in the GUI.
	if old_handle == new_handle:
		return ""
	if get_secret_raw(old_handle).is_empty():
		return "No secret found with handle '%s'" % old_handle
	if not get_secret_raw(new_handle).is_empty():
		return "A secret already exists under handle '%s'" % new_handle
	_exec("UPDATE docket_secrets SET handle=? WHERE handle=?;", [new_handle, old_handle])
	_exec("UPDATE docket_secret_versions SET handle=? WHERE handle=?;", [new_handle, old_handle])
	return ""


func get_secret_handle_for_item(item_id: String, suffix: String = "") -> String:
	## Handle holding this item's payload, or "" if it has none.
	##
	## Resolves by recorded ownership first, falling back to the historical
	## convention so files written before owner_item_id existed still work.
	var want := item_id + suffix
	var rows := _exec_select(
		"SELECT handle FROM docket_secrets WHERE owner_item_id=? AND handle=? LIMIT 1;",
		[item_id, want])
	if rows.size() > 0:
		return str(rows[0].get("handle", ""))
	return want if not get_secret_raw(want).is_empty() else ""


func list_secrets_owned_by(item_id: String) -> Array:
	## Every handle belonging to this item, however it is keyed. Used on delete
	## and move so an owned payload cannot be left orphaned.
	var out: Array = []
	for row in _exec_select(
		"SELECT handle FROM docket_secrets WHERE owner_item_id=? ORDER BY handle;", [item_id]):
		out.append(str(row.get("handle", "")))
	return out


func list_standalone_secrets() -> Array:
	## Vault entries with no owning work item. These have no row in `items`, so
	## they cannot appear in the query grid and are otherwise invisible in the GUI.
	var rows := _exec_select(
		"SELECT handle, created_at, updated_at, requires_2fa FROM docket_secrets "
		+ "WHERE owner_item_id IS NULL OR owner_item_id='' ORDER BY handle ASC;"
	)
	var out: Array = []
	for row in rows:
		out.append({
			"handle": str(row.get("handle", "")),
			"created_at": str(row.get("created_at", "")),
			"updated_at": str(row.get("updated_at", "")),
			"requires_2fa": int(row.get("requires_2fa", 0)) == 1,
		})
	return out


func get_secret_raw(handle: String) -> Dictionary:
	## Returns {ciphertext, iv, mac, requires_2fa} or empty dict if not found.
	var rows := _exec_select("SELECT ciphertext, iv, mac, requires_2fa FROM docket_secrets WHERE handle=?;", [handle])
	if rows.is_empty():
		return {}
	var row: Dictionary = rows[0]
	return {
		"ciphertext": row.ciphertext as PackedByteArray,
		"iv": row.iv as PackedByteArray,
		"mac": row.mac as PackedByteArray,
		"requires_2fa": int(row.get("requires_2fa", 0)) == 1,
	}


func list_secrets() -> Array:
	## Returns [{handle, created_at, updated_at, owner_item_id}] — no decryption.
	## owner_item_id is "" for standalone entries, which is what distinguishes an
	## agent-created secret from a Secret work item's payload.
	var rows := _exec_select(
		"SELECT handle, created_at, updated_at, owner_item_id FROM docket_secrets ORDER BY handle;")
	var result: Array = []
	for row in rows:
		result.append({
			"handle": str(row.handle),
			"created_at": str(row.created_at),
			"updated_at": str(row.updated_at),
			"owner_item_id": str(row.get("owner_item_id", "")),
		})
	return result


func delete_secret(handle: String) -> bool:
	var rows := _exec_select("SELECT handle FROM docket_secrets WHERE handle=?;", [handle])
	if rows.is_empty():
		return false
	_exec("DELETE FROM docket_secrets WHERE handle=?;", [handle])
	return true


func get_all_secrets_raw() -> Array:
	## Returns all secrets with raw encrypted data — for re-encryption on password change.
	var rows := _exec_select("SELECT handle, ciphertext, iv, mac, requires_2fa FROM docket_secrets;")
	var result: Array = []
	for row in rows:
		result.append({
			"handle": str(row.handle),
			"ciphertext": row.ciphertext as PackedByteArray,
			"iv": row.iv as PackedByteArray,
			"mac": row.mac as PackedByteArray,
			"requires_2fa": int(row.get("requires_2fa", 0)) == 1,
		})
	return result


func rotate_secret(handle: String, new_ct: PackedByteArray, new_iv: PackedByteArray, new_mac: PackedByteArray, rotated_by: String = "", requires_2fa: bool = false) -> void:
	## Archive current secret value into versions table, then store new value.
	var now := Time.get_datetime_string_from_system(true)
	# Get current value to archive
	var current := get_secret_raw(handle)
	if not current.is_empty():
		# Determine next version number
		var ver_rows := _exec_select("SELECT COALESCE(MAX(version), 0) AS max_ver FROM docket_secret_versions WHERE handle=?;", [handle])
		var next_ver: int = int(ver_rows[0].get("max_ver", 0)) + 1 if ver_rows.size() > 0 else 1
		# requires_2fa describes the value being archived, so it is read from the
		# row being replaced rather than from the incoming one.
		var was_2fa := 1 if bool(current.get("requires_2fa", false)) else 0
		_exec("INSERT INTO docket_secret_versions (handle, version, ciphertext, iv, mac, created_at, rotated_by, requires_2fa) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
			[handle, next_ver, current.ciphertext, current.iv, current.mac, now, rotated_by, was_2fa])
	# Store new value
	set_secret(handle, new_ct, new_iv, new_mac, requires_2fa)


func get_secret_versions(handle: String) -> Array:
	## Returns [{version, ciphertext, iv, mac, created_at, rotated_by}] ordered by version desc.
	var rows := _exec_select("SELECT version, ciphertext, iv, mac, created_at, rotated_by, requires_2fa FROM docket_secret_versions WHERE handle=? ORDER BY version DESC;", [handle])
	var result: Array = []
	for row in rows:
		result.append({
			"version": int(row.version),
			"ciphertext": row.ciphertext as PackedByteArray,
			"iv": row.iv as PackedByteArray,
			"mac": row.mac as PackedByteArray,
			"created_at": str(row.created_at),
			"rotated_by": str(row.get("rotated_by", "")),
			"requires_2fa": int(row.get("requires_2fa", 0)) == 1,
		})
	return result


func get_all_secret_versions_raw() -> Array:
	## Every archived value, including those of deleted secrets: [{handle,
	## version, ciphertext, iv, mac}].
	var rows := _exec_select("SELECT handle, version, ciphertext, iv, mac FROM docket_secret_versions;")
	var result: Array = []
	for row in rows:
		result.append({
			"handle": str(row.handle),
			"version": int(row.version),
			"ciphertext": row.ciphertext as PackedByteArray,
			"iv": row.iv as PackedByteArray,
			"mac": row.mac as PackedByteArray,
		})
	return result


## Re-encrypts this vault from `old_key` to `new_key`, current and archived
## values alike, in one transaction, keeping its salt and cost and each value's
## requires_2fa flag and owner. Only the outer layer is re-wrapped, which is
## right for 2FA values too. Returns "" or the error, and on an error nothing
## is changed — including when a value does not decrypt under `old_key`,
## which the new key must not be installed over.
func rewrap_vault(old_key: PackedByteArray, new_key: PackedByteArray) -> String:
	_last_sql_error = ""
	var error := _exec_checked("BEGIN TRANSACTION;")
	if not error.is_empty():
		return error
	error = _rewrap_vault_rows(old_key, new_key)
	if error.is_empty():
		error = _last_sql_error
	if error.is_empty():
		error = _exec_checked("COMMIT;")
	if not error.is_empty():
		_rollback()
	return error


## The rows are read here, inside the caller's transaction, so they are the
## ones being replaced.
func _rewrap_vault_rows(old_key: PackedByteArray, new_key: PackedByteArray) -> String:
	if not verify_vault(old_key):
		return "The vault password does not match."
	for secret: Dictionary in get_all_secrets_raw():
		var opened := VaultCrypto.decrypt_checked(secret.ciphertext, secret.iv, secret.mac, old_key)
		if opened.is_empty():
			return "Secret '%s' does not decrypt with the current password." % secret.handle
		var encrypted := VaultCrypto.encrypt(opened.value, new_key)
		_exec("UPDATE docket_secrets SET ciphertext=?, iv=?, mac=? WHERE handle=?;",
			[encrypted.ciphertext, encrypted.iv, encrypted.mac, secret.handle])
	for version: Dictionary in get_all_secret_versions_raw():
		var opened := VaultCrypto.decrypt_checked(version.ciphertext, version.iv, version.mac, old_key)
		if opened.is_empty():
			return "Version %d of secret '%s' does not decrypt with the current password." % [version.version, version.handle]
		var encrypted := VaultCrypto.encrypt(opened.value, new_key)
		_exec("UPDATE docket_secret_versions SET ciphertext=?, iv=?, mac=? WHERE handle=? AND version=?;",
			[encrypted.ciphertext, encrypted.iv, encrypted.mac, version.handle, version.version])
	if _last_sql_error.is_empty():
		init_vault(new_key, get_vault_salt(), get_vault_iterations())
	return _last_sql_error


static func _has_column(col_rows: Array, col_name: String) -> bool:
	for cr in col_rows:
		if str(cr.get("name", "")) == col_name:
			return true
	return false


# -- Internal SQL helpers -----------------------------------------------------

func _on_owner_thread() -> bool:
	if _owner_thread == 0 or OS.get_thread_caller_id() == _owner_thread:
		return true
	var message := "%s is used only from the thread that opened it" % _path
	if _last_sql_error.is_empty(): _last_sql_error = message
	push_error("DocketDB: %s" % message)
	return false


func _exec(sql: String, bindings: Array = []) -> void:
	if not _on_owner_thread(): return
	var ok: bool
	if bindings.is_empty():
		ok = _db.query(sql)
	else:
		ok = _db.query_with_bindings(sql, bindings)
	if not ok and _last_sql_error.is_empty():
		_last_sql_error = _db.error_message if _db.error_message else "SQL execution failed"
	_track_transaction(sql, ok)


func _exec_checked(sql: String, bindings: Array = []) -> String:
	## Like _exec but returns "" on success, error message on failure.
	if not _on_owner_thread(): return _last_sql_error
	var ok: bool
	if bindings.is_empty():
		ok = _db.query(sql)
	else:
		ok = _db.query_with_bindings(sql, bindings)
	_track_transaction(sql, ok)
	if not ok:
		var msg: String = _db.error_message if _db.error_message else "SQL execution failed"
		if _last_sql_error.is_empty(): _last_sql_error = msg
		push_error("DocketDB: %s — %s" % [msg, sql.left(120)])
		return msg
	return ""


## Record that item `id` changed (`event`): reported now, or when the open
## transaction commits (items_changed).
func _record_change(id: String, event: String) -> void:
	_pending_changes.append({"id": id, "event": event})
	if not _transaction_open:
		_report_changes()


## Emit and forget the recorded changes (DocketDBJsonl reports them only once
## its file is saved).
func _report_changes() -> void:
	if _pending_changes.is_empty():
		return
	var changes := _pending_changes
	_pending_changes = []
	items_changed.emit(changes)


func _track_transaction(sql: String, ok: bool) -> void:
	if sql.begins_with("BEGIN"):
		# A failed BEGIN inside a transaction left open does not close it.
		_transaction_open = _transaction_open or ok
	elif sql.begins_with("COMMIT"):
		if ok:
			_transaction_open = false
			_report_changes()
		else:
			_pending_changes = []  # those changes were not made durable
	elif sql.begins_with("ROLLBACK"):
		_transaction_open = false
		_pending_changes = []


func _exec_select(sql: String, bindings: Array = []) -> Array:
	if not _on_owner_thread(): return []
	var ok: bool
	if bindings.is_empty():
		ok = _db.query(sql)
	else:
		ok = _db.query_with_bindings(sql, bindings)
	if not ok:
		var msg: String = _db.error_message if _db.error_message else "SQL query failed"
		if _last_sql_error.is_empty(): _last_sql_error = msg
		push_error("DocketDB: %s — %s" % [msg, sql.left(120)])
		return []
	return _db.query_result if _db.query_result else []


func _begin() -> void:
	_exec("BEGIN TRANSACTION;")


func _commit() -> void:
	_exec("COMMIT;")


func _rollback() -> void:
	_exec("ROLLBACK;")


static func _strip_empty(item: Dictionary) -> Dictionary:
	## Remove empty-string, zero, null, and empty-array values from an item dict.
	## Always keeps: id, type, status, title, created_at, updated_at.
	const KEEP_KEYS := ["id", "type", "status", "title", "created_at", "updated_at"]
	var result := {}
	for key in item:
		var val = item[key]
		if key in KEEP_KEYS:
			result[key] = val
			continue
		if val == null:
			continue
		if val is String and val.is_empty():
			continue
		if val is int and val == 0:
			continue
		if val is Array and val.is_empty():
			continue
		result[key] = val
	return result


static func _build_lean_rows(rows: Array) -> Array:
	## Return [{id, title}, ...] from raw SQL rows. Zero extra queries.
	var result: Array = []
	for row in rows:
		result.append({
			"id": str(row.get("id", "")),
			"title": str(row.get("title", "")),
		})
	return result


static func _build_lean_hint_rows(rows: Array) -> Array:
	## Return [{id, title, component, key, value}, ...] for hints. Zero extra queries.
	var result: Array = []
	for row in rows:
		result.append({
			"id": str(row.get("id", "")),
			"title": str(row.get("title", "")),
			"component": str(row.get("component", "")),
			"key": str(row.get("key", "")),
			"value": str(row.get("value", "")),
		})
	return result


func _build_item_dict(row: Dictionary) -> Dictionary:
	## Convert a raw SQLite row into the same Dictionary format as old JSON items.
	var item := {}
	var id: String = str(row.get("id", ""))

	# Copy all scalar fields
	item["id"] = id
	item["type"] = str(row.get("type", ""))
	item["status"] = str(row.get("status", ""))
	item["title"] = str(row.get("title", ""))
	item["type_id"] = str(row.get("type_id", ""))
	item["type_revision"] = str(row.get("type_revision", ""))
	for envelope in ["fields", "extras"]:
		var raw := str(row.get("%s_json" % envelope, "{}"))
		var decoded = JSON.parse_string(raw)
		if decoded is Dictionary:
			item[envelope] = decoded
		else:
			item[envelope] = {}
			item["_storage_error"] = "malformed %s_json for item %s" % [envelope, id]
	item["description"] = str(row.get("description", ""))
	item["created_at"] = str(row.get("created_at", ""))
	item["updated_at"] = str(row.get("updated_at", ""))
	item["created_by"] = str(row.get("created_by", ""))
	item["assigned_to"] = str(row.get("assigned_to", ""))
	item["directed_to"] = str(row.get("directed_to", ""))
	item["priority"] = int(row.get("priority", 0))
	item["severity"] = int(row.get("severity", 0))
	item["retrieval_count"] = int(row.get("retrieval_count", 0))
	item["research_cost"] = int(row.get("research_cost", 0))
	item["quality"] = int(row.get("quality", 0))

	# Nullable type-specific text fields
	for col in ["resolution", "environment", "repro_steps", "assumed", "corrected",
				 "findings", "answer", "occurred_at", "detected_at", "reported_at",
				 "why_chain", "significant_events", "contributing_factors",
				 "value", "component", "key", "topic", "subtopic", "confidence",
				 "surprise", "surfaced_from", "blocked_by", "parent",
				 "test_setup", "test_steps", "expected_result", "last_reviewed",
				 "command", "usage", "prompt_text", "preconditions",
				 "summary", "article", "parameters",
				 "steps", "outcome", "target",
				 "source", "pristine_hash"]:
		var val = row.get(col)
		if val != null:
			item[col] = str(val)
		else:
			item[col] = ""

	# Plugin-shipped skills boolean fields (Minerva DCR 019df57b).  Stored as
	# INTEGER 0/1 in SQLite; expose as bool to consumers.
	item["customised"] = int(row.get("customised", 0)) != 0
	item["deprecated"] = int(row.get("deprecated", 0)) != 0

	var tool_deps_raw = row.get("tool_deps")
	if tool_deps_raw != null and not str(tool_deps_raw).is_empty():
		var parsed_tool_deps = JSON.parse_string(str(tool_deps_raw))
		item["tool_deps"] = parsed_tool_deps if parsed_tool_deps is Array else []
	else:
		item["tool_deps"] = []

	var optimization_raw = row.get("optimization")
	if optimization_raw != null and not str(optimization_raw).is_empty():
		var parsed_optimization = JSON.parse_string(str(optimization_raw))
		item["optimization"] = parsed_optimization if parsed_optimization is Dictionary else {}
	else:
		item["optimization"] = {}

	# pristine_content: JSON-encoded dict (Minerva DCR 019df57b).  Stores the
	# upstream plugin manifest's skill entry verbatim for later diff prompts.
	var pristine_raw = row.get("pristine_content")
	if pristine_raw != null and not str(pristine_raw).is_empty():
		var parsed_pristine = JSON.parse_string(str(pristine_raw))
		item["pristine_content"] = parsed_pristine if parsed_pristine is Dictionary else {}
	else:
		item["pristine_content"] = {}

	# unsatisfied_deps: JSON-encoded list[str] (Minerva DCR 019df57b).  tool_deps
	# not currently resolvable in the active registry.
	var unsat_raw = row.get("unsatisfied_deps")
	if unsat_raw != null and not str(unsat_raw).is_empty():
		var parsed_unsat = JSON.parse_string(str(unsat_raw))
		item["unsatisfied_deps"] = parsed_unsat if parsed_unsat is Array else []
	else:
		item["unsatisfied_deps"] = []

	# Fetch tags
	var tag_rows := _exec_select("SELECT tag FROM item_tags WHERE item_id=?;", [id])
	var tags: Array = []
	for tag_row in tag_rows:
		tags.append(str(tag_row.tag))
	item["tags"] = tags

	# Fetch events
	item["events"] = get_events(id)

	# Fetch links
	item["links"] = get_links(id)

	return item
