extends Node
## Unit tests for FileLock — advisory .lock file locking.

var A := AssertHelpers
var _test_dir := "user://test_file_lock"
var _target_path: String


# -- Setup / teardown ---------------------------------------------------------

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func before_each() -> void:
	_target_path = _test_dir + "/test.dct.jsonl"
	_cleanup_locks()


func _cleanup_locks() -> void:
	var lock_path := _target_path + ".lock"
	if FileAccess.file_exists(lock_path):
		DirAccess.remove_absolute(lock_path)


func teardown() -> void:
	_cleanup_locks()
	DirAccess.remove_absolute(_test_dir)


# -- Basic acquire / release --------------------------------------------------

func test_acquire_creates_lock_file() -> Variant:
	var lock := FileLock.acquire(_target_path)
	var r = A.not_null(lock, "acquire returns non-null")
	if r is String:
		if lock != null:
			lock.release()
		return r
	r = A.is_true(FileAccess.file_exists(_target_path + ".lock"), "lock file exists")
	lock.release()
	return r


func test_release_removes_lock_file() -> Variant:
	var lock := FileLock.acquire(_target_path)
	var r = A.not_null(lock, "lock acquired")
	if r is String:
		return r
	lock.release()
	return A.is_false(FileAccess.file_exists(_target_path + ".lock"), "lock file removed after release")


func test_is_locked_true_while_held() -> Variant:
	var lock := FileLock.acquire(_target_path)
	var r = A.not_null(lock, "lock acquired")
	if r is String:
		return r
	r = A.is_true(lock.is_locked(), "is_locked() true while held")
	lock.release()
	return r


func test_is_locked_false_after_release() -> Variant:
	var lock := FileLock.acquire(_target_path)
	var r = A.not_null(lock, "lock acquired")
	if r is String:
		return r
	lock.release()
	return A.is_false(lock.is_locked(), "is_locked() false after release")


func test_double_release_is_safe() -> Variant:
	var lock := FileLock.acquire(_target_path)
	var r = A.not_null(lock, "lock acquired")
	if r is String:
		return r
	lock.release()
	lock.release()  # Should not crash or error
	return A.is_false(lock.is_locked(), "still not locked after double release")


# -- Lock file contents -------------------------------------------------------

func test_lock_file_contains_valid_json() -> Variant:
	var lock := FileLock.acquire(_target_path)
	var r = A.not_null(lock, "lock acquired")
	if r is String:
		return r

	var f := FileAccess.open(_target_path + ".lock", FileAccess.READ)
	r = A.not_null(f, "lock file readable")
	if r is String:
		lock.release()
		return r

	var raw := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(raw)
	r = A.not_null(parsed, "lock file contains valid JSON")
	if r is String:
		lock.release()
		return r

	lock.release()
	return A.is_true(parsed is Dictionary, "parsed JSON is a Dictionary")


func test_lock_file_has_pid_field() -> Variant:
	var lock := FileLock.acquire(_target_path)
	var r = A.not_null(lock, "lock acquired")
	if r is String:
		return r

	var f := FileAccess.open(_target_path + ".lock", FileAccess.READ)
	var raw := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(raw)
	lock.release()

	r = A.not_null(parsed, "parsed JSON not null")
	if r is String:
		return r
	return A.is_true(parsed.has("pid"), "lock file has 'pid' field")


func test_lock_file_has_timestamp_field() -> Variant:
	var lock := FileLock.acquire(_target_path)
	var r = A.not_null(lock, "lock acquired")
	if r is String:
		return r

	var f := FileAccess.open(_target_path + ".lock", FileAccess.READ)
	var raw := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(raw)
	lock.release()

	r = A.not_null(parsed, "parsed JSON not null")
	if r is String:
		return r
	return A.is_true(parsed.has("timestamp"), "lock file has 'timestamp' field")


func test_lock_file_pid_matches_current_process() -> Variant:
	var lock := FileLock.acquire(_target_path)
	var r = A.not_null(lock, "lock acquired")
	if r is String:
		return r

	var f := FileAccess.open(_target_path + ".lock", FileAccess.READ)
	var raw := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(raw)
	lock.release()

	r = A.not_null(parsed, "parsed JSON not null")
	if r is String:
		return r
	return A.eq(int(parsed.get("pid", -1)), OS.get_process_id(), "PID matches current process")


# -- Stale lock detection -----------------------------------------------------

