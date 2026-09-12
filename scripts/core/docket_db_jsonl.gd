extends DocketDB
class_name DocketDBJsonl
## DocketDB subclass that writes through to both SQLite (cache) and JSONL (canonical).
##
## JSONL is the source of truth; SQLite is a fast query cache.
## Mutations pass a source-freshness gate, update the disposable SQLite cache,
## then rewrite the entire JSONL file atomically.
##
## Opening flow:
##   1. If JSONL exists and cache is fresh → open cache via DocketDB.open()
##   2. If cache is stale or missing → rebuild from JSONL via JSONLCache
##   3. If neither exists → create new (fresh JSONL + SQLite cache)

var _jsonl_path: String
var _flush_depth: int = 0  # Reentrance guard to avoid redundant JSONL writes
var last_write_error: String = ""
var _write_blocked: bool = false
var _allow_initial_write: bool = false
var _lock_timeout_ms: int = 5000
var _atomic_write_hook: Callable

# Reason the most recent open_jsonl() returned null (e.g. unresolved conflict
# markers). Read immediately after a null return.
static var last_open_error: String = ""


# -- Lifecycle ----------------------------------------------------------------

static func open_jsonl(path: String) -> DocketDBJsonl:
	## Open a JSONL-backed docket. `path` is the .dct.jsonl file.
	## Returns an open DocketDBJsonl, or null on failure.
	var wrapper := DocketDBJsonl.new()
	wrapper._jsonl_path = path

	var cache_path := JSONLCache.cache_path_for(path)

	if not FileAccess.file_exists(path):
		last_open_error = "JSONL file not found: %s" % path
		push_error("DocketDBJsonl: %s" % last_open_error)
		return null

	# Rebuild or reuse cache
	var cache_db: DocketDB
	if JSONLCache.is_cache_valid(path, cache_path):
		# Open cache directly — faster than rebuilding
		var temp_db := DocketDB.new()
		if temp_db.open(cache_path):
			cache_db = temp_db
		else:
			push_warning("DocketDBJsonl: stale cache, rebuilding from %s" % path)
			cache_db = JSONLCache.rebuild_cache(path, cache_path)
	else:
		cache_db = JSONLCache.rebuild_cache(path, cache_path)

	if cache_db == null:
		# Carry the specific reason (e.g. conflict markers) up to the caller so
		# the GUI and MCP can tell the user what to fix.
		last_open_error = JSONLCache.last_error
		if last_open_error.is_empty():
			last_open_error = "failed to open or rebuild cache for %s" % path
		push_error("DocketDBJsonl: %s" % last_open_error)
		return null

	last_open_error = ""

	# Transfer the opened SQLite connection to our wrapper (which IS a DocketDB)
	wrapper._adopt(cache_db)

	return wrapper


static func create_new_jsonl(path: String) -> DocketDBJsonl:
	## Create a brand-new JSONL-backed docket. `path` is the .dct.jsonl file.
	## Writes a 2.0 file with complete starter definitions and creates its cache.
	var wrapper := DocketDBJsonl.new()
	wrapper._jsonl_path = path
	wrapper._allow_initial_write = true

	var cache_path := JSONLCache.cache_path_for_version(path, "2.0.0")

	# Create the SQLite cache via parent's create_new
	var cache_db := DocketDB.create_new(cache_path)
	if cache_db == null:
		push_error("DocketDBJsonl: failed to create cache at %s" % cache_path)
		return null

	# Transfer ownership
	wrapper._adopt(cache_db)
	var seed_error := TypeRegistryBootstrap.seed_cache(wrapper)
	if not seed_error.is_empty():
		wrapper.last_write_error = seed_error
		wrapper._write_blocked = true
		wrapper.close()
		return null

	# Write initial JSONL
	var initial_write_error := wrapper._flush_jsonl()
	wrapper._allow_initial_write = false
	if not initial_write_error.is_empty():
		wrapper.close()
		return null

	return wrapper


func get_jsonl_path() -> String:
	return _jsonl_path


func get_path() -> String:
	## Override: return the JSONL path (canonical), not the cache path.
	return _jsonl_path


