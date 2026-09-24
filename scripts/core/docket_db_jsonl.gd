extends DocketDB
class_name DocketDBJsonl
## DocketDB subclass that writes through to both SQLite (cache) and JSONL (canonical).
##
## JSONL is the source of truth; SQLite is a fast query cache.
## Mutations pass a source-freshness gate, update the disposable SQLite cache,
## then rewrite the entire JSONL file atomically.
##
## Writes to the file or the cache run within a SHARED coordination operation
## (CoordLease) that they own, from the freshness check through the commit,
## the file write and any cleanup after a failure; a mutation's operation
## belongs to its outermost level. When there is no operation to be had the
## write is refused, and so is opening, which may rebuild or migrate the cache.
## (Still without one: checkpointing a cache, also when closing it, setting
## its fingerprint directly, and the diagnostic logs log_transition and
## log_mcp_error write to it.)
##
## Opening flow:
##   1. If JSONL exists and cache is fresh → open cache via DocketDB.open()
##   2. If cache is stale or missing → rebuild from JSONL via JSONLCache
##   3. If neither exists → create new (fresh JSONL + SQLite cache)

var _jsonl_path: String
var last_write_error: String = ""
var _write_blocked: bool = false
var _allow_initial_write: bool = false
var _lock_timeout_ms: int = 5000
var _atomic_write_hook: Callable
var _mutation_depth: int = 0
var _mutation_error: String = ""
# The coordination operation (CoordLease) the outermost mutation holds. Only
# the connection's own thread can join it (DocketDBConnection).
var _mutation_operation: RefCounted = null
# True from a mutation's admission until it has released its operation. A
# change started meanwhile by something the mutation itself triggers (an
# items_changed listener during a reload, say) is refused rather than let it
# take over or drop the outer mutation's operation.
var _mutation_busy := false
# The step of the change through the transaction API (_canonical) that is
# rewriting the file, so a failed write reloads within it.
var _flushing_step: RefCounted = null
# items_changed (DocketDB) is reported once a mutation is committed AND
# saved to the file; a rollback or failed save reports nothing. A reload from
# the file (a change made outside this process, or docket_reload) is reported
# as [{id: "", event: "reloaded"}].

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

	# Opening may rebuild or migrate the cache, so it needs an operation too.
	var lease := CoordLease.shared()
	if lease.has("error"):
		last_open_error = lease.error
		push_error("DocketDBJsonl: %s" % last_open_error)
		return null
	var cache_db := _open_cache(path, cache_path, lease.operation)
	lease.operation.close()

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


static func _open_cache(path: String, cache_path: String, step: RefCounted) -> DocketDB:
	var cache_db: DocketDB
	if JSONLCache.is_cache_valid(path, cache_path):
		# Open cache directly — faster than rebuilding
		var temp_db := DocketDB.new()
		if temp_db.open(cache_path, step):
			cache_db = temp_db
		else:
			push_warning("DocketDBJsonl: stale cache, rebuilding from %s" % path)
			cache_db = JSONLCache.rebuild_cache(path, cache_path)
	else:
		cache_db = JSONLCache.rebuild_cache(path, cache_path)
	return cache_db


static func create_new_jsonl(path: String) -> DocketDBJsonl:
	## Create a brand-new JSONL-backed docket at the canonical `.dct` path.
	## Writes a 2.0 file with complete starter definitions and creates its cache.
	var lease := CoordLease.shared()
	if lease.has("error"):
		last_open_error = lease.error
		push_error("DocketDBJsonl: %s" % lease.error)
		return null
	var created := _create_new_jsonl(path, lease.operation)
	lease.operation.close()
	return created


