extends RefCounted
class_name AuditLog
## Append-only local record of vault access.
##
## Why a separate file rather than the existing log tables or the .dct itself:
##
##   * transition_log and mcp_error_log live only in the SQLite cache, which is
##     rebuilt whenever the .dct changes on disk. Security evidence that a
##     `git pull` can erase is not evidence.
##   * Putting it in the .dct would make every secret read a modification of a
##     file that is committed and merged, producing constant conflicts and
##     leaking access patterns to anyone who can read the repository.
##
## So it is a sidecar next to the .dct, gitignored, one JSON object per line.
## It records that access happened — never what was accessed. No plaintext, no
## passwords, no key material.
##
## Every append, and every snapshot, is made inside a SHARED coordination
## operation and under the project's audit lock (DocketFileIO.audit_lock, in
## that order), so a snapshot never sees half of an append made through here.

## Written next to the .dct as <path>.audit.jsonl (DocketAuditGuard writes
## the same name).
const SUFFIX := ".audit.jsonl"

# Event names, kept stable so the log stays greppable.
const READ := "secret_read"
const WRITE := "secret_write"
const DELETE := "secret_delete"
const UNLOCK_FAILED := "vault_unlock_failed"
const ROTATE := "secret_rotate"

# How long an append or snapshot waits for another holder of the audit lock.
const LOCK_DEADLINE_MS := 2000


static func path_for(dct_path: String) -> String:
	return dct_path + SUFFIX


static func record(dct_path: String, event: String, handle: String, ok: bool, source: String = "", note: String = "") -> void:
	## Append one audit entry. Best-effort: auditing must never break the
	## operation it is recording, so an entry that cannot be written is skipped
	## with a warning naming only the event and why.
	if dct_path.is_empty():
		return

	var entry := {
		"ts": Time.get_datetime_string_from_system(true),
		"event": event,
		"ok": ok,
	}
	# `handle` names which secret, not its contents — safe to record.
	if not handle.is_empty():
		entry["handle"] = handle
	if not source.is_empty():
		entry["source"] = source
	if not note.is_empty():
		entry["note"] = note
	entry["pid"] = OS.get_process_id()

	var line := JSON.stringify(entry) + "\n"
	var written := with_lock(dct_path, func(guard: RefCounted) -> Dictionary: return guard.append(line.to_utf8_buffer()))
	if written.has("error"):
		push_warning("Docket did not record %s in the audit log (%s)." % [event, written.get("kind", "unavailable")])


## The sidecar's exact bytes, a partial last line included, read under the
## audit lock: {present: true, bytes, identity}, {present: false} when there
## is none, or {error, kind}.
static func snapshot(dct_path: String) -> Dictionary:
	return with_lock(dct_path, func(guard: RefCounted) -> Dictionary: return guard.snapshot())


## `work` called with the held audit guard (DocketAuditGuard) of `dct_path`,
## inside a SHARED coordination operation (a step of `parent` when given):
## its result, or {error, kind} when either cannot be had. With `also`, the
## guard holds that path's audit lock too (DocketFileIO.audit_lock_with).
## `work` runs synchronously and must not await.
static func with_lock(dct_path: String, work: Callable, parent: RefCounted = null, also: String = "") -> Dictionary:
	if not ClassDB.class_exists("DocketFileIO"):
		return {"error": "Docket's native extension is not loaded.", "kind": "no_extension"}
	var opened := CoordLease.shared(parent)
	if opened.has("error"):
		return opened
	var io: Object = ClassDB.instantiate("DocketFileIO")
	var source := ProjectSettings.globalize_path(dct_path)
	var locked: Dictionary = io.audit_lock(source, LOCK_DEADLINE_MS) if also.is_empty() \
		else io.audit_lock_with(source, ProjectSettings.globalize_path(also), LOCK_DEADLINE_MS)
	var result: Dictionary = locked if locked.has("error") else work.call(locked.guard)
	if locked.has("guard"):
		locked.guard.release()
	opened.operation.close()
	return result


static func read_entries(dct_path: String, limit: int = 100) -> Array:
	## Most recent entries first. Returns [] if no log exists yet.
	var target := path_for(dct_path)
	if not FileAccess.file_exists(target):
		return []
	var f := FileAccess.open(target, FileAccess.READ)
	if f == null:
		return []

	var entries: Array = []
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if parsed is Dictionary:
			entries.append(parsed)
	f.close()

	entries.reverse()
	if limit > 0 and entries.size() > limit:
		entries.resize(limit)
	return entries
