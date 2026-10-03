extends Node
## Real legacy DBs through session load, AppShell poll, mutation and cache rebuild.
const DIR := "user://test_prefix_collision"
var _state: AppState
var _shell: AppShell

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)

func after_each() -> void:
	if is_instance_valid(_shell):
		remove_child(_shell)
		_shell.free()
		_shell = null
	if _state != null:
		for name in _state.get_project_dbs().keys(): _state.remove_project(str(name))
		_state = null
	var directory := DirAccess.open(DIR)
	if directory != null:
		for name in directory.get_files(): directory.remove(name)
	DirAccess.remove_absolute(DIR)

func _fixture(project: String, id: String) -> PackedByteArray:
	var text := JSON.stringify({"_type":"meta", "version":"1.0.0", "counter":2, "id_prefix":"SAME", "project":project}) + "\n"
	text += JSON.stringify({"_type":"item", "id":id, "type":"chore", "status":"open", "title":project, "created_at":"2026-01-01", "updated_at":"2026-01-01"}) + "\n"
	var file := FileAccess.open(DIR + "/" + project + ".dct", FileAccess.WRITE)
	file.store_string(text)
	file.close()
	return text.to_utf8_buffer()

func test_load_poll_mutation_and_reload_keep_canonical_prefix() -> Variant:
	var alpha_bytes := _fixture("Alpha", "SAME-0001")
	var beta_bytes := _fixture("Beta", "SAME-0002")
	_state = AppState.new()
	_state.load_schema()
	_state.load_projects([DIR + "/Alpha.dct", DIR + "/Beta.dct"])
	var alpha := _state.get_db_for_project("Alpha") as DocketDBJsonl
	var beta := _state.get_db_for_project("Beta") as DocketDBJsonl
	if alpha == null or beta == null: return "colliding legacy projects did not load"
	if alpha.get_id_prefix() == beta.get_id_prefix(): return "session aliases still collide"
	var alias := beta.get_id_prefix()
	_state.prefs = UserPrefs.new()
	_shell = AppShell.new()
	_shell.init(_state)
	add_child(_shell)
	_shell._poll_timer.stop()
	for tick in 3:
		_shell._on_poll_external_changes()
		DocketDBJsonl.settle_projects(_state.get_project_dbs(), true)
		DocketDBJsonl.settle_projects(_state.get_project_dbs(), false)
	if FileAccess.get_file_as_bytes(DIR + "/Alpha.dct") != alpha_bytes: return "load/poll changed first canonical"
	if FileAccess.get_file_as_bytes(DIR + "/Beta.dct") != beta_bytes: return "load/poll materialized collision alias"
	_state.reload_all()
	if beta.get_id_prefix() != "SAME": return "initial cache rebuild retained alias"
	if FileAccess.get_file_as_bytes(DIR + "/Alpha.dct") != alpha_bytes: return "initial rebuild changed first canonical"
	if FileAccess.get_file_as_bytes(DIR + "/Beta.dct") != beta_bytes: return "initial rebuild changed second canonical"
	_state.remove_project("Beta")
	var refusal := _state.add_project(DIR + "/Beta.dct")
	if not refusal.is_empty(): return refusal
	beta = _state.get_db_for_project("Beta") as DocketDBJsonl
	alias = beta.get_id_prefix()
	if alias == alpha.get_id_prefix(): return "re-added project lacks unique session alias"
	var registry := ToolRegistry.new()
	registry.init(_state.schema, alpha, _state.get_project_dbs())
	var result := registry.call_tool("docket_update", {"project":"Beta", "id":"SAME-0002", "title":"Edited Beta"})
	if result.has("error"): return "explicit-project mutation failed: " + str(result)
	if beta.get_item("SAME-0002").get("title") != "Edited Beta": return "mutation routed to wrong project"
	if alpha.get_item("SAME-0001").get("title") != "Alpha": return "mutation changed first project"
	# Legacy generation uses the session alias; UUID7 generation stays stateless.
	var legacy := beta.next_id_checked()
	if not str(legacy.error).is_empty(): return str(legacy.error)
	if not str(legacy.id).begins_with(alias + "-"): return "legacy ID lost session alias"
	var counter := beta.get_counter()
	var uuid := beta.next_uuid7_id()
	if uuid.length() != 32 or beta.get_counter() != counter: return "UUID7 generation changed legacy counter"
	var error := beta.flush_checked()
	if not error.is_empty(): return error
	var parsed := JSONLParser.parse_file(DIR + "/Beta.dct")
	if parsed.meta.get("id_prefix") != "SAME": return "real mutation serialized session alias"
	if FileAccess.get_file_as_bytes(DIR + "/Alpha.dct") != alpha_bytes: return "second mutation rewrote first canonical"
	var settled := FileAccess.get_file_as_bytes(DIR + "/Beta.dct")
	_state.reload_all()
	if beta.get_id_prefix() != "SAME": return "cache adoption did not restore stored prefix"
	if FileAccess.get_file_as_bytes(DIR + "/Alpha.dct") != alpha_bytes: return "cache rebuild changed first canonical"
	if FileAccess.get_file_as_bytes(DIR + "/Beta.dct") != settled: return "cache rebuild changed settled canonical"
	_shell._on_poll_external_changes()
	if _state.find_item_db("SAME-0002") != beta: return "reload changed legacy item routing"
	_state.remove_project("Beta")
	if FileAccess.get_file_as_bytes(DIR + "/Beta.dct") != settled: return "close rewrote canonical"
	var reopened := DocketDBJsonl.open_jsonl(DIR + "/Beta.dct")
	if reopened == null: return DocketDBJsonl.last_open_error
	var prefix := reopened.get_id_prefix()
	reopened.close()
	if prefix != "SAME": return "warm reopen retained session alias"
	return true
