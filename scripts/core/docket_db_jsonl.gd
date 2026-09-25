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
## (A cache rebuild's writes take operations of their own.)
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
# True from an outermost change's admission until it has finished with the
# file. A change started meanwhile by something the change itself triggers
# (an items_changed listener during a reload, say) is refused.
var _mutation_busy := false
# The step of the change or flush (_flush_within) that is rewriting the file,
# so a failed write reloads within it; null when _flush_jsonl is called
# directly, its writes then taking operations of their own.
var _flushing_step: RefCounted = null

# items_changed (DocketDB) is reported once a change is committed AND
# saved to the file; a rollback or failed save reports nothing. A reload from
# the file (a change made outside this process, or docket_reload) is reported
# as [{id: "", event: "reloaded"}].

# Reason the most recent open_jsonl() returned null (e.g. unresolved conflict
# markers). Read immediately after a null return.
static var last_open_error: String = ""


func _flush_within(step: RefCounted) -> String:
	_flushing_step = step
	var error := _flush_jsonl()
	_flushing_step = null
	return error


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
	var initial_write_error := wrapper._flush_within(step)
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
	## No-op mid-mutation: a compound write is not a safe point to swap the DB,
	## nor is another thread than the connection's.
	if not _thread_refusal().is_empty() or _change_in_progress():
		return false
	if not is_stale():
		return false
	return reload()


func reload(report_change: bool = true, parent: RefCounted = null) -> bool:
	## Force a rebuild of the SQLite cache from the canonical JSONL file,
	## discarding cached state. Returns true on success. Within `parent` (a
	## coordination operation) when given, else in an operation of its own.
	if not _thread_refusal().is_empty() or _change_in_progress() or _jsonl_path.is_empty():
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
	var error := CoordLease.run(_flush_within)
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
	if not result is Dictionary: return _refused(result)
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
		result.error = _flush_within(step)
	else:
		# The cache is rebuilt from the file; only a newer file from another
		# writer is reported.
		reload(is_stale(), step)
		last_write_error = result.error
	_mutation_busy = false
	return result


## Held until the change has saved the file (_canonical).
func _report_changes() -> void:
	pass


## A type revision, the type's current pointer, item pins and audit events,
## as one change within a step of `op` (or an operation of its own): "" or
## why not, and then none of it is kept.
func apply_registry_change(type_def: Dictionary, revision: Dictionary, item_bindings: Array, events: Array, expected_current_revision: String, op: RefCounted = null) -> String:
	return run_change(op, _apply_registry_change.bind(type_def, revision, item_bindings, events, expected_current_revision))


func _apply_registry_change(step: RefCounted, type_def: Dictionary, revision: Dictionary, item_bindings: Array, events: Array, expected_current_revision: String) -> String:
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
	var error := ""
	if existing.is_empty(): error = _write_checked(step, "INSERT INTO type_defs (id,slug,lifecycle,current_revision,provenance_json) VALUES (?,?,?,?,?);", [type_def.id, type_def.slug, type_def.lifecycle, type_def.current_revision, JSON.stringify(type_def.provenance, "", true, true)])
	if error.is_empty(): error = _write_checked(step, "INSERT INTO type_def_versions (id,type_id,parent_revision,definition_json,author,created_at,reason) VALUES (?,?,?,?,?,?,?);", [revision.id, revision.type_id, revision.get("parent_revision", null), JSON.stringify(revision.definition, "", true, true), revision.author, revision.created_at, revision.reason])
	if error.is_empty() and not existing.is_empty(): error = _write_checked(step, "UPDATE type_defs SET lifecycle=?,current_revision=?,provenance_json=? WHERE id=? AND current_revision=?;", [type_def.lifecycle, type_def.current_revision, JSON.stringify(type_def.provenance, "", true, true), type_def.id, expected_current_revision])
	for binding in item_bindings:
		if not error.is_empty(): return error
		if binding.has("changes"): error = update_item_fields_checked(str(binding.item_id), binding.changes, step)
		if error.is_empty(): error = _write_checked(step, "UPDATE items SET type=?,type_id=?,type_revision=? WHERE id=?;", [type_def.slug, binding.type_id, binding.type_revision, binding.item_id])
	for event in events:
		if not error.is_empty(): return error
		error = _write_checked(step, "INSERT INTO item_events (item_id,event_type,actor,timestamp,note) VALUES (?,?,?,?,?);", [event.item_id, event.event_type, event.get("actor", ""), event.timestamp, event.get("note", "")])
		if error.is_empty(): _record_change(step, str(event.item_id), str(event.event_type))
	return error


# -- JSONL write-through ------------------------------------------------------

