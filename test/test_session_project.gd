extends Node
## Session-file and memory projects through the MCP project tools on a real
## AppState, the same path the GUI-hosted server takes.
##
## Oracle: the refusal texts returned by the tools and the presence of the
## project file and its owner record on disk (FileAccess on the canonical path). The "second server"
## is a live foreign process named in the file's owner record. For memory
## projects the oracle is the guarantees-table outcome per event (KB
## docket:01a0dc3d7498), the spill files' contents on disk (lease lapse, process
## exit, the quit prompt's choice) and the saved session list. For promotion the
## oracle is the durable target's .dct on disk (item, link and event lines). No
## SessionProject, MemoryProject or SessionPromotion internals are consulted for
## any expectation.

var A := AssertHelpers
const DIR := "user://test_session_project"
const REPO := DIR + "/repo"
const SESSION_PATH := DIR + "/sessions/Scratch.dct"
const SPILL_PATH := DIR + "/sessions/Mem.dct"

var _state: AppState
var _tools: ToolRegistry
var _foreign_pid: int = 0


func setup() -> void:
	_remove_tree(DIR)
	DirAccess.make_dir_recursive_absolute(REPO + "/.git")
	DirAccess.make_dir_recursive_absolute(DIR + "/sessions")
	# Spills go to the session directory; point it inside the test tree.
	OS.set_environment(SessionProject.SESSION_DIR_ENV, ProjectSettings.globalize_path(DIR + "/sessions"))
	_state = AppState.new()
	_state.load_schema()
	_state.create_dct(DIR + "/Primary.dct")
	_tools = ToolRegistry.new()
	_tools.init(_state.schema, _state.db, _state.get_project_dbs())
	_tools.add_project_fn = _state.add_project_result
	_tools.remove_project_fn = _state.remove_project
	_state.file_changed.connect(func() -> void: _tools.update_db(_state.schema, _state.db, _state.get_project_dbs()))


func teardown() -> void:
	if _foreign_pid > 0:
		OS.kill(_foreign_pid)
	for name in _state.get_project_dbs().keys():
		_state.remove_project(str(name))
	OS.unset_environment(SessionProject.SESSION_DIR_ENV)
	# The owner lease is process-wide; end it so the next test starts without an owner.
	MemoryProject._lease_until_msec = 0
	_remove_tree(DIR)


func _remove_tree(path: String) -> void:
	var directory: DirAccess = DirAccess.open(path)
	if directory == null:
		return
	directory.include_hidden = true
	for name in directory.get_directories():
		_remove_tree(path + "/" + name)
	for name in directory.get_files():
		directory.remove(name)
	DirAccess.remove_absolute(path)


func _spawn_foreign_process() -> int:
	## A live process that is not this one, standing in for another Docket server.
	if OS.get_name() == "Windows":
		return OS.create_process("ping", ["-n", "60", "127.0.0.1"])
	return OS.create_process("sleep", ["60"])


func _entry(listing: Dictionary, project: String) -> Dictionary:
	for entry: Dictionary in listing.get("projects", []):
		if entry.get("name") == project:
			return entry
	return {}