func close() -> void:
	# Flush JSONL one last time before closing
	if _is_open and not _jsonl_path.is_empty() and not _write_blocked and FileAccess.file_exists(_jsonl_path):
		_flush_jsonl()
	super.close()


# -- Freshness ----------------------------------------------------------------
#
# The JSONL file is canonical and other processes edit it — most importantly
# `git pull`/`git merge`. Without a freshness check, a long-lived process keeps
# serving its stale cache and the next mutation rewrites the whole file from
# that stale state, silently deleting whatever was pulled. Callers should invoke
# ensure_fresh() at the top of each request (MCP) or poll tick (GUI).

func is_stale() -> bool:
	## True if the JSONL file no longer matches what this cache was built from.
	if not _is_open or _jsonl_path.is_empty():
		return false
	var current := _file_fingerprint(_jsonl_path)
	if current.is_empty():
		return true
	return super.get_meta_value("jsonl_hash", "") != current


func ensure_fresh() -> bool:
	## Reload from JSONL if it changed underneath us. Returns true if reloaded.
	## No-op mid-mutation: a compound write is not a safe point to swap the DB.
	if _flush_depth > 0:
		return false
	if not is_stale():
		return false
	return reload()


func reload() -> bool:
	## Force a rebuild of the SQLite cache from the canonical JSONL file,
	## discarding cached state. Returns true on success.
	if _jsonl_path.is_empty():
		return false

	var cache_path := JSONLCache.cache_path_for(_jsonl_path)

	# Release our connection first so the rebuild can replace the cache file
	# cleanly on platforms that refuse to unlink an open file.
	# NOTE: super.close() (not close()) — the override would flush our stale
	# state over the very file we are trying to read.
	if _is_open:
		super.close()

	var fresh := JSONLCache.rebuild_cache(_jsonl_path, cache_path)
	if fresh == null:
		last_open_error = JSONLCache.last_error
		push_error("DocketDBJsonl: reload failed for %s — %s" % [_jsonl_path, last_open_error])
		# rebuild_cache aborts before touching cache files when the JSONL itself
		# is bad (conflict markers), so the old cache is usually still intact.
		# Reopening it keeps the process usable and read-only-correct.
		var fallback := DocketDB.new()
		if fallback.open(cache_path):
			_adopt(fallback)
		_write_blocked = true
		last_write_error = "canonical reload failed; cached data is read-only"
		return false

	_adopt(fresh)
	last_open_error = ""
	return true


func flush() -> void:
	## Force a JSONL write. Public counterpart to the internal _flush_jsonl().
	_flush_jsonl()


func _adopt(source: DocketDB) -> void:
	## Take ownership of source's SQLite connection, detaching it from source
	## so its destructor cannot close the handle we now hold.
	_db = source._db
	_path = source._path
	_is_open = true
	source._db = null
	source._is_open = false
	var diagnostics := super.get_meta_value("registry_diagnostics", "")
	_write_blocked = not diagnostics.is_empty()
	if _write_blocked: last_write_error = "unresolved type definition data; project is read-only: %s" % diagnostics


func get_storage_diagnostics() -> Array:
	var raw := super.get_meta_value("registry_diagnostics", "")
	var parsed = JSON.parse_string(raw)
	return parsed if parsed is Array else []


func _mutation_precheck() -> String:
	if _write_blocked: return last_write_error
	if not FileAccess.file_exists(_jsonl_path) and not _allow_initial_write:
		_write_blocked = true
		last_write_error = "canonical source is missing; project is read-only"
		return last_write_error
	if is_stale() and not reload():
		_write_blocked = true
		if last_write_error.is_empty(): last_write_error = "canonical source could not be reloaded"
		return last_write_error
	return ""