static func _create_new_jsonl(path: String, step: RefCounted) -> DocketDBJsonl:
	var wrapper := DocketDBJsonl.new()
	wrapper._jsonl_path = path
	wrapper._allow_initial_write = true

	var cache_path := JSONLCache.cache_path_for_version(path, "2.0.0")

	# Create the SQLite cache via parent's create_new
	var cache_db := DocketDB.create_new(cache_path, step)
	if cache_db == null:
		push_error("DocketDBJsonl: failed to create cache at %s" % cache_path)
		return null

	# Transfer ownership
	wrapper._adopt(cache_db)
	var canonical_name: String = path.get_file().get_basename()
	var naming_error: String = ""
	if not canonical_name.is_empty():
		naming_error = wrapper._exec_checked("INSERT OR REPLACE INTO docket_meta(key,value) VALUES('project',?);", [canonical_name])
		if naming_error.is_empty(): naming_error = wrapper._exec_checked("INSERT OR REPLACE INTO docket_meta(key,value) VALUES('id_prefix',?);", [DocketDB._derive_prefix(canonical_name)])
	if not naming_error.is_empty():
		wrapper.last_write_error = naming_error
		wrapper.close()
		return null
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
	# Refused (DocketDB.close_checked) while a mutation is in progress. Durable
	# mutations already replace canonical JSONL before reporting success, so
	# close only releases the disposable cache: read-only sessions and rejected
	# operations cannot normalize or rewrite source bytes as a side effect.
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
	if _mutation_depth > 0:
		return false
	if not is_stale():
		return false
	return reload()


func reload(report_change: bool = true, parent: RefCounted = null) -> bool:
	## Force a rebuild of the SQLite cache from the canonical JSONL file,
	## discarding cached state. Returns true on success. Within `parent` (a
	## coordination operation) when given, else in an operation of its own.
	if _mutation_depth > 0 or _jsonl_path.is_empty():
		return false
	var lease := CoordLease.shared(parent)
	if lease.has("error"):
		last_write_error = lease.error
		return false
	var reloaded := _reload(lease.operation, report_change)
	lease.operation.close()
	return reloaded


func _reload(step: RefCounted, report_change: bool) -> bool:
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
		if fallback.open(cache_path, step):
			_adopt(fallback)
		_write_blocked = true
		last_write_error = "canonical reload failed; cached data is read-only"
		return false

	_adopt(fresh)
	last_open_error = ""
	if report_change:
		items_changed.emit([{"id": "", "event": "reloaded"}])
	return true


func flush() -> void:
	## Force a JSONL write. Public counterpart to the internal _flush_jsonl().
	flush_checked()

func flush_checked() -> String:
	## An empty result inside a nested mutation means the flush is deferred; the
	## outermost completion remains responsible for durable commit and errors.
	var error := CoordLease.run(func(_step: RefCounted) -> String: return _flush_jsonl())
	if not error.is_empty(): last_write_error = error
	return error


func _adopt(source: DocketDB) -> void:
	## Take ownership of source's SQLite connection, detaching it from source
	## so its destructor cannot close the handle we now hold.
	_db = source._db
	_path = source._path
	_owner_thread = source._owner_thread
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


# Before the outermost change: "" or why the project cannot be changed now.
# A stale cache is reloaded first, within `step`.
func _mutation_precheck(step: RefCounted) -> String:
	if _write_blocked: return last_write_error
	if not FileAccess.file_exists(_jsonl_path) and not _allow_initial_write:
		_write_blocked = true
		last_write_error = "canonical source is missing; project is read-only"
		return last_write_error
	if is_stale() and not reload(true, step):
		_write_blocked = true
		if last_write_error.is_empty(): last_write_error = "canonical source could not be reloaded"
		return last_write_error
	return ""


## A canonical mutation is a change in progress too (DocketDB).
func _change_in_progress() -> bool:
	return super() or _mutation_depth > 0


