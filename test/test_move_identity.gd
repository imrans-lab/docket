extends Node
## Filesystem fixtures are independent OS operations, never identity-helper mocks.
const DIR := "user://test_move_identity"
var _dbs: Array[DocketDB] = []

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)

func after_each() -> void:
	JSONLCheckedCommit.stage_hook = Callable()
	for db in _dbs: db.close()
	_dbs.clear()
	_remove_tree(DIR)

func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null: return
	for name in dir.get_files(): dir.remove(name)
	for name in dir.get_directories():
		if dir.is_link(name): dir.remove(name)
		else: _remove_tree(path + "/" + name)
	DirAccess.remove_absolute(path)

func _create(name: String) -> DocketDBJsonl:
	var db := DocketDBJsonl.create_new_jsonl(DIR + "/" + name + ".dct")
	if db != null: _dbs.append(db)
	return db

func _link(source: String, target: String, hard: bool = false) -> bool:
	var output: Array = []
	var driver := "import os,sys; os.link(sys.argv[1],sys.argv[2]) if sys.argv[3]=='hard' else os.symlink(sys.argv[1],sys.argv[2],target_is_directory=os.path.isdir(sys.argv[1]))"
	var python := "python" if OS.get_name() == "Windows" else "python3"
	return OS.execute(python, PackedStringArray(["-c", driver, ProjectSettings.globalize_path(source), ProjectSettings.globalize_path(target), "hard" if hard else "soft"]), output, true) == 0

func test_native_filesystem_states_and_admission() -> Variant:
	if not ClassDB.class_exists("DocketFileIdentity"): return "native helper did not load"
	var source := _create("source")
	if source == null: return "source creation failed"
	var path := source.get_path()
	var bytes := FileAccess.get_file_as_bytes(path)
	var copy := DIR + "/copy.dct"
	var f := FileAccess.open(copy, FileAccess.WRITE)
	f.store_buffer(bytes); f.close()
	for same in [path, DIR + "/./source.dct"]:
		if ProjectOpenings.compare(path, same).state != "SAME": return "same spelling oracle failed"
	if ProjectOpenings.compare(path, copy).state != "DIFFERENT": return "identical bytes copy oracle failed"
	if ProjectOpenings.compare(path, DIR + "/absent.dct").state != "ABSENT": return "absence oracle failed"
	if ProjectOpenings.compare(path, DIR).state != "ERROR": return "directory error oracle failed"
	var invalid := path + "?invalid" if OS.get_name() == "Windows" else path + "/child"
	if ProjectOpenings.compare(path, invalid).state != "ERROR": return "actual native query error oracle failed"
	for hard in [false, true]:
		var alias := DIR + ("/hard.dct" if hard else "/soft.dct")
		if not _link(path, alias, hard): return "OS link fixture failed"
		if ProjectOpenings.compare(path, alias).state != "SAME": return "link identity oracle failed"
		if not ProjectOpenings.path_refusal(alias, {"source":source}).contains("already loaded"): return "alias admission was not refused"
		if FileAccess.file_exists(alias + ".cache"): return "alias opened mutable cache"
	DirAccess.make_dir_recursive_absolute(DIR + "/real/sub")
	if not _link(ProjectSettings.globalize_path(DIR + "/real/sub"), DIR + "/directory-link"): return "directory symlink fixture failed"
	if not _link(path, DIR + "/real/copy.dct", true): return "dot-segment hardlink fixture failed"
	var dotted := DIR + "/directory-link/../copy.dct"
	if ProjectOpenings.compare(path, dotted).state != "SAME": return "symlink parent identity oracle failed"
	if FileAccess.get_file_as_bytes(path) != bytes: return "admission changed source bytes"
	if not ProjectOpenings.path_refusal(DIR + "/new.dct", {"source":source}).is_empty(): return "new file admission refused"
	return true

func test_replacement_invalidates_opening_before_move() -> Variant:
	var source := _create("source")
	var target := _create("target")
	if source == null or target == null: return "creation failed"
	var item := source.next_uuid7_id()
	var error := source.insert_item(item, {"type":"chore", "title":"identity fixture", "status":"open", "created_at":"2026-10-04T00:00:00Z", "updated_at":"2026-10-04T00:00:00Z"})
	if not error.is_empty(): return "insert failed"
	if not ProjectOpenings.move_refusal(source, target).is_empty(): return "distinct opening refused"
	var saved := target.get_path() + ".saved"
	if DirAccess.rename_absolute(target.get_path(), saved) != OK: return "replacement fixture rename failed"
	if not _link(source.get_path(), target.get_path(), true): return "replacement fixture link failed"
	var source_bytes := FileAccess.get_file_as_bytes(source.get_path())
	var saved_bytes := FileAccess.get_file_as_bytes(saved)
	var result := DocketMove.new().execute({"id":item,"source_project":"source","target_project":"target"}, {}, source, {"source":source,"target":target})
	if not result.has("error") or not str(result.error).contains("replaced"): return "replacement move not refused"
	if not source.has_item(item) or target.has_item(item): return "replacement changed rows"
	if FileAccess.get_file_as_bytes(source.get_path()) != source_bytes or FileAccess.get_file_as_bytes(saved) != saved_bytes: return "replacement changed bytes"
	return true

