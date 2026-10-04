extends Node
## Filesystem fixtures are independent OS operations, never identity-helper mocks.
const DIR := "user://test_move_identity"
var _dbs: Array[DocketDB] = []
var _foreign_pid := 0

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)

func after_each() -> void:
	JSONLCheckedCommit.stage_hook = Callable()
	if _foreign_pid > 0: OS.kill(_foreign_pid)
	_foreign_pid = 0
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
	if ProjectOpenings.compare(path, dotted).state != ("DIFFERENT" if OS.get_name() == "Windows" else "SAME"): return "symlink parent identity oracle failed"
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
	var target := JSONLSidecar.path_for(DIR + "/target.dct")
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
		var job := JSONLSettleJob.new()
		job.canonical_path = target.trim_suffix(JSONLSidecar.SUFFIX)
		job.sidecar_prefix = "prefix".to_utf8_buffer()
		for operation in ["marker", "retirement"]:
			var refusal := job.mark_sidecar("prefixtail".to_utf8_buffer()) if operation == "marker" else job.retire_prefix("prefixtail".to_utf8_buffer())
			if refusal.is_empty() or not refusal.contains(temp): return "WAL temp refusal missing path"
			if FileAccess.get_file_as_string(original) != "nonsecret fixture original" or FileAccess.get_file_as_string(target) != "nonsecret fixture original": return "WAL temp guard damaged evidence"
			if mode != "dangling" and FileAccess.get_file_as_bytes(temp) != before: return "WAL temp guard changed occupied bytes"
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

func test_identical_replacement_never_refreshes_opening() -> Variant:
	for stage in ["before_settle", "after_rename"]:
		var db := _create(stage)
		if db == null: return "creation failed"
		var old: Dictionary = db.get_meta("physical_opening")
		var replace_file := func() -> void:
			var bytes := FileAccess.get_file_as_bytes(db.get_path())
			DirAccess.rename_absolute(db.get_path(), db.get_path() + ".saved")
			var f := FileAccess.open(db.get_path(), FileAccess.WRITE)
			f.store_buffer(bytes); f.close()
		if stage == "before_settle": replace_file.call()
		else:
			JSONLCheckedCommit.stage_hook = func(at: String, _path: String, _temp: String) -> String:
				if at == "after_rename": replace_file.call()
				return ""
		var error := db._settle_canonical()
		JSONLCheckedCommit.stage_hook = Callable()
		if error.is_empty() or db.get_meta("physical_opening") != old or ProjectOpenings.opening_refusal(db).is_empty(): return "replacement was blessed by settle"
	return true

func test_memory_file_round_trip_move() -> Variant:
	var memory := DocketDBMemory.create("memory")
	var file := _create("file")
	if memory == null or file == null: return "creation failed"
	_dbs.append(memory)
	var id := memory.next_uuid7_id()
	if not memory.insert_item(id, {"type":"chore", "title":"memory move", "status":"open", "created_at":"2026-10-04T00:00:00Z", "updated_at":"2026-10-04T00:00:00Z"}).is_empty(): return "insert failed"
	var projects := {"memory":memory, "file":file}
	for route in [["memory", "file"], ["file", "memory"]]:
		var result := DocketMove.new().execute({"id":id,"source_project":route[0],"target_project":route[1]}, {}, memory, projects)
		if result.has("error"): return "memory/file move failed"
		id = str(result.new_id)
		if not projects[route[1]].has_item(id): return "move destination missing"
	return true

func test_reserved_siblings_refuse_before_open() -> Variant:
	var target := _create("target")
	if target == null: return "creation failed"
	var source := _create("reserved-source")
	if source == null: return "source creation failed"
	var bytes := FileAccess.get_file_as_bytes(source.get_path())
	for sibling in ProjectOpenings.reserved_paths(target.get_path()):
		if FileAccess.file_exists(sibling): continue
		if not _link(source.get_path(), sibling, true): return "reserved fixture failed"
		if ProjectOpenings.path_refusal(sibling, {"target":target}).is_empty(): return "reserved name admission accepted"
		var alias := DIR + "/alias.dct"
		if not _link(sibling, alias, true): return "reserved alias fixture failed"
		# Distinct source overlaps the destination namespace, including backup recovery.
		if ProjectOpenings.path_refusal(alias, {"target":target}).is_empty(): return "reserved alias admission accepted"
		var state := AppState.new()
		state._project_dbs = {"source":source}
		if state.add_project(target.get_path()).is_empty(): return "destination opened over reserved source"
		if FileAccess.get_file_as_bytes(sibling) != bytes: return "reserved evidence changed"
		DirAccess.remove_absolute(alias); DirAccess.remove_absolute(sibling)
	return true