func _begin_canonical_mutation() -> String:
	var refusal := _thread_refusal()
	if not refusal.is_empty(): return refusal
	if _mutation_depth > 0 and (not _mutation_error.is_empty() or not _last_sql_error.is_empty()):
		return _mutation_error if not _mutation_error.is_empty() else _last_sql_error
	if _mutation_depth == 0:
		if _mutation_busy: return "another change to this project is in progress"
		# Held from before the freshness check until the outermost completion.
		var lease := CoordLease.shared()
		if lease.has("error"): return lease.error
		_mutation_busy = true
		_mutation_operation = lease.operation
		var precheck := _mutation_precheck(_mutation_operation)
		if not precheck.is_empty():
			_close_mutation_operation()
			return precheck
		_last_sql_error = ""
		_pending_changes = []
		_mutation_error = _exec_checked("BEGIN TRANSACTION;")
		if not _mutation_error.is_empty():
			_close_mutation_operation()
			return _mutation_error
	_mutation_depth += 1
	return ""


func _complete_canonical_mutation(error: String = "") -> String:
	if not error.is_empty() and _mutation_error.is_empty(): _mutation_error = error
	if not _last_sql_error.is_empty() and _mutation_error.is_empty(): _mutation_error = _last_sql_error
	_mutation_depth -= 1
	if _mutation_depth > 0: return _mutation_error
	if _mutation_error.is_empty(): _mutation_error = _exec_checked("COMMIT;")
	if not _mutation_error.is_empty():
		var failed := _mutation_error
		_rollback()
		reload(is_stale(), _mutation_operation)  # reports another writer's change it adopts, not ours
		last_write_error = failed
		_mutation_error = ""
		_close_mutation_operation()
		return failed
	var flush_error := _flush_jsonl()
	_mutation_error = ""
	# Listeners hear of the change only once the operation is given back, so
	# one that makes a change of its own starts it as a separate operation.
	_close_mutation_operation()
	if flush_error.is_empty():
		super._report_changes()
	else:
		_pending_changes = []
	return flush_error


# -- Canonical changes through the transaction API --------------------------
#
# A change runs `work` (called with its step, returning a Dictionary with an
# "error" entry) within a step of `op`, in a transaction that the cache and
# the canonical file share: the outermost change checks the file's freshness
# first, and once the transaction has committed rewrites the file, still
# within its step. A nested change (a call the outer one makes, such as
# deleting an item's vault entries) joins the transaction and leaves the file
# to the outermost. Changes are reported after the file is written and the
# step given back; a rollback or a failed write reports none.

func _canonical(op: RefCounted, work: Callable) -> Dictionary:
	var result: Variant = _writing(op, _canonical_step.bind(work))
	if not result is Dictionary: return {"error": _last_sql_error}
	if not _change_in_progress():
		if str(result.error).is_empty(): super._report_changes()
		else: _pending_changes = []
	return result


func _canonical_step(step: RefCounted, work: Callable) -> Dictionary:
	var outermost := not _change_in_progress()
	if outermost:
		# A listener of this change's own reload cannot start another one.
		if _mutation_busy: return {"error": "another change to this project is in progress"}
		_mutation_busy = true
		var precheck := _mutation_precheck(step)
		if not precheck.is_empty():
			_mutation_busy = false
			return {"error": precheck}
	var txn := _begin_transaction(step)
	if txn.has("error"):
		if outermost: _mutation_busy = false
		return {"error": txn.error}
	var result: Dictionary = work.call(step)
	result.error = _complete_transaction(step, txn.ticket, str(result.get("error", "")))
	if not outermost: return result
	if str(result.error).is_empty():
		_flushing_step = step
		result.error = _flush_jsonl()
		_flushing_step = null
	else:
		# The cache is rebuilt from the file; only a newer file from another
		# writer is reported.
		reload(is_stale(), step)
		last_write_error = result.error
	_mutation_busy = false
	return result


func _close_mutation_operation() -> void:
	if _mutation_operation != null:
		_mutation_operation.close()
		_mutation_operation = null
	_mutation_busy = false


## Held until _complete_canonical_mutation has saved the file.
func _report_changes() -> void:
	pass


