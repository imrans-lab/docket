extends Node
## Tests that a corrupt .dct is refused rather than silently truncated.
##
## The bug these guard against needed no edit to destroy data. The parser
## skipped an unparseable line; the cache therefore never held it; close()
## rewrites the whole file from cache. Opening a project and closing it deleted
## the record, and `validate` reported the file OK with exit 0 while it happened.

var A := AssertHelpers
var _test_dir := "user://test_malformed_refusal"
var _path: String

const META := '{"_type":"meta","version":"1.0.0","counter":0,"id_prefix":"MAL"}'


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func before_each() -> void:
	_path = _test_dir + "/mal.dct"
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


func _item(id: String, title: String) -> String:
	return ('{"_type":"item","id":"%s","type":"chore","status":"open","title":"%s",'
		+ '"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}') % [id, title]


## A truncated line — what a partial write or a botched merge leaves behind.
const TRUNCATED := '{"_type":"item","id":"bbb","type":"chore","status":"open","title":"TRUNCATED'


# -- Refusal -------------------------------------------------------------------

func test_open_is_refused_when_a_line_is_malformed() -> Variant:
	_write(META + "\n" + _item("aaa", "one") + "\n" + TRUNCATED + "\n")
	var db := DocketDBJsonl.open_jsonl(_path)
	if db != null:
		db.close()
		return "opened a corrupt file instead of refusing"
	return A.contains(DocketDBJsonl.last_open_error, "malformed", "reason is reported")


func test_corrupt_file_is_left_intact() -> Variant:
	## The regression that matters: a refused open must not rewrite the file.
	var original := META + "\n" + _item("aaa", "one") + "\n" + TRUNCATED + "\n"
	_write(original)
	var db := DocketDBJsonl.open_jsonl(_path)
	if db != null:
		db.close()
	var r = A.eq(_read(), original, "file is byte-identical after a refused open")
	if r != true:
		return r
	return A.is_true(not FileAccess.file_exists(_path + ".cache"), "no cache was built")


func test_no_cache_means_no_flush_can_truncate() -> Variant:
	## Before the fix this sequence deleted the line with no edit at all.
	_write(META + "\n" + _item("aaa", "one") + "\n" + TRUNCATED + "\n"
		+ _item("ccc", "three") + "\n")
	var db := DocketDBJsonl.open_jsonl(_path)
	if db != null:
		db.close()
	return A.contains(_read(), "TRUNCATED", "the malformed line survives open+close")


func test_line_number_is_reported() -> Variant:
	_write(META + "\n" + _item("aaa", "one") + "\n" + TRUNCATED + "\n")
	var parsed := JSONLParser.parse_file(_path)
	return A.contains(str(parsed["error"]), "line 3", "error identifies the offending line")


func test_missing_type_is_refused() -> Variant:
	_write(META + "\n" + '{"id":"x","title":"no type"}' + "\n")
	var parsed := JSONLParser.parse_file(_path)
	return A.is_true(not str(parsed.get("error", "")).is_empty(), "line without _type is fatal")


func test_non_object_line_is_refused() -> Variant:
	_write(META + "\n" + '["not","an","object"]' + "\n")
	var parsed := JSONLParser.parse_file(_path)
	return A.is_true(not str(parsed.get("error", "")).is_empty(), "non-object line is fatal")


# -- What must still be tolerated ---------------------------------------------

func test_clean_file_still_opens() -> Variant:
	_write(META + "\n" + _item("aaa", "one") + "\n" + _item("bbb", "two") + "\n")
	var db := DocketDBJsonl.open_jsonl(_path)
	var r = A.not_null(db, "a clean file opens")
	if r != true:
		return r
	var count := db.execute_query({}).size()
	db.close()
	return A.eq(count, 2, "both items load")


func test_blank_lines_are_still_tolerated() -> Variant:
	_write(META + "\n\n" + _item("aaa", "one") + "\n   \n" + _item("bbb", "two") + "\n")
	var parsed := JSONLParser.parse_file(_path)
	var r = A.eq(str(parsed.get("error", "")), "", "blank lines are not corruption")
	if r != true:
		return r
	return A.eq(parsed["items"].size(), 2, "both items parsed")


func test_unknown_type_is_still_tolerated() -> Variant:
	## Forward compatibility, not damage: a newer Docket wrote a line type this
	## version does not know. Aborting here would make every future format
	## addition break older clients outright.
	_write(META + "\n" + '{"_type":"future_thing","data":"x"}' + "\n" + _item("aaa", "one") + "\n")
	var parsed := JSONLParser.parse_file(_path)
	var r = A.eq(str(parsed.get("error", "")), "", "unknown _type does not abort the read")
	if r != true:
		return r
	return A.eq(parsed["items"].size(), 1, "known lines still parse")


# -- The validation gate -------------------------------------------------------

func test_validator_fails_on_malformed_line() -> Variant:
	## The docs present `validate` as a pre-commit gate. It previously returned
	## ok=true (exit 0) for a file that was already losing records.
	_write(META + "\n" + _item("aaa", "one") + "\n" + TRUNCATED + "\n")
	var report := JSONLValidator.validate_file(_path)
	var r = A.is_true(not report["ok"], "validate reports failure")
	if r != true:
		return r
	return A.is_true(report["errors"].size() > 0, "recorded as an error, not a warning")


func test_validator_passes_a_clean_file() -> Variant:
	_write(META + "\n" + _item("aaa", "one") + "\n")
	var report := JSONLValidator.validate_file(_path)
	return A.is_true(report["ok"], "clean file still validates")
