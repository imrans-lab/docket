extends DocketDB
class_name DocketDBJsonl
## DocketDB subclass that writes through to both SQLite (cache) and JSONL (canonical).
##
## JSONL is the source of truth; SQLite is a fast query cache.
## Mutations pass a source-freshness gate and stage their rows in a
## transaction on the disposable SQLite cache; the outermost one appends one
## record to the write-ahead sidecar (JSONLSidecar, beside the canonical) and
## commits the transaction under one FileLock hold. The canonical is rewritten
## atomically only when it settles: on an idle debounce (settle_projects), on
## close() with pending records, on File → Save (settle_in_background), on
## flush() (docket_flush), on open when a sidecar survived, and at once for
## changes the sidecar does not journal (type registry, secrets, saved queries).
##
## The debounce and File → Save settle in the background (JSONLSettleJob): the
## cache is read on the main thread (in per-tick slices when
## snapshot_slice_ms >= 0), formatting and the temp-file write run on a
## worker, and the rename commits on a later main-thread tick. Every other
## settle is synchronous and first waits for a background one to commit.
##
## Opening flow:
##   1. If JSONL exists and cache is fresh → open cache via DocketDB.open()
##   2. If cache is stale or missing → rebuild from JSONL + sidecar via JSONLCache
##   3. If neither exists → create new (fresh JSONL + SQLite cache)
##   4. A non-empty sidecar is then compacted into the canonical
##
## Ephemeral items (ItemStorage) live in the cache only and are never journaled
## or settled.
##
## Every process on the machine shares one cache file, and a rebuild refreshes
## it in place (JSONLCache.rebuild_cache), so this connection stays on the file
## every other process uses; after another process's rebuild it reads the
## rebuilt rows and the stored fingerprint that matches them.

var _jsonl_path: String
# Load-time collision aliases never enter stored metadata or canonical snapshots.
var _session_id_prefix: String = ""
var last_write_error: String = ""
## Emitted only after a successful content reload, never a new opening.
signal content_reloaded

## Successful cache replacements, including a refused settle recovery.
var reload_generation: int = 0
var _write_blocked: bool = false
var _adopt_write_block_reason: String = ""
var _allow_initial_write: bool = false
var _lock_timeout_ms: int = 5000
## Test seam for a mutation's durable write, called as (target_path, text) in
## place of it: target is the canonical (full replacement text) on a settle,
## or the sidecar (one record line to append) on an ordinary mutation.
var _atomic_write_hook: Callable
var _mutation_depth: int = 0
var _mutation_error: String = ""
# The committed mutation changed a table the sidecar does not journal.
var _settle_after_commit: bool = false
# Reuses the canonical's hash while its stat proves it unchanged (JSONLFreshness).
var _freshness := JSONLFreshness.new()

## Settle once no record has been appended for this long...
const SETTLE_IDLE_MS := 2000
## ...or once the oldest unsettled record is this old, so a steady stream of
## mutations cannot keep the canonical from converging.
const SETTLE_MAX_AGE_MS := 30000
# Ticks of this process's first and latest unsettled sidecar append; 0 = none.
var _pending_first_ms: int = 0
var _pending_last_ms: int = 0
# The background settle in flight, or null. At most one per project.
var _settle_job: JSONLSettleJob = null

## Per-tick time budget for reading a background settle's snapshot in slices
## (JSONLSettleJob.read_slice), so no frame holds the whole cache read; -1
## reads it in one FileLock hold. The GUI sets it (main.gd _start_gui).
static var snapshot_slice_ms: int = -1
## Rows per chunk of a sliced read.
static var snapshot_chunk_rows: int = 500
## Restarts after which a sliced read falls back to one hold.
const MAX_SNAPSHOT_RESTARTS := 3

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

	# A sidecar that outlived its writer (crash, kill) is already replayed into
	# the cache; compact it now. On failure the records stay journaled and
	# visible, and the next settle retries. While another process holds the
	# lock it is writing this sidecar, so it is replayed but left in place.
	if not wrapper._write_blocked and JSONLSidecar.has_content(JSONLSidecar.path_for(path)) and not FileLock.held_by_other(path):
		var compact_error := wrapper._settle_canonical()
		if not compact_error.is_empty():
			push_warning("DocketDBJsonl: sidecar for %s not compacted: %s" % [path, compact_error])

	return wrapper


static func create_new_jsonl(path: String) -> DocketDBJsonl:
	## Create a brand-new JSONL-backed docket at the canonical `.dct` path.
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
	if _mutation_depth > 0: return
	# Only this process's own unsettled appends are written back, so read-only
	# sessions and rejected operations cannot normalize or rewrite source bytes
	# as a side effect of closing.
	var settle_error := settle_if_pending()
	if not settle_error.is_empty():
		push_warning("DocketDBJsonl: %s stays journaled in its sidecar: %s" % [_jsonl_path, settle_error])
	super.close()


