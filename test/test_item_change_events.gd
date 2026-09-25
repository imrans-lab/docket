extends Node
## items_changed, which the stdio transport forwards as item_changed: a change
## is reported once it is durable and only then — on a SQLite project at its
## statement or transaction commit (never after a rollback), on a JSONL
## project once its file is saved (never for a failed save, whose change is
## undone, or kept unsaved when the file changed meanwhile) — and a move
## reports the items in other projects whose references it rewrote. A JSONL
## project's failed saves never lose a change, and one that cannot be read as
## its file is refused, and read again when it can; docket_flush reports a
## project whose file it could not write as an error, not a count.

const AppShell := preload("res://scripts/ui/app_shell.gd")

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
	var r = A.eq(changes, [{"id": id, "event": "noted"}], "a change of its own: reported by the time it returns")
	if r is String: return r

	changes.clear()
	var seen := {"before_end": -1}
	db.run_change(null, func(step: RefCounted) -> String:
		db.add_event_checked(id, "rolled_back", "test", "", step)
		seen.before_end = changes.size()
		return "roll it back")
	r = A.eq([seen.before_end, changes.size()], [0, 0], "a rolled-back change is never reported")
	if r is String: return r

	var error := db.run_change(null, func(step: RefCounted) -> String:
		var added := db.add_event_checked(id, "committed", "test", "", step)
		seen.before_end = changes.size()
		return added)
	return A.eq([error, seen.before_end, changes], ["", 0, [{"id": id, "event": "committed"}]], "reported at commit, not before")


# One change, two ways it could leak: a nested write that fails is the
# change's failure even when the change ignores it, and writes from another
# operation (a change of its own, refused as it begins, and a bare write) are
# refused without failing the change they tried to join.
func test_a_change_keeps_all_or_nothing_and_only_its_own_writes() -> Variant:
	var db := _sqlite("owned")
	var id := _new_bug(_registry({"owned": db}), "owned", "Owned")
	db._exec("CREATE TRIGGER reject_event BEFORE INSERT ON item_events WHEN NEW.event_type='rejected' BEGIN SELECT RAISE(ABORT, 'event rejected'); END;")
	var events := func() -> Array: return db.get_events(id).map(func(event: Dictionary) -> String: return str(event.event_type))
	var changes: Array = []
	db.items_changed.connect(func(batch: Array): changes.append_array(batch))
	var error := db.run_change(null, func(step: RefCounted) -> String:
		db.add_event_checked(id, "kept", "test", "", step)
		db.add_event_checked(id, "rejected", "test", "", step)
		return "")
	var r = A.is_true(error.contains("event rejected") and not events.call().has("kept") and changes.is_empty(),
		"an ignored nested failure still rolls the whole change back: %s %s %s" % [error, events.call(), changes])
	if r is String: return r

	var foreign := {}
	var retrievals := func() -> int: return int(db._exec_select("SELECT retrieval_count AS n FROM items WHERE id=?;", [id])[0].n)
	var retrieved: int = retrievals.call()
	error = db.run_change(null, func(step: RefCounted) -> String:
		foreign.change = db.add_event_checked(id, "foreign", "other operation")
		foreign.write = db.bump_retrieval_checked(id)
		return db.add_event_checked(id, "owned", "test", "", step))
	return A.is_true(error.is_empty() and str(foreign.change).contains("another operation's change") and str(foreign.write).contains("another operation's change")
		and events.call().has("owned") and not events.call().has("foreign") and retrievals.call() == retrieved
		and changes == [{"id": id, "event": "owned"}],
		"another operation's writes are refused and the change still commits: %s %s %s %s" % [error, foreign, events.call(), changes])


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


func test_jsonl_reports_only_saved_changes_and_keeps_one_over_outside_edits() -> Variant:
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
	db._atomic_write_hook = func(_path, _text, _staged): return "injected write failure"
	var save_error := db.add_event_checked(id, "unsaved", "test")
	db._atomic_write_hook = Callable()
	var r = A.eq([save_error, changes], ["injected write failure", []], "the save failed, and reported nothing")
	if r is String: return r

	# Another writer changes the file while this one's mutation is open: the
	# save fails, and the change is kept here unsaved rather than read over or
	# written over; nothing is reported, and the project takes no more changes.
	DirAccess.copy_absolute(path, outside)
	var other := DocketDBJsonl.open_jsonl(outside)
	other.add_event(id, "outside_edit", "other writer")
	other.close()
	var error := db.run_change(null, func(step: RefCounted) -> String:
		var added := db.add_event_checked(id, "local_edit", "test", "", step)
		DirAccess.copy_absolute(outside, path)
		return added)
	var events: Array = db.get_events(id).map(func(event: Dictionary) -> String: return str(event.event_type))
	r = A.is_true(error.contains("kept here"), "the save over another writer's change fails, keeping the change: %s" % error)
	if r is String: return r
	r = A.eq(changes, [], "nothing is reported")
	if r is String: return r
	var next := db.add_event_checked(id, "later", "test")
	return A.is_true(events.has("local_edit") and not events.has("outside_edit") and FileAccess.get_file_as_string(path).contains("outside_edit")
		and not next.is_empty(), "the change is kept, the other writer's file is left as it is, and the project is refused: %s %s" % [events, next])


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
	db._atomic_write_hook = func(_path, _text, _staged): return "injected write failure"
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


