extends DocketDBVault
class_name DocketDB
## SQLite-backed storage replacing FileManager + QueryEngine + IdGenerator.
## Returns Dictionaries in the same format as the old in-memory dicts. The
## connection, its coordinated writes, transactions and project metadata are
## DocketDBConnection's; the vault's storage is DocketDBVault's.

const DocketFields := preload("res://scripts/core/docket_fields.gd")

func item_columns() -> Array:
	var result: Array = []
	for value in _ITEM_COLS: result.append(str(value))
	return result


# -- Lifecycle ----------------------------------------------------------------
#
# Opening, creating, checkpointing and closing write to the database (WAL
# mode, schema migration, project defaults, checkpoints), so each runs within
# a step of the coordination operation `op` it is given, or an operation of
# its own when `op` is null, from before the connection opens. Without one it
# is refused: open and create fail, close keeps the connection open.

func open(path: String, op: RefCounted = null) -> bool:
	if _db != null and not _on_owner_thread(): return false
	if _change_in_progress():
		var refusal := "%s cannot be reopened while a change is in progress" % _path
		if _last_sql_error.is_empty(): _last_sql_error = refusal
		push_error("DocketDB: %s" % refusal)
		return false
	var opened: Variant = _writing(op, _open.bind(path))
	return opened is bool and opened


func _open(step: RefCounted, path: String) -> bool:
	if not _connect(path, "open"): return false
	var error := _configure(step)
	if error.is_empty():
		_is_open = true
		DocketDBSchema.migrate_schema(self, step)
		_default_naming(step, path, true)
		error = _last_sql_error
	return _settle_open(error, "open")


# A new connection to `path`, owned by this thread: false (reported) when it
# cannot be opened.
func _connect(path: String, verb: String) -> bool:
	if _db != null and _is_open: _db.close_db()
	_is_open = false
	_path = path
	_last_sql_error = ""
	_db = SQLite.new()
	if not _db.has_method(READ_ONLY_QUERY):
		_last_sql_error = "the SQLite extension has no %s (it is not built from Docket's patched source; see scripts/build/build_gdextension.sh)" % READ_ONLY_QUERY
		push_error("DocketDB: cannot %s %s: %s" % [verb, path, _last_sql_error])
		_db = null
		return false
	_db.path = path
	_db.verbosity_level = SQLite.QUIET
	_owner_thread = OS.get_thread_caller_id()
	if _db.open_db(): return true
	push_error("DocketDB: failed to %s %s" % [verb, path])
	_db = null
	_owner_thread = 0
	return false


# WAL, foreign keys and the busy timeout for the new connection: "" or why not.
func _configure(step: RefCounted) -> String:
	for pragma: String in ["PRAGMA journal_mode=WAL;", "PRAGMA foreign_keys=ON;", "PRAGMA busy_timeout=15000;"]:
		var error := _write_checked(step, pragma)
		if not error.is_empty(): return error
	return ""


# Keeps the new connection when opening or creating it succeeded (`error`
# empty); otherwise closes it, leaving nothing half open. Whether it succeeded.
func _settle_open(error: String, verb: String) -> bool:
	if error.is_empty(): return true
	push_error("DocketDB: could not %s %s: %s" % [verb, _path, error])
	_db.close_db()
	_db = null
	_is_open = false
	_owner_thread = 0
	return false


# Project name and ID prefix from the file name, where still the defaults.
func _default_naming(step: RefCounted, path: String, keep_docket_prefix: bool) -> void:
	var basename := path.get_file().get_basename()
	if basename.is_empty():
		return
	if get_project_name().is_empty():
		_write(step, "INSERT OR REPLACE INTO docket_meta (key, value) VALUES ('project', ?);", [basename])
	if get_id_prefix() == "DKT" and not (keep_docket_prefix and basename == "docket"):
		_write(step, "INSERT OR REPLACE INTO docket_meta (key, value) VALUES ('id_prefix', ?);", [_derive_prefix(basename)])


