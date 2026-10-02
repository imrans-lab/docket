extends RefCounted
class_name JSONLCache
## Builds and validates a SQLite cache from a JSONL file.
##
## Version 1 caches use <jsonl_path>.cache and version 2 caches use
## <jsonl_path>.v2.cache. Both are gitignored and disposable.
##
## Cache freshness is content-addressed. Size/mtime can collide for rapid
## same-length edits, which is unacceptable at a write boundary.
##
## The cache is built from the canonical plus its write-ahead sidecar
## (JSONLSidecar): a rebuild replays the sidecar's records, and the stored
## fingerprint is the hash of the very bytes it parsed from both files, so a
## record appended by any process, even during the rebuild, makes every other
## cache of this canonical stale.
##
## The cache also holds the project's ephemeral items (ItemStorage), which no
## file has. A rebuild therefore never replaces the file: it refreshes the
## durable rows of the existing file in one write-locked transaction and leaves
## the ephemeral rows where they are (ItemStorage.clear_durable_rows).
##
## Other connections, in this process or another, keep the file open through a
## rebuild. SQLite's write lock serializes the rebuild with their writes
## (busy_timeout), and WAL gives each of their reads the committed state from
## before or after the rebuild's COMMIT, never part of it. The stored
## fingerprint commits with the rows, so it always describes them.


# Reason the most recent rebuild_cache() returned null. Read it immediately
# after a null return — the next rebuild overwrites it.
static var last_error: String = ""
static var cache_delete_hook: Callable
## Test seam: called inside the rebuild transaction after every row is
## written and before the fingerprint; a non-empty return fails the rebuild.
static var rebuild_failure_hook: Callable
## Test seam: called after each source read, before the rebuild takes the
## write lock.
static var before_write_lock_hook: Callable
# _refresh's return when the files changed while it waited for the write lock.
const _SOURCE_MOVED := "source files changed while the rebuild waited for the write lock"


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
	## Refresh the cache at cache_path from the JSONL file and its sidecar.
	## Returns an open DocketDB on success, null on failure; a failure leaves
	## the file's previous rows and fingerprint in place.
	var source := _read_source(jsonl_path, cache_path)
	if source.is_empty(): return null
	var db := _open_for_rebuild(jsonl_path, cache_path)
	if db == null: return null
	# Every attempt compares the files with the bytes it parsed once it holds
	# the write lock. Files that changed are read once more; a second change
	# fails the rebuild with nothing written, so the cache keeps the rows and
	# fingerprint its writers committed and the next rebuild reads again.
	var error := _refresh(db, source, jsonl_path, cache_path)
	if error == _SOURCE_MOVED:
		source = _read_source(jsonl_path, cache_path)
		error = _refresh(db, source, jsonl_path, cache_path) if not source.is_empty() else last_error
		if error == _SOURCE_MOVED: error = "%s, twice; not rebuilt" % _SOURCE_MOVED
	if not error.is_empty():
		last_error = error
		push_error("JSONLCache: %s" % error)
		db.close()
		return null
	return db


static func _read_source(jsonl_path: String, cache_path: String) -> Dictionary:
	## {"parsed": canonical with the sidecar replayed, "fingerprint": of the
	## bytes parsed}, or {} with last_error set.

	# Canonical and sidecar are each read once here. The cache is built from these
	# bytes and its stored fingerprint is their hash, so a write by another
	# process after the read makes this cache stale instead of hiding inside it.
	if not FileAccess.file_exists(jsonl_path):
		last_error = "file not found: %s" % jsonl_path
		push_error("JSONLCache: %s" % last_error)
		return {}
	var canonical_bytes := FileAccess.get_file_as_bytes(jsonl_path)
	if FileAccess.get_open_error() != OK:
		last_error = "cannot open file: %s" % jsonl_path
		push_error("JSONLCache: %s" % last_error)
		return {}
	var sidecar_read := JSONLSidecar.read_bytes(JSONLSidecar.path_for(jsonl_path))
	if not str(sidecar_read.error).is_empty():
		last_error = str(sidecar_read.error)
		push_error("JSONLCache: %s" % last_error)
		return {}
	var sidecar_bytes: PackedByteArray = sidecar_read.bytes
	var canonical_sha := JSONLSidecar.sha256_bytes(canonical_bytes)

	# Parse the JSONL source
	var parsed := JSONLParser.parse_bytes(canonical_bytes, jsonl_path)
	# A hard parse error (conflict markers, unreadable file) must abort before we
	# touch the cache. Rebuilding from a conflicted file would union both sides,
	# and the next flush would write that back over the file.
	var parse_error: String = str(parsed.get("error", ""))
	if not parse_error.is_empty():
		last_error = parse_error
		push_error("JSONLCache: %s" % parse_error)
		return {}
	if parsed.is_empty() or parsed["meta"].is_empty():
		last_error = "failed to parse JSONL (or missing meta): %s" % jsonl_path
		push_error("JSONLCache: %s" % last_error)
		return {}
	var expected_cache_path := cache_path_for_version(jsonl_path, str(parsed.meta.version))
	if cache_path != expected_cache_path:
		last_error = "format %s requires cache path %s" % [parsed.meta.version, expected_cache_path]
		return {}
	# Same refusal rule as the canonical: a sidecar that cannot be replayed
	# faithfully aborts before the cache is touched.
	var replay_error := JSONLSidecar.replay_into(parsed, jsonl_path, canonical_sha, sidecar_bytes)
	if not replay_error.is_empty():
		last_error = replay_error
		push_error("JSONLCache: %s" % replay_error)
		return {}
	last_error = ""
	return {"parsed": parsed, "fingerprint": JSONLSidecar.fingerprint_of(canonical_sha, sidecar_bytes)}


