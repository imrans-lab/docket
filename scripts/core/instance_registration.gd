extends RefCounted
class_name InstanceRegistration
## One discovery record per profile. SQLite serializes publishers and cleanup;
## its OS lock releases on a crash, without a second claim/lease protocol.

const FILE_NAME := "instance.json"
const LOCK_NAME := "instance.lock.sqlite"
var status: String = "not_registered"
var _profile: String
var _path: String
var _lock_path: String
var _lock_db: SQLite
var _published: String = ""
var _pid: int
var _started_at: String


func _init(profile: String, pid: int, started_at: String) -> void:
	_profile = profile
	_path = profile.path_join(FILE_NAME)
	_lock_path = profile.path_join(LOCK_NAME)
	_pid = pid
	_started_at = started_at


func publish(version: String, protocol_version: String, port: int) -> String:
	if not _take_lock():
		status = "lock_unavailable"
		return status
	var exists := FileAccess.file_exists(_path)
	var existing: String = FileAccess.get_file_as_string(_path) if exists else ""
	var refusal := ""
	if not _published.is_empty():
		if existing != _published:
			refusal = "record_changed"
	elif exists:
		var existing_pid := _read_pid(existing)
		if existing_pid <= 0 or (existing_pid != _pid and FileLock.is_pid_running(existing_pid)):
			refusal = "profile_occupied"
	if refusal.is_empty():
		var payload := JSON.stringify({"pid":_pid, "version":version, "protocol_version":protocol_version,
			"endpoint":{"host":"127.0.0.1", "port":port}, "profile":_profile, "started_at":_started_at})
		var temporary := _profile.path_join("instance.%d.tmp" % _pid)
		var error := _write(temporary, payload)
		if error == OK:
			error = DirAccess.rename_absolute(temporary, _path)
		if error == OK:
			_published = payload
		else:
			refusal = "write_failed"
			_remove_matching(temporary, payload)
	if not _release_lock():
		refusal = "commit_failed"
	status = "registered" if refusal.is_empty() else refusal
	return status


func close() -> void:
	if _published.is_empty():
		return
	if not _take_lock():
		status = "cleanup_lock_unavailable"
		push_warning("Docket instance registration: " + status)
		return
	_remove_matching(_path, _published)
	var committed := _release_lock()
	_published = ""
	status = "closed" if committed else "cleanup_commit_failed"


func _take_lock() -> bool:
	_lock_db = SQLite.new()
	_lock_db.path = _lock_path
	_lock_db.verbosity_level = SQLite.QUIET
	if _lock_db.open_db() and _lock_db.query("PRAGMA busy_timeout=5000;") and _lock_db.query("BEGIN IMMEDIATE;"):
		return true
	_lock_db.close_db()
	_lock_db = null
	return false


func _release_lock() -> bool:
	var committed := _lock_db.query("COMMIT;")
	if not committed:
		push_warning("Docket instance registration: lock commit failed")
	_lock_db.close_db()
	_lock_db = null
	return committed


static func _read_pid(raw: String) -> int:
	var parsed: Variant = JSON.parse_string(raw)
	if not parsed is Dictionary:
		return -1
	var value: Variant = parsed.get("pid")
	if not (value is int or value is float) or float(value) <= 0 or float(value) > 4294967295 or float(value) != floor(float(value)):
		return -1
	return int(value)


static func _write(path: String, payload: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(payload)
	file.flush()
	var error := file.get_error()
	file.close()
	return error


static func _remove_matching(path: String, payload: String) -> void:
	if not payload.is_empty() and FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) == payload:
		if DirAccess.remove_absolute(path) != OK:
			push_warning("Docket instance registration: record cleanup failed")