# -- Freshness ----------------------------------------------------------------
#
# The JSONL file is canonical and other processes edit it — most importantly
# `git pull`/`git merge`. Without a freshness check, a long-lived process keeps
# serving its stale cache and the next mutation rewrites the whole file from
# that stale state, silently deleting whatever was pulled. Callers should invoke
# ensure_fresh() at the top of each request (MCP) or poll tick (GUI).

func poll_source_token() -> String:
	## Same identity as the cache freshness gate: zero canonical bytes for a
	## stable warmed file, full verification while its timestamp is racy.
	return _source_fingerprint() if _is_open else "closed"


func is_stale() -> bool:
	## True if the JSONL file no longer matches what this cache was built from.
	if not _is_open or _jsonl_path.is_empty():
		return false
	var current := _source_fingerprint()
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


func reload() -> bool:
	## Force a rebuild of the SQLite cache from the canonical JSONL file,
	## discarding cached durable state; ephemeral rows stay. Returns true on
	## success.
	if _mutation_depth > 0 or _jsonl_path.is_empty():
		return false
	# A snapshot of the cache being discarded must never reach the canonical.
	if _settle_job != null:
		_settle_job.discard()
		_settle_job = null

	var cache_path := JSONLCache.cache_path_for(_jsonl_path)

	# The rebuild refreshes the file through its own connection, which this
	# wrapper then adopts; this one is released first.
	# NOTE: super.close() (not close()) — the override would flush our stale
	# state over the very file we are trying to read.
	if _is_open:
		super.close()

	var fresh := JSONLCache.rebuild_cache(_jsonl_path, cache_path)
	if fresh == null:
		last_open_error = JSONLCache.last_error
		push_error("DocketDBJsonl: reload failed for %s — %s" % [_jsonl_path, last_open_error])
		# A failed rebuild rolls back, or stops before touching the cache (bad
		# JSONL, busy or unusable cache file), so the old rows are intact.
		# Reopening it keeps the process usable and read-only-correct.
		var fallback := DocketDB.new()
		if fallback.open(cache_path):
			_adopt(fallback)
		_write_blocked = true
		last_write_error = "canonical reload failed; cached data is read-only"
		return false

	_adopt(fresh)
	reload_generation += 1
	last_open_error = ""
	content_reloaded.emit()
	return true


# Settle verbs. Sync returns after the canonical is replaced (or refused);
# async returns with a background settle (JSONLSettleJob) in flight.
#   verb                  called by                                  mode
#   flush, flush_checked  docket_flush (MCP tool), tests             sync
#   settle_in_background  File → Save (AppState.flush_all)           async
#   settle_if_idle        settle_projects(idle_only)                 async: commits a finished
#                                                                    job or starts one when idle
#   settle_if_pending     close(), settle_projects(quit)             sync
#   finish_settle         every sync settle, before reading cache    sync: wait + commit; a job
#                                                                    still reading slices is dropped
#   settle_projects       idle: DocketHttpServer._process, AppShell  per project, see above
#                         _process and 3 s poll; quit: _exit_tree,
#                         AppShell._quit
#   close                 remove project, upgrade                    settle_if_pending first
# Sync paths end in _settle_canonical; async ones in _start/_commit_settle_job.

func flush() -> void:
	## Settle: rewrite the canonical from the cache and empty the sidecar.
	flush_checked()

func flush_checked() -> String:
	## An empty result inside a nested mutation means the flush is deferred; the
	## outermost completion remains responsible for durable commit and errors.
	if _mutation_depth > 0: return ""
	return _settle_canonical()


func has_pending_sidecar() -> bool:
	## True while this process has sidecar appends the canonical does not hold.
	return _pending_first_ms != 0


func is_settling() -> bool:
	## True while a background settle has not committed yet.
	return _settle_job != null


func settle_in_background() -> String:
	## File → Save. Starts a background settle when this process has unsettled
	## appends or the sidecar holds anything; a clean project is not rewritten.
	## A request while one is in flight is coalesced: that settle covers
	## everything journaled before it started, and a follow-up for later appends
	## starts when it commits.
	if not _uses_sidecar(): return flush_checked()
	if not _is_open or _mutation_depth > 0: return ""
	if _settle_job != null:
		if not _settle_job.is_done():
			_settle_job.resettle = true
			return ""
		var error := _poll_settle_job()
		if not error.is_empty() or _settle_job != null: return error
	if not has_pending_sidecar() and not JSONLSidecar.has_content(JSONLSidecar.path_for(_jsonl_path)): return ""
	return _start_settle_job(true)