static func _open_for_rebuild(jsonl_path: String, cache_path: String) -> DocketDB:
	## The cache file at cache_path, opened and migrated in place to this
	## build's schema (migrate_schema, then init_schema for any missing table),
	## or created when there is none. The format version never
	## shares a file: it picks the path (cache_path_for_version).
	## The file is replaced only when it is unusable as a cache: SQLite reports
	## it is not a database or is malformed, or it has no items table (zero
	## bytes, or a crash between creating the file and its schema).
	## Creating and replacing run under the project's FileLock (the lock
	## _commit_mutation takes), taken with no SQLite handle open on the file:
	## the file is inspected again under the lock, since a peer may have created
	## or replaced it meanwhile, and only a file still unusable is deleted. The
	## lock is released once the new file's schema is committed, so a holder of
	## the lock never sees a file another rebuild is still creating.
	## (DocketDBJsonl.create_new_jsonl creates its cache unlocked, before the
	## canonical exists; a rebuild refuses a missing canonical before it gets
	## here.) A lock not acquired within its timeout, or a
	## delete that fails (on Windows, while any process still holds the file
	## open), refuses the rebuild and leaves the file in place. Any other open
	## or migration error (busy included) is refused without touching the file.
	if FileAccess.file_exists(cache_path):
		var probe := _inspect(cache_path)
		if probe.db != null: return probe.db
		if not probe.unusable: return _refuse_open(cache_path, probe.error)
	var lock := FileLock.acquire(jsonl_path)
	if lock == null:
		last_error = "cache %s is missing or unusable and the lock for %s could not be acquired; not replaced" % [cache_path, jsonl_path]
		push_error("JSONLCache: %s" % last_error)
		return null
	var db := _create_or_replace(cache_path)
	lock.release()
	return db


static func _create_or_replace(cache_path: String) -> DocketDB:
	## Called with the FileLock held.
	if FileAccess.file_exists(cache_path):
		var probe := _inspect(cache_path)
		if probe.db != null: return probe.db
		if not probe.unusable: return _refuse_open(cache_path, probe.error)
		var delete_error := _delete_cache_files(cache_path)
		if not delete_error.is_empty():
			last_error = "cache %s is unusable (%s) and could not be replaced: %s. Close every Docket process using this project, delete the file and reopen" % [cache_path, probe.error, delete_error]
			push_error("JSONLCache: %s" % last_error)
			return null
		push_warning("JSONLCache: replaced unusable cache %s (%s)" % [cache_path, probe.error])
	return _create(cache_path)


static func _inspect(cache_path: String) -> Dictionary:
	## {"db": the open, migrated DocketDB or null, "unusable": bool, "error": String}.
	## Closes the file unless it returns it.
	# open() returns false only when SQLite cannot open a handle at all ("cannot
	# open", never replaced). On a file SQLite cannot read it still returns true:
	# its PRAGMAs and migrate_schema fail, leaving the first error ("file is not
	# a database", "... malformed") in _last_sql_error. A file with no items
	# table opens as an empty database and migrate_schema fails on
	# "no such table: items", so that case is told apart by asking sqlite_master.
	# migrate_schema adds columns and some tables but not every table, so a
	# usable file also gets init_schema (IF NOT EXISTS throughout): a table the
	# file lacks is created, as the fresh file a rebuild used to make had it.
	var db := DocketDB.new()
	var opened := db.open(cache_path, false)
	var open_error := db._last_sql_error if opened else "cannot open"
	if opened and open_error.is_empty():
		db._init_schema()
		open_error = db._last_sql_error
		if open_error.is_empty(): return {"db": db, "unusable": false, "error": ""}
		db.close()
		return {"db": null, "unusable": false, "error": open_error}
	var unusable := open_error.containsn("not a database") or open_error.containsn("malformed")
	if opened and not unusable:
		db._last_sql_error = ""
		var items_table := db._exec_select("SELECT 1 FROM sqlite_master WHERE type='table' AND name='items';")
		unusable = items_table.is_empty() and db._last_sql_error.is_empty()
	if opened: db.close()
	return {"db": null, "unusable": unusable, "error": open_error}