func test_session_file_project_lives_outside_git_has_one_owner_and_explicit_close_discard() -> Variant:
	# A path under a tree containing .git is refused, and no file appears.
	var in_repo := REPO + "/work/Inside.dct"
	var refused: Dictionary = _tools.call_tool("docket_project_add", {"mode":"session_file", "path":in_repo, "create":true})
	var r = A.contains(str(refused.get("error", "")), "inside the Git checkout", "in-repo session path refused: %s" % refused)
	if r is String: return r
	r = A.is_false(FileAccess.file_exists(in_repo), "no file written inside the repository")
	if r is String: return r

	# Created outside Git; project_list shows the mode beside the stage.
	var added: Dictionary = _tools.call_tool("docket_project_add", {"mode":"session_file", "path":SESSION_PATH, "create":true, "name":"Scratch"})
	r = A.is_true(added.get("name") == "Scratch" and FileAccess.file_exists(SESSION_PATH), "session project created on disk: %s" % added)
	if r is String: return r
	# Admitting it writes this process's owner record beside the file.
	var claim: Variant = JSON.parse_string(FileAccess.get_file_as_string(SESSION_PATH + ".owner")) if FileAccess.file_exists(SESSION_PATH + ".owner") else null
	r = A.is_true(claim is Dictionary and int(claim.get("pid", 0)) == OS.get_process_id(), "owner record names this process: %s" % claim)
	if r is String: return r
	var listing: Dictionary = _tools.call_tool("docket_project_list", {})
	var scratch := _entry(listing, "Scratch")
	var primary := _entry(listing, "Primary")
	r = A.is_true(scratch.get("storage_mode") == "session_file" and scratch.has("stage") and primary.get("storage_mode") == "durable", "project_list reports storage_mode per project: %s" % listing)
	if r is String: return r

	var created: Dictionary = _tools.call_tool("docket_create", {"project":"Scratch", "type":"work_item", "title":"Unfinished"})
	if created.has("error"): return "fixture create failed: %s" % created.error
	var id: String = created.id

	# Close keeps the file.
	var closed: Dictionary = _tools.call_tool("docket_project_close", {"name":"Scratch"})
	r = A.is_true(closed.get("closed") == "Scratch" and FileAccess.file_exists(SESSION_PATH) and not FileAccess.file_exists(SESSION_PATH + ".owner"), "close unloads, keeps the file and drops the owner record: %s" % closed)
	if r is String: return r

	# A second server holds the file: opening it here is refused, naming the owner.
	_foreign_pid = _spawn_foreign_process()
	var owner_record := FileAccess.open(SESSION_PATH + ".owner", FileAccess.WRITE)
	owner_record.store_string(JSON.stringify({"pid":_foreign_pid, "role":"serve", "port":3999, "claimed_at":"2026-09-26T00:00:00"}))
	owner_record.close()
	var second: Dictionary = _tools.call_tool("docket_project_add", {"path":SESSION_PATH})
	var refusal := str(second.get("error", ""))
	r = A.is_true(refusal.contains("owned by another Docket server") and refusal.contains("pid %d" % _foreign_pid) and refusal.contains("http://127.0.0.1:3999/mcp"), "second opener refused naming the owner: %s" % second)
	if r is String: return r
	r = A.is_true(FileAccess.file_exists(SESSION_PATH) and not _state.get_project_dbs().has("Scratch"), "refused open leaves the file and loads nothing")
	if r is String: return r

	# The owner exits; its record no longer names a live process, so the file opens here.
	OS.kill(_foreign_pid)
	_foreign_pid = 0
	OS.delay_msec(200)
	var reopened: Dictionary = _tools.call_tool("docket_project_add", {"path":SESSION_PATH})
	r = A.is_true(reopened.get("name") == "Scratch" and reopened.get("storage_mode") == "session_file", "reopened after the owner is gone: %s" % reopened)
	if r is String: return r

	# Discard without confirm lists the outstanding item and changes nothing.
	var dry: Dictionary = _tools.call_tool("docket_project_discard", {"name":"Scratch"})
	var listed: Array = []
	for item: Dictionary in dry.get("outstanding", []):
		listed.append(item.get("id"))
	r = A.is_true(dry.get("discarded") == false and listed.has(id) and FileAccess.file_exists(SESSION_PATH) and _state.get_project_dbs().has("Scratch"), "discard without confirm lists outstanding items and does nothing: %s" % dry)
	if r is String: return r

	# Discard with confirm removes the file and reports what it discarded.
	var gone: Dictionary = _tools.call_tool("docket_project_discard", {"name":"Scratch", "confirm":true})
	var discarded: Array = []
	for item: Dictionary in gone.get("outstanding_discarded", []):
		discarded.append(item.get("id"))
	return A.is_true(gone.get("discarded") == true and discarded.has(id) and not FileAccess.file_exists(SESSION_PATH), "discard with confirm deletes the file: %s" % gone)