func apply_registry_change(type_def: Dictionary, revision: Dictionary, item_bindings: Array, events: Array, expected_current_revision: String) -> String:
	## One checked cache transaction stages the immutable snapshot, current
	## pointer, item pins, and audit events before one canonical replacement.
	var error := _mutation_precheck()
	if not error.is_empty(): return error
	if JSONLParser._parse_type_def(type_def).is_empty() or JSONLParser._parse_type_def_version(revision).is_empty(): return "incomplete type definition snapshot"
	if str(type_def.get("id", "")) != str(revision.get("type_id", "")): return "revision belongs to another type"
	if str(type_def.current_revision) != str(revision.id): return "current pointer does not target proposed revision"
	if _exec_select("SELECT 1 FROM type_def_versions WHERE id=?;", [revision.id]).size() > 0: return "immutable revision id already exists"
	var existing := _exec_select("SELECT slug,current_revision FROM type_defs WHERE id=?;", [type_def.id])
	if not existing.is_empty() and str(existing[0].slug) != str(type_def.slug): return "type slug is immutable"
	if not existing.is_empty() and str(existing[0].current_revision) != expected_current_revision: return "stale type revision proposal"
	for binding in item_bindings:
		if str(binding.type_id) != str(type_def.id) or str(binding.type_revision) != str(revision.id): return "item binding does not target proposed revision"
		if not has_item(str(binding.item_id)): return "item binding refers to missing item '%s'" % binding.item_id
	for event in events:
		if not has_item(str(event.item_id)): return "event refers to missing item '%s'" % event.item_id
	error = _exec_checked("BEGIN TRANSACTION;")
	if error.is_empty(): error = _exec_checked("INSERT INTO type_def_versions (id,type_id,parent_revision,definition_json,author,created_at,reason) VALUES (?,?,?,?,?,?,?);", [revision.id, revision.type_id, revision.get("parent_revision", null), JSON.stringify(revision.definition, "", true, true), revision.author, revision.created_at, revision.reason])
	if error.is_empty():
		if existing.is_empty(): error = _exec_checked("INSERT INTO type_defs (id,slug,lifecycle,current_revision,provenance_json) VALUES (?,?,?,?,?);", [type_def.id, type_def.slug, type_def.lifecycle, type_def.current_revision, JSON.stringify(type_def.provenance, "", true, true)])
		else: error = _exec_checked("UPDATE type_defs SET lifecycle=?,current_revision=?,provenance_json=? WHERE id=? AND current_revision=?;", [type_def.lifecycle, type_def.current_revision, JSON.stringify(type_def.provenance, "", true, true), type_def.id, expected_current_revision])
	for binding in item_bindings:
		if not error.is_empty(): break
		error = _exec_checked("UPDATE items SET type_id=?,type_revision=? WHERE id=?;", [binding.type_id, binding.type_revision, binding.item_id])
	for event in events:
		if not error.is_empty(): break
		error = _exec_checked("INSERT INTO item_events (item_id,event_type,actor,timestamp,note) VALUES (?,?,?,?,?);", [event.item_id, event.event_type, event.get("actor", ""), event.timestamp, event.get("note", "")])
	if not error.is_empty(): _rollback(); return error
	error = _exec_checked("COMMIT;")
	if not error.is_empty(): _rollback(); return error
	return _flush_jsonl()


# -- JSONL write-through ------------------------------------------------------

func _flush_jsonl() -> String:
	## Serialize current DB state to JSONL and write atomically.
	## Uses _flush_depth to coalesce nested mutations (e.g. add_comment → add_event).
	## Acquires the supported advisory sidecar before writing and validates the
	## canonical content again after acquisition.
	if _jsonl_path.is_empty():
		return "canonical path is empty"
	if _flush_depth > 0:
		return ""  # We're inside a compound mutation — will flush when outermost returns
	if _write_blocked:
		return last_write_error
	if not FileAccess.file_exists(_jsonl_path) and not _allow_initial_write:
		return _fail_flush("canonical source is missing; refusing to recreate it from cache")
	if FileAccess.file_exists(_jsonl_path) and is_stale():
		return _fail_flush("canonical source changed; reload before writing")
	var expected_source_hash := super.get_meta_value("jsonl_hash", "")
	var cache_error := _validate_cache_for_flush()
	if not cache_error.is_empty(): return _fail_flush(cache_error)

	var jsonl_text := JSONLSerializer.serialize_all(self)
	if jsonl_text.is_empty():
		return _fail_flush("serializer produced empty output")

	# The sidecar only reduces overlap. Recheck the strong source identity after
	# acquiring it so a writer in the serialization window cannot be overwritten.
	var lock := FileLock.acquire(_jsonl_path, _lock_timeout_ms)
	if lock == null:
		return _fail_flush("could not acquire advisory lock for %s" % _jsonl_path)
	if not _allow_initial_write and _file_fingerprint(_jsonl_path) != expected_source_hash:
		lock.release()
		return _fail_flush("canonical source changed while acquiring write lock")

	var write_error: String = str(_atomic_write_hook.call(_jsonl_path, jsonl_text)) if _atomic_write_hook.is_valid() else _atomic_write(_jsonl_path, jsonl_text)

	if lock != null:
		lock.release()
	if not write_error.is_empty():
		return _fail_flush(write_error)

	# Update cache fingerprint so it stays valid
	var fingerprint := _file_fingerprint(_jsonl_path)
	if not fingerprint.is_empty():
		# Use super to avoid triggering another flush
		super.set_meta_value("jsonl_hash", fingerprint)
	last_write_error = ""
	return ""