func test_a_checked_change_from_another_thread_is_refused_and_changes_nothing() -> Variant:
	var dir := OS.get_cache_dir().path_join("docket_changes_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	_dirs.append(dir)
	var path := dir.path_join("threads.dct")
	_paths.append(path)
	var db := DocketDBJsonl.create_new_jsonl(path)
	_open.append(db)
	db.set_project_name("threads")
	var saved := FileAccess.get_file_as_string(path)
	var owner := db._owner_thread
	var changes: Array = []
	db.items_changed.connect(func(batch: Array): changes.append_array(batch))

	# Refused before any coordination or file work: those belong to the
	# connection's own thread.
	var worker := Thread.new()
	worker.start(func() -> String: return db.set_project_name_checked("changed elsewhere"))
	var error: String = worker.wait_to_finish()
	return A.is_true(error.contains("thread") and db._owner_thread == owner and FileAccess.get_file_as_string(path) == saved
		and changes.is_empty() and db.get_project_name() == "threads",
		"the change is refused with the thread as the reason, and nothing changed: %s" % error)


# A JSONL project with one bug, open, its path and the bug: [db, path, id].
func _jsonl(name: String) -> Array:
	var dir := OS.get_cache_dir().path_join("docket_changes_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	_dirs.append(dir)
	var path := dir.path_join(name + ".dct")
	_paths.append(path)
	var db := DocketDBJsonl.create_new_jsonl(path)
	_open.append(db)
	db.set_project_name(name)
	return [db, path, _new_bug(_registry({name: db}), name, "First")]


func test_failed_saves_undo_or_keep_the_change_and_never_lose_it() -> Variant:
	var opened := _jsonl("fault")
	var db: DocketDBJsonl = opened[0]
	var path: String = opened[1]
	var id: String = opened[2]
	var event_types := func(of: DocketDB) -> Array: return of.get_events(id).map(func(event: Dictionary) -> String: return str(event.event_type))
	var changes: Array = []
	db.items_changed.connect(func(batch: Array): changes.append_array(batch))
	var fail := func(_path: String, _text: String, _staged: Dictionary) -> String: return "injected write failure"

	# A save that wrote nothing undoes the change in the cache, reporting nothing.
	db._atomic_write_hook = fail
	var undone := db.add_event_checked(id, "undone", "test")
	db._atomic_write_hook = Callable()
	var r = A.is_true(undone == "injected write failure" and not event_types.call(db).has("undone") and changes.is_empty(),
		"the failed change is gone from the cache, and nothing is reported: %s %s" % [undone, changes])
	if r is String: return r

	# When the cache to undo it cannot be built, the change is kept, unsaved,
	# and the project takes nothing more; opening it again reads the file.
	db._atomic_write_hook = fail
	JSONLCache.rebuild_failure_hook = func() -> String: return "injected rebuild failure"
	var kept := db.add_event_checked(id, "kept", "test")
	JSONLCache.rebuild_failure_hook = Callable()
	db._atomic_write_hook = Callable()
	var later := db.add_event_checked(id, "later", "test")
	r = A.is_true(kept.contains("kept here") and event_types.call(db).has("kept") and not later.is_empty()
		and not FileAccess.get_file_as_string(path).contains("\"kept\""), "the change is kept unsaved, the file untouched: %s %s" % [kept, later])
	if r is String: return r
	db.close()
	var reopened := DocketDBJsonl.open_jsonl(path)
	_open.append(reopened)
	r = A.is_false(event_types.call(reopened).has("kept"), "a cache holding an unsaved change is not taken for its file's")
	if r is String: return r

	# A write that reached the file but cannot be confirmed as the bytes
	# written is "commit uncertain": the project waits for a person, and its
	# marked cache is not taken for the file's either.
	reopened._atomic_write_hook = func(write_path: String, text: String, staged: Dictionary) -> String:
		return DocketDBJsonl._atomic_write(write_path, text + "\n", staged)
	var uncertain := reopened.add_event_checked(id, "uncertain", "test")
	reopened._atomic_write_hook = Callable()
	var cache_path := JSONLCache.cache_path_for(path)
	r = A.is_true(uncertain.begins_with("commit uncertain") and not reopened.add_event_checked(id, "after", "test").is_empty()
		and not JSONLCache.is_cache_valid(path, cache_path), "an unconfirmed write is commit uncertain, and its cache is not trusted: %s" % uncertain)
	if r is String: return r
	reopened.close()
	var read_again := DocketDBJsonl.open_jsonl(path)
	_open.append(read_again)
	return A.eq([read_again.get_meta_value(JSONLCache.UNSAVED_META, ""), event_types.call(read_again).has("uncertain")], ["", true],
		"opened again, the project is its file: what reached it, and no unsaved mark")


func test_a_flush_that_cannot_write_its_file_is_an_error() -> Variant:
	var opened := _jsonl("settle")
	var db: DocketDBJsonl = opened[0]
	var tool := DocketFlush.new()
	db._atomic_write_hook = func(_path: String, _text: String, _staged: Dictionary) -> String: return "injected write failure"
	var failed: Dictionary = tool.execute({"project": "settle"}, {}, db, {"settle": db})
	db._atomic_write_hook = Callable()
	var r = A.is_true(str(failed.get("error", "")).contains("settle") and str(failed.get("error", "")).contains("injected write failure")
		and failed.get("failed", []).size() == 1, "a flush whose file cannot be written names the project and why: %s" % [failed])
	if r is String: return r
	var settled: Dictionary = tool.execute({"project": "settle"}, {}, db, {"settle": db})
	return A.is_true(not settled.has("error") and int(settled.get("count", 0)) == 1, "a flush that can write reports it: %s" % [settled])


func test_a_project_that_cannot_be_read_is_refused_then_read_again() -> Variant:
	var opened := _jsonl("ready")
	var db: DocketDBJsonl = opened[0]
	var path: String = opened[1]
	var id: String = opened[2]
	db.close()
	var state := AppState.new()
	# The shell reads the schema and preferences a running app's state has.
	state.schema = TypeRegistryBootstrap.load_shipped_schema()
	state.prefs = UserPrefs.new()
	state.load_dct(path)
	var setup = A.is_true(not state.schema.get("types", {}).is_empty() and state.db != null and state.get_project_dbs().has("ready"),
		"setup: the state has its schema and the project open")
	if setup is String: return setup
	var source := LocalDocketSource.new(state)
	var shell := AppShell.new()
	shell.init(source)
	add_child(shell)
	var rewrite := func(from: String, to: String) -> void:
		var text := FileAccess.get_file_as_string(path)
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(text.replace(from, to))
		file.close()

	# A read the file cannot answer now is refused, and the shell says so and
	# keeps it for a retry, even with the files as they were.
	rewrite.call("First", "Second")
	JSONLCache.rebuild_failure_hook = func() -> String: return "injected rebuild failure"
	var refused: Dictionary = source.item_title("ready", id)
	var action_refused := source.action_refusal()
	await shell._poll_external_changes()
	JSONLCache.rebuild_failure_hook = Callable()
	var r = A.is_true(str(refused.get("kind", "")) == "stale" and action_refused.contains("not ready")
		and bool(shell._unavailable.get("retryable", false)) and shell._unavailable_banner.visible,
		"reads and actions are refused and the shell shows why: %s %s %s" % [refused, action_refused, shell._unavailable])
	if r is String: shell.queue_free(); return r

	# A later poll, with nothing new on disk, reads it again and clears it.
	shell._retry_at_msec = 0
	await shell._poll_external_changes()
	r = A.is_true(shell._unavailable.is_empty() and not shell._unavailable_banner.visible and source.action_refusal().is_empty()
		and str(source.item_title("ready", id).get("title", "")) == "Second", "the retry reads the file and clears the notice: %s" % [shell._unavailable])
	if r is String: shell.queue_free(); return r

	# An edit another read took in first still reaches the view: with no item
	# open, the grid; with it open, the item, asked about once.
	var grid_titles := func() -> Array:
		return shell._query_grid._current_results.map(func(row: Dictionary) -> String: return str(row.get("title", "")))
	rewrite.call("Second", "Third")
	source.item_title("ready", id)
	await shell._poll_external_changes()
	await get_tree().process_frame
	var grid_after: Array = grid_titles.call()
	shell._on_item_activated(id, "ready")
	rewrite.call("Third", "Fourth")
	source.item_title("ready", id)
	await shell._poll_external_changes()
	var asked: bool = shell._confirm_reload_dialog.visible
	shell._confirm_reload_dialog.hide()
	# Read again with nothing new for the item: it is not asked about twice.
	var asked_at: String = shell._reconciled_revision
	var other_file := FileAccess.open(path, FileAccess.READ_WRITE)
	other_file.seek_end()
	other_file.store_string("\n")
	other_file.close()
	await shell._poll_external_changes()
	r = A.is_true(grid_after.has("Third") and asked and shell._reconciled_revision != asked_at and not shell._confirm_reload_dialog.visible,
		"an edit read in elsewhere refreshes the grid and asks about the open item once: %s %s" % [grid_after, asked])
	shell.queue_free()
	state.remove_project("ready")
	return r
