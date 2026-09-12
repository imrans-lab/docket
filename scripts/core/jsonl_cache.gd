extends RefCounted
class_name JSONLCache
## Builds and validates a SQLite cache from a JSONL file.
##
## The cache file lives at <jsonl_path>.cache (e.g. "project.dct.jsonl.cache")
## and is gitignored/disposable — it can be deleted and rebuilt at any time.
##
## Cache freshness is content-addressed. Size/mtime can collide for rapid
## same-length edits, which is unacceptable at a write boundary.


# Reason the most recent rebuild_cache() returned null. Read it immediately
# after a null return — the next rebuild overwrites it.
static var last_error: String = ""
static var cache_delete_hook: Callable
static var rebuild_failure_hook: Callable


# -- Public API ---------------------------------------------------------------

static func open_or_rebuild(jsonl_path: String) -> DocketDB:
	## Open the cache if it is fresh, otherwise rebuild it from the JSONL file.
	## Returns an open DocketDB on success, null on failure.
	var cache_path := cache_path_for(jsonl_path)
	if is_cache_valid(jsonl_path, cache_path):
		var db := DocketDB.new()
		if db.open(cache_path):
			return db
		push_warning("JSONLCache: could not open existing cache %s — rebuilding" % cache_path)
	return rebuild_cache(jsonl_path, cache_path)


static func rebuild_cache(jsonl_path: String, cache_path: String) -> DocketDB:
	## Parse the JSONL file and write a fresh SQLite cache.
	## Returns an open DocketDB on success, null on failure.

	# Parse the JSONL source
	var parsed := JSONLParser.parse_file(jsonl_path)
	# A hard parse error (conflict markers, unreadable file) must abort before we
	# touch the cache. Rebuilding from a conflicted file would union both sides,
	# and the next flush would write that back over the file.
	var parse_error: String = str(parsed.get("error", ""))
	if not parse_error.is_empty():
		last_error = parse_error
		push_error("JSONLCache: %s" % parse_error)
		return null
	if parsed.is_empty() or parsed["meta"].is_empty():
		last_error = "failed to parse JSONL (or missing meta): %s" % jsonl_path
		push_error("JSONLCache: %s" % last_error)
		return null
	var expected_cache_path := cache_path_for_version(jsonl_path, str(parsed.meta.version))
	if cache_path != expected_cache_path:
		last_error = "format %s requires cache path %s" % [parsed.meta.version, expected_cache_path]
		return null
	last_error = ""

	# Remove stale cache files (db + WAL/SHM)
	var delete_error := _delete_cache_files(cache_path)
	if not delete_error.is_empty():
		last_error = delete_error
		return null

	# Create a fresh database
	var db := DocketDB.create_new(cache_path)
	if db == null:
		push_error("JSONLCache: could not create cache db at %s" % cache_path)
		return null

	# Bulk insert everything in one transaction for performance
	db._last_sql_error = ""
	var transaction_error := db._exec_checked("BEGIN TRANSACTION;")
	if not transaction_error.is_empty():
		last_error = "cache transaction failed: %s" % transaction_error
		db.close()
		_delete_cache_files(cache_path)
		return null

	_insert_meta(db, parsed["meta"])
	if not parsed.get("registry_diagnostics", []).is_empty():
		db.set_meta_value("registry_diagnostics", JSON.stringify(parsed.registry_diagnostics, "", true, true))
	_insert_type_registry(db, parsed["type_defs"], parsed["type_def_versions"])
	_insert_items(db, parsed["items"])
	_insert_events(db, parsed["events"])
	_insert_comments(db, parsed["comments"])
	_insert_links(db, parsed["links"])
	_insert_attachments(db, parsed["attachments"])
	_insert_secrets(db, parsed["secrets"])
	_insert_secret_versions(db, parsed["secret_versions"])
	_insert_saved_queries(db, parsed["saved_queries"])
	if rebuild_failure_hook.is_valid():
		var injected_error := str(rebuild_failure_hook.call())
		if not injected_error.is_empty() and db._last_sql_error.is_empty(): db._last_sql_error = injected_error

	# Store a fingerprint so we can validate freshness later
	var fingerprint := _file_fingerprint(jsonl_path)
	db.set_meta_value("jsonl_hash", fingerprint)

	if not db._last_sql_error.is_empty():
		db._rollback()
		last_error = "cache rebuild SQL failed: %s" % db._last_sql_error
		db.close()
		_delete_cache_files(cache_path)
		return null
	transaction_error = db._exec_checked("COMMIT;")
	if not transaction_error.is_empty():
		db._rollback()
		last_error = "cache commit failed: %s" % transaction_error
		db.close()
		_delete_cache_files(cache_path)
		return null
	return db


