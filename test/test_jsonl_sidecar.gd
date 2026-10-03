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
	# The debounce settles in the background; its commit lands on a later tick.
	if settle_error.is_empty(): settle_error = db.finish_settle()
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


func test_save_skips_clean_projects_and_quit_waits_for_the_background_write() -> Variant:
	## File → Save (AppState.flush_all) and the quit hook on two projects, one
	## with an empty sidecar. Oracles are files: bytes, whole-second mtime,
	## sidecar lines, probe strings, leftover temp files, and the parser.
	## The in-flight write is not under real contention: a two-line project's
	## worker finishes before the next step, so quit's wait path never blocks.
	var clean_path := DIR + "/Clean.dct"
	var dirty_path := DIR + "/Dirty.dct"
	for path in [clean_path, dirty_path]:
		var created := DocketDBJsonl.create_new_jsonl(path)
		if created == null: return "could not create %s" % path
		created.close()
	var state := AppState.new()
	state.load_schema()
	state.load_projects([clean_path, dirty_path])
	var dirty := state.get_db_for_project("Dirty") as DocketDBJsonl
	if dirty == null or state.get_db_for_project("Clean") == null: return "projects did not load"
	var r = A.eq(dirty.set_project_meta_checked({"hypothesis": "save-probe-1"}), "", "first mutation journals")
	if r is String: return _close_all(state, r)
	var clean_bytes := FileAccess.get_file_as_bytes(clean_path)
	var clean_mtime := FileAccess.get_modified_time(clean_path)
	# Past the file's whole second, so any rewrite of Clean would move its mtime.
	while Time.get_unix_time_from_system() < clean_mtime + 1.1: OS.delay_msec(50)

	# Save snapshots Dirty now; the canonical is replaced only on a later commit.
	state.flush_all()
	r = A.eq(dirty.set_project_meta_checked({"success_criteria": "save-probe-2"}), "", "a mutation while the write is in flight journals")
	if r is String: return _close_all(state, r)
	r = A.eq(dirty.finish_settle(), "", "background settle commits")
	if r is String: return _close_all(state, r)
	var settled := FileAccess.get_file_as_string(dirty_path)
	r = A.is_true(settled.contains("save-probe-1") and not settled.contains("save-probe-2") and _sidecar_lines(dirty_path) == 1 and FileAccess.get_file_as_string(dirty_path + ".log").contains("save-probe-2"), "the canonical holds what was journaled before Save; the later record stays in the sidecar")
	if r is String: return _close_all(state, r)

	# Save again and quit at once: quit waits for that write and commits it.
	state.flush_all()
	DocketDBJsonl.settle_projects(state.get_project_dbs(), false)
	var final_text := FileAccess.get_file_as_string(dirty_path)
	var parsed := JSONLParser.parse_file(dirty_path)
	r = A.is_true(str(parsed.get("error", "")).is_empty() and not (parsed.get("meta", {}) as Dictionary).is_empty() and final_text.contains("save-probe-1") and final_text.contains("save-probe-2") and _sidecar_lines(dirty_path) == 0, "after quit the canonical parses and holds both records, and no sidecar is left")
	if r is String: return _close_all(state, r)
	for name in DirAccess.get_files_at(DIR):
		r = A.is_false(name.contains(".tmp."), "no temp file is left behind (%s)" % name)
		if r is String: return _close_all(state, r)
	r = A.is_true(FileAccess.get_file_as_bytes(clean_path) == clean_bytes and FileAccess.get_modified_time(clean_path) == clean_mtime and _sidecar_lines(clean_path) == 0, "the project with an empty sidecar keeps its bytes and mtime")
	if r is String: return _close_all(state, r)

	# Control: a Save whose settle is refused rebuilds that project's cache and
	# tells views to re-read. A foreign line appended to Dirty's canonical after
	# a journaled mutation makes the settle's fingerprint check refuse.
	var re_reads := [0]
	state.data_changed.connect(func() -> void: re_reads[0] += 1)
	r = A.eq(dirty.set_project_meta_checked({"hypothesis": "save-probe-3"}), "", "a mutation journals before the foreign write")
	if r is String: return _close_all(state, r)
	var foreign := FileAccess.open(dirty_path, FileAccess.READ_WRITE)
	foreign.seek_end()
	foreign.store_string("\n" + JSON.stringify({"_type": "saved_query", "name": "foreign-probe", "query": {}}) + "\n")
	foreign.close()
	state.save()
	r = A.eq(re_reads[0], 1, "a Save whose settle is refused emits data_changed once")
	if r is String: return _close_all(state, r)
	r = A.eq(dirty.flush_checked(), "", "the rebuilt project settles, leaving every project clean")
	if r is String: return _close_all(state, r)

	# A Save with every project clean tells no view to re-read the cache.
	state.save()
	return _close_all(state, A.eq(re_reads[0], 1, "a Save of clean projects emits no data_changed"))