static func _refuse_open(cache_path: String, open_error: String) -> DocketDB:
	last_error = "cache %s cannot be opened; not rebuilt: %s" % [cache_path, open_error]
	push_error("JSONLCache: %s" % last_error)
	return null


static func _create(cache_path: String) -> DocketDB:
	var db := DocketDB.create_new(cache_path)
	if db == null:
		last_error = "could not create cache db at %s" % cache_path
		push_error("JSONLCache: %s" % last_error)
	return db


static func _refresh(db: DocketDB, source: Dictionary, jsonl_path: String, cache_path: String) -> String:
	## One transaction: BEGIN IMMEDIATE waits (busy_timeout) for any other
	## connection's write transaction and then holds the write lock; durable
	## rows are deleted, the canonical's rows inserted, and the fingerprint
	## stored. Any error rolls all of it back. Returns "" or the error.
	## Returns _SOURCE_MOVED, having written nothing, when the files no longer
	## match source once the lock is held: a writer that held the lock while this
	## waited appended to the sidecar (_commit_mutation appends and commits
	## under that lock), and its committed rows must not be replaced by older
	## ones.
	var parsed: Dictionary = source.parsed
	if before_write_lock_hook.is_valid(): before_write_lock_hook.call()
	db._last_sql_error = ""
	var error := db._exec_checked("BEGIN IMMEDIATE TRANSACTION;")
	if not error.is_empty(): return "cache transaction failed: %s" % error
	if _file_fingerprint(jsonl_path) != str(source.fingerprint):
		db._rollback()
		return _SOURCE_MOVED

	var cleared := ItemStorage.clear_durable_rows(db, parsed)
	if cleared.has("error"): db._rollback(); return "cache rebuild SQL failed: %s" % cleared.error
	_reset_meta(db, cache_path)
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
	ItemStorage.relink(db, cleared.links)
	if rebuild_failure_hook.is_valid():
		var injected_error := str(rebuild_failure_hook.call())
		if not injected_error.is_empty() and db._last_sql_error.is_empty(): db._last_sql_error = injected_error

	# The identity of exactly the bytes parsed. Ephemeral rows are never part of
	# it: neither file ever holds one.
	db.set_meta_value("jsonl_hash", str(source.fingerprint))

	if not db._last_sql_error.is_empty():
		error = db._last_sql_error
		db._rollback()
		return "cache rebuild SQL failed: %s" % error
	error = db._exec_checked("COMMIT;")
	if not error.is_empty():
		db._rollback()
		return "cache commit failed: %s" % error
	return ""


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
	return JSONLSidecar.source_fingerprint(path)


static func _delete_cache_files(cache_path: String) -> String:
	for suffix: String in ["", "-wal", "-shm"]:
		var p := cache_path + suffix
		if FileAccess.file_exists(p):
			var error: int = int(cache_delete_hook.call(p)) if cache_delete_hook.is_valid() else DirAccess.remove_absolute(p)
			if error != OK: return "cannot remove incompatible cache %s (error %d)" % [p, error]
	return ""


# -- Meta ---------------------------------------------------------------------

static func _reset_meta(db: DocketDB, cache_path: String) -> void:
	## Every docket_meta row is rebuilt: the canonical's meta line plus this
	## cache's own keys. Seeds the same defaults as DocketDB.create_new.
	db._exec("DELETE FROM docket_meta;")
	db._exec("INSERT INTO docket_meta (key, value) VALUES ('version', '2.0.0'), ('counter', '0'), ('id_prefix', 'DKT');")
	var basename := cache_path.get_file().get_basename()
	if not basename.is_empty(): db.set_project_name(basename)