func apply_registry_change(type_def: Dictionary, revision: Dictionary, item_bindings: Array, events: Array, expected_current_revision: String) -> String:
	## One checked cache transaction stages the immutable snapshot, current
	## pointer, item pins, and audit events before one canonical replacement.
	return CoordLease.run(_apply_registry_change.bind(type_def, revision, item_bindings, events, expected_current_revision))


func _apply_registry_change(step: RefCounted, type_def: Dictionary, revision: Dictionary, item_bindings: Array, events: Array, expected_current_revision: String) -> String:
	var error := _mutation_precheck(step)
	if not error.is_empty(): return error
	_last_sql_error = ""
	if JSONLParser._parse_type_def(type_def).is_empty() or JSONLParser._parse_type_def_version(revision).is_empty(): return "incomplete type definition snapshot"
	if str(type_def.get("id", "")) != str(revision.get("type_id", "")): return "revision belongs to another type"
	var expected_revision_id: String = "%s@%s" % [revision.type_id, TypeRegistryBootstrap._definition_hash(revision.definition)]
	if str(revision.id) != expected_revision_id: return "revision id does not match canonical definition digest"
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
	if not _last_sql_error.is_empty(): return _last_sql_error
	error = _begin_canonical_mutation()
	if not error.is_empty(): return error
	if error.is_empty():
		if existing.is_empty(): error = _exec_checked("INSERT INTO type_defs (id,slug,lifecycle,current_revision,provenance_json) VALUES (?,?,?,?,?);", [type_def.id, type_def.slug, type_def.lifecycle, type_def.current_revision, JSON.stringify(type_def.provenance, "", true, true)])
	if error.is_empty(): error = _exec_checked("INSERT INTO type_def_versions (id,type_id,parent_revision,definition_json,author,created_at,reason) VALUES (?,?,?,?,?,?,?);", [revision.id, revision.type_id, revision.get("parent_revision", null), JSON.stringify(revision.definition, "", true, true), revision.author, revision.created_at, revision.reason])
	if error.is_empty() and not existing.is_empty(): error = _exec_checked("UPDATE type_defs SET lifecycle=?,current_revision=?,provenance_json=? WHERE id=? AND current_revision=?;", [type_def.lifecycle, type_def.current_revision, JSON.stringify(type_def.provenance, "", true, true), type_def.id, expected_current_revision])
	for binding in item_bindings:
		if not error.is_empty(): break
		if binding.has("changes"):
			error = update_item_fields_checked(str(binding.item_id), binding.changes)
			if not error.is_empty(): break
		error = _exec_checked("UPDATE items SET type=?,type_id=?,type_revision=? WHERE id=?;", [type_def.slug, binding.type_id, binding.type_revision, binding.item_id])
	for event in events:
		if not error.is_empty(): break
		error = _exec_checked("INSERT INTO item_events (item_id,event_type,actor,timestamp,note) VALUES (?,?,?,?,?);", [event.item_id, event.event_type, event.get("actor", ""), event.timestamp, event.get("note", "")])
		_record_change(str(event.item_id), str(event.event_type))
	return _complete_canonical_mutation(error)


# -- JSONL write-through ------------------------------------------------------

func _flush_jsonl() -> String:
	## Serialize current DB state to JSONL and write atomically.
	## Nested mutations defer serialization until their outer transaction commits.
	## Acquires the supported advisory sidecar before writing and validates the
	## canonical content again after acquisition.
	if _jsonl_path.is_empty():
		return "canonical path is empty"
	if _mutation_depth > 0:
		return ""  # We're inside a compound mutation — will flush when outermost returns
	if _write_blocked:
		return last_write_error
	if not FileAccess.file_exists(_jsonl_path) and not _allow_initial_write:
		return _fail_flush("canonical source is missing; refusing to recreate it from cache")
	if FileAccess.file_exists(_jsonl_path) and is_stale():
		return _fail_flush("canonical source changed; reload before writing")
	_last_sql_error = ""
	var expected_source_hash := super.get_meta_value("jsonl_hash", "")
	var cache_error := _validate_cache_for_flush()
	if not cache_error.is_empty(): return _fail_flush(cache_error)

	var jsonl_text := JSONLSerializer.serialize_all(self)
	if not _last_sql_error.is_empty():
		return _fail_flush("cache read failed during serialization: %s" % _last_sql_error)
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
		# a failed compound write cannot leak into a later successful flush. The
		# failed change is not reported; another writer's change it adopts is.
		reload(is_stale(), _flushing_step if _flushing_step != null else _mutation_operation)
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
	return CoordLease.run(_insert_item.bind(id, item))