func finish_settle() -> String:
	## Wait for the background settle, if any, and commit it. A job still
	## reading its snapshot in slices has written nothing and is dropped; its
	## records stay journaled for the caller's own settle.
	if _settle_job == null: return ""
	if _settle_job.reading:
		_settle_job = null
		return ""
	return _commit_settle_job()


func settle_if_pending() -> String:
	## Close and quit: nothing this process journaled is left unsettled.
	var error := finish_settle()
	if has_pending_sidecar() and _is_open: return _settle_canonical()
	return error


func settle_if_idle(now_ms: int) -> String:
	## Debounce tick: commit a finished background settle, or start one once
	## the appends have been idle (or old) long enough.
	# Mid-mutation the cache holds uncommitted rows; never settle them.
	if _mutation_depth > 0: return ""
	var error := ""
	if _settle_job != null:
		error = _poll_settle_job()
	elif has_pending_sidecar() and _is_open and (now_ms - _pending_last_ms >= SETTLE_IDLE_MS or now_ms - _pending_first_ms >= SETTLE_MAX_AGE_MS):
		error = _start_settle_job(true)
	# Back off a failing settle to the next idle window instead of every tick.
	if not error.is_empty(): _pending_last_ms = now_ms
	if _settle_job == null and _is_open: _freshness.recheck_if_due(_jsonl_path)
	return error


static func settle_projects(project_dbs: Dictionary, idle_only: bool) -> Array:
	## Debounce tick (idle_only) and quit hook for a project map. On quit every
	## project with pending appends starts formatting first, so the workers run
	## in parallel; then each is waited for and committed, and anything
	## appended meanwhile settles synchronously. Quit returns only after that.
	var reloaded: Array = []
	var generations := {}
	var now_ms := Time.get_ticks_msec()
	var jsonl_dbs := {}
	for project_name in project_dbs:
		if project_dbs[project_name] is DocketDBJsonl: jsonl_dbs[project_name] = project_dbs[project_name]
	for project_name in jsonl_dbs:
		generations[project_name] = jsonl_dbs[project_name].reload_generation
	if not idle_only:
		for project_name in jsonl_dbs:
			var jsonl_db: DocketDBJsonl = jsonl_dbs[project_name]
			if jsonl_db._settle_job == null and jsonl_db.has_pending_sidecar() and jsonl_db._is_open and jsonl_db._mutation_depth == 0:
				var start_error := jsonl_db._start_settle_job()
				if not start_error.is_empty(): push_warning("DocketDBJsonl: settle of %s deferred: %s" % [project_name, start_error])
	for project_name in jsonl_dbs:
		var jsonl_db: DocketDBJsonl = jsonl_dbs[project_name]
		var error := jsonl_db.settle_if_idle(now_ms) if idle_only else jsonl_db.settle_if_pending()
		if not error.is_empty(): push_warning("DocketDBJsonl: settle of %s deferred: %s" % [project_name, error])
		if jsonl_db.reload_generation != generations[project_name]: reloaded.append(project_name)
	return reloaded


func _uses_sidecar() -> bool:
	return true


func _adopt(source: DocketDB) -> void:
	## Take ownership of source's SQLite connection, detaching it from source
	## so its destructor cannot close the handle we now hold.
	_session_id_prefix = ""
	_db = source._db
	_path = source._path
	_is_open = true
	source._db = null
	source._is_open = false
	var version := super.get_meta_value("jsonl_version", "1.0.0")
	if last_write_error == _adopt_write_block_reason: last_write_error = ""
	_adopt_write_block_reason = "format %s is newer than this Docket; project is read-only" % version if JSONLParser.is_newer_version(version) else ""
	_write_blocked = not _adopt_write_block_reason.is_empty()
	if _write_blocked: last_write_error = _adopt_write_block_reason
	if _write_blocked: return
	var diagnostics := super.get_meta_value("registry_diagnostics", "")
	_write_blocked = not diagnostics.is_empty()
	if _write_blocked:
		_adopt_write_block_reason = "unresolved type definition data; project is read-only: %s" % diagnostics
		last_write_error = _adopt_write_block_reason
	if _uses_sidecar():
		var tracking_error := JSONLSidecar.install_dirty_tracking(self)
		if not tracking_error.is_empty():
			_write_blocked = true
			_adopt_write_block_reason = tracking_error
			last_write_error = tracking_error


func get_write_block_reason() -> String:
	if not _write_blocked: return ""
	return _adopt_write_block_reason if not _adopt_write_block_reason.is_empty() else last_write_error


func get_storage_diagnostics() -> Array:
	var raw := super.get_meta_value("registry_diagnostics", "")
	var parsed = JSON.parse_string(raw)
	return parsed if parsed is Array else []