func test_memory_project_is_owner_gated_bounded_listed_and_spilled_when_the_lease_lapses() -> Variant:
	# Row: creation needs an owner present. None holds the lease, so it is refused.
	var refused: Dictionary = _tools.call_tool("docket_project_add", {"mode":"memory", "name":"Mem", "max_items":3})
	var r = A.is_true(str(refused.get("error", "")).contains("owner-class client") and not _state.get_project_dbs().has("Mem"), "memory project refused without an owner: %s" % refused)
	if r is String: return r

	# A tool client's heartbeat does not count; an owner's does.
	var tool_beat: Dictionary = _tools.call_tool("docket_project_heartbeat", {"client":"agent", "client_class":"tool"})
	r = A.is_true(tool_beat.get("renewed") == false and tool_beat.get("lease", {}).get("owner_present") == false, "tool-class heartbeat renews nothing: %s" % tool_beat)
	if r is String: return r
	_tools.call_tool("docket_project_heartbeat", {"client":"test-owner", "client_class":"owner", "lease_seconds":60})
	var added: Dictionary = _tools.call_tool("docket_project_add", {"mode":"memory", "name":"Mem", "max_items":3})
	r = A.is_true(added.get("name") == "Mem" and added.get("storage_mode") == "memory", "memory project created with an owner present: %s" % added)
	if r is String: return r

	# project_list shows mode=memory and usage against the bound; no file exists.
	var mem := _entry(_tools.call_tool("docket_project_list", {}), "Mem")
	r = A.is_true(mem.get("storage_mode") == "memory" and mem.get("usage", {}).get("items") == 0 and mem.get("usage", {}).get("max_items") == 3 and not FileAccess.file_exists(SPILL_PATH), "list shows memory mode and usage 0/3: %s" % mem)
	if r is String: return r

	# Row: past the bound the next create is refused naming the limit; nothing is evicted.
	var ids: Array[String] = []
	for i in 3:
		var created: Dictionary = _tools.call_tool("docket_create", {"project":"Mem", "type":"work_item", "title":"Memory %d" % i})
		if created.has("error"): return "fixture create %d failed: %s" % [i, created.error]
		ids.append(str(created.id))
	var over: Dictionary = _tools.call_tool("docket_create", {"project":"Mem", "type":"work_item", "title":"One too many"})
	r = A.contains(str(over.get("error", "")), "limit of 3 items", "fourth create refused naming the limit: %s" % over)
	if r is String: return r
	var held: Dictionary = _tools.call_tool("docket_query", {"project":"Mem"})
	var held_ids: Array = []
	for item: Dictionary in held.get("items", []):
		held_ids.append(item.get("id"))
	r = A.is_true(held_ids.size() == 3 and held_ids.has(ids[0]) and held_ids.has(ids[1]) and held_ids.has(ids[2]), "existing items intact after the refusal: %s" % held)
	if r is String: return r
	mem = _entry(_tools.call_tool("docket_project_list", {}), "Mem")
	r = A.is_true(mem.get("usage", {}).get("items") == 3 and mem.get("usage", {}).get("max_items") == 3, "list shows usage 3/3: %s" % mem)
	if r is String: return r

	# Closing would lose it silently, so close is refused.
	var closed: Dictionary = _tools.call_tool("docket_project_close", {"name":"Mem"})
	r = A.is_true(str(closed.get("error", "")).contains("memory project") and _state.get_project_dbs().has("Mem"), "close of a memory project refused: %s" % closed)
	if r is String: return r

	# Row: the owner stops renewing and the lease lapses. The next call spills the
	# outstanding project to a session file, which is then served under the same name.
	_tools.call_tool("docket_project_heartbeat", {"client":"test-owner", "client_class":"owner", "lease_seconds":1})
	OS.delay_msec(1500)
	var after: Dictionary = _tools.call_tool("docket_project_list", {})
	r = A.is_true(FileAccess.file_exists(SPILL_PATH), "spill file written at the session path after the lease lapsed: %s" % after)
	if r is String: return r
	var spilled_text := FileAccess.get_file_as_string(SPILL_PATH)
	r = A.is_true(spilled_text.contains(ids[0]) and spilled_text.contains(ids[1]) and spilled_text.contains(ids[2]) and spilled_text.contains("session_file"), "spill file holds every item and records session_file mode")
	if r is String: return r
	mem = _entry(after, "Mem")
	return A.is_true(mem.get("storage_mode") == "session_file" and ProjectSettings.globalize_path(str(mem.get("path", ""))) == ProjectSettings.globalize_path(SPILL_PATH), "spilled project is served from the session file: %s" % mem)