## Checkpoints the WAL into the database file and closes the connection:
## "" or why not; closing a closed connection does nothing. Refused, leaving
## the connection open, while a change is in progress or without a
## coordination operation; a checkpoint that could not finish is reported,
## and the connection is closed all the same.
func close_checked(op: RefCounted = null) -> String:
	var refusal := _thread_refusal()
	if not refusal.is_empty(): return refusal
	if _db == null or not _is_open:
		return ""
	if _change_in_progress(): return "%s cannot close while a change is in progress" % _path
	return _writing_text(op, func(step: RefCounted) -> String:
		var error := _checkpoint(step, "TRUNCATE")
		_db.close_db()
		_is_open = false
		return error)


func close() -> void:
	var error := close_checked()
	if not error.is_empty():
		push_error("DocketDB: %s" % error)


## Flushes the WAL to the database file so other processes see every change:
## "" or why not.
func checkpoint_checked(op: RefCounted = null) -> String:
	if _db == null or not _is_open: return ""
	var refusal := _thread_refusal()
	if not refusal.is_empty(): return refusal
	return _writing_text(op, func(step: RefCounted) -> String: return _checkpoint(step, "PASSIVE"))


func checkpoint() -> void:
	var error := checkpoint_checked()
	if not error.is_empty():
		push_error("DocketDB: %s" % error)


# PRAGMA wal_checkpoint answers one row (busy, log, checkpointed); busy
# means it could not finish.
func _checkpoint(step: RefCounted, mode: String) -> String:
	var rows := _write_rows(step, "PRAGMA wal_checkpoint(%s);" % mode)
	if rows.size() != 1:
		return "checkpointing %s failed: %s" % [_path, _last_sql_error]
	if int(rows[0].get("busy", 0)) != 0:
		return "checkpointing %s did not finish: the database was busy" % _path
	return ""


func is_open() -> bool:
	return _is_open


static func create_new(path: String, op: RefCounted = null) -> DocketDB:
	var lease := CoordLease.shared(op)
	if lease.has("error"):
		push_error("DocketDB: %s" % lease.error)
		return null
	var db := DocketDB.new()
	var created := db._create(lease.operation, path)
	lease.operation.close()
	return db if created else null


func _create(step: RefCounted, path: String) -> bool:
	if not _connect(path, "create"): return false
	var error := _configure(step)
	if error.is_empty():
		DocketDBSchema.init_schema(self, step)
		_is_open = true
		_default_naming(step, path, false)
		error = _last_sql_error
	return _settle_open(error, "create")


func get_path() -> String:
	return _path


# -- ID generation ------------------------------------------------------------

func next_id() -> String:
	var result := next_id_checked()
	if not str(result.error).is_empty(): push_error("DocketDB: %s" % result.error)
	return str(result.id)


## The next sequential item id (PREFIX-0001), counted, within a step of `op`
## (or an operation of its own): {id, error}, `id` "" on failure. The counter
## is read and advanced in one transaction, begun IMMEDIATE, so two writers
## cannot take the same number.
func next_id_checked(op: RefCounted = null) -> Dictionary:
	var result := _refused(_writing(op, _next_id))
	if not result.has("id"): result["id"] = ""
	return result


func _next_id(step: RefCounted) -> Dictionary:
	var txn := _begin_transaction(step)
	if txn.has("error"): return {"id": "", "error": txn.error}
	var counter := get_counter() + 1
	_write(step, "UPDATE docket_meta SET value=? WHERE key='counter';", [str(counter)])
	var prefix := get_id_prefix()
	var error := _complete_transaction(step, txn.ticket)
	if not error.is_empty(): return {"id": "", "error": error}
	return {"id": ("%s-%04d" if counter <= 9999 else "%s-%d") % [prefix, counter], "error": ""}


func get_id_prefix() -> String:
	return get_meta_value("id_prefix", "DKT")


func set_id_prefix(prefix: String) -> void:
	set_meta_value("id_prefix", prefix)


func set_id_prefix_checked(prefix: String, op: RefCounted = null) -> String:
	return set_meta_value_checked("id_prefix", prefix, op)


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
	var error := set_counter_checked(val)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


func set_counter_checked(val: int, op: RefCounted = null) -> String:
	return _writing_text(op, _set_counter.bind(val))


