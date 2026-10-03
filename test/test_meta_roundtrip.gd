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
	for suffix: String in ["", ".log", ".cache", ".cache-wal", ".cache-shm", ".v2.cache", ".v2.cache-wal", ".v2.cache-shm", ".lock"]:
		var p := _path + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func teardown() -> void:
	_cleanup()
	DirAccess.remove_absolute(_test_dir)


func _drop_cache() -> void:
	for suffix: String in [".cache", ".cache-wal", ".cache-shm", ".v2.cache", ".v2.cache-wal", ".v2.cache-shm"]:
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


# The reported meta line is literal, including the redundant version alias.
const OBSERVED_META := '{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"MST","project":"Master","jsonl_version":"1.0.0"}'
const LEGACY_ITEM := '{"_type":"item","id":"MST-001","type":"chore","status":"open","title":"legacy untouched","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}'

func _write_legacy(meta: String) -> PackedByteArray:
	var bytes := (meta + "\n" + LEGACY_ITEM + "\n").to_utf8_buffer()
	var file := FileAccess.open(_path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	return bytes

func test_untouched_observed_legacy_meta_load_startup_settle_and_poll_are_byte_identical() -> Variant:
	for meta in [OBSERVED_META, OBSERVED_META.replace(',"project":"Master"', '')]:
		for added in [false, true]:
			_cleanup()
			var original := _write_legacy(meta)
			var state := AppState.new()
			state.schema = TypeRegistryBootstrap.load_shipped_schema()
			state.prefs = UserPrefs.new()
			var shell := AppShell.new()
			shell.init(state)
			add_child(shell)
			shell._poll_timer.stop()
			var error := ""
			if added: error = state.add_project(_path)
			else: state.load_dct(_path)
			var loaded: Array = state.get_project_dbs().values()
			var r: Variant = A.is_true(error.is_empty() and loaded.size() == 1 and not loaded[0].get_project_name().is_empty(), "legacy load retains a displayed project name (%s)" % error)
			if r == true: r = A.eq(FileAccess.get_file_as_bytes(_path), original, "load leaves literal observed meta bytes unchanged")
			state.save()
			shell._on_poll_external_changes()
			if r == true: r = A.eq(FileAccess.get_file_as_bytes(_path), original, "startup settle and poll leave untouched1.0 bytes unchanged")
			remove_child(shell)
			shell.free()
			for db: DocketDB in loaded: db.close()
			if r == true: r = A.eq(FileAccess.get_file_as_bytes(_path), original, "close leaves untouched bytes unchanged too")
			if r is String: return r
	return true

func test_legacy_alias_is_canonicalised_only_on_real_mutation_and_compaction() -> Variant:
	var original := _write_legacy(OBSERVED_META)
	var db := DocketDBJsonl.open_jsonl(_path)
	if db == null: return "legacy fixture did not open"
	var error := db.update_item_fields_checked("MST-001", {"title": "legacy journaled"})
	var r = A.is_true(error.is_empty() and FileAccess.get_file_as_bytes(_path) == original and JSONLSidecar.has_content(_path + ".log"), "mutation journals without rewriting original canonical (%s)" % error)
	# Simulate a writer exiting before settle; its real journal survives.
	db._jsonl_path = ""
	db.close()
	if r is String: return r
	db = DocketDBJsonl.open_jsonl(_path)
	if db == null: return "legacy surviving journal did not reopen"
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(_path).get_slice("\n", 0))
	r = A.is_true(parsed is Dictionary and parsed.get("version") == "1.0.0" and not parsed.has("jsonl_version") and not JSONLSidecar.has_content(_path + ".log") and str(db.get_item("MST-001").title) == "legacy journaled", "open compaction canonicalises alias while preserving format and journaled mutation")
	if r is String: db.close(); return r
	error = db.update_item_fields_checked("MST-001", {"title": "legacy settled"})
	if error.is_empty(): error = db.flush_checked()
	db.close()
	if not error.is_empty(): return error
	_drop_cache()
	db = DocketDBJsonl.open_jsonl(_path)
	if db == null: return "legacy rebuilt cache did not open"
	var title := str(db.get_item("MST-001").title)
	parsed = JSON.parse_string(FileAccess.get_file_as_string(_path).get_slice("\n", 0))
	db.close()
	return A.is_true(title == "legacy settled" and parsed is Dictionary and not parsed.has("jsonl_version") and parsed.get("version") == "1.0.0", "a real mutation still settles and cache rebuild preserves format after alias canonicalisation")