func test_temp_namespace_refusal_preserves_existing_evidence() -> Variant:
	var target := DIR + "/target.dct"
	var temp := target + ".tmp.%d" % OS.get_process_id()
	var original := DIR + "/original.dct"
	for path in [target, original]:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string("nonsecret fixture original"); f.close()
	for mode in ["source_at_temp", "hard", "soft", "dangling"]:
		if mode == "source_at_temp":
			var f := FileAccess.open(temp, FileAccess.WRITE)
			f.store_string("nonsecret fixture source"); f.close()
		elif not _link(DIR + "/missing" if mode == "dangling" else original, temp, mode == "hard"):
			return "temp link fixture failed"
		var before := FileAccess.get_file_as_bytes(temp) if mode != "dangling" else PackedByteArray()
		var result := JSONLCheckedCommit.replace(target, "replacement", func() -> String: return "")
		if result.error.is_empty() or result.committed: return "occupied temp commit was accepted"
		if FileAccess.get_file_as_string(target) != "nonsecret fixture original" or FileAccess.get_file_as_string(original) != "nonsecret fixture original": return "temp refusal changed original bytes"
		if mode != "dangling" and FileAccess.get_file_as_bytes(temp) != before: return "temp refusal changed source bytes"
		var dir := DirAccess.open(DIR)
		if mode == "dangling" and not dir.is_link(temp.get_file()): return "refusal removed unowned link"
		if DirAccess.remove_absolute(temp) != OK: return "temp evidence cleanup failed"
	return true

func test_move_source_at_target_temp_name_preserves_rows_and_bytes() -> Variant:
	var target := _create("target")
	if target == null: return "target creation failed"
	var temp := target.get_path() + ".tmp.%d" % OS.get_process_id()
	var source := DocketDBJsonl.create_new_jsonl(temp)
	if source == null: return "source-at-temp creation failed"
	_dbs.append(source)
	var item := source.next_uuid7_id()
	if not source.insert_item(item, {"type":"chore", "title":"temporary source", "status":"open", "created_at":"2026-10-04T00:00:00Z", "updated_at":"2026-10-04T00:00:00Z"}).is_empty(): return "source insert failed"
	if not source.finish_settle().is_empty(): return "source settle failed"
	var source_bytes := FileAccess.get_file_as_bytes(temp)
	var target_bytes := FileAccess.get_file_as_bytes(target.get_path())
	var result := DocketMove.new().execute({"id":item,"source_project":"source","target_project":"target"}, {}, source, {"source":source,"target":target})
	if not result.has("error") or result.get("partial_copy", false): return "temp collision move not refused before commit"
	if not source.has_item(item) or target.has_item(item): return "temp collision changed rows"
	if FileAccess.get_file_as_bytes(temp) != source_bytes or FileAccess.get_file_as_bytes(target.get_path()) != target_bytes: return "temp collision changed bytes"
	return true

func test_move_temp_hardlink_refuses_before_target_write() -> Variant:
	var source := _create("source")
	var target := _create("target")
	if source == null or target == null: return "creation failed"
	var item := source.next_uuid7_id()
	if not source.insert_item(item, {"type":"chore", "title":"hardlink source", "status":"open", "created_at":"2026-10-04T00:00:00Z", "updated_at":"2026-10-04T00:00:00Z"}).is_empty(): return "source insert failed"
	if not source.finish_settle().is_empty(): return "source settle failed"
	var temp := target.get_path() + ".tmp.%d" % OS.get_process_id()
	if not _link(source.get_path(), temp, true): return "temp hardlink fixture failed"
	var source_bytes := FileAccess.get_file_as_bytes(source.get_path())
	var target_bytes := FileAccess.get_file_as_bytes(target.get_path())
	var result := DocketMove.new().execute({"id":item,"source_project":"source","target_project":"target"}, {}, source, {"source":source,"target":target})
	if not result.has("error") or not str(result.error).contains("temporary namespace") or result.get("partial_copy", false): return "temp hardlink move was not refused before write"
	if not source.has_item(item) or target.has_item(item): return "temp hardlink changed rows"
	if FileAccess.get_file_as_bytes(source.get_path()) != source_bytes or FileAccess.get_file_as_bytes(temp) != source_bytes or FileAccess.get_file_as_bytes(target.get_path()) != target_bytes: return "temp hardlink changed bytes"
	return true