func _mutation_precheck() -> String:
	if _write_blocked: return get_write_block_reason()
	if not FileAccess.file_exists(_jsonl_path) and not _allow_initial_write:
		_write_blocked = true
		last_write_error = "canonical source is missing; project is read-only"
		return last_write_error
	if is_stale() and not reload():
		_write_blocked = true
		if last_write_error.is_empty(): last_write_error = "canonical source could not be reloaded"
		return last_write_error
	return get_write_block_reason()


func _begin_canonical_mutation(write_lock: bool = false) -> String:
	## write_lock opens the outermost transaction with BEGIN IMMEDIATE: it waits
	## (busy_timeout) for SQLite's write lock on the shared cache and holds it
	## until COMMIT/ROLLBACK, so no other connection commits between this
	## mutation's reads and its writes. The default deferred BEGIN takes the
	## lock at the first write. Ignored when nested: the outer BEGIN decides.
	if _mutation_depth > 0 and (not _mutation_error.is_empty() or not _last_sql_error.is_empty()):
		return _mutation_error if not _mutation_error.is_empty() else _last_sql_error
	if _mutation_depth == 0:
		var precheck := _mutation_precheck()
		if not precheck.is_empty(): return precheck
		_last_sql_error = ""
		_mutation_error = _exec_checked("BEGIN IMMEDIATE TRANSACTION;" if write_lock else "BEGIN TRANSACTION;")
		if not _mutation_error.is_empty(): return _mutation_error
	_mutation_depth += 1
	return ""


func _complete_canonical_mutation(error: String = "") -> String:
	if not error.is_empty() and _mutation_error.is_empty(): _mutation_error = error
	if not _last_sql_error.is_empty() and _mutation_error.is_empty(): _mutation_error = _last_sql_error
	_mutation_depth -= 1
	if _mutation_depth > 0: return _mutation_error
	_work_fields.clear()
	if _mutation_error.is_empty(): _mutation_error = _commit_mutation()
	if not _mutation_error.is_empty():
		var failed := _mutation_error
		_rollback()
		_mutation_error = ""
		_settle_after_commit = false  # nothing committed, so nothing to settle
		# A memory project has no files to rebuild from; the rollback is enough.
		if _uses_sidecar(): return _fail_flush(failed)
		last_write_error = failed
		return failed
	var flush_error := _flush_jsonl()
	_mutation_error = ""
	return flush_error


func _refuse_canonical_mutation(refusal: String) -> String:
	## Ends a mutation with a refusal found inside it, before anything was
	## journaled. The outermost one only rolls back: no file was touched, so
	## the cache is not rebuilt and last_write_error is left alone. Nested, or
	## after a SQL error, it completes with the refusal as the error instead.
	if _mutation_depth != 1 or not _mutation_error.is_empty() or not _last_sql_error.is_empty():
		return _complete_canonical_mutation(refusal)
	_mutation_depth = 0
	_rollback()
	_settle_after_commit = false
	return refusal


func apply_registry_change(type_def: Dictionary, revision: Dictionary, item_bindings: Array, events: Array, expected_current_revision: String) -> String:
	## One checked cache transaction stages the immutable snapshot, current
	## pointer, item pins, and audit events before one canonical replacement.
	var error := _mutation_precheck()
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
		if error.is_empty(): error = ProjectEvents.stamp_last(self, str(event.item_id), str(event.event_type))
	return _complete_canonical_mutation(error)


# -- JSONL write-through ------------------------------------------------------