static func is_cache_valid(jsonl_path: String, cache_path: String) -> bool:
	## True if the cache exists and its stored fingerprint matches the JSONL file.
	if not FileAccess.file_exists(cache_path):
		return false
	# Parse before trusting even a matching warm-cache fingerprint. This is the
	# compatibility gate for higher versions, new record kinds and conflicts.
	var parsed := JSONLParser.parse_file(jsonl_path)
	if not str(parsed.get("error", "")).is_empty():
		last_error = parsed.error
		return false
	if cache_path != cache_path_for_version(jsonl_path, str(parsed.meta.version)):
		return false

	var db := DocketDB.new()
	if not db.open(cache_path):
		return false

	var stored := db.get_meta_value("jsonl_hash", "")
	db.close()

	if stored.is_empty():
		return false

	var current := _file_fingerprint(jsonl_path)
	return stored == current


# -- Internal helpers ---------------------------------------------------------

static func cache_path_for(jsonl_path: String) -> String:
	var parsed := JSONLParser.parse_file(jsonl_path)
	if str(parsed.get("error", "")).is_empty(): return cache_path_for_version(jsonl_path, str(parsed.meta.version))
	return jsonl_path + ".cache"

static func cache_path_for_version(jsonl_path: String, version: String) -> String:
	return jsonl_path + (".v2.cache" if version == "2.0.0" else ".cache")

static func delete_cache_family(jsonl_path: String) -> String:
	for base in [jsonl_path + ".cache", jsonl_path + ".v2.cache"]:
		var error := _delete_cache_files(base)
		if not error.is_empty(): return error
	return ""


