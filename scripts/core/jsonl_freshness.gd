extends RefCounted
class_name JSONLFreshness
## Content identity (sha256) of a canonical file that skips re-reading it while
## nothing can have changed it since this instance last hashed it.
##
## A hash is reused only while (a) the file's mtime and size equal those seen
## on both sides of that hash, (b) the hash started at least MTIME_WINDOW_SEC
## after the file's mtime, and (c) no other process's lock file is present.
## FileAccess.get_modified_time returns whole seconds, so mtime + size alone can
## collide on an equal-length rewrite inside one second. Condition (b) closes
## that: every write after the hash started happens at a wall-clock time past
## the window and so carries a newer mtime. A rename carries the renamed file's
## mtime, not the rename's time, so a writer that replaces the canonical by
## rename writes the temp file's last byte immediately before the rename, under
## the FileLock (DocketDBJsonl._atomic_write). A hash taken inside the window
## (typically right after our own settle) is used once and not reused; the
## first check past the window hashes again and is reused from then on. The window is 2 s so that 2-second FAT timestamps are covered too.
##
## Lock evidence: a lock file naming another process (another Docket, or
## Minerva's integrated Docket, which uses the same .lock format) means a
## cooperating writer is active, so the caller gets a full hash. A caller whose
## own lock acquisition had to wait passes force_full for the same reason.

const MTIME_WINDOW_SEC := 2

## hash_file calls per path in this process. Instrumentation for tests; a
## read of the file through any other API is not counted.
static var hash_reads: Dictionary = {}

var _path := ""
var _mtime := -1
var _size := -1
var _sha := ""


static func hash_file(path: String) -> String:
	## Every content hash of a canonical or sidecar goes through here.
	hash_reads[path] = int(hash_reads.get(path, 0)) + 1
	return FileAccess.get_sha256(path)


func canonical_sha(path: String, force_full: bool = false) -> String:
	## sha256 of the file at path, or "" when it is missing or unreadable.
	# Taken before the first stat, so a reusable hash provably started after
	# every write that its recorded mtime could stand for.
	var started_at := Time.get_unix_time_from_system()
	if not FileAccess.file_exists(path):
		forget()
		return ""
	var mtime := FileAccess.get_modified_time(path)
	var size := _size_of(path)
	if not force_full and path == _path and mtime == _mtime and size == _size and not FileLock.held_by_other(path):
		return _sha
	forget()
	var sha := hash_file(path)
	if sha.is_empty() or mtime <= 0 or size < 0 or started_at < mtime + MTIME_WINDOW_SEC:
		return sha
	if FileAccess.get_modified_time(path) == mtime and _size_of(path) == size and not FileLock.held_by_other(path):
		_path = path
		_mtime = mtime
		_size = size
		_sha = sha
	return sha


func forget() -> void:
	_path = ""
	_mtime = -1
	_size = -1
	_sha = ""


static func _size_of(path: String) -> int:
	## Opening for the length reads none of the file's bytes.
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f != null else -1