static func _insert_meta(db: DocketDB, meta: Dictionary) -> void:
	## Write all meta fields into docket_meta, overriding the defaults that
	## _reset_meta seeds (version, counter, id_prefix).
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

	# Preserve any extra fields that the parser may have forwarded. JSON numbers
	# parse as floats; an integral one is stored as the integer text the
	# serializer wrote it from ("4", not "4.0").
	const KNOWN_META_KEYS := ["_type", "version", "counter", "id_prefix", "project",
		"vault_salt", "vault_verify"]
	for key in meta:
		if key not in KNOWN_META_KEYS:
			var value: Variant = meta[key]
			var integral: bool = value is float and is_finite(value) and value == floorf(value)
			db.set_meta_value(key, str(int(value)) if integral else str(value))


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
			db._last_sql_error = "invalid canonical record: item with empty id"
			continue
		# insert_item() accepts the parsed dict directly.
		# Tags are in item["tags"]; events/links arrays are empty (loaded separately).
		var err := db.insert_item(id, item)
		if not err.is_empty():
			db._last_sql_error = "canonical item insert failed for %s: %s" % [id, err]


# -- Events -------------------------------------------------------------------

static func _insert_events(db: DocketDB, events: Array) -> void:
	## Events are inserted in file order, which sets their autoincrement rowids.
	## Rowid is only a tiebreak now — reads and serialization both sort by
	## timestamp first, so a merge that interleaved lines out of chronological
	## order is corrected on the next read rather than baked in.
	# The canonical's items (never an ephemeral one), so an orphaned event is refused
	var valid_ids := {}
	var rows = db._exec_select("SELECT id FROM items WHERE storage<>'ephemeral';", [])
	for r in rows:
		valid_ids[str(r.get("id", ""))] = true

	for ev in events:
		var item_id: String = str(ev.get("item_id", ""))
		var event_type: String = str(ev.get("event_type", ""))
		var actor: String = str(ev.get("actor", ""))
		var timestamp: String = str(ev.get("timestamp", ""))
		var note: String = str(ev.get("note", ""))
		if item_id.is_empty() or event_type.is_empty():
			db._last_sql_error = "invalid canonical record: event with missing item_id or event_type"
			continue
		if not valid_ids.has(item_id):
			db._last_sql_error = "invalid canonical record: orphaned event for missing item %s" % item_id
			continue
		# eid / fields: the project event id and changed fields (ProjectEvents).
		var fields: Variant = ev.get("fields")
		db._exec(
			"INSERT INTO item_events (item_id, event_type, actor, timestamp, note, eid, fields, extras_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
			[item_id, event_type, actor, timestamp, note, ev.get("eid"), JSON.stringify(fields) if fields is Array else "", JSON.stringify(ev.get("extras", {}))]
		)


# -- Comments -----------------------------------------------------------------

static func _insert_comments(db: DocketDB, comments: Array) -> void:
	## Restore comments with their original autoincrement IDs (needed for parent_id threading).
	# The canonical's items (never an ephemeral one), so an orphaned comment is refused
	var valid_ids := {}
	var rows = db._exec_select("SELECT id FROM items WHERE storage<>'ephemeral';", [])
	for r in rows:
		valid_ids[str(r.get("id", ""))] = true

	for c in comments:
		var cid: int = int(c.get("id", 0))
		var item_id: String = str(c.get("item_id", ""))
		var created_at: String = str(c.get("created_at", ""))
		if item_id.is_empty() or created_at.is_empty():
			db._last_sql_error = "invalid canonical record: comment with missing item_id or created_at"
			continue
		if not valid_ids.has(item_id):
			db._last_sql_error = "invalid canonical record: orphaned comment for missing item %s" % item_id
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
			db._last_sql_error = "invalid canonical record: link with missing from_id, to_id, or relation"
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
			db._last_sql_error = "invalid canonical record: attachment with missing required fields"
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
			db._last_sql_error = "invalid canonical record: secret with missing required fields"
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
	# Ephemeral items kept through the rebuild never own a vault entry.
	var hits := db._exec_select("SELECT 1 FROM items WHERE id=? AND storage<>'ephemeral' LIMIT 1;", [candidate])
	return candidate if hits.size() > 0 else ""


# -- Secret versions ----------------------------------------------------------

static func _insert_secret_versions(db: DocketDB, secret_versions: Array) -> void:
	for sv in secret_versions:
		var handle: String = str(sv.get("handle", ""))
		var version: int = int(sv.get("version", 0))
		var created_at: String = str(sv.get("created_at", ""))
		if handle.is_empty() or version == 0 or created_at.is_empty():
			db._last_sql_error = "invalid canonical record: secret_version with missing required fields"
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
			db._last_sql_error = "invalid canonical record: saved_query with empty name"
			continue
		if not query_dict is Dictionary:
			query_dict = {}
		db.save_query(name, query_dict)