## The target .dct's item lines by id, its link lines, and its event lines by
## item id, read from disk.
func _dct_records(path: String) -> Dictionary:
	var items := {}
	var links: Array = []
	var events := {}
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var record: Variant = JSON.parse_string(line)
		if not record is Dictionary:
			continue
		if record.get("_type") == "item":
			items[str(record.id)] = record
		elif record.get("_type") == "link":
			links.append(record)
		elif record.get("_type") == "event":
			(events.get_or_add(str(record.item_id), []) as Array).append(record)
	return {"items": items, "links": links, "events": events}


## Ten records in `project`: the 2nd is the 1st's child and links to it (both
## promoted) and links to the 3rd (left behind). Returns the ten ids.
func _seed_ten(project: String) -> Array[String]:
	var ids: Array[String] = []
	for i in 10:
		var args := {"project":project, "type":"work_item", "title":"%s record %d" % [project, i]}
		if i == 1:
			args["parent"] = ids[0]
		var created: Dictionary = _tools.call_tool("docket_create", args)
		if created.has("error"):
			return []
		ids.append(str(created.id))
	_tools.call_tool("docket_link", {"project":project, "from":ids[1], "to":ids[0], "relation":"follow_up"})
	_tools.call_tool("docket_link", {"project":project, "from":ids[1], "to":ids[2], "relation":"blocks"})
	return ids


func _check_promotion(source: String, mode: String, ids: Array[String], primary_path: String) -> Variant:
	var before: Dictionary = _dct_records(primary_path)
	var result: Dictionary = _tools.call_tool("docket_promote", {"items":[ids[0], ids[1]], "source_project":source, "to_project":"Primary", "promoted_by":"local:tester", "import_definition":true})
	if result.has("error"):
		return "promote from %s failed: %s" % [source, result.error]
	var after: Dictionary = _dct_records(primary_path)
	var added: Array = []
	for id in after.items:
		if not before.items.has(id):
			added.append(after.items[id])
	var r = A.is_true(added.size() == 2, "exactly two records written to the target from %s: %s" % [source, added])
	if r is String: return r

	var by_origin := {}
	for item: Dictionary in added:
		var provenance: Dictionary = item.get("extras", {}).get("promoted_from", {})
		r = A.is_true(provenance.get("project") == source and provenance.get("storage_mode") == mode and provenance.get("promoted_by") == "local:tester" and not str(provenance.get("promoted_at", "")).is_empty(), "provenance recorded on %s: %s" % [item.id, provenance])
		if r is String: return r
		by_origin[str(provenance.get("item_id", ""))] = item
		# The arrival is a `promoted` event on the copy, naming where it came from and who promoted it.
		var arrivals: Array = (after.events.get(str(item.id), []) as Array).filter(func(ev: Dictionary) -> bool: return ev.get("event_type") == "promoted")
		var note := str(arrivals[0].get("note", "")) if arrivals.size() == 1 else ""
		r = A.is_true(arrivals.size() == 1 and arrivals[0].get("actor") == "local:tester" and note.contains("%s:%s" % [source, provenance.get("item_id", "")]) and note.contains(mode), "one promoted event on %s carrying its provenance: %s" % [item.id, arrivals])
		if r is String: return r
	r = A.is_true(by_origin.has(ids[0]) and by_origin.has(ids[1]), "the two copies are of the two chosen records: %s" % by_origin.keys())
	if r is String: return r
	var first_copy := str(by_origin[ids[0]].id)
	var second: Dictionary = by_origin[ids[1]]

	# References inside the promoted set follow the copies; the one outside stays and is reported.
	var kept := "%s:%s" % [source, ids[2]]
	r = A.is_true(str(second.get("parent", "")) == "Primary:%s" % first_copy, "parent rewritten to the new id: %s" % second.get("parent"))
	if r is String: return r
	var targets := {}
	for link: Dictionary in after.links:
		if link.get("from_id") == second.id:
			targets[str(link.relation)] = str(link.to_id)
	r = A.is_true(targets.get("follow_up") == "Primary:%s" % first_copy and targets.get("blocks") == kept, "intra-set link rewritten, outside link kept qualified: %s" % targets)
	if r is String: return r
	var reported: Array = []
	for miss: Dictionary in result.get("unresolved", []):
		reported.append(miss.get("reference"))
	return A.is_true(reported == [kept] and second.get("extras", {}).get("promoted_from", {}).get("unresolved_refs", []) == [kept], "the left-behind reference is reported unresolved in the reply and on disk: %s" % result.get("unresolved"))


