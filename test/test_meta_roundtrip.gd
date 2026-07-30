extends Node
## Tests that everything in docket_meta survives serialization.
##
## The serializer used to write a hardcoded key list, so anything not on it
## lived only in the disposable SQLite cache and vanished on the next rebuild —
## which now happens automatically whenever the file changes on disk. That lost
## the project lifecycle fields outright, and would have stranded every vault
## when the KDF iteration count was added.

var A := AssertHelpers
var _test_dir := "user://test_meta_roundtrip"
var _path: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func before_each() -> void:
	_path = _test_dir + "/meta.dct"
	_cleanup()


func _cleanup() -> void:
	for suffix: String in ["", ".cache", ".cache-wal", ".cache-shm", ".lock"]:
		var p := _path + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func teardown() -> void:
	_cleanup()
	DirAccess.remove_absolute(_test_dir)


func _drop_cache() -> void:
	for suffix: String in [".cache", ".cache-wal", ".cache-shm"]:
		var p := _path + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


# -- Project lifecycle metadata ------------------------------------------------

func test_project_meta_survives_cache_rebuild() -> Variant:
	var db := DocketDBJsonl.create_new_jsonl(_path)
	db.set_project_meta({
		"stage": "experiment",
		"hypothesis": "JSONL merges cleanly",
		"success_criteria": "no conflicts across two machines",
	})
	db.close()

	_drop_cache()
	var reopened := DocketDBJsonl.open_jsonl(_path)
	var meta := reopened.get_project_meta()
	reopened.close()

	var r = A.eq(str(meta.get("stage", "")), "experiment", "stage survives")
	if r != true:
		return r
	r = A.eq(str(meta.get("hypothesis", "")), "JSONL merges cleanly", "hypothesis survives")
	if r != true:
		return r
	return A.eq(str(meta.get("success_criteria", "")), "no conflicts across two machines",
		"success_criteria survives")


func test_project_meta_is_written_to_the_file() -> Variant:
	var db := DocketDBJsonl.create_new_jsonl(_path)
	db.set_project_meta({"stage": "incubating"})
	db.close()
	var text := FileAccess.get_file_as_string(_path)
	return A.contains(text, "project_stage", "lifecycle field reaches the JSONL")


# -- Generic guarantee ---------------------------------------------------------

func test_arbitrary_meta_survives_rebuild() -> Variant:
	## The guarantee is general: whatever is in docket_meta is persisted, so a
	## future key cannot silently fail to round-trip.
	var db := DocketDBJsonl.create_new_jsonl(_path)
	db.set_meta_value("some_future_setting", "kept")
	db.close()

	_drop_cache()
	var reopened := DocketDBJsonl.open_jsonl(_path)
	var got := reopened.get_meta_value("some_future_setting", "")
	reopened.close()
	return A.eq(got, "kept", "unknown meta key round-trips")


func test_cache_fingerprint_is_not_serialized() -> Variant:
	## jsonl_hash describes the local cache's view of the file. Writing it into
	## the file would make the content depend on the cache built from it, and
	## would differ per machine for identical data.
	var db := DocketDBJsonl.create_new_jsonl(_path)
	db.set_project_meta({"stage": "experiment"})
	db.close()
	var text := FileAccess.get_file_as_string(_path)
	return A.is_true(not text.contains("jsonl_hash"), "cache fingerprint stays out of the file")


func test_meta_line_remains_single_and_valid() -> Variant:
	var db := DocketDBJsonl.create_new_jsonl(_path)
	db.set_project_meta({"stage": "experiment", "hypothesis": "h"})
	db.set_meta_value("extra_key", "v")
	db.close()

	var text := FileAccess.get_file_as_string(_path)
	var meta_lines := 0
	for line in text.split("\n"):
		if line.strip_edges().is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if parsed == null:
			return "non-JSON line produced: %s" % line
		if parsed is Dictionary and parsed.get("_type") == "meta":
			meta_lines += 1
	return A.eq(meta_lines, 1, "exactly one meta line")


func test_required_keys_still_present() -> Variant:
	## Extras must not displace the required fields or their order.
	var db := DocketDBJsonl.create_new_jsonl(_path)
	db.set_meta_value("zzz_last_alphabetically", "v")
	db.close()
	var first_line := FileAccess.get_file_as_string(_path).split("\n")[0]
	var parsed = JSON.parse_string(first_line)
	var r = A.is_true(parsed is Dictionary, "meta line parses")
	if r != true:
		return r
	for key in ["_type", "version", "counter", "id_prefix"]:
		if not parsed.has(key):
			return "meta line lost required key '%s'" % key
	return true