func _insert_item(step: RefCounted, id: String, item: Dictionary) -> String:
	var source_error := _mutation_precheck(step)
	if not source_error.is_empty(): return source_error
	var candidate := item.duplicate(true)
	if super.get_meta_value("jsonl_version", "1.0.0") == "2.0.0" and (not candidate.has("type_id") or not candidate.has("type_revision")):
		var rows := _exec_select("SELECT id,current_revision FROM type_defs WHERE slug=?;", [candidate.get("type", "")])
		if rows.size() != 1: return "type '%s' has no active project definition" % candidate.get("type", "")
		candidate["type_id"] = rows[0].id
		candidate["type_revision"] = rows[0].current_revision
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return precheck
	var result := super.insert_item(id, candidate)
	return _complete_canonical_mutation(result)


func update_item_fields(id: String, changes: Dictionary) -> void:
	update_item_fields_checked(id, changes)


func update_item_fields_checked(id: String, changes: Dictionary) -> String:
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return precheck
	var error := super.update_item_fields_checked(id, changes)
	return _complete_canonical_mutation(error)


func set_item_field(id: String, field: String, val) -> void:
	set_item_field_checked(id, field, val)

func set_item_field_checked(id: String, field: String, val) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.set_item_field(id, field, val)
	return _complete_canonical_mutation()


func delete_item_checked(id: String, op: RefCounted = null) -> String:
	return str(_canonical(op, _delete_item_in_cache.bind(id)).error)


# The deletion's own vault-entry deletions come back through
# delete_secret_checked below and join its transaction.
func _delete_item_in_cache(step: RefCounted, id: String) -> Dictionary:
	return {"error": super.delete_item_checked(id, step)}


func import_item_full(new_id: String, exported: Dictionary) -> void:
	import_item_full_checked(new_id, exported)


func import_item_full_checked(new_id: String, exported: Dictionary) -> String:
	var comments: Variant = exported.get("comments", [])
	if not comments is Array: return "import comments must be an array"
	for value in comments:
		if not value is Dictionary: return "import comments must be objects"
		var comment: Dictionary = value
		if int(comment.get("id", 0)) <= 0 or str(comment.get("created_at", "")).is_empty(): return "import comment is missing id or created_at"
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return precheck
	super.import_item_full(new_id, exported)
	return _complete_canonical_mutation()


func rewrite_refs(old_qualified: String, new_qualified: String, old_bare_id: String, new_qualified_for_bare: String, rewrite_bare: bool = true) -> int:
	var result := rewrite_refs_checked(old_qualified, new_qualified, old_bare_id, new_qualified_for_bare, rewrite_bare)
	if not str(result.error).is_empty(): last_write_error = str(result.error)
	return int(result.count)


func rewrite_refs_checked(old_qualified: String, new_qualified: String, old_bare_id: String, new_qualified_for_bare: String, rewrite_bare: bool = true) -> Dictionary:
	var begin_error := _begin_canonical_mutation()
	if not begin_error.is_empty(): return {"count": 0, "error": begin_error}
	var count := super.rewrite_refs(old_qualified, new_qualified, old_bare_id, new_qualified_for_bare, rewrite_bare)
	var error := _complete_canonical_mutation()
	return {"count": count if error.is_empty() else 0, "error": error}


# -- ID generation (mutates counter) -----------------------------------------

func next_id() -> String:
	var checked := next_id_checked()
	return str(checked.id) if str(checked.error).is_empty() else ""