func _commit_mutation() -> String:
	## COMMIT of the outermost mutation's cache transaction. A change the sidecar
	## journals is appended first: one FileLock hold covers the source check,
	## the append, the stored identity and the COMMIT, so a process that reads
	## the cache under the lock never sees rows the sidecar does not hold. On
	## any failure inside the hold the sidecar is cut back to its length before
	## the append, and the error is returned with the transaction still open for
	## the caller to roll back. Other changes only commit here; _flush_jsonl
	## settles them.
	if not _uses_sidecar() or _allow_initial_write: return _exec_checked("COMMIT;")
	if _write_blocked: return last_write_error
	if not FileAccess.file_exists(_jsonl_path): return "canonical source is missing; refusing to recreate it from cache"
	var expected_source := super.get_meta_value("jsonl_hash", "")
	var built := JSONLSidecar.build_record(self, JSONLSidecar.canonical_part(expected_source))
	if built.has("error"): return str(built.error)
	if built.get("full", false):
		_settle_after_commit = true
		return _exec_checked("COMMIT;")
	if str(built.line).is_empty(): return _exec_checked("COMMIT;")

	# Same lock and strong source check as a canonical write: a record may only
	# extend the exact canonical + sidecar this cache was built from.
	var sidecar := JSONLSidecar.path_for(_jsonl_path)
	var lock := FileLock.acquire(_jsonl_path, _lock_timeout_ms)
	if lock == null:
		return "could not acquire advisory lock for %s" % _jsonl_path
	if _source_fingerprint(lock.contended) != expected_source:
		lock.release()
		return "canonical source changed while acquiring write lock"
	var length_before := JSONLSidecar.length_of(sidecar)
	if length_before < 0 and FileAccess.file_exists(sidecar):
		lock.release()
		return "cannot read sidecar %s before appending" % sidecar
	var error: String = str(_atomic_write_hook.call(sidecar, built.line)) if _atomic_write_hook.is_valid() else JSONLSidecar.append(sidecar, built.line)
	if error.is_empty():
		# The cache now holds exactly canonical + sidecar; this identity commits
		# with the rows, so this process's own append does not read as a
		# foreign change.
		super.set_meta_value("jsonl_hash", JSONLSidecar.fingerprint_with(JSONLSidecar.canonical_part(expected_source), _jsonl_path))
		error = _last_sql_error
	if error.is_empty(): error = JSONLSidecar.clear_dirty(self)
	if error.is_empty(): error = _exec_checked("COMMIT;")
	if not error.is_empty():
		var undo_error := JSONLSidecar.truncate(sidecar, length_before)
		if not undo_error.is_empty():
			push_error("DocketDBJsonl: %s" % undo_error)
			error = "%s; %s" % [error, undo_error]
	lock.release()
	if not error.is_empty(): return error

	var now_ms := Time.get_ticks_msec()
	if _pending_first_ms == 0: _pending_first_ms = now_ms
	_pending_last_ms = now_ms
	last_write_error = ""
	return ""


func _flush_jsonl() -> String:
	## Durable step after the outermost mutation commits. Nested mutations defer
	## to their outer transaction. Journaled changes were appended by
	## _commit_mutation; the first write of a new file and changes the sidecar
	## does not journal settle the canonical here.
	if _jsonl_path.is_empty():
		return "canonical path is empty"
	if _mutation_depth > 0:
		return ""  # We're inside a compound mutation — will flush when outermost returns
	var settle := _allow_initial_write or _settle_after_commit
	_settle_after_commit = false
	if _write_blocked:
		return last_write_error
	return _settle_canonical() if settle else ""


func _settle_canonical() -> String:
	## Serialize the cache to the canonical atomically and retire the sidecar.
	## Acquires the advisory lock before writing and validates the source
	## identity (canonical + sidecar) again after acquisition.
	if _jsonl_path.is_empty():
		return "canonical path is empty"
	# One settle at a time: a background one commits (or fails and reloads)
	# before this one reads the cache.
	var join_error := finish_settle()
	if not join_error.is_empty():
		return join_error
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

	# The lock only reduces overlap. Recheck the strong source identity after
	# acquiring it so a writer in the serialization window cannot be overwritten.
	var lock := FileLock.acquire(_jsonl_path, _lock_timeout_ms)
	if lock == null:
		return _fail_flush("could not acquire advisory lock for %s" % _jsonl_path)
	if not _allow_initial_write and _source_fingerprint(lock.contended) != expected_source_hash:
		lock.release()
		return _fail_flush("canonical source changed while acquiring write lock")

	var verify := func() -> String:
		return "" if _allow_initial_write or _source_fingerprint(true) == expected_source_hash else "canonical source changed while settling"
	var committed := JSONLCheckedCommit.replace(_jsonl_path, jsonl_text, verify, _atomic_write_hook)
	var write_error: String = committed.error
	# Our own replacement is always hashed in full: its stat is fresh, so the
	# hash is reused only after a later check past the mtime window.
	var fingerprint := _source_fingerprint(true)
	lock.release()
	if not write_error.is_empty():
		return _fail_flush(write_error)

	# Update cache fingerprint so it stays valid
	if not fingerprint.is_empty():
		# Use super to avoid triggering another flush
		super.set_meta_value("jsonl_hash", fingerprint)
	JSONLSidecar.clear_dirty(self)
	_pending_first_ms = 0
	_pending_last_ms = 0
	last_write_error = ""
	return ""


func _start_settle_job(sliced: bool = false) -> String:
	## Main-thread half of a background settle. With sliced and
	## snapshot_slice_ms >= 0 the large row sets are read over the following
	## ticks (_advance_settle_job) before the hold; otherwise the hold is now.
	if _write_blocked:
		return last_write_error
	if not FileAccess.file_exists(_jsonl_path):
		return _fail_flush("canonical source is missing; refusing to recreate it from cache")
	if not sliced or snapshot_slice_ms < 0:
		return _seal_settle_job(null)
	var generation := cache_generation()
	if generation.is_empty(): return _seal_settle_job(null)
	_settle_job = JSONLSettleJob.begin_reading(_jsonl_path, generation)
	return _advance_settle_job()