func _validate_cache_for_flush() -> String:
	for row in _exec_select("SELECT id,fields_json,extras_json FROM items;"):
		for key in ["fields_json", "extras_json"]:
			if not JSON.parse_string(str(row.get(key, ""))) is Dictionary:
				return "malformed %s for item %s; refusing canonical flush" % [key, row.id]
	for row in _exec_select("SELECT d.id,d.current_revision,v.type_id FROM type_defs d LEFT JOIN type_def_versions v ON v.id=d.current_revision;"):
		if row.get("type_id") == null or str(row.type_id) != str(row.id): return "invalid current type revision pointer for %s" % row.id
	return ""


func _fail_flush(message: String) -> String:
	last_write_error = message
	if FileAccess.file_exists(_jsonl_path):
		# SQLite is disposable. Rebuilding it restores the last canonical state so
		# a failed compound write cannot leak into a later successful flush.
		reload()
		last_write_error = message
	else:
		_write_blocked = true
	return message


static func _file_fingerprint(path: String) -> String:
	## Strong content identity prevents a same-size, same-timestamp external edit
	## from being overwritten by a cache that only appeared fresh.
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_sha256(path)


static func _atomic_write(path: String, content: String) -> String:
	## Write content to a file atomically: write to .tmp, then rename.
	var tmp_path := path + ".tmp.%d" % OS.get_process_id()

	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return "cannot open temp file %s for writing" % tmp_path
	f.store_string(content)
	f.flush()
	var file_error := f.get_error()
	f.close()
	if file_error != OK:
		DirAccess.remove_absolute(tmp_path)
		return "temp file write failed (error %d)" % file_error

	# Atomic rename
	var err := DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		push_error("DocketDBJsonl: rename %s → %s failed (error %d)" % [tmp_path, path, err])
		# Clean up temp file on failure
		DirAccess.remove_absolute(tmp_path)
		return "cannot replace canonical file (error %d)" % err
	return ""


# -- Overridden mutating methods ----------------------------------------------

# Each override: call super (SQLite), then flush JSONL.


func insert_item(id: String, item: Dictionary) -> String:
	var precheck := _mutation_precheck()
	if not precheck.is_empty(): return precheck
	var candidate := item.duplicate(true)
	if super.get_meta_value("jsonl_version", "1.0.0") == "2.0.0" and (not candidate.has("type_id") or not candidate.has("type_revision")):
		var rows := _exec_select("SELECT id,current_revision FROM type_defs WHERE slug=?;", [candidate.get("type", "")])
		if rows.size() != 1: return "type '%s' has no active project definition" % candidate.get("type", "")
		candidate["type_id"] = rows[0].id
		candidate["type_revision"] = rows[0].current_revision
	var result := super.insert_item(id, candidate)
	if result.is_empty():  # success
		result = _flush_jsonl()
	return result


func update_item_fields(id: String, changes: Dictionary) -> void:
	update_item_fields_checked(id, changes)


func update_item_fields_checked(id: String, changes: Dictionary) -> String:
	var precheck := _mutation_precheck()
	if not precheck.is_empty(): return precheck
	var error := super.update_item_fields_checked(id, changes)
	if not error.is_empty(): return error
	return _flush_jsonl()