func test_promote_copies_exactly_the_chosen_records_from_session_file_and_memory_projects() -> Variant:
	var primary_path := DIR + "/Primary.dct"
	var session: Dictionary = _tools.call_tool("docket_project_add", {"mode":"session_file", "path":SESSION_PATH, "create":true, "name":"Scratch"})
	if session.has("error"): return "fixture session project failed: %s" % session.error
	_tools.call_tool("docket_project_heartbeat", {"client":"test-owner", "client_class":"owner", "lease_seconds":60})
	var memory: Dictionary = _tools.call_tool("docket_project_add", {"mode":"memory", "name":"Mem"})
	if memory.has("error"): return "fixture memory project failed: %s" % memory.error

	var session_ids := _seed_ten("Scratch")
	var memory_ids := _seed_ten("Mem")
	if session_ids.size() != 10 or memory_ids.size() != 10:
		return "fixture records failed"
	var r = _check_promotion("Scratch", SessionProject.MODE_SESSION_FILE, session_ids, primary_path)
	if r is String: return r
	return _check_promotion("Mem", SessionProject.MODE_MEMORY, memory_ids, primary_path)


func test_memory_projects_at_exit_and_at_the_quit_prompt_leave_every_item_on_disk() -> Variant:
	# Oracle: the session files on disk and the saved session list. The saved
	# session list is the user's; it is restored afterwards.
	var saved_session := UserPrefs.load_session()
	_tools.call_tool("docket_project_heartbeat", {"client":"test-owner", "client_class":"owner", "lease_seconds":60})
	var added: Dictionary = _tools.call_tool("docket_project_add", {"mode":"memory", "name":"Mem"})
	if added.has("error"): return "fixture memory project failed: %s" % added.error
	var ids: Array[String] = []
	for i in 3:
		var created: Dictionary = _tools.call_tool("docket_create", {"project":"Mem", "type":"work_item", "title":"Open %d" % i})
		if created.has("error"): return "fixture create %d failed: %s" % [i, created.error]
		ids.append(str(created.id))

	# Process exit with open items: every item is written to a session file,
	# and that file joins the saved session list so the next start opens it.
	MemoryProject.spill_on_exit(_state.get_project_dbs())
	var on_exit := _dct_records(SPILL_PATH)
	var listed := UserPrefs.load_session()
	UserPrefs.save_session(saved_session)
	var r = A.is_true(on_exit.items.has(ids[0]) and on_exit.items.has(ids[1]) and on_exit.items.has(ids[2]) and FileAccess.get_file_as_string(SPILL_PATH).contains("session_file"), "spill_on_exit wrote every item to %s: %s" % [SPILL_PATH, on_exit.items.keys()])
	if r is String: return r
	r = A.is_true(listed.has(ProjectSettings.globalize_path(SPILL_PATH)), "the exit spill is recorded in the saved session list: %s" % listed)
	if r is String: return r

	# A clean quit asks first; choosing "Spill" writes the project to a new
	# session file and serves it from there, and only then reports resolved.
	var dialog := MemoryProjectsDialog.new()
	add_child(dialog)
	dialog.init(_state)
	var resolved := [false]
	dialog.resolved.connect(func() -> void: resolved[0] = true)
	dialog.ask(MemoryProject.outstanding_projects(_state.get_project_dbs()))
	dialog.confirmed.emit()
	var mem := _entry(_tools.call_tool("docket_project_list", {}), "Mem")
	var chosen_path := str(mem.get("path", ""))
	var on_quit := _dct_records(chosen_path) if not chosen_path.is_empty() else {"items": {}}
	dialog.queue_free()
	r = A.is_true(resolved[0] and mem.get("storage_mode") == "session_file" and ProjectSettings.globalize_path(chosen_path) != ProjectSettings.globalize_path(SPILL_PATH) and on_quit.items.has(ids[0]) and on_quit.items.has(ids[1]) and on_quit.items.has(ids[2]), "the quit prompt's spill choice is on disk with every item and served: %s %s" % [mem, on_quit.items.keys()])
	if r is String: return r
	return A.is_true(MemoryProject.outstanding_projects(_state.get_project_dbs()).is_empty(), "nothing is left in memory to lose after the choice")