func _flush_jsonl() -> String:
	## Serialize current DB state to JSONL and write atomically.
	## Nested mutations defer serialization until their outer transaction commits.
	## Acquires the supported advisory sidecar before writing and validates the
	## canonical content again after acquisition.
	if _jsonl_path.is_empty():
		return "canonical path is empty"
	if _change_in_progress():
		return ""  # Inside a change: the outermost writes the file once it has committed
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
		super.set_meta_value_checked("jsonl_hash", fingerprint, _flushing_step)
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
		reload(is_stale(), _flushing_step)
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

# A change made through run_change (DocketDB) is a canonical one: its
# transaction is the cache's, and the file is rewritten once it commits.
func _change(op: RefCounted, work: Callable) -> Dictionary:
	return _canonical(op, work)


# An item of a format 2.0 project is pinned to its type's current revision
# unless it names one, as read within the change.
func _insert_item(step: RefCounted, id: String, item: Dictionary) -> String:
	var candidate := item.duplicate(true)
	if super.get_meta_value("jsonl_version", "1.0.0") == "2.0.0" and (not candidate.has("type_id") or not candidate.has("type_revision")):
		var rows := _exec_select("SELECT id,current_revision FROM type_defs WHERE slug=?;", [candidate.get("type", "")])
		if rows.size() != 1: return "type '%s' has no active project definition" % candidate.get("type", "")
		candidate["type_id"] = rows[0].id
		candidate["type_revision"] = rows[0].current_revision
	return super._insert_item(step, id, candidate)


func delete_item_checked(id: String, op: RefCounted = null) -> String:
	return str(_canonical(op, _delete_item_in_cache.bind(id)).error)


# The deletion's own vault-entry deletions come back through
# delete_secret_checked below and join its transaction.
func _delete_item_in_cache(step: RefCounted, id: String) -> Dictionary:
	return {"error": super.delete_item_checked(id, step)}


func import_item_full_checked(new_id: String, exported: Dictionary, op: RefCounted = null) -> String:
	var comments: Variant = exported.get("comments", [])
	if not comments is Array: return "import comments must be an array"
	for value in comments:
		if not value is Dictionary: return "import comments must be objects"
		var comment: Dictionary = value
		if int(comment.get("id", 0)) <= 0 or str(comment.get("created_at", "")).is_empty(): return "import comment is missing id or created_at"
	return str(_canonical(op, _import_item_full_in_cache.bind(new_id, exported)).error)


func _import_item_full_in_cache(step: RefCounted, new_id: String, exported: Dictionary) -> Dictionary:
	return {"error": super.import_item_full_checked(new_id, exported, step)}


# -- ID generation (mutates counter) -----------------------------------------

func next_id_checked(op: RefCounted = null) -> Dictionary:
	var result := _canonical(op, _next_id_in_cache)
	return {"id": str(result.get("id", "")) if str(result.error).is_empty() else "", "error": result.error}


func _next_id_in_cache(step: RefCounted) -> Dictionary:
	return super.next_id_checked(step)


# next_uuid7_id() does NOT mutate the counter — it's stateless. No override needed.


# -- Meta mutations -----------------------------------------------------------

# set_project_name_checked and set_id_prefix_checked (DocketDB) come here too.
func set_meta_value_checked(meta_key: String, val: String, op: RefCounted = null) -> String:
	# The cache's fingerprint of the file, written while the file is being
	# written: not a project change of its own.
	if meta_key == "jsonl_hash":
		return super.set_meta_value_checked(meta_key, val, op)
	return str(_canonical(op, _set_meta_value_in_cache.bind(meta_key, val)).error)


func _set_meta_value_in_cache(step: RefCounted, meta_key: String, val: String) -> Dictionary:
	return {"error": super.set_meta_value_checked(meta_key, val, step)}


func set_project_meta_checked(meta: Dictionary, op: RefCounted = null) -> String:
	return str(_canonical(op, _set_project_meta_in_cache.bind(meta)).error)


func _set_project_meta_in_cache(step: RefCounted, meta: Dictionary) -> Dictionary:
	return {"error": super.set_project_meta_checked(meta, step)}


func set_counter_checked(val: int, op: RefCounted = null) -> String:
	return str(_canonical(op, _set_counter_in_cache.bind(val)).error)


func _set_counter_in_cache(step: RefCounted, val: int) -> Dictionary:
	return {"error": super.set_counter_checked(val, step)}


# -- Attachments --------------------------------------------------------------