static func _file_fingerprint(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_sha256(path)


static func _delete_cache_files(cache_path: String) -> String:
	for suffix: String in ["", "-wal", "-shm"]:
		var p := cache_path + suffix
		if FileAccess.file_exists(p):
			var error: int = int(cache_delete_hook.call(p)) if cache_delete_hook.is_valid() else DirAccess.remove_absolute(p)
			if error != OK: return "cannot remove incompatible cache %s (error %d)" % [p, error]
	return ""


# -- Meta ---------------------------------------------------------------------

static func _insert_meta(db: DocketDB, meta: Dictionary) -> void:
	## Write all meta fields into docket_meta, overriding the defaults that
	## create_new() seeds (version, counter, id_prefix).
	var version: String = str(meta.get("version", "1.0.0"))
	db.set_meta_value("jsonl_version", version)

	var counter: int = int(meta.get("counter", 0))
	db.set_counter(counter)

	var id_prefix: String = str(meta.get("id_prefix", "DKT"))
	db.set_id_prefix(id_prefix)

	var project: String = str(meta.get("project", ""))
	if not project.is_empty():
		db.set_project_name(project)

	# vault_salt and vault_verify are stored directly as base64 strings
	var vault_salt: String = str(meta.get("vault_salt", ""))
	if not vault_salt.is_empty():
		db.set_meta_value("vault_salt", vault_salt)

	var vault_verify: String = str(meta.get("vault_verify", ""))
	if not vault_verify.is_empty():
		db.set_meta_value("vault_verify", vault_verify)

	# Preserve any extra fields that the parser may have forwarded
	const KNOWN_META_KEYS := ["_type", "version", "counter", "id_prefix", "project",
		"vault_salt", "vault_verify"]
	for key in meta:
		if key not in KNOWN_META_KEYS:
			db.set_meta_value(key, str(meta[key]))


# -- Items --------------------------------------------------------------------

static func _insert_type_registry(db: DocketDB, definitions: Array, revisions: Array) -> void:
	for value in definitions:
		var record: Dictionary = value
		db._exec("INSERT INTO type_defs (id,slug,lifecycle,current_revision,provenance_json) VALUES (?,?,?,?,?);", [record.id, record.slug, record.lifecycle, record.current_revision, JSON.stringify(record.provenance, "", true, true)])
	for value in revisions:
		var record: Dictionary = value
		db._exec("INSERT INTO type_def_versions (id,type_id,parent_revision,definition_json,author,created_at,reason) VALUES (?,?,?,?,?,?,?);", [record.id, record.type_id, record.get("parent_revision", null), JSON.stringify(record.definition, "", true, true), record.author, record.created_at, record.reason])


static func _insert_items(db: DocketDB, items: Array) -> void:
	for item in items:
		var id: String = str(item.get("id", ""))
		if id.is_empty():
			push_warning("JSONLCache: skipping item with empty id")
			continue
		# insert_item() accepts the parsed dict directly.
		# Tags are in item["tags"]; events/links arrays are empty (loaded separately).
		var err := db.insert_item(id, item)
		if not err.is_empty():
			push_warning("JSONLCache: insert_item failed for %s: %s" % [id, err])


# -- Events -------------------------------------------------------------------

static func _insert_events(db: DocketDB, events: Array) -> void:
	## Events are inserted in file order, which sets their autoincrement rowids.
	## Rowid is only a tiebreak now — reads and serialization both sort by
	## timestamp first, so a merge that interleaved lines out of chronological
	## order is corrected on the next read rather than baked in.
	# Collect valid item IDs so we can skip orphaned events (FK would fail)
	var valid_ids := {}
	var rows = db._exec_select("SELECT id FROM items;", [])
	for r in rows:
		valid_ids[str(r.get("id", ""))] = true

	for ev in events:
		var item_id: String = str(ev.get("item_id", ""))
		var event_type: String = str(ev.get("event_type", ""))
		var actor: String = str(ev.get("actor", ""))
		var timestamp: String = str(ev.get("timestamp", ""))
		var note: String = str(ev.get("note", ""))
		if item_id.is_empty() or event_type.is_empty():
			push_warning("JSONLCache: skipping event with missing item_id or event_type")
			continue
		if not valid_ids.has(item_id):
			push_warning("JSONLCache: skipping orphaned event for missing item %s" % item_id)
			continue
		db._exec(
			"INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
			[item_id, event_type, actor, timestamp, note]
		)


# -- Comments -----------------------------------------------------------------

static func _insert_comments(db: DocketDB, comments: Array) -> void:
	## Restore comments with their original autoincrement IDs (needed for parent_id threading).
	# Collect valid item IDs so we can skip orphaned comments (FK would fail)
	var valid_ids := {}
	var rows = db._exec_select("SELECT id FROM items;", [])
	for r in rows:
		valid_ids[str(r.get("id", ""))] = true

	for c in comments:
		var cid: int = int(c.get("id", 0))
		var item_id: String = str(c.get("item_id", ""))
		var created_at: String = str(c.get("created_at", ""))
		if item_id.is_empty() or created_at.is_empty():
			push_warning("JSONLCache: skipping comment with missing item_id or created_at")
			continue
		if not valid_ids.has(item_id):
			push_warning("JSONLCache: skipping orphaned comment for missing item %s" % item_id)
			continue
		var parent_id: int = int(c.get("parent_id", 0))
		var author: String = str(c.get("author", ""))
		var text: String = str(c.get("text", ""))
		var status: String = str(c.get("status", "open"))
		if status.is_empty():
			status = "open"
		var resolved_at: String = str(c.get("resolved_at", ""))
		var resolved_by: String = str(c.get("resolved_by", ""))
		# Use INSERT with explicit id to preserve the original autoincrement value
		db._exec(
			"INSERT INTO comments (id, item_id, parent_id, author, text, status, created_at, resolved_at, resolved_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);",
			[cid, item_id, parent_id, author, text, status, created_at, resolved_at, resolved_by]
		)


# -- Links --------------------------------------------------------------------

static func _insert_links(db: DocketDB, links: Array) -> void:
	for lnk in links:
		var from_id: String = str(lnk.get("from_id", ""))
		var to_id: String = str(lnk.get("to_id", ""))
		var relation: String = str(lnk.get("relation", ""))
		if from_id.is_empty() or to_id.is_empty() or relation.is_empty():
			push_warning("JSONLCache: skipping link with missing from_id, to_id, or relation")
			continue
		db._exec(
			"INSERT INTO item_links (from_id, to_id, relation) VALUES (?, ?, ?);",
			[from_id, to_id, relation]
		)


# -- Attachments --------------------------------------------------------------

static func _insert_attachments(db: DocketDB, attachments: Array) -> void:
	## Restore attachments with their original IDs (referenced by nothing currently,
	## but preserving them ensures roundtrip fidelity per the spec).
	for att in attachments:
		var att_id: int = int(att.get("id", 0))
		var item_id: String = str(att.get("item_id", ""))
		var filename: String = str(att.get("filename", ""))
		var created_at: String = str(att.get("created_at", ""))
		if item_id.is_empty() or filename.is_empty() or created_at.is_empty():
			push_warning("JSONLCache: skipping attachment with missing required fields")
			continue
		# data is already a PackedByteArray from the parser
		var data: PackedByteArray = att.get("data", PackedByteArray())
		var mime_type: String = str(att.get("mime_type", "application/octet-stream"))
		if mime_type.is_empty():
			mime_type = "application/octet-stream"
		var size_bytes: int = int(att.get("size_bytes", data.size()))
		var description: String = str(att.get("description", ""))
		# Insert with explicit id to preserve autoincrement value
		db._exec_checked(
			"INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, data, created_at, description) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
			[att_id, item_id, filename, mime_type, size_bytes, data, created_at, description]
		)


# -- Secrets ------------------------------------------------------------------

static func _insert_secrets(db: DocketDB, secrets: Array) -> void:
	for s in secrets:
		var handle: String = str(s.get("handle", ""))
		var created_at: String = str(s.get("created_at", ""))
		var updated_at: String = str(s.get("updated_at", ""))
		if handle.is_empty() or created_at.is_empty() or updated_at.is_empty():
			push_warning("JSONLCache: skipping secret with missing required fields")
			continue
		# ciphertext/iv/mac are PackedByteArrays decoded by the parser
		var ciphertext: PackedByteArray = s.get("ciphertext", PackedByteArray())
		var iv: PackedByteArray = s.get("iv", PackedByteArray())
		var mac: PackedByteArray = s.get("mac", PackedByteArray())
		var requires_2fa: bool = bool(s.get("requires_2fa", false))
		var flag: int = 1 if requires_2fa else 0
		db._exec_checked(
			"INSERT INTO docket_secrets (handle, ciphertext, iv, mac, created_at, updated_at, requires_2fa, owner_item_id, extra_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);",
			[handle, ciphertext, iv, mac, created_at, updated_at, flag,
				_derive_owner(db, handle, str(s.get("owner_item_id", ""))),
				_extra_json(s)]
		)


static func _extra_json(s: Dictionary) -> String:
	## Fields the parser kept but this build has no column for. Stored verbatim
	## so the serializer can put them back exactly as they arrived.
	const MODELLED := ["_type", "handle", "ciphertext", "iv", "mac", "created_at",
		"updated_at", "requires_2fa", "owner_item_id",
		"ciphertext_b64", "iv_b64", "mac_b64"]
	var extra := {}
	for key in s:
		if key not in MODELLED:
			extra[key] = s[key]
	return JSON.stringify(extra) if not extra.is_empty() else ""


static func _derive_owner(db: DocketDB, handle: String, recorded: String) -> String:
	## Ownership for files written before owner_item_id existed.
	##
	## The schema migration only backfills when the *column* is added, which never
	## happens for a JSONL file: its cache is built fresh and already has the
	## column. So derivation has to happen here, on every rebuild, for any secret
	## that does not carry it.
	##
	## This reads what the handle already encoded — a Secret item's payload was
	## stored under handle == item_id, its notes under "<item_id>:notes". Nothing
	## is renamed and no ciphertext moves, so an older Docket can still open the
	## file and will simply recompute the same mapping.
	if not recorded.is_empty():
		return recorded
	var candidate := handle
	if handle.ends_with(":notes"):
		candidate = handle.substr(0, handle.length() - 6)
	if candidate.is_empty():
		return ""
	# Items are inserted before secrets during a rebuild, so this can see them.
	var hits := db._exec_select("SELECT 1 FROM items WHERE id=? LIMIT 1;", [candidate])
	return candidate if hits.size() > 0 else ""


# -- Secret versions ----------------------------------------------------------

static func _insert_secret_versions(db: DocketDB, secret_versions: Array) -> void:
	for sv in secret_versions:
		var handle: String = str(sv.get("handle", ""))
		var version: int = int(sv.get("version", 0))
		var created_at: String = str(sv.get("created_at", ""))
		if handle.is_empty() or version == 0 or created_at.is_empty():
			push_warning("JSONLCache: skipping secret_version with missing required fields")
			continue
		var ciphertext: PackedByteArray = sv.get("ciphertext", PackedByteArray())
		var iv: PackedByteArray = sv.get("iv", PackedByteArray())
		var mac: PackedByteArray = sv.get("mac", PackedByteArray())
		var rotated_by: String = str(sv.get("rotated_by", ""))
		db._exec_checked(
			"INSERT INTO docket_secret_versions (handle, version, ciphertext, iv, mac, created_at, rotated_by) VALUES (?, ?, ?, ?, ?, ?, ?);",
			[handle, version, ciphertext, iv, mac, created_at, rotated_by]
		)


# -- Saved queries ------------------------------------------------------------

static func _insert_saved_queries(db: DocketDB, saved_queries: Array) -> void:
	for sq in saved_queries:
		var name: String = str(sq.get("name", ""))
		var query_dict = sq.get("query", {})
		if name.is_empty():
			push_warning("JSONLCache: skipping saved_query with empty name")
			continue
		if not query_dict is Dictionary:
			query_dict = {}
		db.save_query(name, query_dict)