func test_stale_lock_by_age_is_broken() -> Variant:
	## Write a lock file with a timestamp far in the past.
	var lock_path := _target_path + ".lock"
	var old_payload := JSON.stringify({
		"pid": OS.get_process_id(),
		"timestamp": Time.get_unix_time_from_system() - 120.0,  # 2 minutes ago
	})
	var f := FileAccess.open(lock_path, FileAccess.WRITE)
	var r = A.not_null(f, "wrote stale lock file")
	if r is String:
		return r
	f.store_string(old_payload)
	f.close()

	# acquire() should break the stale lock and succeed
	var lock := FileLock.acquire(_target_path, 1000)
	r = A.not_null(lock, "acquire broke stale lock")
	if lock != null:
		lock.release()
	return r


func test_stale_lock_by_dead_pid_is_broken() -> Variant:
	## Write a lock file with a very large impossible PID and a recent timestamp.
	## On Linux, /proc/<pid> won't exist for a dead PID, so acquire() should
	## treat it as stale, remove it, and succeed.
	var lock_path := _target_path + ".lock"
	# PID 999999 is far above the typical kernel.pid_max (~4194304 max on modern
	# Linux) but use a value that definitely won't be a live process. We pick a
	# value in the valid but very-high range. If for some reason it happens to be
	# a live PID the test would fail, but that's astronomically unlikely.
	var impossible_pid := 999997
	var payload := JSON.stringify({
		"pid": impossible_pid,
		"timestamp": Time.get_unix_time_from_system(),
	})
	var f := FileAccess.open(lock_path, FileAccess.WRITE)
	var r = A.not_null(f, "wrote dead-pid lock file")
	if r is String:
		return r
	f.store_string(payload)
	f.close()

	# On Linux: /proc/999997 won't exist → _is_pid_running returns false → stale
	var lock := FileLock.acquire(_target_path, 1000)
	r = A.not_null(lock, "acquire broke dead-pid lock")
	if lock != null:
		lock.release()
	return r


func test_corrupt_lock_file_treated_as_stale() -> Variant:
	## A lock file with invalid JSON should be treated as stale and broken.
	var lock_path := _target_path + ".lock"
	var f := FileAccess.open(lock_path, FileAccess.WRITE)
	var r = A.not_null(f, "wrote corrupt lock file")
	if r is String:
		return r
	f.store_string("this is not json {{{")
	f.close()

	var lock := FileLock.acquire(_target_path, 1000)
	r = A.not_null(lock, "acquire broke corrupt lock")
	if lock != null:
		lock.release()
	return r


# -- Timeout ------------------------------------------------------------------

func test_acquire_times_out_on_active_lock() -> Variant:
	## Simulate an active lock held by the current PID but with a very recent
	## timestamp, then try to acquire with a very short timeout.
	var lock_path := _target_path + ".lock"
	var payload := JSON.stringify({
		"pid": OS.get_process_id(),  # Our own PID — so it's "running"
		"timestamp": Time.get_unix_time_from_system(),
	})
	var f := FileAccess.open(lock_path, FileAccess.WRITE)
	var r = A.not_null(f, "wrote active lock file")
	if r is String:
		return r
	f.store_string(payload)
	f.close()

	# Short timeout — should fail quickly
	var lock := FileLock.acquire(_target_path, 200)

	# Clean up the fake lock regardless of outcome
	if FileAccess.file_exists(lock_path):
		DirAccess.remove_absolute(lock_path)
	if lock != null:
		lock.release()

	# Expect null (timeout) — but since the PID is our own and the file was
	# created by us (not _try_create_lock), PID check passes so it won't be
	# treated as stale. acquire() should time out and return null.
	return A.is_null(lock, "acquire returned null on timeout")


# -- Lock path ----------------------------------------------------------------

func test_lock_path_is_target_plus_dot_lock() -> Variant:
	var lock := FileLock.acquire(_target_path)
	var r = A.not_null(lock, "lock acquired")
	if r is String:
		return r
	r = A.is_true(FileAccess.file_exists(_target_path + ".lock"), ".lock path correct")
	lock.release()
	return r


# -- Integration: DocketDBJsonl uses lock on flush ----------------------------

func test_flush_creates_and_removes_lock() -> Variant:
	## After a mutation, the .lock file must be gone (released after write).
	var jsonl_path := _test_dir + "/proj.dct.jsonl"
	var lock_path := jsonl_path + ".lock"

	var db := DocketDBJsonl.create_new_jsonl(jsonl_path)
	var r = A.not_null(db, "db created")
	if r is String:
		return r

	# Force a mutation to trigger _flush_jsonl
	db.set_project_name("lock-test")

	# Lock file must not exist after flush completes
	r = A.is_false(FileAccess.file_exists(lock_path), "lock file removed after flush")

	# Cleanup
	db._jsonl_path = ""
	db.close()
	for p: String in [jsonl_path, jsonl_path + ".cache", jsonl_path + ".cache-wal", jsonl_path + ".cache-shm"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

	return r