func _set_counter(step: RefCounted, val: int) -> String:
	return _write_checked(step, "UPDATE docket_meta SET value=? WHERE key='counter';", [str(val)])


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


## Inserts item `id` with its tags, events and links, as one change within a
## step of `op` (or an operation of its own): "" or why not.
func insert_item(id: String, item: Dictionary, op: RefCounted = null) -> String:
	return run_change(op, _insert_item.bind(id, item))


# The rows, within `step`: inside a transaction any failed write fails it
# (_write); outside one (a cache rebuild) it is kept in _last_sql_error.
func _insert_item(step: RefCounted, id: String, item: Dictionary) -> String:
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
	var err := _write_checked(step, sql, bindings)
	if not err.is_empty():
		return err

	# Tags — ensure it's an Array
	var tags_raw = item.get("tags", [])
	var tags: Array = tags_raw if tags_raw is Array else []
	for tag in tags:
		_write(step, "INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?);", [id, str(tag)])

	# Events
	var events: Array = item.get("events", [])
	for ev in events:
		_write(step, "INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
			[id, str(ev.get("event_type", "")), str(ev.get("actor", "")),
			 str(ev.get("timestamp", "")), str(ev.get("note", ""))])

	# Links
	var links: Array = item.get("links", [])
	for link in links:
		var to_id: String = str(link.get("to", ""))
		var relation: String = str(link.get("relation", ""))
		if not to_id.is_empty() and not relation.is_empty():
			_write(step, "INSERT INTO item_links (from_id, to_id, relation) VALUES (?, ?, ?);",
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
	var error := update_item_fields_checked(id, changes)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## Applies `changes` to item `id` (columns, `fields`/`extras` merged into the
## stored envelopes, `unset_fields`/`unset_extras` removed from them, `tags`
## replaced), as one change within a step of `op` (or an operation of its
## own): "" or why not.
func update_item_fields_checked(id: String, changes: Dictionary, op: RefCounted = null) -> String:
	if changes.is_empty():
		return ""
	return run_change(op, _update_item_fields.bind(id, changes))


func _update_item_fields(step: RefCounted, id: String, changes: Dictionary) -> String:
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
		var error := _write_checked(step, "UPDATE items SET %s WHERE id=?;" % ",".join(sets), bindings)
		if not error.is_empty(): return error

	# Handle tags replacement
	if changes.has("tags"):
		var error := _write_checked(step, "DELETE FROM item_tags WHERE item_id=?;", [id])
		if not error.is_empty(): return error
		var tags: Array = changes["tags"]
		for tag in tags:
			error = _write_checked(step, "INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?);", [id, str(tag)])
			if not error.is_empty(): return error
	return ""


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
	var error := import_item_full_checked(new_id, exported)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## Imports a full item export (export_item_full) under `new_id`, adding a
## "moved" event, all or nothing, within a step of `op` (or an operation of
## its own): "" or why not.
func import_item_full_checked(new_id: String, exported: Dictionary, op: RefCounted = null) -> String:
	return _writing_text(op, _import_item_full.bind(new_id, exported))


func _import_item_full(step: RefCounted, new_id: String, exported: Dictionary) -> String:
	var txn := _begin_transaction(step)
	if txn.has("error"): return txn.error
	return _complete_transaction(step, txn.ticket, _import_item_rows(step, new_id, exported))


# A failed write fails the transaction (see _write); a malformed comment
# thread is returned as the failure.
func _import_item_rows(step: RefCounted, new_id: String, exported: Dictionary) -> String:
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
	if _write_checked(step, sql, bindings).is_empty():
		_record_change(step, new_id, "created")

	# Tags
	var tags: Array = exported.get("tags", [])
	for tag in tags:
		_write(step, "INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?);", [new_id, str(tag)])

	# Events (preserve existing + add moved event)
	var events: Array = exported.get("events", [])
	for ev in events:
		_write(step, "INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
			[new_id, str(ev.get("event_type", "")), str(ev.get("actor", "")),
			 str(ev.get("timestamp", "")), str(ev.get("note", ""))])
	# Add "moved" event
	var ts := Time.get_datetime_string_from_system(true)
	_write(step, "INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
		[new_id, "moved", "", ts, "Moved to this project as %s" % new_id])

	# Links
	var links: Array = exported.get("links", [])
	for link in links:
		var to_id: String = str(link.get("to", ""))
		var relation: String = str(link.get("relation", ""))
		if not to_id.is_empty() and not relation.is_empty():
			_write(step, "INSERT INTO item_links (from_id, to_id, relation) VALUES (?, ?, ?);",
				[new_id, to_id, relation])

	# Comments, parents before replies (new ids are mapped as they are made)
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
			var comment_error := _write_checked(step, "INSERT INTO comments (item_id, parent_id, author, text, status, created_at, resolved_at, resolved_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?);", [new_id,mapped_parent,str(c.get("author", "")),str(c.get("text", "")),str(c.get("status", "open")),str(c.get("created_at", "")),str(c.get("resolved_at", "")),str(c.get("resolved_by", ""))])
			if not comment_error.is_empty(): return comment_error
			var inserted: Array = _exec_select("SELECT last_insert_rowid() AS id;")
			if old_id > 0 and not inserted.is_empty(): comment_ids[old_id] = int(inserted[0].id)
			pending_comments.remove_at(index); progressed = true
		if not progressed:
			return "comment thread contains an unresolved parent"

	# Attachments
	var attachments: Array = exported.get("attachments", [])
	for att in attachments:
		var att_data = att.get("data", PackedByteArray())
		var size_bytes: int = att_data.size() if att_data is PackedByteArray else 0
		_write(step,
			"INSERT INTO attachments (item_id, filename, mime_type, size_bytes, data, created_at, description) VALUES (?, ?, ?, ?, ?, ?, ?);",
			[new_id, str(att.get("filename", "")), str(att.get("mime_type", "")),
			 size_bytes, att_data, str(att.get("created_at", "")),
			 str(att.get("description", ""))])

	# Update timestamp
	_write(step, "UPDATE items SET updated_at=? WHERE id=?;", [ts, new_id])
	return ""


func delete_item(id: String) -> void:
	var error := delete_item_checked(id)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## Deletes item `id` with everything attached to it (tags, events, links,
## comments, attachments, and the vault entries it owns), in one transaction
## within a step of `op` (or an operation of its own): "" or why not, and then
## nothing is deleted.
func delete_item_checked(id: String, op: RefCounted = null) -> String:
	return _writing_text(op, _delete_item.bind(id))


func _delete_item(step: RefCounted, id: String) -> String:
	var txn := _begin_transaction(step)
	if txn.has("error"): return txn.error
	return _complete_transaction(step, txn.ticket, _delete_item_rows(step, id))


# Foreign keys with ON DELETE CASCADE would remove most of these; they are
# deleted explicitly all the same. A failed write fails the transaction.
func _delete_item_rows(step: RefCounted, id: String) -> String:
	_write(step, "DELETE FROM item_tags WHERE item_id=?;", [id])
	_write(step, "DELETE FROM item_events WHERE item_id=?;", [id])
	_write(step, "DELETE FROM item_links WHERE from_id=? OR to_id=?;", [id, id])
	_write(step, "DELETE FROM comments WHERE item_id=?;", [id])
	_write(step, "DELETE FROM attachments WHERE item_id=?;", [id])
	# Vault entries go by recorded ownership as well as by convention: an entry
	# attached under some other handle would otherwise be left orphaned, with
	# no item to reach it through and no listing that shows it.
	var handles := list_secrets_owned_by(id)
	handles.append_array([id, id + ":notes"])
	for handle: String in handles:
		var removed := delete_secret_checked(handle, step)
		if not str(removed.error).is_empty(): return removed.error
		_write(step, "DELETE FROM docket_secret_versions WHERE handle=?;", [handle])
	if _write_checked(step, "DELETE FROM items WHERE id=?;", [id]).is_empty():
		_record_change(step, id, "deleted")
	return ""


func rewrite_refs(old_qualified: String, new_qualified: String, old_bare_id: String, new_qualified_for_bare: String, rewrite_bare: bool = true) -> int:
	var result := rewrite_refs_checked(old_qualified, new_qualified, old_bare_id, new_qualified_for_bare, rewrite_bare)
	if not str(result.error).is_empty(): push_error("DocketDB: %s" % result.error)
	return int(result.count)


## Rewrites parent, blocked_by and link references from the old id to the new
## one (the bare id too, when `rewrite_bare`), as one change within a step of
## `op` (or an operation of its own): {count, error}, `count` the rows
## rewritten (0 on failure). Each item whose references changed is reported
## ("references_updated").
func rewrite_refs_checked(old_qualified: String, new_qualified: String, old_bare_id: String, new_qualified_for_bare: String, rewrite_bare: bool = true, op: RefCounted = null) -> Dictionary:
	var result := _change(op, _rewrite_refs.bind(old_qualified, new_qualified, old_bare_id, new_qualified_for_bare, rewrite_bare))
	var error := str(result.error)
	return {"count": int(result.get("count", 0)) if error.is_empty() else 0, "error": error}


func _rewrite_refs(step: RefCounted, old_qualified: String, new_qualified: String, old_bare_id: String, new_qualified_for_bare: String, rewrite_bare: bool) -> Dictionary:
	var referencing: Array[String] = []
	for ref in [old_qualified, old_bare_id] if rewrite_bare else [old_qualified]:
		for row in _exec_select("SELECT id FROM items WHERE parent=? OR blocked_by=? UNION SELECT from_id FROM item_links WHERE to_id=?;", [ref, ref, ref]):
			if not str(row.id) in referencing:
				referencing.append(str(row.id))
	var count := 0
	for sql in ["UPDATE items SET parent=? WHERE parent=?;", "UPDATE items SET blocked_by=? WHERE blocked_by=?;", "UPDATE item_links SET to_id=? WHERE to_id=?;"]:
		for pair in [[new_qualified, old_qualified], [new_qualified_for_bare, old_bare_id]] if rewrite_bare else [[new_qualified, old_qualified]]:
			var error := _write_checked(step, sql, pair)
			if not error.is_empty(): return {"error": error}
			count += _get_changes_count()
	for id in referencing:
		_record_change(step, id, "references_updated")
	return {"count": count, "error": ""}


func _get_changes_count() -> int:
	## Get the number of rows modified by the last UPDATE/INSERT/DELETE.
	var rows := _exec_select("SELECT changes() as cnt;")
	return int(rows[0].cnt) if rows.size() > 0 else 0


# -- Events -------------------------------------------------------------------

func add_event(item_id: String, event_type: String, actor: String, note: String = "") -> void:
	var error := add_event_checked(item_id, event_type, actor, note)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## Records event `event_type` on item `item_id` and touches its updated_at,
## as one change within a step of `op` (or an operation of its own): "" or
## why not.
func add_event_checked(item_id: String, event_type: String, actor: String, note: String = "", op: RefCounted = null) -> String:
	return run_change(op, _add_event.bind(item_id, event_type, actor, note))


func _add_event(step: RefCounted, item_id: String, event_type: String, actor: String, note: String) -> String:
	var ts := Time.get_datetime_string_from_system(true)
	var error := _write_checked(step, "INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
		[item_id, event_type, actor, ts, note])
	if error.is_empty():
		error = _write_checked(step, "UPDATE items SET updated_at=? WHERE id=?;", [ts, item_id])
	if error.is_empty():
		_record_change(step, item_id, event_type)
	return error


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
	_log("INSERT INTO transition_log (timestamp, item_type, from_state, attempted_to, succeeded, valid_transitions) VALUES (?, ?, ?, ?, ?, ?);",
		[ts, item_type, from_state, attempted_to, 1 if succeeded else 0, ",".join(valid_transitions)])


# A diagnostic log row, within an operation of its own; a failure is only
# reported (push_error), as the logs are not project data.
func _log(sql: String, bindings: Array) -> void:
	var error := _writing_text(null, func(step: RefCounted) -> String: return _write_checked(step, sql, bindings))
	if not error.is_empty(): push_error("DocketDB: %s" % error)


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
	_log("INSERT INTO mcp_error_log (timestamp, tool_name, error_message, arg_keys) VALUES (?, ?, ?, ?);",
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
	var error := add_link_checked(from_id, to_id, relation)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## Links `from_id` to `to_id` as `relation`, within a step of `op` (or an
## operation of its own): "" or why not.
func add_link_checked(from_id: String, to_id: String, relation: String, op: RefCounted = null) -> String:
	return run_change(op, func(step: RefCounted) -> String:
		return _write_checked(step, "INSERT INTO item_links (from_id, to_id, relation) VALUES (?, ?, ?);", [from_id, to_id, relation]))


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
	var error := bump_retrieval_checked(id)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## bump_retrieval within a step of `op` (or an operation of its own): "" or
## why not.
func bump_retrieval_checked(id: String, op: RefCounted = null) -> String:
	return _writing_text(op, _bump_retrieval.bind(id))


func _bump_retrieval(step: RefCounted, id: String) -> String:
	return _write_checked(step, "UPDATE items SET retrieval_count=retrieval_count+1 WHERE id=?;", [id])


func bump_retrieval_many(ids: Array) -> void:
	## Batch form of bump_retrieval. Exists so a backend that persists on every
	## mutation can persist ONCE for the whole batch — see
	## DocketDBJsonl.bump_retrieval_many_checked. Callers that bump more than
	## one item (any query returning a result set) must use this, not a loop
	## over bump_retrieval.
	var error := bump_retrieval_many_checked(ids)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## bump_retrieval for each of `ids` (empty ones skipped), all or none, within
## a step of `op` (or an operation of its own): "" or why not.
func bump_retrieval_many_checked(ids: Array, op: RefCounted = null) -> String:
	if ids.is_empty(): return ""
	return _writing_text(op, _bump_retrieval_many.bind(ids))


func _bump_retrieval_many(step: RefCounted, ids: Array) -> String:
	var txn := _begin_transaction(step)
	if txn.has("error"): return txn.error
	var error := ""
	for id in ids:
		var s := str(id)
		if not s.is_empty() and error.is_empty():
			error = bump_retrieval_checked(s, step)
	return _complete_transaction(step, txn.ticket, error)


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
	var error := save_query_checked(name, query_dict)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## Saves `query_dict` as query `name`, replacing one of that name, within a
## step of `op` (or an operation of its own): "" or why not.
func save_query_checked(name: String, query_dict: Dictionary, op: RefCounted = null) -> String:
	return _writing_text(op, _save_query.bind(name, query_dict))


func _save_query(step: RefCounted, name: String, query_dict: Dictionary) -> String:
	return _write_checked(step, "INSERT OR REPLACE INTO saved_queries (name, query_json) VALUES (?, ?);", [name, JSON.stringify(query_dict)])


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

## Attaches `data` to item `item_id`, within a step of `op` (or an operation
## of its own): the attachment's record, or {error}.
func attach_file(item_id: String, filename: String, data: PackedByteArray, mime: String = "application/octet-stream", desc: String = "", op: RefCounted = null) -> Dictionary:
	var size_bytes: int = data.size()
	if size_bytes > MAX_ATTACHMENT_BYTES:
		push_error("DocketDB: attachment too large: %d bytes (max %d)" % [size_bytes, MAX_ATTACHMENT_BYTES])
		return {"error": "File too large: %d bytes (max 5 MB)" % size_bytes}
	return _refused(_writing(op, _attach_file.bind(item_id, filename, data, mime, desc)))


# The row and the id SQLite gives it are read in one transaction.
func _attach_file(step: RefCounted, item_id: String, filename: String, data: PackedByteArray, mime: String, desc: String) -> Dictionary:
	var txn := _begin_transaction(step)
	if txn.has("error"): return {"error": txn.error}
	var ts := Time.get_datetime_string_from_system(true)
	var size_bytes: int = data.size()
	var error := _write_checked(step,
		"INSERT INTO attachments (item_id, filename, mime_type, size_bytes, data, created_at, description) VALUES (?, ?, ?, ?, ?, ?, ?);",
		[item_id, filename, mime, size_bytes, data, ts, desc])
	var rows := _exec_select("SELECT last_insert_rowid() as lid;") if error.is_empty() else []
	var att_id: int = int(rows[0].lid) if rows.size() > 0 else 0
	error = _complete_transaction(step, txn.ticket, error)
	if not error.is_empty(): return {"error": error}

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
	var error := detach_file_checked(att_id)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## Removes attachment `att_id` within a step of `op` (or an operation of its
## own): "" or why not.
func detach_file_checked(att_id: int, op: RefCounted = null) -> String:
	return _writing_text(op, _detach_file.bind(att_id))


func _detach_file(step: RefCounted, att_id: int) -> String:
	return _write_checked(step, "DELETE FROM attachments WHERE id=?;", [att_id])


# -- Comments -----------------------------------------------------------------

## Adds a comment (a reply when `parent_id` is set) and its event, as one
## change within a step of `op` (or an operation of its own): the comment's
## record, or {error}.
func add_comment(item_id: String, author: String, text: String, parent_id: int = 0, op: RefCounted = null) -> Dictionary:
	return _without_error(_change(op, _add_comment.bind(item_id, author, text, parent_id)))


func _add_comment(step: RefCounted, item_id: String, author: String, text: String, parent_id: int) -> Dictionary:
	var ts := Time.get_datetime_string_from_system(true)
	var clean_text: String = _normalize_text(text)
	var error := _write_checked(step, "INSERT INTO comments (item_id, parent_id, author, text, status, created_at) VALUES (?, ?, ?, ?, 'open', ?);",
		[item_id, parent_id, author, clean_text, ts])
	if not error.is_empty(): return {"error": error}
	var rows := _exec_select("SELECT last_insert_rowid() as lid;")
	var cid: int = int(rows[0].lid) if rows.size() > 0 else 0
	error = _add_event(step, item_id, "comment_reply" if parent_id > 0 else "comment_added", author, text.substr(0, 80))
	return {"id": cid, "item_id": item_id, "parent_id": parent_id, "author": author, "text": text, "status": "open", "created_at": ts, "error": error}


# A change's record without its "error" entry once it succeeded, or just
# {error}.
static func _without_error(result: Dictionary) -> Dictionary:
	var error := str(result.error)
	if not error.is_empty(): return {"error": error}
	result.erase("error")
	return result


func list_comments(item_id: String) -> Array:
	var rows := _exec_select("SELECT * FROM comments WHERE item_id=? ORDER BY id ASC;", [item_id])
	var result: Array = []
	for row in rows:
		result.append(_build_comment_dict(row))
	return result


## Resolves comment `comment_id` as "accepted" or "rejected", with its event,
## as one change within a step of `op` (or an operation of its own): the
## comment's record, or {error}.
func resolve_comment(comment_id: int, resolution: String, resolved_by: String, op: RefCounted = null) -> Dictionary:
	if resolution not in ["accepted", "rejected"]:
		return {"error": "Resolution must be 'accepted' or 'rejected'"}
	return _without_error(_change(op, _resolve_comment.bind(comment_id, resolution, resolved_by)))


func _resolve_comment(step: RefCounted, comment_id: int, resolution: String, resolved_by: String) -> Dictionary:
	var ts := Time.get_datetime_string_from_system(true)
	var error := _write_checked(step, "UPDATE comments SET status=?, resolved_at=?, resolved_by=? WHERE id=?;",
		[resolution, ts, resolved_by, comment_id])
	if not error.is_empty(): return {"error": error}
	var rows := _exec_select("SELECT * FROM comments WHERE id=?;", [comment_id])
	if rows.is_empty():
		return {"error": "Comment not found"}
	var row: Dictionary = rows[0]
	var item_id: String = str(row.get("item_id", ""))
	error = _add_event(step, item_id, "comment_" + resolution, resolved_by, str(row.get("text", "")).substr(0, 80))
	var result := _build_comment_dict(row)
	result["error"] = error
	return result


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


static func _has_column(col_rows: Array, col_name: String) -> bool:
	for cr in col_rows:
		if str(cr.get("name", "")) == col_name:
			return true
	return false


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