func set_item_field(id: String, field: String, val) -> void:
	if not _mutation_precheck().is_empty(): return
	super.set_item_field(id, field, val)
	_flush_jsonl()


func delete_item(id: String) -> void:
	if not _mutation_precheck().is_empty(): return
	# delete_item internally calls delete_secret (which we override).
	_flush_depth += 1
	super.delete_item(id)
	_flush_depth -= 1
	_flush_jsonl()


func import_item_full(new_id: String, exported: Dictionary) -> void:
	if not _mutation_precheck().is_empty(): return
	super.import_item_full(new_id, exported)
	_flush_jsonl()


func rewrite_refs(old_qualified: String, new_qualified: String, old_bare_id: String, new_qualified_for_bare: String) -> int:
	if not _mutation_precheck().is_empty(): return 0
	var count := super.rewrite_refs(old_qualified, new_qualified, old_bare_id, new_qualified_for_bare)
	if count > 0:
		_flush_jsonl()
	return count


# -- ID generation (mutates counter) -----------------------------------------

func next_id() -> String:
	if not _mutation_precheck().is_empty(): return ""
	var result := super.next_id()
	_flush_jsonl()
	return result


# next_uuid7_id() does NOT mutate the counter — it's stateless. No override needed.


# -- Meta mutations -----------------------------------------------------------

func set_meta_value(meta_key: String, val: String) -> void:
	if meta_key != "jsonl_hash" and not _mutation_precheck().is_empty(): return
	super.set_meta_value(meta_key, val)
	# Avoid infinite recursion: _flush_jsonl calls set_meta_value("jsonl_hash", ...)
	if meta_key == "jsonl_hash":
		return
	_flush_jsonl()


func set_id_prefix(prefix: String) -> void:
	if not _mutation_precheck().is_empty(): return
	# set_id_prefix calls set_meta_value internally.
	_flush_depth += 1
	super.set_id_prefix(prefix)
	_flush_depth -= 1
	_flush_jsonl()


func set_project_name(name: String) -> void:
	if not _mutation_precheck().is_empty(): return
	# set_project_name calls set_meta_value internally.
	_flush_depth += 1
	super.set_project_name(name)
	_flush_depth -= 1
	_flush_jsonl()


func set_counter(val: int) -> void:
	if not _mutation_precheck().is_empty(): return
	super.set_counter(val)
	_flush_jsonl()


# -- Events -------------------------------------------------------------------

func add_event(item_id: String, event_type: String, actor: String, note: String = "") -> void:
	if not _mutation_precheck().is_empty(): return
	super.add_event(item_id, event_type, actor, note)
	_flush_jsonl()


# -- Links --------------------------------------------------------------------

func add_link(from_id: String, to_id: String, relation: String) -> void:
	if not _mutation_precheck().is_empty(): return
	super.add_link(from_id, to_id, relation)
	_flush_jsonl()


# -- Attachments --------------------------------------------------------------

func attach_file(item_id: String, filename: String, data: PackedByteArray, mime: String = "application/octet-stream", desc: String = "") -> Dictionary:
	var precheck := _mutation_precheck()
	if not precheck.is_empty(): return {"error": precheck}
	var result := super.attach_file(item_id, filename, data, mime, desc)
	if not result.has("error"):
		var flush_error := _flush_jsonl()
		if not flush_error.is_empty(): return {"error": flush_error}
	return result


func detach_file(att_id: int) -> void:
	if not _mutation_precheck().is_empty(): return
	super.detach_file(att_id)
	_flush_jsonl()


# -- Comments -----------------------------------------------------------------

func add_comment(item_id: String, author: String, text: String, parent_id: int = 0) -> Dictionary:
	var precheck := _mutation_precheck()
	if not precheck.is_empty(): return {"error": precheck}
	# add_comment internally calls add_event (which triggers our override + flush).
	# Use depth guard to coalesce into a single flush.
	_flush_depth += 1
	var result := super.add_comment(item_id, author, text, parent_id)
	_flush_depth -= 1
	var flush_error := _flush_jsonl()
	if not flush_error.is_empty(): return {"error": flush_error}
	return result


