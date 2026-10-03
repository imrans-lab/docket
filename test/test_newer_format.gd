extends Node

const DIR := "user://test_newer_format"
const PATH := DIR + "/future.dct"
const ITEM := '{"_type":"item","id":"FUT-0001","type":"chore","status":"open","title":"Known item","created_at":"2026-01-01","updated_at":"2026-01-01","future_field":{"opaque":true}}'
var _state: AppState
var _db: DocketDBJsonl
var _shell: AppShell

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)

func after_each() -> void:
	if is_instance_valid(_shell):
		remove_child(_shell)
		_shell.free()
		_shell = null
	if _state != null:
		for project in _state.get_project_dbs().keys(): _state.remove_project(str(project))
		_state = null
	if _db != null and _db.is_open(): _db.close()
	_db = null
	for suffix: String in ["", ".log", ".lock", ".cache", ".cache-wal", ".cache-shm", ".future.cache", ".future.cache-wal", ".future.cache-shm", ".v2.cache", ".v2.cache-wal", ".v2.cache-shm"]:
		DirAccess.remove_absolute(PATH + suffix)
	DirAccess.remove_absolute(DIR)

func _write(version: String, unknown: bool = true) -> PackedByteArray:
	var text := JSON.stringify({"_type":"meta", "version":version, "counter":1, "id_prefix":"FUT", "project":"future"}) + "\n" + ITEM + "\n"
	if unknown: text += '{"_type":"future_record","opaque":42}\n'
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	return text.to_utf8_buffer()

func test_future_real_db_ui_mcp_poll_reload_and_close_preserve_bytes() -> Variant:
	var original := _write("3.0.0")
	_state = AppState.new()
	_state.load_schema()
	var failures: Array = []
	_state.load_failed.connect(func(_path: String, reason: String) -> void: failures.append(reason))
	_state.load_dct(PATH)
	if _state.db == null: return "future project failed to open: " + str(failures)
	if not failures.is_empty(): return "quiet open emitted load_failed"
	_db = _state.db as DocketDBJsonl
	if _db.get_item("FUT-0001").get("title") != "Known item": return "known record not readable"
	if _db.get_item("FUT-0001").get("extras", {}).has("future_field"): return "unknown field reached display cache"
	if _db.execute_query({"filter":{"type":"chore"}}).size() != 1: return "known item not queryable"
	_state.prefs = UserPrefs.new()
	_shell = AppShell.new()
	_shell.init(_state)
	add_child(_shell)
	_shell._poll_timer.stop()
	_shell._update_window_title()
	var label := _shell._file_label.text
	if not label.contains("3.0.0") or not label.contains("read-only"): return "UI status lacks read-only version reason"
	var registry := ToolRegistry.new()
	registry.init(_state.schema, _db, _state.get_project_dbs())
	var result := registry.call_tool("docket_update", {"id":"FUT-0001", "title":"Refused"})
	var error := str(result.get("error", ""))
	if not error.contains("3.0.0") or not error.contains("read-only"): return "MCP mutation lacks version reason: " + str(result)
	var projects := registry.call_tool("docket_project_list", {})
	if not str(projects.projects[0].get("read_only_reason", "")).contains("3.0.0"): return "MCP project status lacks version"
	for tick in 3:
		_shell._on_poll_external_changes()
		DocketDBJsonl.settle_projects(_state.get_project_dbs(), true)
		DocketDBJsonl.settle_projects(_state.get_project_dbs(), false)
	if not _db.flush_checked().contains("3.0.0"): return "explicit settle did not refuse with version"
	_db.settle_in_background()
	_state.reload_all()
	if not _db.update_item_fields_checked("FUT-0001", {"title":"Refused after rebuild"}).contains("3.0.0"): return "rebuild lost write block"
	_state.remove_project("future")
	_db = null
	# Reopen the warmed cache and verify the block survives cache adoption.
	_db = DocketDBJsonl.open_jsonl(PATH)
	if _db == null: return DocketDBJsonl.last_open_error
	if not _db.update_item_fields_checked("FUT-0001", {"title":"Refused warm"}).contains("3.0.0"): return "warm cache lost write block"
	_db.close()
	_db = null
	if FileAccess.get_file_as_bytes(PATH) != original: return "future file bytes changed"
	if FileAccess.file_exists(PATH + ".log"): return "future session created sidecar"
	return true

