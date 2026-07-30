extends Node
## Tests for merge-safety behaviour:
##   - unresolved git conflict markers are refused, not silently unioned
##   - a cache that went stale (git pull) is reloaded rather than clobbering
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
	for suffix: String in ["", ".cache", ".cache-wal", ".cache-shm", ".lock"]:
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

	var text := _read()
	db.close()
	var r = A.contains(text, "\"a2\"", "pulled item survived the local write")
	if r != true:
		return r
	return A.contains(text, "\"a3\"", "local item was written")


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


func test_validator_warns_on_orphaned_events() -> Variant:
	_write(META + "\n" + _item_line("a1", "one") + "\n"
		+ '{"_type":"event","item_id":"ghost","seq":1,"event_type":"created","timestamp":"2026-01-01T00:00:00"}' + "\n")
	var report := JSONLValidator.validate_file(_path)
	var r = A.is_true(report["ok"], "orphans are a warning, not an error")
	if r != true:
		return r
	return A.contains(str(report["warnings"]), "ghost", "names the missing item")


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