func resolve_comment(comment_id: int, resolution: String, resolved_by: String) -> Dictionary:
	var precheck := _mutation_precheck()
	if not precheck.is_empty(): return {"error": precheck}
	# resolve_comment internally calls add_event.
	_flush_depth += 1
	var result := super.resolve_comment(comment_id, resolution, resolved_by)
	_flush_depth -= 1
	var flush_error := _flush_jsonl()
	if not flush_error.is_empty(): return {"error": flush_error}
	return result


# -- Saved queries ------------------------------------------------------------

func save_query(name: String, query_dict: Dictionary) -> void:
	if not _mutation_precheck().is_empty(): return
	super.save_query(name, query_dict)
	_flush_jsonl()


# -- Secrets ------------------------------------------------------------------

func init_vault(key: PackedByteArray, salt: PackedByteArray, iterations: int = VaultCrypto.PBKDF2_ITERATIONS) -> void:
	if not _mutation_precheck().is_empty(): return
	# init_vault calls set_meta_value three times internally.
	_flush_depth += 1
	super.init_vault(key, salt, iterations)
	_flush_depth -= 1
	_flush_jsonl()


func set_secret(handle: String, ciphertext: PackedByteArray, iv: PackedByteArray, mac: PackedByteArray, requires_2fa: bool = false, owner_item_id: String = "") -> void:
	if not _mutation_precheck().is_empty(): return
	super.set_secret(handle, ciphertext, iv, mac, requires_2fa, owner_item_id)
	_flush_jsonl()


func set_secret_owner(handle: String, owner_item_id: String) -> void:
	if not _mutation_precheck().is_empty(): return
	super.set_secret_owner(handle, owner_item_id)
	_flush_jsonl()


func rekey_secret(old_handle: String, new_handle: String) -> String:
	var precheck := _mutation_precheck()
	if not precheck.is_empty(): return precheck
	var err := super.rekey_secret(old_handle, new_handle)
	if err.is_empty():
		err = _flush_jsonl()
	return err


func delete_secret(handle: String) -> bool:
	if not _mutation_precheck().is_empty(): return false
	var result := super.delete_secret(handle)
	if result:
		_flush_jsonl()
	return result


func rotate_secret(handle: String, new_ct: PackedByteArray, new_iv: PackedByteArray, new_mac: PackedByteArray, rotated_by: String = "", requires_2fa: bool = false) -> void:
	if not _mutation_precheck().is_empty(): return
	# rotate_secret internally calls set_secret (which we override).
	_flush_depth += 1
	super.rotate_secret(handle, new_ct, new_iv, new_mac, rotated_by, requires_2fa)
	_flush_depth -= 1
	_flush_jsonl()


func set_secret_2fa(handle: String, requires: bool) -> void:
	if not _mutation_precheck().is_empty(): return
	super.set_secret_2fa(handle, requires)
	_flush_jsonl()


# -- Retrieval bump -----------------------------------------------------------

func bump_retrieval(id: String) -> void:
	if not _mutation_precheck().is_empty(): return
	super.bump_retrieval(id)
	_flush_jsonl()


func bump_retrieval_many(ids: Array) -> void:
	if not _mutation_precheck().is_empty(): return
	## ONE flush for the whole batch, not one per id.
	##
	## _flush_jsonl() re-serializes the ENTIRE database and atomically rewrites
	## the file, so a loop of N bumps costs N full rewrites of the whole store.
	## That is quadratic-feeling work on a read path, and it is not theoretical:
	## on 2026-08-16 a single unfiltered docket_hint_query matched all 276 hints
	## in a 9.3 MB / 11,385-record store and pinned the main thread at 100% CPU
	## for ~15 minutes doing 276 serializations. Because the MCP HTTP server is
	## polled from that same main loop, the server accepted no connections for
	## the duration — every other tool call in flight timed out.
	if ids.is_empty():
		return
	_flush_depth += 1
	super.bump_retrieval_many(ids)
	_flush_depth -= 1
	_flush_jsonl()


# -- Transition/error logs (NOT serialized to JSONL per spec) -----------------
# log_transition() and log_mcp_error() are intentionally NOT overridden.
# Per the JSONL format spec section 7, transition_log and mcp_error_log are
# ephemeral diagnostic data local to the SQLite cache.
