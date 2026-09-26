extends Node
## Session-file projects through the MCP project tools on a real AppState, the
## same path the GUI-hosted server takes.
##
## Oracle: the refusal texts returned by the tools and the presence of the
## project file on disk (FileAccess on the canonical path). The "second server"
## is a live foreign process named in the file's owner record; SessionProject
## internals are not consulted for any expectation.

var A := AssertHelpers
const DIR := "user://test_session_project"
const REPO := DIR + "/repo"
const SESSION_PATH := DIR + "/sessions/Scratch.dct"

var _state: AppState
var _tools: ToolRegistry
var _foreign_pid: int = 0


func setup() -> void:
	_remove_tree(DIR)
	DirAccess.make_dir_recursive_absolute(REPO + "/.git")
	DirAccess.make_dir_recursive_absolute(DIR + "/sessions")
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
	r = A.is_true(closed.get("closed") == "Scratch" and FileAccess.file_exists(SESSION_PATH), "close unloads and keeps the file: %s" % closed)
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
