extends RefCounted
class_name JSONLReplace
## Windows rename-over-existing deletes the destination before moving. Stage it
## in our reserved adjacent namespace instead. Callers hold the canonical lock.
## No atomic visibility or fsync guarantee: the target can briefly be absent.
const SUFFIX := ".docket-replace-backup"
## Bounded real-file test seams; Linux can exercise the Windows protocol.
static var force_windows := false
static var stage_hook: Callable

static func _enabled() -> bool:
	return OS.get_name() == "Windows" or force_windows

static func _exists(path: String) -> bool:
	return FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path)

static func pending(path: String) -> bool:
	return _enabled() and (_exists(path + SUFFIX) or _exists(JSONLSidecar.path_for(path) + SUFFIX))

static func recover(path: String) -> String:
	if not pending(path): return ""
	# Reuse the existing process's hold (bootstrap/read_source/write checks).
	# This is the same advisory PID identity as FileLock, not authentication.
	if FileAccess.file_exists(path + ".lock") and not FileLock.held_by_other(path):
		return _recover_locked(path)
	var lock := FileLock.acquire(path)
	if lock == null: return "cannot acquire advisory lock to recover %s" % path
	var error := _recover_locked(path)
	lock.release()
	return error

static func _canonical(path: String) -> Dictionary:
	if DirAccess.dir_exists_absolute(path): return {"error":"unreadable canonical " + path}
	var bytes := FileAccess.get_file_as_bytes(path)
	if FileAccess.get_open_error() != OK: return {"error":"cannot read canonical " + path}
	var parsed := JSONLParser.parse_bytes(bytes, path)
	var error := JSONLCache._parsed_source_error(parsed, path)
	if error.is_empty(): error = str(parsed.get("read_only_reason", ""))
	if not error.is_empty(): return {"error":"invalid or unsupported canonical %s: %s" % [path, error]}
	return {"parsed":parsed, "sha":JSONLSidecar.sha256_bytes(bytes)}

static func _recover_locked(path: String) -> String:
	if not pending(path): return ""
	var backup := path + SUFFIX
	var wal := JSONLSidecar.path_for(path)
	# Validate ALL evidence before restoring/removing anything. A reserved name
	# implies ownership only; there is no independent origin receipt.
	var canonical := {}
	for candidate in [backup, path]:
		if not _exists(candidate): continue
		var checked := _canonical(candidate)
		if checked.has("error"): return "%s; recovery preserved target %s and backup %s" % [checked.error, path, backup]
		canonical = checked # Valid destination wins when both are present.
	if canonical.is_empty(): return "missing canonical for recovery of %s; files preserved" % path
	for candidate in [wal + SUFFIX, wal]:
		if not _exists(candidate): continue
		if DirAccess.dir_exists_absolute(candidate): return "unreadable WAL %s; recovery files preserved" % candidate
		var read := JSONLSidecar.read_bytes(candidate)
		if not str(read.error).is_empty(): return str(read.error)
		var error := JSONLSidecar.replay_into(canonical.parsed.duplicate(true), path, canonical.sha, read.bytes)
		if not error.is_empty(): return "invalid WAL %s; recovery files preserved: %s" % [candidate, error]
	for target in [path, wal]:
		var saved: String = target + SUFFIX
		if not _exists(saved): continue
		if not _exists(target):
			var error := DirAccess.rename_absolute(saved, target)
			if error != OK: return "cannot restore %s from %s (error %d); backup preserved" % [target, saved, error]
		else:
			var error := DirAccess.remove_absolute(saved)
			if error != OK: return "cannot remove recovered backup %s (error %d); files preserved" % [saved, error]
	return ""

static func _stage(stage: String, target: String, temp: String) -> String:
	return str(stage_hook.call(stage, target, temp)) if stage_hook.is_valid() else ""

static func replace(temp: String, target: String, wal: bool = false) -> String:
	if not _enabled():
		var error := DirAccess.rename_absolute(temp, target)
		return "" if error == OK else "cannot replace %s (error %d)" % [target, error]
	# Check BEFORE staging; the real missing-temp regression must leave old bytes.
	if not FileAccess.file_exists(temp): return "replacement temp is missing: " + temp
	var canonical := target.trim_suffix(JSONLSidecar.SUFFIX) if wal else target
	var recovery_error := recover(canonical)
	if not recovery_error.is_empty(): return recovery_error
	if DirAccess.dir_exists_absolute(target): return "replacement target is unreadable: " + target
	var backup := target + SUFFIX
	var staged := FileAccess.file_exists(target)
	if staged:
		var error := DirAccess.rename_absolute(target, backup)
		if error != OK: return "cannot stage %s at %s (error %d)" % [target, backup, error]
	var error := _stage("after_backup", target, temp)
	if error.is_empty():
		var moved := DirAccess.rename_absolute(temp, target)
		if moved != OK: error = "cannot install %s (error %d)" % [target, moved]
	if not error.is_empty():
		if staged:
			var restore_error := _stage("before_restore", target, temp)
			if restore_error.is_empty():
				var restored := DirAccess.rename_absolute(backup, target)
				if restored != OK: restore_error = "error %d" % restored
			if not restore_error.is_empty(): return "%s; cannot restore %s from %s (%s); backup preserved" % [error, target, backup, restore_error]
		return error
	# Installation committed. Cleanup failure is a warning, never rollback.
	var warning := _stage("after_install", target, temp)
	if warning.is_empty() and staged:
		warning = _stage("before_cleanup", target, temp)
		if warning.is_empty():
			var removed := DirAccess.remove_absolute(backup)
			if removed != OK: warning = "cannot remove committed backup %s (error %d)" % [backup, removed]
	if not warning.is_empty(): push_warning("JSONLReplace: " + warning)
	return ""