func _advance_settle_job() -> String:
	## One tick of a sliced read. Any cache write since the reads began (this
	## connection's or another process's) restarts them; after
	## MAX_SNAPSHOT_RESTARTS the snapshot is taken in one hold instead.
	var job := _settle_job
	var generation := cache_generation()
	if generation != job.generation or generation.is_empty():
		if job.restarts >= MAX_SNAPSHOT_RESTARTS or generation.is_empty():
			_settle_job = null
			var fallback_error := _seal_settle_job(null)
			if _settle_job != null: _settle_job.resettle = job.resettle
			return fallback_error
		job.restart_reading(generation)
	_last_sql_error = ""
	var complete := job.read_slice(self, snapshot_slice_ms, snapshot_chunk_rows)
	if not _last_sql_error.is_empty():
		_settle_job = null
		return _fail_flush("cache read failed during serialization: %s" % _last_sql_error)
	return _seal_settle_job(job) if complete else ""


func _seal_settle_job(job: JSONLSettleJob) -> String:
	## Takes the snapshot and launches the worker; job is a sliced job whose
	## row sets are all read, or null to read everything here.
	##
	## One FileLock hold covers the source check against the stored jsonl_hash,
	## the type-pointer check, the cache snapshot and the sidecar read. Every
	## journaled mutation checks, appends, stores its identity and commits its
	## cache rows under the same lock (_commit_mutation), so no other process's
	## append or rows land between any two of them: the prefix is exactly the
	## sidecar the snapshot and the stored identity stand for. Rows a sliced job
	## read before the hold are used only if the cache generation still equals
	## the one they were read under, so they equal what a read here would
	## return; otherwise the hold is dropped and the next tick restarts them.
	## The hold is reads only (one freshness-gated hash of each file, SQLite
	## selects, one sidecar read); formatting runs on the worker. Nothing inside
	## appends or settles, so it never waits on this process's own lock.
	_last_sql_error = ""
	var lock := FileLock.acquire(_jsonl_path, _lock_timeout_ms)
	if lock == null:
		_settle_job = null
		return _fail_flush("could not acquire advisory lock for %s" % _jsonl_path)
	var stored := super.get_meta_value("jsonl_hash", "")
	if _source_fingerprint(lock.contended) != stored:
		lock.release()
		_settle_job = null
		return _fail_flush("canonical source changed; reload before writing")
	if job != null and cache_generation() != job.generation:
		lock.release()
		return ""
	var pointer_error := _validate_type_pointers()
	var snapshot := {}
	if pointer_error.is_empty(): snapshot = JSONLSerializer.snapshot(self, job.rows_read() if job != null else {})
	var prefix := JSONLSidecar.read_bytes(JSONLSidecar.path_for(_jsonl_path))
	lock.release()
	if not pointer_error.is_empty() or not _last_sql_error.is_empty() or not str(prefix.error).is_empty():
		_settle_job = null
	if not pointer_error.is_empty(): return _fail_flush(pointer_error)
	if not _last_sql_error.is_empty():
		return _fail_flush("cache read failed during serialization: %s" % _last_sql_error)
	if not str(prefix.error).is_empty():
		push_error("DocketDBJsonl: %s" % prefix.error)
		return _fail_flush(str(prefix.error))
	if job == null:
		_settle_job = JSONLSettleJob.start(_jsonl_path, snapshot, JSONLSidecar.canonical_part(stored), prefix.bytes)
	else:
		job.launch(snapshot, JSONLSidecar.canonical_part(stored), prefix.bytes)
	return ""


func _poll_settle_job() -> String:
	## Read the next slice, or commit a finished background settle and start
	## the coalesced follow-up.
	if _settle_job == null: return ""
	if _settle_job.reading: return _advance_settle_job()
	if not _settle_job.is_done(): return ""
	var follow_up := _settle_job.resettle
	var error := _commit_settle_job()
	if error.is_empty() and follow_up and has_pending_sidecar(): error = _start_settle_job(true)
	return error