func test_sliced_snapshot_restarts_when_the_cache_is_written_between_slices() -> Variant:
	## A background settle reading its snapshot one row per tick. A mutation
	## after the first item row was read must still reach the canonical: the
	## oracle is the canonical's bytes and the sidecar's absence after commit.
	var path := DIR + "/Sliced.dct"
	var created := DocketDBJsonl.create_new_jsonl(path)
	if created == null: return "could not create %s" % path
	created.close()
	var db := DocketDBJsonl.open_jsonl(path)
	if db == null: return "project did not open: %s" % DocketDBJsonl.last_open_error
	var ids: Array = []
	for i in 3:
		var id := db.next_id()
		ids.append(id)
		var error := db.insert_item(id, {"type": "bug", "status": "open", "title": "sliced-item-%d" % i, "created_at": "2026-09-29T10:00:00Z", "updated_at": "2026-09-29T10:00:00Z", "tags": ["t%d" % i]})
		if not error.is_empty(): db.close(); return "insert failed: %s" % error
	ids.sort()
	var saved_slice := DocketDBJsonl.snapshot_slice_ms
	var saved_rows := DocketDBJsonl.snapshot_chunk_rows
	DocketDBJsonl.snapshot_slice_ms = 0
	DocketDBJsonl.snapshot_chunk_rows = 1
	var r = A.eq(db.settle_in_background(), "", "Save starts a sliced settle")
	if r is String: return _restore_slicing(db, saved_slice, saved_rows, r)
	r = A.is_true(db.is_settling(), "the settle is reading its snapshot")
	if r is String: return _restore_slicing(db, saved_slice, saved_rows, r)
	# The first slice read the first item row; this rewrites that row.
	r = A.eq(db.update_item_fields_checked(str(ids[0]), {"title": "rewritten-between-slices"}), "", "a mutation between slices journals")
	if r is String: return _restore_slicing(db, saved_slice, saved_rows, r)
	var ticks := 0
	while db.is_settling() and ticks < 500:
		DocketDBJsonl.settle_projects({"Sliced": db}, true)
		OS.delay_msec(2)
		ticks += 1
	var text := FileAccess.get_file_as_string(path)
	var parsed := JSONLParser.parse_file(path)
	r = A.is_true(not db.is_settling() and str(parsed.get("error", "")).is_empty() and text.contains("rewritten-between-slices") and not text.contains("sliced-item-0") and text.contains("sliced-item-2") and text.contains("\"t2\"") and _sidecar_lines(path) == 0, "the canonical parses, holds the mid-read rewrite and every item and tag, and the sidecar is retired")
	return _restore_slicing(db, saved_slice, saved_rows, r)


func _restore_slicing(db: DocketDBJsonl, slice_ms: int, chunk_rows: int, result: Variant) -> Variant:
	DocketDBJsonl.snapshot_slice_ms = slice_ms
	DocketDBJsonl.snapshot_chunk_rows = chunk_rows
	db.close()
	return result


func _close_all(state: AppState, result: Variant) -> Variant:
	for name in state.get_project_dbs().keys():
		state.remove_project(str(name))
	return result


func test_later_tick_refused_settle_notifies_and_refreshes_rebuilt_rows_once() -> Variant:
	var fixture := preload("res://test/test_poll_freshness.gd").new()
	add_child(fixture)
	fixture.setup()
	var error: String = fixture._fixture(2)
	var outcome: Variant = error if not error.is_empty() else true
	if outcome == true:
		outcome = _later_tick_refusal(fixture)
	fixture.teardown()
	remove_child(fixture)
	fixture.free()
	return outcome

func test_server_owned_later_tick_refusal_notifies_and_refreshes_once() -> Variant:
	var fixture := preload("res://test/test_poll_freshness.gd").new()
	add_child(fixture)
	fixture.setup()
	var error: String = fixture._fixture(2)
	var outcome: Variant = error if not error.is_empty() else true
	if outcome == true:
		outcome = _later_tick_refusal(fixture, true)
	fixture.teardown()
	remove_child(fixture)
	fixture.free()
	return outcome

func _later_tick_refusal(fixture: Node, server_owned: bool = false) -> Variant:
	var db: DocketDBJsonl = fixture.dbs[0]
	var registry: TypeRegistry = fixture.state.get_type_registry("poll0")
	var item := registry.create_item({"type": "chore", "title": "row original"}, "tester")
	if item.has("error"): return item.error
	var error := db.flush_checked()
	if not error.is_empty(): return error
	var canonical := FileAccess.get_file_as_string(db.get_path())
	error = db.update_item_fields_checked(str(item.id), {"title": "row pending"})
	if not error.is_empty(): return error
	fixture.shell._query_grid.refresh()
	error = db.settle_in_background()
	if not error.is_empty() or not db.is_settling(): return "background job did not start: %s" % error
	# Worker completion is distinct from its later main-thread commit. An
	# external replacement makes that commit refuse and reload real files.
	db._settle_job.wait()
	var file := FileAccess.open(db.get_path(), FileAccess.WRITE)
	file.store_string(canonical.replace("row original", "row rebuilt"))
	file.close()
	DirAccess.remove_absolute(db.get_path() + ".log")
	var signals: Array = []
	fixture.state.data_changed.connect(func() -> void: signals.append("changed"))
	var queries: int = fixture.state.queries
	if server_owned:
		# No _ready/tree attachment: this tests the server frame without opening
		# a listener, accessing user preferences or racing the shell frame.
		var server := DocketHttpServer.new()
		server.external_state = fixture.state
		server._project_dbs = fixture.state.get_project_dbs()
		server._process(0.0)
		server.free()
	else:
		fixture.shell._process(0.0)
	var r = A.is_true(not db.last_write_error.is_empty() and signals.size() == 1 and fixture.state.queries == queries + 1, "later refused commit emits once and queries once (%s)" % db.last_write_error)
	if r is String: return r
	r = A.eq(fixture._shown_rows(), fixture._expected_rows(), "visible rows equal rebuilt core query")
	if r is String: return r
	r = A.eq(str(db.get_item(str(item.id)).title), "row rebuilt", "rebuilt external title is shown")
	if r is String: return r
	fixture.shell._on_poll_external_changes()
	return A.is_true(signals.size() == 1 and fixture.state.queries == queries + 1, "next idle tick neither signals nor queries again")