func test_reload_adopts_only_rebuilt_identity_and_multi_owner_write() -> Variant:
	var db := _create("reload-owner")
	if db == null: return "creation failed"
	var other := DocketDBJsonl.open_jsonl(db.get_path())
	if other == null: return "second owner failed"
	_dbs.append(other)
	var settled := other.set_project_name_checked("refreshed-owner")
	if settled.is_empty(): settled = other.flush_checked()
	if not settled.is_empty(): return "second owner settle failed: " + settled
	if not db.ensure_fresh() or not ProjectOpenings.opening_refusal(db).is_empty(): return "settle reload identity not adopted"
	var id := db.next_uuid7_id()
	var error := db.insert_item(id, {"type":"chore", "title":"after reload", "status":"open", "created_at":"2026-10-04T00:00:00Z", "updated_at":"2026-10-04T00:00:00Z"})
	return true if error.is_empty() and db.has_item(id) else "multi-owner reload write refused: " + error

func test_real_lock_contention_identical_replacement_refuses_append() -> Variant:
	var db := _create("contended")
	if db == null: return "creation failed"
	var path := db.get_path()
	var driver := "import os,sys,time,pathlib,json; p=pathlib.Path(sys.argv[1]); lock=pathlib.Path(str(p)+'.lock'); lock.write_text(json.dumps(dict(pid=os.getpid(),timestamp=time.time()))); pathlib.Path(str(p)+'.ready').touch(); time.sleep(1); data=p.read_bytes(); p.rename(str(p)+'.saved'); p.write_bytes(data); lock.unlink(); time.sleep(5)"
	var python := "python" if OS.get_name() == "Windows" else "python3"
	_foreign_pid = OS.create_process(python, PackedStringArray(["-c", driver, ProjectSettings.globalize_path(path)]))
	var deadline := Time.get_ticks_msec() + 3000
	while not FileAccess.file_exists(path + ".ready") and Time.get_ticks_msec() < deadline: OS.delay_msec(10)
	if not FileAccess.file_exists(path + ".ready"): return "contention child not ready"
	var bytes := FileAccess.get_file_as_bytes(path)
	var wal := FileAccess.get_file_as_bytes(JSONLSidecar.path_for(path))
	var id := db.next_uuid7_id()
	var error := db.insert_item(id, {"type":"chore", "title":"refused append", "status":"open", "created_at":"2026-10-04T00:00:00Z", "updated_at":"2026-10-04T00:00:00Z"})
	if not error.contains("replaced") or not error.contains(path) or db.has_item(id): return "post-lock replacement committed cache rows"
	return true if FileAccess.get_file_as_bytes(path) == bytes and FileAccess.get_file_as_bytes(JSONLSidecar.path_for(path)) == wal else "post-lock refusal changed bytes"

func test_strict_temp_query_error_refuses_before_install_and_marker() -> Variant:
	var db := _create("receipt-error")
	if db == null: return "creation failed"
	var path := db.get_path()
	var sidecar := JSONLSidecar.path_for(path)
	var f := FileAccess.open(sidecar, FileAccess.WRITE)
	f.store_string("nonsecret retained WAL evidence"); f.close()
	var bytes := FileAccess.get_file_as_bytes(path)
	var wal := FileAccess.get_file_as_bytes(sidecar)
	JSONLCheckedCommit.stage_hook = func(stage: String, _path: String, temp: String) -> String:
		if stage == "before_verify":
			DirAccess.remove_absolute(temp)
			DirAccess.make_dir_absolute(temp)
		return ""
	var result := JSONLCheckedCommit.replace(path, "replacement", func() -> String: return "")
	JSONLCheckedCommit.stage_hook = Callable()
	if result.committed or not str(result.error).contains("ERROR") or not str(result.error).contains(path + ".tmp."): return "strict temp query error was not refused before install"
	return true if FileAccess.get_file_as_bytes(path) == bytes and FileAccess.get_file_as_bytes(sidecar) == wal else "failed strict receipt changed canonical or WAL"
