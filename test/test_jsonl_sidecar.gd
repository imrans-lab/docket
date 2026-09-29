extends Node
## Write-ahead sidecar: a mutation leaves the canonical's bytes alone and adds
## one line to <canonical>.log; a settle folds the lines into the canonical and
## retires the sidecar; a process that dies before settling loses nothing.
##
## Every oracle is computed from files: the fixture's own text and sha256, the
## sidecar's line count, and record counts and probe strings in the canonical.

var A := AssertHelpers
const DIR := "user://test_jsonl_sidecar"
const FIXTURE := "res://test/fixtures/dynamic_types_record_order_v2.jsonl"


func setup() -> void: DirAccess.make_dir_recursive_absolute(DIR)
func teardown() -> void:
	var dir := DirAccess.open(DIR)
	if dir != null:
		for name in dir.get_files(): dir.remove(name)
	DirAccess.remove_absolute(DIR)


func _sidecar_lines(path: String) -> int:
	var sidecar := path + ".log"
	if not FileAccess.file_exists(sidecar): return 0
	return FileAccess.get_file_as_string(sidecar).split("\n", false).size()


func _count(text: String, needle: String) -> int:
	return text.count(needle)


func test_mutations_journal_settle_and_survive_a_crash_before_settling() -> Variant:
	var path := DIR + "/journal.dct"
	var fixture := FileAccess.get_file_as_string(FIXTURE)
	var out := FileAccess.open(path, FileAccess.WRITE); out.store_string(fixture); out.close()
	var fixture_sha := FileAccess.get_sha256(path)
	var fixture_comments := _count(fixture, '{"_type":"comment"')
	var db := DocketDBJsonl.open_jsonl(path)
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error

	# N ordinary mutations: canonical bytes untouched, exactly N sidecar lines.
	var errors: Array = []
	for i in 3:
		errors.append(str(db.add_comment("ORD-0001", "tester", "sidecar-probe-%d" % i).get("error", "")))
	errors.append(db.add_event_checked("ORD-0001", "noted", "tester", "sidecar-event-probe"))
	errors.append(db.update_item_fields_checked("ORD-0001", {"tags":["sidecar-tag-probe"]}))
	var n := errors.size()
	var r = A.eq(errors, ["", "", "", "", ""], "every mutation succeeds")
	if r is String: db.close(); return r
	r = A.eq(FileAccess.get_sha256(path), fixture_sha, "mutations leave the canonical's bytes unchanged")
	if r is String: db.close(); return r
	r = A.eq(_sidecar_lines(path), n, "one sidecar line per mutation")
	if r is String: db.close(); return r

	# A refusal leaves no trace: the lock file is held (FileLock is not
	# re-entrant, so this process waits too), the mutation fails before any
	# append, and the sidecar, the canonical and the reloaded cache lack it.
	var sidecar_bytes := FileAccess.get_file_as_bytes(path + ".log")
	var held := FileAccess.open(path + ".lock", FileAccess.WRITE)
	held.store_string(JSON.stringify({"pid": OS.get_process_id(), "timestamp": Time.get_unix_time_from_system()})); held.close()
	db._lock_timeout_ms = 200
	var refused := str(db.add_comment("ORD-0001", "tester", "refused-probe").get("error", ""))
	DirAccess.remove_absolute(path + ".lock")
	db._lock_timeout_ms = 5000
	var rows := db._exec_select("SELECT COUNT(*) AS n FROM comments WHERE text=?;", ["refused-probe"])
	r = A.is_true(not refused.is_empty() and FileAccess.get_file_as_bytes(path + ".log") == sidecar_bytes and FileAccess.get_sha256(path) == fixture_sha and rows.size() == 1 and int(rows[0].n) == 0, "a refused append leaves the sidecar's bytes, the canonical and the reloaded cache without it (%s)" % refused)
	if r is String: db.close(); return r

	# Inside the idle window nothing settles; past it, the debounce settles.
	db.settle_if_idle(Time.get_ticks_msec())
	r = A.eq(FileAccess.get_sha256(path), fixture_sha, "no settle inside the idle window")
	if r is String: db.close(); return r
	var settle_error := db.settle_if_idle(Time.get_ticks_msec() + DocketDBJsonl.SETTLE_IDLE_MS)
	var settled := FileAccess.get_file_as_string(path)
	r = A.is_true(settle_error.is_empty() and _sidecar_lines(path) == 0 and _count(settled, '{"_type":"comment"') == fixture_comments + 3, "settle empties the sidecar and the canonical holds the 3 comments (%s)" % settle_error)
	if r is String: db.close(); return r
	for probe in ["sidecar-probe-0", "sidecar-probe-1", "sidecar-probe-2", "sidecar-event-probe", "sidecar-tag-probe"]:
		r = A.contains(settled, probe, "settled canonical carries %s" % probe)
		if r is String: db.close(); return r

	# Crash with a warm cache: the process dies after an append, before settling.
	var settled_sha := FileAccess.get_sha256(path)
	errors = [str(db.add_comment("ORD-0001", "tester", "warm-crash-probe").get("error", ""))]
	db._jsonl_path = ""  # close() can no longer reach the files: no settle
	db.close()
	r = A.is_true(errors == [""] and FileAccess.get_sha256(path) == settled_sha and _sidecar_lines(path) == 1, "an unsettled append stays in the sidecar only: %s" % errors)
	if r is String: return r
	db = DocketDBJsonl.open_jsonl(path)
	if db == null: return "warm reopen failed: %s" % DocketDBJsonl.last_open_error
	var reopened := FileAccess.get_file_as_string(path)
	r = A.is_true(_sidecar_lines(path) == 0 and reopened.contains("warm-crash-probe") and _count(reopened, '{"_type":"comment"') == fixture_comments + 4, "reopen compacts the surviving record into the canonical")
	if r is String: db.close(); return r

	# Crash with no cache at all: the record is recovered by replaying the sidecar.
	errors = [str(db.add_comment("ORD-0001", "tester", "cold-crash-probe").get("error", ""))]
	db._jsonl_path = ""
	db.close()
	JSONLCache.delete_cache_family(path)
	r = A.is_true(errors == [""] and _sidecar_lines(path) == 1 and not FileAccess.get_file_as_string(path).contains("cold-crash-probe"), "second unsettled append is journaled only: %s" % errors)
	if r is String: return r
	db = DocketDBJsonl.open_jsonl(path)
	if db == null: return "cold reopen failed: %s" % DocketDBJsonl.last_open_error
	db.close()
	var replayed := FileAccess.get_file_as_string(path)
	r = A.is_true(_sidecar_lines(path) == 0 and _count(replayed, '{"_type":"comment"') == fixture_comments + 5, "replay after a cold crash compacts every record")
	if r is String: return r
	for probe in ["sidecar-probe-0", "sidecar-tag-probe", "warm-crash-probe", "cold-crash-probe"]:
		r = A.contains(replayed, probe, "replayed canonical carries %s" % probe)
		if r is String: return r
	return true


