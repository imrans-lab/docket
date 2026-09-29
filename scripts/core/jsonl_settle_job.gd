extends RefCounted
class_name JSONLSettleJob
## One canonical settle whose expensive middle runs on a worker thread.
##
##   main    DocketDBJsonl._seal_settle_job, under one FileLock hold: checks
##           and every cache read (JSONLSerializer.snapshot), plus the identity
##           that snapshot stands for: the canonical's sha and the sidecar's
##           bytes at that moment. A sliced job (begin_reading) first reads the
##           large row sets in chunks over several ticks (read_slice); the hold
##           takes them only if the cache generation (DocketDBJsonl.
##           _cache_generation) is the one the reads started under, so every
##           row stands for the same instant as the rest of the snapshot.
##   worker  _run: JSONLSerializer.format_all, sha256 of the text, and the full
##           write of the temp file. It touches no SQLite connection, sidecar,
##           lock or freshness state, and never renames.
##   main    DocketDBJsonl._commit_settle_job, under the FileLock: verify, mark
##           the sidecar, rewrite the temp file's last byte and rename it over
##           the canonical, retire the sidecar prefix the snapshot already holds.
##
## Mutations keep appending to the sidecar while the worker runs. Those bytes
## are the tail past sidecar_prefix and are kept: before the rename the sidecar
## becomes prefix + settle marker + tail, so a crash replays prefix + tail over
## the old canonical (the marker's target does not match it) or only the tail
## over the new one; after the rename it becomes the tail alone.

var canonical_path := ""
## Canonical part of the cache identity the snapshot was taken from.
var canonical_sha := ""
## Sidecar bytes the snapshot already holds.
var sidecar_prefix := PackedByteArray()
var started_ms := 0
## Another settle was asked for while this one ran; its caller starts a
## follow-up for the tail once this one commits.
var resettle := false

# Written by the worker; read on the main thread only after wait().
var temp_path := ""
var text_sha := ""
var error := ""

# Sliced read (main thread only): true until launch().
var reading := false
## Cache generation the sliced reads started under; restarts count retries.
var generation: Array = []
var restarts := 0
var _read: Dictionary = {}
var _set_index := 0
var _offset := 0

var _snapshot: Dictionary = {}
var _task_id := -1
# The pool's Callable does not keep this object alive; this does, until wait().
var _self_ref: JSONLSettleJob


static func start(path: String, snapshot: Dictionary, source_sha: String, prefix: PackedByteArray) -> JSONLSettleJob:
	## snapshot, source_sha and prefix must come from one FileLock hold.
	var job := JSONLSettleJob.new()
	job.canonical_path = path
	job.launch(snapshot, source_sha, prefix)
	return job


static func begin_reading(path: String, cache_generation: Array) -> JSONLSettleJob:
	var job := JSONLSettleJob.new()
	job.canonical_path = path
	job.reading = true
	job.generation = cache_generation
	return job


func restart_reading(cache_generation: Array) -> void:
	## The cache was written since the reads began; they are dropped.
	restarts += 1
	generation = cache_generation
	_read = {}
	_set_index = 0
	_offset = 0


func read_slice(db: DocketDB, budget_ms: int, chunk_rows: int) -> bool:
	## Main thread. Reads chunks of the sliced row sets until budget_ms has
	## passed (at least one chunk). True once every sliced set is read; the
	## caller checks db._last_sql_error.
	var deadline := Time.get_ticks_msec() + budget_ms
	while _set_index < JSONLSerializer.SLICED_SETS:
		var key: String = JSONLSerializer.row_sets()[_set_index][0]
		var rows := JSONLSerializer.read_chunk(db, _set_index, _offset, chunk_rows)
		if not db._last_sql_error.is_empty(): return false
		if not _read.has(key): _read[key] = []
		(_read[key] as Array).append_array(rows)
		_offset += rows.size()
		if rows.size() < chunk_rows:
			_set_index += 1
			_offset = 0
		if Time.get_ticks_msec() >= deadline: break
	return _set_index >= JSONLSerializer.SLICED_SETS


func rows_read() -> Dictionary:
	## The sliced row sets read so far, for JSONLSerializer.snapshot.
	return _read


func launch(snapshot: Dictionary, source_sha: String, prefix: PackedByteArray) -> void:
	## snapshot, source_sha and prefix must come from one FileLock hold.
	reading = false
	_read = {}
	canonical_sha = source_sha
	sidecar_prefix = prefix
	started_ms = Time.get_ticks_msec()
	_snapshot = snapshot
	_self_ref = self
	_task_id = WorkerThreadPool.add_task(_run, false, "docket canonical settle")