func _commit_settle_job() -> String:
	## Main-thread commit of a background settle: under the lock, verify, then
	## mark, rename, keep only the tail. The freshness state and the stored
	## identity change only after the rename.
	##
	## The verify step needs all three to hold (the job's snapshot, canonical_sha
	## and sidecar_prefix were captured under one lock hold, _start_settle_job):
	## - the files' fingerprint equals the stored jsonl_hash: nothing but this
	##   process's own appends (which keep jsonl_hash current) touched them;
	## - the stored canonical part equals job.canonical_sha: the canonical is
	##   still the one the snapshot was taken over, not replaced since;
	## - the sidecar still starts with job.sidecar_prefix: the records the
	##   snapshot holds are still its head, so everything after is a tail of
	##   later appends that the new canonical does not contain.
	## With a tail left, _pending_first_ms becomes job.started_ms: every tail
	## record was appended after the snapshot, so its oldest is no older than
	## that, and the max-age debounce counts from there.
	var job := _settle_job
	_settle_job = null
	job.wait()
	if not job.error.is_empty():
		job.remove_temp()
		return _fail_flush(job.error)
	var lock := FileLock.acquire(_jsonl_path, _lock_timeout_ms)
	if lock == null:
		job.remove_temp()
		return _fail_flush("could not acquire advisory lock for %s" % _jsonl_path)
	var stored := super.get_meta_value("jsonl_hash", "")
	var sidecar_read := JSONLSidecar.read_bytes(JSONLSidecar.path_for(_jsonl_path))
	if not str(sidecar_read.error).is_empty():
		lock.release()
		job.remove_temp()
		push_error("DocketDBJsonl: %s" % sidecar_read.error)
		return _fail_flush(str(sidecar_read.error))
	var sidecar_now: PackedByteArray = sidecar_read.bytes
	if _source_fingerprint(lock.contended) != stored or JSONLSidecar.canonical_part(stored) != job.canonical_sha or not job.holds_prefix_of(sidecar_now):
		lock.release()
		job.remove_temp()
		return _fail_flush("canonical source changed while settling")
	var write_error := job.mark_sidecar(sidecar_now)
	if write_error.is_empty():
		write_error = job.replace_canonical()
	var fingerprint := ""
	if write_error.is_empty():
		_freshness.forget()
		var retire_error := job.retire_prefix(sidecar_now)
		# The canonical is complete; a leftover prefix is skipped by its marker.
		if not retire_error.is_empty(): push_warning("DocketDBJsonl: %s" % retire_error)
		# The worker hashed exactly the bytes now renamed into place.
		fingerprint = JSONLSidecar.fingerprint_with(job.text_sha, _jsonl_path)
	lock.release()
	if not write_error.is_empty():
		job.remove_temp()
		return _fail_flush(write_error)
	super.set_meta_value("jsonl_hash", fingerprint)
	if job.tail_of(sidecar_now).is_empty():
		_pending_first_ms = 0
		_pending_last_ms = 0
	else:
		_pending_first_ms = job.started_ms
	last_write_error = ""
	return ""


func _validate_cache_for_flush() -> String:
	var malformed := JSONLSerializer.malformed_item(_exec_select("SELECT id,fields_json,extras_json FROM items WHERE storage<>'ephemeral';"))
	if not malformed.is_empty(): return malformed
	return _validate_type_pointers()


func _validate_type_pointers() -> String:
	for row in _exec_select("SELECT d.id,d.current_revision,v.type_id FROM type_defs d LEFT JOIN type_def_versions v ON v.id=d.current_revision;"):
		if row.get("type_id") == null or str(row.type_id) != str(row.id): return "invalid current type revision pointer for %s" % row.id
	return ""


func _fail_flush(message: String) -> String:
	last_write_error = message
	if FileAccess.file_exists(_jsonl_path):
		# SQLite is disposable. Rebuilding it restores the last canonical state so
		# a failed compound write cannot leak into a later successful flush.
		reload()
		if not _write_blocked: last_write_error = message
	else:
		_write_blocked = true
	return message


func _source_fingerprint(force_full: bool = false) -> String:
	## Strong content identity prevents a same-size, same-timestamp external edit
	## from being overwritten by a cache that only appeared fresh. Same value as
	## JSONLSidecar.source_fingerprint; the canonical's hash is reused only under
	## JSONLFreshness's rules, and the sidecar is always hashed, so another
	## process's append also reads as a change.
	var canonical_sha := _freshness.canonical_sha(_jsonl_path, force_full)
	return "" if canonical_sha.is_empty() else JSONLSidecar.fingerprint_with(canonical_sha, _jsonl_path)


static func _atomic_write(path: String, content: String) -> String:
	## Write content to a file atomically: write to .tmp, then rename.
	var written := _write_temp(path, content)
	if not str(written.error).is_empty():
		return str(written.error)
	return _rename_over(str(written.path), path)


static func _write_temp(path: String, content: String) -> Dictionary:
	## {"path": temp file beside path holding content, "error": ""}. Touches only
	## that temp file, so a worker thread may call it.
	var tmp_path := path + ".tmp.%d" % OS.get_process_id()

	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return {"path": "", "error": "cannot open temp file %s for writing" % tmp_path}
	f.store_string(content)
	f.flush()
	var file_error := f.get_error()
	f.close()
	if file_error != OK:
		DirAccess.remove_absolute(tmp_path)
		return {"path": "", "error": "temp file write failed (error %d)" % file_error}
	return {"path": tmp_path, "error": ""}