func next_id_checked() -> Dictionary:
	var begin_error := _begin_canonical_mutation()
	if not begin_error.is_empty(): return {"id": "", "error": begin_error}
	var result := super.next_id()
	var error := _complete_canonical_mutation()
	return {"id": result if error.is_empty() else "", "error": error}


# next_uuid7_id() does NOT mutate the counter — it's stateless. No override needed.


# -- Meta mutations -----------------------------------------------------------

func set_meta_value(meta_key: String, val: String) -> void:
	set_meta_value_checked(meta_key, val)

func set_meta_value_checked(meta_key: String, val: String) -> String:
	# Avoid infinite recursion: _flush_jsonl calls set_meta_value("jsonl_hash", ...)
	if meta_key == "jsonl_hash":
		super.set_meta_value(meta_key, val)
		return _last_sql_error
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.set_meta_value(meta_key, val)
	return _complete_canonical_mutation()


func set_id_prefix(prefix: String) -> void:
	set_id_prefix_checked(prefix)

func set_id_prefix_checked(prefix: String) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.set_id_prefix(prefix)
	return _complete_canonical_mutation()


func set_project_name(name: String) -> void:
	set_project_name_checked(name)

func set_project_name_checked(name: String) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.set_project_name(name)
	return _complete_canonical_mutation()


func set_project_meta(meta: Dictionary) -> void:
	set_project_meta_checked(meta)


func set_project_meta_checked(meta: Dictionary) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.set_project_meta(meta)
	return _complete_canonical_mutation()


func set_counter(val: int) -> void:
	set_counter_checked(val)

func set_counter_checked(val: int) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.set_counter(val)
	return _complete_canonical_mutation()


# -- Events -------------------------------------------------------------------

func add_event(item_id: String, event_type: String, actor: String, note: String = "") -> void:
	add_event_checked(item_id, event_type, actor, note)


func add_event_checked(item_id: String, event_type: String, actor: String, note: String = "") -> String:
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return precheck
	super.add_event(item_id, event_type, actor, note)
	return _complete_canonical_mutation()


# -- Links --------------------------------------------------------------------

func add_link(from_id: String, to_id: String, relation: String) -> void:
	add_link_checked(from_id, to_id, relation)


func add_link_checked(from_id: String, to_id: String, relation: String) -> String:
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return precheck
	super.add_link(from_id, to_id, relation)
	return _complete_canonical_mutation()


# -- Attachments --------------------------------------------------------------

func attach_file(item_id: String, filename: String, data: PackedByteArray, mime: String = "application/octet-stream", desc: String = "") -> Dictionary:
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return {"error": precheck}
	var result := super.attach_file(item_id, filename, data, mime, desc)
	var flush_error := _complete_canonical_mutation(str(result.get("error", "")))
	if not flush_error.is_empty(): return {"error": flush_error}
	return result


func detach_file(att_id: int) -> void:
	detach_file_checked(att_id)


func detach_file_checked(att_id: int) -> String:
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return precheck
	super.detach_file(att_id)
	return _complete_canonical_mutation()


# -- Comments -----------------------------------------------------------------

func add_comment(item_id: String, author: String, text: String, parent_id: int = 0) -> Dictionary:
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return {"error": precheck}
	# add_comment internally calls add_event (which triggers our override + flush).
	# One transaction and depth guard make the comment, event and item timestamp
	# one persistence unit.
	var result := super.add_comment(item_id, author, text, parent_id)
	var flush_error := _complete_canonical_mutation(str(result.get("error", "")))
	if not flush_error.is_empty(): return {"error": flush_error}
	return result


func resolve_comment(comment_id: int, resolution: String, resolved_by: String) -> Dictionary:
	var begin_error := _begin_canonical_mutation()
	if not begin_error.is_empty(): return {"error": begin_error}
	var result := super.resolve_comment(comment_id, resolution, resolved_by)
	var flush_error := _complete_canonical_mutation(str(result.get("error", "")))
	if not flush_error.is_empty(): return {"error": flush_error}
	return result