func test_a_step_failing_after_the_append_cuts_the_sidecar_back() -> Variant:
	## The write hook performs the real append, then drops the dirty table, so
	## JSONLSidecar.clear_dirty (the step after the append, inside the same lock
	## hold) fails. _commit_mutation cuts the sidecar back to its prior length
	## and the transaction rolls back; the next mutation appends normally.
	var path := DIR + "/undo.dct"
	var sidecar := path + ".log"
	var out := FileAccess.open(path, FileAccess.WRITE); out.store_string(FileAccess.get_file_as_string(FIXTURE)); out.close()
	var db := DocketDBJsonl.open_jsonl(path)
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var r = A.eq(str(db.add_comment("ORD-0001", "tester", "undo-before-probe").get("error", "")), "", "a first record journals, so the cut-back is a resize")
	if r is String: db.close(); return r
	var canonical_sha := FileAccess.get_sha256(path)
	var sidecar_before := FileAccess.get_file_as_bytes(sidecar)

	var appended_lengths: Array = []
	db._atomic_write_hook = func(target: String, text: String) -> String:
		var error := JSONLSidecar.append(target, text)
		appended_lengths.append(JSONLSidecar.length_of(target))
		if error.is_empty(): error = db._exec_checked("DROP TABLE temp.sidecar_dirty;")
		return error
	var failed := str(db.add_comment("ORD-0001", "tester", "undo-probe").get("error", ""))
	db._atomic_write_hook = Callable()
	r = A.is_true(not failed.is_empty() and appended_lengths.size() == 1 and int(appended_lengths[0]) > sidecar_before.size(), "the append landed and the later step failed (%s, lengths %s)" % [failed, appended_lengths])
	if r is String: db.close(); return r
	r = A.is_true(FileAccess.get_file_as_bytes(sidecar) == sidecar_before and FileAccess.get_sha256(path) == canonical_sha, "the sidecar is cut back to its exact prior bytes and the canonical is untouched")
	if r is String: db.close(); return r
	var rows := db._exec_select("SELECT COUNT(*) AS n FROM comments WHERE text=?;", ["undo-probe"])
	r = A.is_true(rows.size() == 1 and int(rows[0].n) == 0, "the reloaded cache has no row for the failed mutation")
	if r is String: db.close(); return r

	r = A.eq(str(db.add_comment("ORD-0001", "tester", "undo-after-probe").get("error", "")), "", "the next mutation succeeds")
	if r is String: db.close(); return r
	var sidecar_after := FileAccess.get_file_as_bytes(sidecar)
	var new_lines := sidecar_after.slice(sidecar_before.size()).get_string_from_utf8().split("\n", false)
	db._jsonl_path = ""  # no settle on close: the sidecar is the oracle
	db.close()
	return A.is_true(sidecar_after.slice(0, sidecar_before.size()) == sidecar_before and new_lines.size() == 1 and new_lines[0].contains("undo-after-probe") and not new_lines[0].contains("undo-probe\""), "the next record is the sidecar's only new line (%d new)" % new_lines.size())


