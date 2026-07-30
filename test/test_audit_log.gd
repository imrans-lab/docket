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
	for p in [_dct, AuditLog.path_for(_dct)]:
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