# -- Saved queries ------------------------------------------------------------

func save_query(name: String, query_dict: Dictionary) -> void:
	save_query_checked(name, query_dict)

func save_query_checked(name: String, query_dict: Dictionary) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.save_query(name, query_dict)
	return _complete_canonical_mutation()


# -- Secrets ------------------------------------------------------------------

func init_vault(key: PackedByteArray, salt: PackedByteArray, iterations: int = VaultCrypto.PBKDF2_ITERATIONS) -> void:
	init_vault_checked(key, salt, iterations)


func init_vault_checked(key: PackedByteArray, salt: PackedByteArray, iterations: int = VaultCrypto.PBKDF2_ITERATIONS) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.init_vault(key, salt, iterations)
	return _complete_canonical_mutation()


func set_secret(handle: String, ciphertext: PackedByteArray, iv: PackedByteArray, mac: PackedByteArray, requires_2fa: bool = false, owner_item_id: String = "") -> void:
	set_secret_checked(handle, ciphertext, iv, mac, requires_2fa, owner_item_id)

func set_secret_checked(handle: String, ciphertext: PackedByteArray, iv: PackedByteArray, mac: PackedByteArray, requires_2fa: bool = false, owner_item_id: String = "") -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.set_secret(handle, ciphertext, iv, mac, requires_2fa, owner_item_id)
	return _complete_canonical_mutation()


func set_secret_owner(handle: String, owner_item_id: String) -> void:
	set_secret_owner_checked(handle, owner_item_id)

func set_secret_owner_checked(handle: String, owner_item_id: String) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.set_secret_owner(handle, owner_item_id)
	return _complete_canonical_mutation()


func rekey_secret(old_handle: String, new_handle: String) -> String:
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return precheck
	var err := super.rekey_secret(old_handle, new_handle)
	return _complete_canonical_mutation(err)


func delete_secret_checked(handle: String, op: RefCounted = null) -> Dictionary:
	var result := _canonical(op, _delete_secret_in_cache.bind(handle))
	return {"deleted": bool(result.get("deleted", false)) and str(result.error).is_empty(), "error": result.error}


func _delete_secret_in_cache(step: RefCounted, handle: String) -> Dictionary:
	return super.delete_secret_checked(handle, step)


func rotate_secret(handle: String, new_ct: PackedByteArray, new_iv: PackedByteArray, new_mac: PackedByteArray, rotated_by: String = "", requires_2fa: bool = false) -> void:
	rotate_secret_checked(handle, new_ct, new_iv, new_mac, rotated_by, requires_2fa)

func rotate_secret_checked(handle: String, new_ct: PackedByteArray, new_iv: PackedByteArray, new_mac: PackedByteArray, rotated_by: String = "", requires_2fa: bool = false) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.rotate_secret(handle, new_ct, new_iv, new_mac, rotated_by, requires_2fa)
	return _complete_canonical_mutation()


func rewrap_vault(old_key: PackedByteArray, new_key: PackedByteArray) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	return _complete_canonical_mutation(_rewrap_vault_rows(old_key, new_key))


# -- Retrieval bump -----------------------------------------------------------

func bump_retrieval(id: String) -> void:
	bump_retrieval_checked(id)

func bump_retrieval_checked(id: String) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.bump_retrieval(id)
	return _complete_canonical_mutation()


func bump_retrieval_many(ids: Array) -> void:
	bump_retrieval_many_checked(ids)

func bump_retrieval_many_checked(ids: Array) -> String:
	## The batch shares one cache transaction and one canonical serialization.
	if ids.is_empty():
		return ""
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.bump_retrieval_many(ids)
	return _complete_canonical_mutation()


# -- Transition/error logs (NOT serialized to JSONL per spec) -----------------
# log_transition() and log_mcp_error() are intentionally NOT overridden.
# Per the JSONL format spec section 7, transition_log and mcp_error_log are
# ephemeral diagnostic data local to the SQLite cache.
