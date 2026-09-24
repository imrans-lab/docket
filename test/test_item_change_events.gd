extends Node
## items_changed, which the stdio transport forwards as item_changed: a change
## is reported once it is durable and only then — on a SQLite project at its
## statement or transaction commit (never after a rollback), on a JSONL
## project once its file is saved (never for a failed save, though another
## writer's state that a failed save adopts is reported as a reload) — and a
## move reports the items in other projects whose references it rewrote.

var A := AssertHelpers
var _schema: Dictionary
var _paths: Array[String] = []
var _dirs: Array[String] = []
# Databases still open, closed by teardown (an early failed assertion
# returns before a test closes its own).
var _open: Array = []


func setup() -> void:
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	_schema = JSON.parse_string(f.get_as_text())


func teardown() -> void:
	for db in _open:
		db.close()
	_open.clear()
	for path in _paths:
		for suffix in ["", ".cache", ".v2.cache", ".cache-wal", ".cache-shm", ".v2.cache-wal", ".v2.cache-shm", "-wal", "-shm", ".lock"]:
			if FileAccess.file_exists(path + suffix):
				DirAccess.remove_absolute(path + suffix)
	for dir in _dirs:
		DirAccess.remove_absolute(dir)


func _sqlite(name: String) -> DocketDB:
	var path := "user://test_changes_%s_%d.dct" % [name, Time.get_ticks_usec()]
	_paths.append(ProjectSettings.globalize_path(path))
	var db := DocketDB.create_new(path)
	db.set_project_name(name)
	_open.append(db)
	return db


func _registry(project_dbs: Dictionary) -> ToolRegistry:
	var registry := ToolRegistry.new()
	registry.init(_schema, project_dbs.values()[0], project_dbs)
	return registry


func _new_bug(registry: ToolRegistry, project: String, title: String) -> String:
	return str(registry.call_tool("docket_create", {"type": "bug", "title": title, "project": project}).get("id", ""))


func test_sqlite_changes_are_reported_when_durable() -> Variant:
	var db := _sqlite("legacy")
	var id := _new_bug(_registry({"legacy": db}), "legacy", "Legacy")
	var changes: Array = []
	db.items_changed.connect(func(batch: Array): changes.append_array(batch))

	db.add_event(id, "noted", "test")
	var r = A.eq(changes, [{"id": id, "event": "noted"}], "outside a transaction: reported at once")
	if r is String: return r

	changes.clear()
	db._exec_checked("BEGIN TRANSACTION;")
	db.add_event(id, "rolled_back", "test")
	var before_end := changes.size()
	db._rollback()
	r = A.eq([before_end, changes.size()], [0, 0], "a rolled-back change is never reported")
	if r is String: return r

	db._exec_checked("BEGIN TRANSACTION;")
	db.add_event(id, "committed", "test")
	before_end = changes.size()
	db._exec_checked("COMMIT;")
	return A.eq([before_end, changes], [0, [{"id": id, "event": "committed"}]], "reported at commit, not before")


func test_move_reports_references_rewritten_in_another_project() -> Variant:
	var alpha := _sqlite("alpha")
	var beta := _sqlite("beta")
	var gamma := _sqlite("gamma")
	var registry := _registry({"alpha": alpha, "beta": beta, "gamma": gamma})
	var moved := _new_bug(registry, "alpha", "Moved")
	var child := _new_bug(registry, "gamma", "Child in a third project")
	gamma.update_item_fields(child, {"parent": "alpha:%s" % moved})
	var gamma_changes: Array = []
	gamma.items_changed.connect(func(batch: Array): gamma_changes.append_array(batch))

	var result: Dictionary = registry.call_tool("docket_move", {"id": moved, "target_project": "beta"})
	var r = A.eq(str(result.get("error", "")), "", "moved")
	if r is String: return r
	r = A.is_true(not alpha.has_item(moved) and beta.has_item(str(result.get("new_id", ""))),
		"the item is in the target project and no longer in the source: %s" % [result])
	if r is String: return r
	return A.is_true(gamma_changes.has({"id": child, "event": "references_updated"}),
		"the referencing item in the third project is reported: %s" % [gamma_changes])


