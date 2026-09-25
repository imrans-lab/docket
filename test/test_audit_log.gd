extends Node
## Tests for the vault access audit log.

var A := AssertHelpers
var _test_dir := "user://test_audit_log"
var _dct: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func before_each() -> void:
	_dct = _test_dir + "/audited.dct"
	_cleanup()


func _cleanup() -> void:
	var cache := _dct + ".v2.cache"
	for p in [_dct, AuditLog.path_for(_dct), cache, cache + "-wal", cache + "-shm", _dct + ".lock"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func teardown() -> void:
	_cleanup()
	DirAccess.remove_absolute(_test_dir)


# -- Basics -------------------------------------------------------------------

func test_log_is_created_on_first_record() -> Variant:
	var r = A.is_true(not FileAccess.file_exists(AuditLog.path_for(_dct)), "no log before use")
	if r != true:
		return r
	AuditLog.record(_dct, AuditLog.READ, "db-password", true, "mcp")
	return A.is_true(FileAccess.file_exists(AuditLog.path_for(_dct)), "log created on first record")


func test_entries_append_rather_than_overwrite() -> Variant:
	AuditLog.record(_dct, AuditLog.READ, "one", true, "mcp")
	AuditLog.record(_dct, AuditLog.READ, "two", true, "mcp")
	AuditLog.record(_dct, AuditLog.WRITE, "three", true, "gui")
	return A.eq(AuditLog.read_entries(_dct).size(), 3, "all three entries retained")


func test_most_recent_first() -> Variant:
	AuditLog.record(_dct, AuditLog.READ, "older", true, "mcp")
	AuditLog.record(_dct, AuditLog.READ, "newer", true, "mcp")
	var entries := AuditLog.read_entries(_dct)
	return A.eq(str(entries[0].get("handle", "")), "newer", "newest entry comes first")


func test_limit_is_respected() -> Variant:
	for i in range(10):
		AuditLog.record(_dct, AuditLog.READ, "h%d" % i, true, "mcp")
	return A.eq(AuditLog.read_entries(_dct, 4).size(), 4, "limit caps returned entries")


func test_missing_log_reads_as_empty() -> Variant:
	return A.eq(AuditLog.read_entries(_dct).size(), 0, "absent log is not an error")


# -- Content ------------------------------------------------------------------

func test_failure_is_recorded_distinctly() -> Variant:
	AuditLog.record(_dct, AuditLog.UNLOCK_FAILED, "db-password", false, "mcp", "bad password")
	var e: Dictionary = AuditLog.read_entries(_dct)[0]
	var r = A.eq(bool(e.get("ok", true)), false, "failure recorded as ok=false")
	if r != true:
		return r
	return A.eq(str(e.get("event", "")), AuditLog.UNLOCK_FAILED, "event type preserved")


func test_entry_carries_timestamp_and_source() -> Variant:
	AuditLog.record(_dct, AuditLog.READ, "h", true, "gui")
	var e: Dictionary = AuditLog.read_entries(_dct)[0]
	var r = A.is_true(not str(e.get("ts", "")).is_empty(), "timestamp present")
	if r != true:
		return r
	return A.eq(str(e.get("source", "")), "gui", "source recorded")


func test_no_secret_material_is_written() -> Variant:
	## The log must record that access happened, never what was accessed.
	AuditLog.record(_dct, AuditLog.READ, "db-password", true, "mcp")
	var text := FileAccess.get_file_as_string(AuditLog.path_for(_dct))
	var r = A.contains(text, "db-password", "handle is recorded")
	if r != true:
		return r
	# The handle names the secret; nothing should carry a value or key field.
	var e: Dictionary = AuditLog.read_entries(_dct)[0]
	var forbidden := ["value", "plaintext", "password", "key", "ciphertext"]
	for k in forbidden:
		if e.has(k):
			return "audit entry contains forbidden field '%s'" % k
	return true


func test_every_line_is_valid_json() -> Variant:
	## The log is append-only from possibly-concurrent processes; a malformed
	## line would break reading the whole file.
	for i in range(5):
		AuditLog.record(_dct, AuditLog.READ, "h%d" % i, i % 2 == 0, "mcp", "note %d" % i)
	var text := FileAccess.get_file_as_string(AuditLog.path_for(_dct))
	for line in text.split("\n"):
		if line.strip_edges().is_empty():
			continue
		if JSON.parse_string(line) == null:
			return "non-JSON line in audit log: %s" % line
	return true


# -- Durability ---------------------------------------------------------------

func test_log_survives_cache_deletion() -> Variant:
	## The whole point of a sidecar: unlike transition_log and mcp_error_log, it
	## is not wiped when the SQLite cache is rebuilt after an external change.
	AuditLog.record(_dct, AuditLog.READ, "durable", true, "mcp")
	for suffix: String in [".cache", ".cache-wal", ".cache-shm"]:
		var p := _dct + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	return A.eq(AuditLog.read_entries(_dct).size(), 1, "entry survives cache removal")


func test_empty_path_is_ignored() -> Variant:
	## Auditing must never raise; a missing path is simply a no-op.
	AuditLog.record("", AuditLog.READ, "h", true, "mcp")
	return true


# -- Coordination -------------------------------------------------------------

func test_held_lock_skips_entry_not_secret_operation() -> Variant:
	## While another holder keeps the audit lock, a second is refused once its
	## deadline has passed, and a secret deletion still succeeds, its entry
	## skipped.
	## Once the lock is given back, a snapshot returns the sidecar's exact
	## bytes, a torn last line included.
	var db := DocketDBJsonl.create_new_jsonl(_dct)
	db.set_secret("scratch", "CT".to_utf8_buffer(), "IV".to_utf8_buffer(), "MAC".to_utf8_buffer())
	AuditLog.record(_dct, AuditLog.READ, "before", true, "mcp")
	var torn := FileAccess.open(AuditLog.path_for(_dct), FileAccess.READ_WRITE)
	torn.seek_end()
	torn.store_string("{\"event\": \"torn")
	torn.close()
	var before := FileAccess.get_file_as_bytes(AuditLog.path_for(_dct))

	var io: Object = ClassDB.instantiate("DocketFileIO")
	var held: Dictionary = io.audit_lock(ProjectSettings.globalize_path(_dct), 0)
	var started := Time.get_ticks_msec()
	var second: Dictionary = io.audit_lock(ProjectSettings.globalize_path(_dct), 100)
	var waited := Time.get_ticks_msec() - started
	var deleted := DocketSecretDelete.new().execute({"handle": "scratch"}, {}, db)
	if held.has("guard"):
		held.guard.release()
	db.close()
	var snapshot := AuditLog.snapshot(_dct)

	var r = A.is_true(held.has("guard") and second.get("kind") == "busy" and waited >= 100,
		"a second holder is refused after the wait it asked for: %s after %d ms" % [second, waited])
	if r != true:
		return r
	r = A.eq(deleted.get("deleted"), true, "the secret operation succeeds without its audit entry: %s" % deleted)
	if r != true:
		return r
	return A.is_true(snapshot.get("present") == true and snapshot.get("bytes") == before,
		"the snapshot is the sidecar's exact bytes, the torn line and no skipped entry: %s" % snapshot)
