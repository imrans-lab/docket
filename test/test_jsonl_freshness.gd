extends Node
## Tests for merge-safety behaviour:
##   - unresolved git conflict markers are refused, not silently unioned
##   - a cache that went stale (git pull) is reloaded rather than clobbering
##   - an own write is not re-read; a foreign edit or lock holder still is
##   - JSONLValidator reporting
##   - events read back in chronological order regardless of file line order

var A := AssertHelpers
var _test_dir := "user://test_jsonl_freshness"
var _path: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func before_each() -> void:
	_path = _test_dir + "/fresh.dct"
	_cleanup()


func _cleanup() -> void:
	for suffix: String in ["", ".cache", ".cache-wal", ".cache-shm", ".v2.cache", ".v2.cache-wal", ".v2.cache-shm", ".lock", ".log"]:
		var p := _path + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func teardown() -> void:
	_cleanup()
	DirAccess.remove_absolute(_test_dir)


func _write(text: String) -> void:
	var f := FileAccess.open(_path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read() -> String:
	var f := FileAccess.open(_path, FileAccess.READ)
	var t := f.get_as_text()
	f.close()
	return t


const META := '{"_type":"meta","version":"1.0.0","counter":0,"id_prefix":"TST"}'


func _item_line(id: String, title: String) -> String:
	return ('{"_type":"item","id":"%s","type":"chore","status":"open","title":"%s",'
		+ '"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}') % [id, title]


# -- Conflict markers ---------------------------------------------------------

func test_parser_refuses_conflict_markers() -> Variant:
	_write(META + "\n<<<<<<< HEAD\n" + _item_line("a1", "ours")
		+ "\n=======\n" + _item_line("a2", "theirs") + "\n>>>>>>> branch\n")
	var parsed := JSONLParser.parse_file(_path)
	var r = A.is_true(not str(parsed.get("error", "")).is_empty(), "parse_file reports an error")
	if r != true:
		return r
	return A.contains(str(parsed["error"]), "conflict marker", "error names the cause")


func test_parser_reports_conflict_line_number() -> Variant:
	_write(META + "\n" + _item_line("a1", "one") + "\n<<<<<<< HEAD\n")
	var parsed := JSONLParser.parse_file(_path)
	return A.contains(str(parsed["error"]), "line 3", "error carries the line number")


func test_open_jsonl_refuses_conflicted_file() -> Variant:
	_write(META + "\n<<<<<<< HEAD\n" + _item_line("a1", "ours") + "\n")
	var db := DocketDBJsonl.open_jsonl(_path)
	var r = A.eq(db, null, "open_jsonl returns null on a conflicted file")
	if r != true:
		return r
	return A.contains(DocketDBJsonl.last_open_error, "conflict marker", "reason is reported")


func test_conflicted_file_is_left_untouched() -> Variant:
	## The file must survive a refused open — it is the only copy of the data.
	var original := META + "\n<<<<<<< HEAD\n" + _item_line("a1", "ours") + "\n"
	_write(original)
	DocketDBJsonl.open_jsonl(_path)
	var r = A.eq(_read(), original, "file content is unchanged")
	if r != true:
		return r
	return A.is_true(not FileAccess.file_exists(_path + ".cache"), "no cache was built")


func test_clean_file_still_opens() -> Variant:
	_write(META + "\n" + _item_line("a1", "fine") + "\n")
	var db := DocketDBJsonl.open_jsonl(_path)
	var r = A.not_null(db, "a clean file opens")
	if r != true:
		return r
	var item := db.get_item("a1")
	db.close()
	return A.eq(str(item.get("title", "")), "fine", "item is readable")


# -- Staleness / reload -------------------------------------------------------

func test_external_change_marks_cache_stale() -> Variant:
	_write(META + "\n" + _item_line("a1", "one") + "\n")
	var db := DocketDBJsonl.open_jsonl(_path)
	var r = A.is_true(not db.is_stale(), "freshly opened cache is not stale")
	if r != true:
		db.close()
		return r
	# Simulate a git pull bringing in another machine's item
	_write(META + "\n" + _item_line("a1", "one") + "\n" + _item_line("a2", "pulled") + "\n")
	r = A.is_true(db.is_stale(), "external write marks the cache stale")
	db.close()
	return r


func test_ensure_fresh_picks_up_external_item() -> Variant:
	_write(META + "\n" + _item_line("a1", "one") + "\n")
	var db := DocketDBJsonl.open_jsonl(_path)
	_write(META + "\n" + _item_line("a1", "one") + "\n" + _item_line("a2", "pulled") + "\n")

	var reloaded := db.ensure_fresh()
	var r = A.is_true(reloaded, "ensure_fresh reports a reload")
	if r != true:
		db.close()
		return r
	var pulled := db.get_item("a2")
	db.close()
	return A.eq(str(pulled.get("title", "")), "pulled", "externally added item is visible")


func test_mutation_after_pull_does_not_clobber() -> Variant:
	## The core regression: a write must not rewrite the file from a stale
	## cache, discarding whatever arrived on disk in the meantime.
	_write(META + "\n" + _item_line("a1", "one") + "\n")
	var db := DocketDBJsonl.open_jsonl(_path)

	_write(META + "\n" + _item_line("a1", "one") + "\n" + _item_line("a2", "pulled") + "\n")
	db.ensure_fresh()
	db.insert_item("a3", {
		"id": "a3", "type": "chore", "status": "open", "title": "local",
		"created_at": "2026-01-02T00:00:00", "updated_at": "2026-01-02T00:00:00",
	})

	db.close()
	var text := _read()
	var r = A.contains(text, "\"a2\"", "pulled item survived the local write")
	if r != true:
		return r
	return A.contains(text, "\"a3\"", "local item was written")


func _canonical_reads() -> int:
	return int(JSONLFreshness.hash_reads.get(_path, 0))


func test_own_write_skips_the_rehash_and_a_foreign_edit_is_still_detected() -> Variant:
	## Oracles: JSONLFreshness.hash_reads counts hash_file calls on the
	## canonical, not bytes read; it sits inside the module under test, so a
	## read through another API would not show. Detection is judged from the
	## file's own bytes after a hand edit this test makes.
	_write(META + "\n" + _item_line("a1", "one") + "\n" + _item_line("a2", "original") + "\n")
	var db := DocketDBJsonl.open_jsonl(_path)
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var errors: Array = [db.add_event_checked("a1", "noted", "tester", "before-settle"), db.flush_checked()]
	# Our settle was the canonical's last write. Past the mtime window the first
	# check hashes once; after that our own writes cost no canonical read.
	while Time.get_unix_time_from_system() < FileAccess.get_modified_time(_path) + JSONLFreshness.MTIME_WINDOW_SEC + 0.1:
		OS.delay_msec(100)
	errors.append(db.add_event_checked("a1", "noted", "tester", "first-past-window"))
	var reads := _canonical_reads()
	for i in 3: errors.append(db.add_event_checked("a1", "noted", "tester", "own-write-probe-%d" % i))
	var r = A.is_true(errors == ["", "", "", "", "", ""] and _canonical_reads() == reads, "mutations after our own write read nothing of the canonical: %s, %d reads" % [errors, _canonical_reads() - reads])
	if r != true: db.close(); return r

	# A lock file naming another process forces the full check.
	var lock := FileAccess.open(_path + ".lock", FileAccess.WRITE)
	lock.store_string(JSON.stringify({"pid": OS.get_process_id() + 1, "timestamp": Time.get_unix_time_from_system()}))
	lock.close()
	var stale := db.is_stale()
	DirAccess.remove_absolute(_path + ".lock")
	r = A.is_true(not stale and _canonical_reads() == reads + 1, "a foreign lock holder forces one full hash")
	if r != true: db.close(); return r
	# Re-establish a reusable hash so detection below rests on the stat alone.
	db.is_stale()
	reads = _canonical_reads()
	db.is_stale()
	r = A.eq(_canonical_reads(), reads, "with the lock gone the hash is reused again")
	if r != true: db.close(); return r

	# A foreign in-place edit of equal length (same file, same size).
	var text := _read()
	var edited := text.replace('"title":"original"', '"title":"handedit"')
	r = A.is_true(edited != text and edited.length() == text.length(), "hand edit applies and keeps the length")
	if r != true: db.close(); return r
	var out := FileAccess.open(_path, FileAccess.READ_WRITE)
	out.store_string(edited)
	out.close()
	reads = _canonical_reads()
	errors = [db.add_event_checked("a1", "noted", "tester", "after-foreign-probe"), db.flush_checked()]
	db.close()
	var final_text := _read()
	r = A.is_true(errors == ["", ""] and _canonical_reads() > reads, "the foreign edit is hashed: %s" % [errors])
	if r != true: return r
	r = A.contains(final_text, '"title":"handedit"', "the hand edit survives our next write (reloaded, not clobbered)")
	if r != true: return r
	r = A.is_true(not final_text.contains('"title":"original"'), "the pre-edit title is gone")
	if r != true: return r
	return A.contains(final_text, "after-foreign-probe", "our mutation after the foreign edit is written")


func test_reload_recovers_after_conflict_is_resolved() -> Variant:
	_write(META + "\n" + _item_line("a1", "one") + "\n")
	var db := DocketDBJsonl.open_jsonl(_path)

	# Someone leaves a conflicted file on disk: reload refuses it...
	_write(META + "\n<<<<<<< HEAD\n" + _item_line("a2", "ours") + "\n")
	var r = A.is_true(not db.reload(), "reload refuses a conflicted file")
	if r != true:
		db.close()
		return r
	# ...and the process stays usable rather than dying
	r = A.eq(str(db.get_item("a1").get("title", "")), "one", "previous data still readable")
	if r != true:
		db.close()
		return r

	# ...then the conflict is resolved and reload succeeds
	_write(META + "\n" + _item_line("a1", "one") + "\n" + _item_line("a2", "ours") + "\n")
	r = A.is_true(db.reload(), "reload succeeds once resolved")
	if r != true:
		db.close()
		return r
	var recovered := db.get_item("a2")
	db.close()
	return A.eq(str(recovered.get("title", "")), "ours", "resolved content is loaded")


# -- Validator ----------------------------------------------------------------

func test_validator_flags_conflict_markers() -> Variant:
	_write(META + "\n<<<<<<< HEAD\n")
	var report := JSONLValidator.validate_file(_path)
	var r = A.is_true(not report["ok"], "conflicted file is not ok")
	if r != true:
		return r
	return A.eq(report["errors"].size(), 1, "one error reported")


func test_validator_flags_duplicate_ids() -> Variant:
	## What a merge leaves behind when both sides edited the same item.
	_write(META + "\n" + _item_line("a1", "ours") + "\n" + _item_line("a1", "theirs") + "\n")
	var report := JSONLValidator.validate_file(_path)
	var r = A.is_true(not report["ok"], "duplicate ids make the file invalid")
	if r != true:
		return r
	return A.contains(str(report["errors"]), "duplicate item id", "names the problem")


func test_validator_refuses_orphaned_events_without_rewriting_source() -> Variant:
	var canonical := (META + "\n" + _item_line("a1", "one") + "\n"
		+ '{"_type":"event","item_id":"ghost","seq":1,"event_type":"created","timestamp":"2026-01-01T00:00:00"}' + "\n")
	_write(canonical)
	var report := JSONLValidator.validate_file(_path)
	var r = A.is_false(report["ok"], "orphaned canonical records are refused")
	if r is String: return r
	r = A.contains(str(report["errors"]), "ghost", "error names the missing item")
	if r is String: return r
	var file := FileAccess.open(_path, FileAccess.READ)
	var preserved := file.get_as_text()
	file.close()
	return A.eq(preserved, canonical, "validation does not rewrite the refused source")


func test_validator_accepts_clean_file() -> Variant:
	_write(META + "\n" + _item_line("a1", "one") + "\n")
	var report := JSONLValidator.validate_file(_path)
	var r = A.is_true(report["ok"], "clean file validates")
	if r != true:
		return r
	return A.eq(report["errors"].size(), 0, "no errors")


# -- Event ordering -----------------------------------------------------------

func test_events_read_back_chronologically() -> Variant:
	## A merge can interleave event lines out of order ("ours" before "theirs").
	## Reads must sort by timestamp so history is not silently reordered.
	_write(META + "\n" + _item_line("a1", "one") + "\n"
		+ '{"_type":"event","item_id":"a1","seq":1,"event_type":"later","timestamp":"2026-02-02T00:00:00"}' + "\n"
		+ '{"_type":"event","item_id":"a1","seq":2,"event_type":"earlier","timestamp":"2026-01-01T00:00:00"}' + "\n")
	var db := DocketDBJsonl.open_jsonl(_path)
	var events := db.get_events("a1")
	db.close()

	var r = A.eq(events.size(), 2, "both events loaded")
	if r != true:
		return r
	return A.eq(str(events[0].get("event_type", "")), "earlier", "earliest event comes first")