static func _rename_over(tmp_path: String, path: String) -> String:
	var err := DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		push_error("DocketDBJsonl: rename %s → %s failed (error %d)" % [tmp_path, path, err])
		# Clean up temp file on failure
		DirAccess.remove_absolute(tmp_path)
		return "cannot replace canonical file (error %d)" % err
	return ""


# -- Overridden mutating methods ----------------------------------------------

# Each override: call super (SQLite), then commit durably via _flush_jsonl().


func insert_item(id: String, item: Dictionary, canonical_input: bool = false) -> String:
	var source_error := _mutation_precheck()
	if not source_error.is_empty(): return source_error
	var candidate := item.duplicate(true)
	if super.get_meta_value("jsonl_version", "1.0.0") == "2.0.0" and (not candidate.has("type_id") or not candidate.has("type_revision")):
		var rows := _exec_select("SELECT id,current_revision FROM type_defs WHERE slug=?;", [candidate.get("type", "")])
		if rows.size() != 1: return "type '%s' has no active project definition" % candidate.get("type", "")
		candidate["type_id"] = rows[0].id
		candidate["type_revision"] = rows[0].current_revision
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return precheck
	var result := super.insert_item(id, candidate, canonical_input)
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


func delete_item(id: String) -> void:
	delete_item_checked(id)


func delete_item_checked(id: String) -> String:
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return precheck
	# delete_item internally calls delete_secret (which we override).
	super.delete_item(id)
	return _complete_canonical_mutation()


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


func get_id_prefix() -> String:
	return _session_id_prefix if not _session_id_prefix.is_empty() else super.get_id_prefix()


func set_session_id_prefix(prefix: String) -> void:
	_session_id_prefix = prefix


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

func add_event(item_id: String, event_type: String, actor: String, note: String = "", timestamp: String = "") -> Dictionary:
	var precheck: String = _begin_canonical_mutation()
	if not precheck.is_empty(): return {"error":precheck}
	var result: Dictionary = super.add_event(item_id, event_type, actor, note, timestamp)
	var error: String = _complete_canonical_mutation(str(result.get("error", "")))
	return {"error":error} if not error.is_empty() else result


func add_event_checked(item_id: String, event_type: String, actor: String, note: String = "") -> String:
	return str(add_event(item_id, event_type, actor, note).get("error", ""))


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
	# One transaction makes the comment, checked event reference and item
	# timestamp one persistence unit.
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
	var error := ItemStorage.owner_refusal(self, owner_item_id)
	if not error.is_empty(): return error
	error = _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.set_secret(handle, ciphertext, iv, mac, requires_2fa, owner_item_id)
	return _complete_canonical_mutation()


func set_secret_owner(handle: String, owner_item_id: String) -> void:
	set_secret_owner_checked(handle, owner_item_id)

func set_secret_owner_checked(handle: String, owner_item_id: String) -> String:
	var error := ItemStorage.owner_refusal(self, owner_item_id)
	if not error.is_empty(): return error
	error = _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.set_secret_owner(handle, owner_item_id)
	return _complete_canonical_mutation()


func rekey_secret(old_handle: String, new_handle: String) -> String:
	var precheck := _begin_canonical_mutation()
	if not precheck.is_empty(): return precheck
	var err := super.rekey_secret(old_handle, new_handle)
	return _complete_canonical_mutation(err)


func delete_secret(handle: String) -> bool:
	var result := delete_secret_checked(handle)
	return bool(result.deleted) and str(result.error).is_empty()

func delete_secret_checked(handle: String) -> Dictionary:
	var begin_error := _begin_canonical_mutation()
	if not begin_error.is_empty(): return {"deleted": false, "error": begin_error}
	var result := super.delete_secret(handle)
	var error := _complete_canonical_mutation()
	return {"deleted": result and error.is_empty(), "error": error}


func rotate_secret(handle: String, new_ct: PackedByteArray, new_iv: PackedByteArray, new_mac: PackedByteArray, rotated_by: String = "", requires_2fa: bool = false) -> void:
	rotate_secret_checked(handle, new_ct, new_iv, new_mac, rotated_by, requires_2fa)

func rotate_secret_checked(handle: String, new_ct: PackedByteArray, new_iv: PackedByteArray, new_mac: PackedByteArray, rotated_by: String = "", requires_2fa: bool = false) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.rotate_secret(handle, new_ct, new_iv, new_mac, rotated_by, requires_2fa)
	return _complete_canonical_mutation()


func set_secret_2fa(handle: String, requires: bool) -> void:
	set_secret_2fa_checked(handle, requires)

func set_secret_2fa_checked(handle: String, requires: bool) -> String:
	var error := _begin_canonical_mutation()
	if not error.is_empty(): return error
	super.set_secret_2fa(handle, requires)
	return _complete_canonical_mutation()


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