func test_a_damaged_or_unreadable_sidecar_refuses_the_load_and_is_kept() -> Variant:
	## A sidecar holding a NUL byte, and one that exists but cannot be read, both
	## refuse the open; the canonical's bytes and the sidecar file stay as they
	## were. The unreadable half needs permissions this runner can drop (not
	## root, not Windows); where it cannot, it is skipped and says so.
	var path := DIR + "/damaged.dct"
	var sidecar := path + ".log"
	var out := FileAccess.open(path, FileAccess.WRITE); out.store_string(FileAccess.get_file_as_string(FIXTURE)); out.close()
	var db := DocketDBJsonl.open_jsonl(path)
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var error := str(db.add_comment("ORD-0001", "tester", "damaged-probe").get("error", ""))
	db._jsonl_path = ""  # crash before settling: the record lives only in the sidecar
	db.close()
	var canonical_bytes := FileAccess.get_file_as_bytes(path)
	var good_sidecar := FileAccess.get_file_as_bytes(sidecar)
	var r = A.is_true(error.is_empty() and not good_sidecar.is_empty(), "the record is journaled (%s)" % error)
	if r is String: return r

	# A NUL byte after the acknowledged record.
	var damaged := good_sidecar.duplicate()
	damaged.append_array(PackedByteArray([0, 10]))
	out = FileAccess.open(sidecar, FileAccess.WRITE); out.store_buffer(damaged); out.close()
	r = A.is_null(DocketDBJsonl.open_jsonl(path), "a sidecar with a NUL byte refuses the open")
	if r is String: return r
	r = A.is_true(FileAccess.get_file_as_bytes(path) == canonical_bytes and FileAccess.get_file_as_bytes(sidecar) == damaged, "after the NUL refusal the canonical and the sidecar keep their bytes")
	if r is String: return r
	out = FileAccess.open(sidecar, FileAccess.WRITE); out.store_buffer(good_sidecar); out.close()

	# An existing sidecar this process cannot read.
	var sidecar_os := ProjectSettings.globalize_path(sidecar)
	var dropped := OS.get_name() != "Windows" and OS.execute("chmod", ["000", sidecar_os]) == 0 and FileAccess.open(sidecar, FileAccess.READ) == null
	if dropped:
		var reopened := DocketDBJsonl.open_jsonl(path)
		var still_there := FileAccess.file_exists(sidecar)
		OS.execute("chmod", ["644", sidecar_os])
		if reopened != null: reopened.close()
		r = A.is_true(reopened == null and still_there and FileAccess.get_file_as_bytes(path) == canonical_bytes and FileAccess.get_file_as_bytes(sidecar) == good_sidecar, "an unreadable sidecar refuses the open and neither file changes")
		if r is String: return r
	else:
		OS.execute("chmod", ["644", sidecar_os])
		print("  SKIP unreadable-sidecar half: this runner cannot drop read permission on %s" % sidecar_os)

	# Control: the same sidecar, readable and clean, opens and compacts.
	db = DocketDBJsonl.open_jsonl(path)
	if db == null: return "clean sidecar did not open: %s" % DocketDBJsonl.last_open_error
	db.close()
	return A.is_true(FileAccess.get_file_as_string(path).contains("damaged-probe") and not FileAccess.file_exists(sidecar), "once repaired, the record reaches the canonical and the sidecar is retired")
