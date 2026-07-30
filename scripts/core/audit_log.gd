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

## Written next to the .dct as <path>.audit.jsonl
const SUFFIX := ".audit.jsonl"

# Event names, kept stable so the log stays greppable.
const READ := "secret_read"
const WRITE := "secret_write"
const DELETE := "secret_delete"
const UNLOCK_FAILED := "vault_unlock_failed"
const ROTATE := "secret_rotate"


static func path_for(dct_path: String) -> String:
	return dct_path + SUFFIX


static func record(dct_path: String, event: String, handle: String, ok: bool, source: String = "", note: String = "") -> void:
	## Append one audit entry. Best-effort: auditing must never break or block
	## the operation it is recording, so all failures here are swallowed.
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

	# FileAccess has no append mode that creates the file when missing, so open
	# READ_WRITE when it exists and WRITE when it does not.
	var target := path_for(dct_path)
	var f: FileAccess
	if FileAccess.file_exists(target):
		f = FileAccess.open(target, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(target, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(line)
	f.close()


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