func attach_file(item_id: String, filename: String, data: PackedByteArray, mime: String = "application/octet-stream", desc: String = "", op: RefCounted = null, actor: String = "") -> Dictionary:
	# Refused before any change starts (DocketDB checks it too).
	if data.size() > MAX_ATTACHMENT_BYTES: return super.attach_file(item_id, filename, data, mime, desc, op, actor)
	var result := _canonical(op, _attach_file_in_cache.bind(item_id, filename, data, mime, desc, actor))
	if not str(result.error).is_empty(): return {"error": result.error}
	result.erase("error")
	return result


func _attach_file_in_cache(step: RefCounted, item_id: String, filename: String, data: PackedByteArray, mime: String, desc: String, actor: String) -> Dictionary:
	var result := super.attach_file(item_id, filename, data, mime, desc, step, actor)
	if not result.has("error"): result["error"] = ""
	return result


func detach_file_checked(att_id: int, op: RefCounted = null) -> String:
	return str(_canonical(op, _detach_file_in_cache.bind(att_id)).error)


func _detach_file_in_cache(step: RefCounted, att_id: int) -> Dictionary:
	return {"error": super.detach_file_checked(att_id, step)}


# -- Saved queries ------------------------------------------------------------

func save_query_checked(name: String, query_dict: Dictionary, op: RefCounted = null) -> String:
	return str(_canonical(op, _save_query_in_cache.bind(name, query_dict)).error)


func _save_query_in_cache(step: RefCounted, name: String, query_dict: Dictionary) -> Dictionary:
	return {"error": super.save_query_checked(name, query_dict, step)}


# -- Secrets ------------------------------------------------------------------

func init_vault_checked(key: PackedByteArray, salt: PackedByteArray, iterations: int = VaultCrypto.PBKDF2_ITERATIONS, op: RefCounted = null) -> String:
	return str(_canonical(op, _init_vault_in_cache.bind(key, salt, iterations)).error)


func _init_vault_in_cache(step: RefCounted, key: PackedByteArray, salt: PackedByteArray, iterations: int) -> Dictionary:
	return {"error": super.init_vault_checked(key, salt, iterations, step)}


func set_secret_owner_checked(handle: String, owner_item_id: String, op: RefCounted = null) -> String:
	return str(_canonical(op, _set_secret_owner_in_cache.bind(handle, owner_item_id)).error)


func _set_secret_owner_in_cache(step: RefCounted, handle: String, owner_item_id: String) -> Dictionary:
	return {"error": super.set_secret_owner_checked(handle, owner_item_id, step)}


func rekey_secret(old_handle: String, new_handle: String, op: RefCounted = null) -> String:
	return str(_canonical(op, _rekey_secret_in_cache.bind(old_handle, new_handle)).error)


func _rekey_secret_in_cache(step: RefCounted, old_handle: String, new_handle: String) -> Dictionary:
	return {"error": super.rekey_secret(old_handle, new_handle, step)}


func delete_secret_checked(handle: String, op: RefCounted = null) -> Dictionary:
	var result := _canonical(op, _delete_secret_in_cache.bind(handle))
	return {"deleted": bool(result.get("deleted", false)) and str(result.error).is_empty(), "error": result.error}


func _delete_secret_in_cache(step: RefCounted, handle: String) -> Dictionary:
	return super.delete_secret_checked(handle, step)


func rewrap_vault(old_key: PackedByteArray, new_key: PackedByteArray, op: RefCounted = null) -> String:
	return str(_canonical(op, _rewrap_vault_in_cache.bind(old_key, new_key)).error)


func _rewrap_vault_in_cache(step: RefCounted, old_key: PackedByteArray, new_key: PackedByteArray) -> Dictionary:
	return {"error": super.rewrap_vault(old_key, new_key, step)}


# -- Retrieval bump -----------------------------------------------------------

func bump_retrieval_checked(id: String, op: RefCounted = null) -> String:
	return str(_canonical(op, _bump_retrieval_in_cache.bind(id)).error)


func _bump_retrieval_in_cache(step: RefCounted, id: String) -> Dictionary:
	return {"error": super.bump_retrieval_checked(id, step)}



## The batch shares one cache transaction and one file rewrite.
func bump_retrieval_many_checked(ids: Array, op: RefCounted = null) -> String:
	if ids.is_empty(): return ""
	return str(_canonical(op, _bump_retrieval_many_in_cache.bind(ids)).error)


func _bump_retrieval_many_in_cache(step: RefCounted, ids: Array) -> Dictionary:
	return {"error": super.bump_retrieval_many_checked(ids, step)}


# -- Transition/error logs (NOT serialized to JSONL per spec) -----------------
# log_transition() and log_mcp_error() are intentionally NOT overridden.
# Per the JSONL format spec section 7, transition_log and mcp_error_log are
# ephemeral diagnostic data local to the SQLite cache.