func is_done() -> bool:
	return not reading and (_task_id < 0 or WorkerThreadPool.is_task_completed(_task_id))


func wait() -> void:
	## Every task must be waited for exactly once; later calls return at once.
	if _task_id < 0: return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	_self_ref = null


func discard() -> void:
	wait()
	remove_temp()


func _run() -> void:
	var snapshot := _snapshot
	_snapshot = {}
	error = JSONLSerializer.malformed_item(snapshot.items)
	if not error.is_empty(): return
	var text := JSONLSerializer.format_all(snapshot)
	if text.is_empty():
		error = "serializer produced empty output"
		return
	text_sha = text.sha256_text()
	var written := DocketDBJsonl._write_temp(canonical_path, text)
	temp_path = str(written.path)
	error = str(written.error)


# -- Commit steps (main thread, under the FileLock) ---------------------------

func holds_prefix_of(sidecar_now: PackedByteArray) -> bool:
	var n := sidecar_prefix.size()
	return sidecar_now.size() >= n and sidecar_now.slice(0, n) == sidecar_prefix


func tail_of(sidecar_now: PackedByteArray) -> PackedByteArray:
	return sidecar_now.slice(sidecar_prefix.size())


func mark_sidecar(sidecar_now: PackedByteArray) -> String:
	## Before the rename. With no tail this is the synchronous settle's append.
	if sidecar_prefix.is_empty(): return ""
	var sidecar := JSONLSidecar.path_for(canonical_path)
	var marker := JSONLSidecar.settle_marker(text_sha)
	var tail := tail_of(sidecar_now)
	if tail.is_empty(): return JSONLSidecar.append(sidecar, marker)
	var fence := "" if sidecar_prefix[sidecar_prefix.size() - 1] == 10 else "\n"
	return _replace_bytes(sidecar, sidecar_prefix + (fence + marker + "\n").to_utf8_buffer() + tail)


func replace_canonical() -> String:
	## A rename keeps the renamed file's mtime, and the worker may have written
	## the temp file seconds ago, even in the old canonical's mtime second.
	## Rewriting its last byte first gives the new canonical the rename's
	## mtime, which is past any hash of the old one that JSONLFreshness may
	## reuse (that hash started >= 2 s after the old mtime).
	var touch_error := _rewrite_last_byte(temp_path)
	if not touch_error.is_empty(): return touch_error
	var rename_error := DocketDBJsonl._rename_over(temp_path, canonical_path)
	if rename_error.is_empty(): temp_path = ""
	return rename_error


func retire_prefix(sidecar_now: PackedByteArray) -> String:
	## After the rename: the canonical holds the prefix; keep only the tail.
	if sidecar_prefix.is_empty(): return ""
	var sidecar := JSONLSidecar.path_for(canonical_path)
	var tail := tail_of(sidecar_now)
	return JSONLSidecar.remove(sidecar) if tail.is_empty() else _replace_bytes(sidecar, tail)


func remove_temp() -> void:
	if not temp_path.is_empty() and FileAccess.file_exists(temp_path):
		DirAccess.remove_absolute(temp_path)
	temp_path = ""


static func _rewrite_last_byte(path: String) -> String:
	## Same bytes; only the file's mtime changes.
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null: return "cannot reopen %s before the rename (error %d)" % [path, FileAccess.get_open_error()]
	var length := f.get_length()
	if length > 0:
		f.seek(length - 1)
		var last := f.get_8()
		f.seek(length - 1)
		f.store_8(last)
		f.flush()
	var file_error := f.get_error()
	f.close()
	return "" if file_error == OK else "cannot rewrite %s before the rename (error %d)" % [path, file_error]


static func _replace_bytes(path: String, content: PackedByteArray) -> String:
	var tmp_path := path + ".tmp.%d" % OS.get_process_id()
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null: return "cannot open %s for writing (error %d)" % [tmp_path, FileAccess.get_open_error()]
	f.store_buffer(content)
	f.flush()
	var file_error := f.get_error()
	f.close()
	if file_error == OK: file_error = DirAccess.rename_absolute(tmp_path, path)
	if file_error != OK:
		DirAccess.remove_absolute(tmp_path)
		return "cannot rewrite sidecar %s (error %d)" % [path, file_error]
	return ""