func test_supported_unknown_kind_and_invalid_versions_are_refused() -> Variant:
	for version: String in ["2.0.0", "1.0.0", "0.9.0", "1.9.9", "3", "03.0.0", "3.0.0-01", "3.0.0-", "3.0.0+", "2.0.0+build"]:
		var original := _write(version)
		_db = DocketDBJsonl.open_jsonl(PATH)
		if _db != null: return "incorrectly opened unsupported/unknown-kind version " + version
		if FileAccess.get_file_as_bytes(PATH) != original: return "refusal changed file " + version
	return true

func test_semver_newer_discrimination() -> Variant:
	for version: String in ["2.0.1", "2.1.0-alpha.1", "3.0.0-beta+build.4", "999999999999999999999.0.0"]:
		if not JSONLParser.is_newer_version(version): return "valid future SemVer refused: " + version
	for version: String in ["2.0.0-rc.1", "2.0.0", "1.999.0", "v3.0.0", "3.0.0-00"]:
		if JSONLParser.is_newer_version(version): return "nonfuture/malformed SemVer accepted: " + version
	return true

func test_legacy_real_mutation_keeps_version_and_explicit_upgrade_requires_approval() -> Variant:
	_write("1.0.0", false)
	_db = DocketDBJsonl.open_jsonl(PATH)
	if _db == null: return DocketDBJsonl.last_open_error
	var error := _db.update_item_fields_checked("FUT-0001", {"title":"Allowed legacy edit"})
	if not error.is_empty(): return error
	error = _db.flush_checked()
	if not error.is_empty(): return error
	_db.close()
	_db = null
	var parsed := JSONLParser.parse_file(PATH)
	if parsed.meta.version != "1.0.0": return "mutation silently upgraded legacy version"
	var before := FileAccess.get_file_as_bytes(PATH)
	var preview := JSONLTypeUpgrade.preview(PATH)
	if not preview.ok: return "explicit upgrade preview failed: " + str(preview.error)
	var denied := JSONLTypeUpgrade.apply(PATH, preview)
	if denied.ok or not str(denied.error).contains("confirm"): return "upgrade bypassed explicit approval"
	return AssertHelpers.eq(FileAccess.get_file_as_bytes(PATH), before, "unapproved upgrade leaves bytes unchanged")

func test_reload_from_supported_to_future_prevents_first_write() -> Variant:
	_write("1.0.0", false)
	_db = DocketDBJsonl.open_jsonl(PATH)
	if _db == null: return DocketDBJsonl.last_open_error
	var original := _write("3.0.0")
	var error := _db.update_item_fields_checked("FUT-0001", {"title":"Refused after external upgrade"})
	if not error.contains("3.0.0"): return "freshness reload allowed first mutation: " + error
	_db.close()
	_db = null
	if FileAccess.file_exists(PATH + ".log"): return "freshness gate created future sidecar"
	return AssertHelpers.eq(FileAccess.get_file_as_bytes(PATH), original, "external future bytes preserved")

func test_future_sidecar_is_neither_replayed_nor_retired() -> Variant:
	var original := _write("3.0.0")
	var sidecar := FileAccess.open(PATH + ".log", FileAccess.WRITE)
	var journal := "opaque future journal\n".to_utf8_buffer()
	sidecar.store_buffer(journal)
	sidecar.close()
	_db = DocketDBJsonl.open_jsonl(PATH)
	if _db == null: return DocketDBJsonl.last_open_error
	_db.settle_in_background()
	_db.flush_checked()
	_db.reload()
	_db.close()
	_db = null
	if FileAccess.get_file_as_bytes(PATH) != original: return "future sidecar settle changed canonical"
	return AssertHelpers.eq(FileAccess.get_file_as_bytes(PATH + ".log"), journal, "future sidecar preserved")