func test_jsonl_reports_only_saved_changes_and_adopted_outside_edits() -> Variant:
	var dir := OS.get_cache_dir().path_join("docket_changes_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	_dirs.append(dir)
	var path := dir.path_join("canon.dct")
	var outside := dir.path_join("outside.dct")
	_paths.append_array([path, outside])
	var db := DocketDBJsonl.create_new_jsonl(path)
	_open.append(db)
	db.set_project_name("canon")
	var id := _new_bug(_registry({"canon": db}), "canon", "Canonical")
	var changes: Array = []
	db.items_changed.connect(func(batch: Array): changes.append_array(batch))

	# A change whose save fails is not reported.
	db._atomic_write_hook = func(_path, _text): return "injected write failure"
	var save_error := db.add_event_checked(id, "unsaved", "test")
	db._atomic_write_hook = Callable()
	var r = A.eq([save_error, changes], ["injected write failure", []], "the save failed, and reported nothing")
	if r is String: return r

	# Another writer changes the file while this one's mutation is open: the
	# save fails, the outside state is adopted and reported; ours is not.
	DirAccess.copy_absolute(path, outside)
	var other := DocketDBJsonl.open_jsonl(outside)
	other.add_event(id, "outside_edit", "other writer")
	other.close()
	db._begin_canonical_mutation()
	db.add_event(id, "local_edit", "test")
	DirAccess.copy_absolute(outside, path)
	var error := db._complete_canonical_mutation()
	var events: Array = db.get_events(id).map(func(event: Dictionary) -> String: return str(event.event_type))
	r = A.is_false(error.is_empty(), "the save over another writer's change fails")
	if r is String: return r
	r = A.eq(changes, [{"id": "", "event": "reloaded"}], "only the adopted outside state is reported")
	if r is String: return r
	return A.is_true(events.has("outside_edit") and not events.has("local_edit"), "the outside edit is adopted: %s" % [events])


func test_jsonl_deletion_is_reported_once_saved_and_its_step_released() -> Variant:
	var dir := OS.get_cache_dir().path_join("docket_changes_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	_dirs.append(dir)
	var path := dir.path_join("deleting.dct")
	_paths.append(path)
	var db := DocketDBJsonl.create_new_jsonl(path)
	_open.append(db)
	db.set_project_name("deleting")
	var registry := _registry({"deleting": db})
	var id := _new_bug(registry, "deleting", "Deleted")
	var other := _new_bug(registry, "deleting", "Deleted by a listener")
	db.set_secret(id, "CT".to_utf8_buffer(), "IV".to_utf8_buffer(), "MAC".to_utf8_buffer(), false, id)
	var saved := FileAccess.get_file_as_string(path)
	var changes: Array = []
	db.items_changed.connect(func(batch: Array): changes.append_array(batch))

	# A deletion whose save fails leaves file, cache and vault entry as they
	# were, and reports nothing.
	db._atomic_write_hook = func(_path, _text): return "injected write failure"
	var error := db.delete_item_checked(id)
	db._atomic_write_hook = Callable()
	var r = A.eq([error, changes], ["injected write failure", []], "the save failed, and reported nothing")
	if r is String: return r
	r = A.is_true(FileAccess.get_file_as_string(path) == saved and db.has_item(id) and not db.get_secret_raw(id).is_empty(),
		"file, cache and vault entry are as before")
	if r is String: return r

	# A listener hears of the deletion once the file no longer has the item,
	# and can make a change of its own: the deletion's step is given back.
	var seen := {}
	db.items_changed.connect(func(batch: Array):
		if batch.has({"id": id, "event": "deleted"}):
			seen.file_has_item = FileAccess.get_file_as_string(path).contains(id)
			seen.own_change = db.delete_item_checked(other))
	error = db.delete_item_checked(id)
	r = A.eq([error, seen], ["", {"file_has_item": false, "own_change": ""}], "reported after saving, to a listener free to change the project")
	if r is String: return r
	return A.is_true(not db.has_item(other) and db.get_secret_raw(id).is_empty(), "both deletions took effect")


func test_sqlite_deletion_failing_at_its_last_step_changes_and_reports_nothing() -> Variant:
	var db := _sqlite("rollback")
	var id := _new_bug(_registry({"rollback": db}), "rollback", "Deleted")
	# Vault entries the item owns: under its own handle (with an archived
	# version) and under another one. Deletion removes them before the item.
	db.set_secret(id, "CT".to_utf8_buffer(), "IV".to_utf8_buffer(), "MAC".to_utf8_buffer(), false, id)
	db.rotate_secret(id, "CT2".to_utf8_buffer(), "IV2".to_utf8_buffer(), "MAC2".to_utf8_buffer(), "test")
	db.set_secret("owned-elsewhere", "CT".to_utf8_buffer(), "IV".to_utf8_buffer(), "MAC".to_utf8_buffer(), false, id)
	var changes: Array = []
	db.items_changed.connect(func(batch: Array): changes.append_array(batch))

	db._exec("CREATE TRIGGER reject_item_delete BEFORE DELETE ON items BEGIN SELECT RAISE(ABORT, 'item delete rejected'); END;")
	var error := db.delete_item_checked(id)
	var r = A.is_true(not error.is_empty() and changes.is_empty(), "the deletion failed and reported nothing: %s %s" % [error, changes])
	if r is String: return r
	r = A.is_true(db.has_item(id) and not db.get_secret_raw(id).is_empty() and not db.get_secret_raw("owned-elsewhere").is_empty()
		and db.get_secret_versions(id).size() == 1, "the item, its vault entries and their archive are all still there")
	if r is String: return r

	db._exec("DROP TRIGGER reject_item_delete;")
	error = db.delete_item_checked(id)
	return A.is_true(error.is_empty() and changes == [{"id": id, "event": "deleted"}] and not db.has_item(id)
		and db.get_secret_raw(id).is_empty() and db.get_secret_raw("owned-elsewhere").is_empty() and db.get_secret_versions(id).is_empty(),
		"retried, it deletes all of them and reports the deletion once: %s %s" % [error, changes])
