extends Node
## The Docket UI over RemoteDocketSource, answered by the real tool registry
## through McpHandler as a host's connection would: with some replies held
## back, a reply for an item the form has since moved away from must leave
## nothing of that item on screen (not its fields, and not its children);
## a shell shown inside a host must leave the host's preferences and theme as
## they were; and an item changed on disk while the panel's own change was
## waiting is asked about once, when that change is back.

const AppShell := preload("res://scripts/ui/app_shell.gd")
const RecordForm := preload("res://scripts/ui/record_form.gd")

const A = preload("res://test/assert_helpers.gd")
const Remote = preload("res://scripts/ui/remote_docket_source.gd")
const DIR := "user://fixtures/remote_source"
var _dbs: Array[DocketDB] = []


## A host connection that answers through McpHandler and holds calls to
## `held_tools` until release().
class HeldConnection:
	extends RefCounted
	signal released
	var handler: McpHandler
	var held_tools: Array[String] = []

	func call_tool(name: String, arguments: Dictionary, _operation_id: String = "") -> Dictionary:
		if held_tools.has(name):
			await released
		var reply: Dictionary = handler.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
			"params": {"name": name, "arguments": arguments}})
		return reply.get("result", {"error": reply.get("error", {})})

	func release() -> void:
		held_tools.clear()
		released.emit()


class Prefs:
	extends RefCounted
	func get_display_name() -> String:
		return "Tester"


## A trusted host for one panel over the real handler: it opens the panel's
## session, runs the panel's calls through the private docket/panel/call, and
## hands the panel each event the process sends before the reply it came
## with (the order of the stdio stream). A reply for the tool named `hold` is
## held back until release().
class PanelHost:
	extends RefCounted
	signal released
	var handler: McpHandler
	var source  # RemoteDocketSource
	var session := ""
	var hold := ""
	var delivered: Array = []
	var _outbox: Array = []

	func watch(projects: Dictionary) -> void:
		for project in projects:
			projects[project].items_changed.connect(func(changes: Array):
				for change in changes:
					_outbox.append(DocketHttpServer.host_event(change, project, handler)))

	func open(secret: String) -> void:
		var opened: Dictionary = handler.handle({"jsonrpc": "2.0", "id": 1, "method": "docket/panel/open_session",
			"params": {"panel_secret": secret, "panel": "test-panel"}})
		session = str(opened.get("result", {}).get("panel_session", ""))

	func panel_origin() -> String:
		return "panel:test-panel"

	func call_tool(name: String, arguments: Dictionary, operation_id: String = "") -> Dictionary:
		var reply: Dictionary = handler.handle({"jsonrpc": "2.0", "id": 1, "method": "docket/panel/call",
			"params": {"panel_session": session, "name": name, "arguments": arguments, "operation_id": operation_id}})
		await deliver()
		if name == hold:
			await released
		return reply.get("result", {"error": reply.get("error", {})})

	func deliver() -> void:
		while not _outbox.is_empty():
			var event: Dictionary = _outbox.pop_front()
			delivered.append(event)
			await source.handle_host_event(event)

	func release() -> void:
		hold = ""
		released.emit()


## Host preferences that record every write made to them.
class RecordingPrefs:
	extends RefCounted
	var first_name := "Host"
	var last_name := "Person"
	var writes: Array = []

	func get_display_name() -> String:
		return "Host Person"

	func has_ui_setting(_key: String) -> bool:
		return false

	func load_ui_setting(_key: String, default_value: String) -> String:
		return default_value

	func save_ui_setting(key: String, value: String) -> void:
		writes.append([key, value])

	func save() -> void:
		writes.append(["save"])


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	teardown()  # a run that stopped early may have left its fixtures


func teardown() -> void:
	for db in _dbs:
		if db != null and db.is_open():
			db.close()
	_dbs.clear()
	for child in get_children():
		remove_child(child)
		child.free()
	for filename in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [DIR, filename]))


func test_late_replies_for_a_previous_item_change_nothing_on_screen() -> Variant:
	var db := DocketDBJsonl.create_new_jsonl("%s/remote.dct" % DIR)
	_dbs.append(db)
	db.set_project_name("remote")
	var registry := ToolRegistry.new()
	registry.init(TypeRegistryBootstrap.load_shipped_schema(), db, {"remote": db})
	var created := func(title: String, parent: String = "") -> String:
		var args := {"type": "bug", "title": title, "project": "remote"}
		if not parent.is_empty():
			args["parent"] = "remote:%s" % parent
		return str(registry.call_tool("docket_create", args).get("id", ""))
	var item_a: String = created.call("Item A")
	var item_b: String = created.call("Item B")
	created.call("Child of A 1", item_a)
	created.call("Child of A 2", item_a)
	created.call("Child of B", item_b)

	var connection := HeldConnection.new()
	connection.handler = McpHandler.new()
	connection.handler.init_with_registry(registry)
	var source = Remote.new(connection, Prefs.new())
	var started: String = await source.start()
	var r = A.eq(started, "", "the remote source reads the process")
	if r is String: return r
	var form := RecordForm.new()
	add_child(form)
	form.init(source)

	# A's children reply is held; B loads completely; then A's reply lands.
	connection.held_tools = ["docket_query"]
	form.load_item(item_a, "remote")
	connection.held_tools = []
	await form.load_item(item_b, "remote")
	connection.release()
	r = A.eq([form._current_id, form._children_list.item_count, form._children_badge], [item_b, 1, " (1)"],
		"B's single child and count stay after A's two children arrive late")
	if r is String: return r

	# A's item view is held while B loads again; then it lands.
	connection.held_tools = ["docket_item_view"]
	form.load_item(item_a, "remote")
	connection.held_tools = []
	await form.load_item(item_b, "remote")
	connection.release()
	return A.eq([form._current_id, form._title_edit.text], [item_b, "Item B"],
		"a late view of A does not replace B on the form")


func test_a_shell_inside_a_host_leaves_its_preferences_and_theme_alone() -> Variant:
	var db := DocketDBJsonl.create_new_jsonl("%s/embedded.dct" % DIR)
	_dbs.append(db)
	db.set_project_name("embedded")
	var registry := ToolRegistry.new()
	registry.init(TypeRegistryBootstrap.load_shipped_schema(), db, {"embedded": db})
	var connection := HeldConnection.new()
	connection.handler = McpHandler.new()
	connection.handler.init_with_registry(registry)
	var prefs := RecordingPrefs.new()
	var source = Remote.new(connection, prefs)
	var r = A.eq(await source.start(), "", "the remote source reads the process")
	if r is String: return r
	var shared := Theme.new()
	shared.default_font_size = 13
	var shell := AppShell.new()
	shell.theme = shared
	shell.init(source, true)
	add_child(shell)
	for i in 3:
		await get_tree().process_frame  # the shell restores its settings as it starts
	shell._set_font_size("large")
	shell._on_prefs_confirmed()
	return A.eq([prefs.writes, shared.default_font_size, shell.theme != shared, shell.theme.default_font_size],
		[[], 13, true, 18], "font size and preferences stay in the shell; the host's theme keeps its size")


## The open item changed in the project file by another writer, found by the
## panel's own next comment, whose request has the file read again: the
## owner reports that as an external reload (no origin, no operation) and the
## comment as the panel's own (its origin, an operation id); nothing is asked
## while the comment waits for its reply, and exactly once when it is back.
## The panel's own comment alone asks nothing.
func test_a_change_made_elsewhere_during_the_panels_own_is_asked_about_once() -> Variant:
	var db := DocketDBJsonl.create_new_jsonl("%s/held.dct" % DIR)
	_dbs.append(db)
	db.set_project_name("held")
	var registry := ToolRegistry.new()
	registry.init(TypeRegistryBootstrap.load_shipped_schema(), db, {"held": db})
	var item := str(registry.call_tool("docket_create", {"type": "bug", "title": "Open", "project": "held"}).get("id", ""))
	var secret := Crypto.new().generate_random_bytes(32).hex_encode()
	OS.set_environment(McpHandler.PanelAuthority.SECRET_VARIABLE, secret)
	var host := PanelHost.new()
	host.handler = McpHandler.new()
	host.handler.init_with_registry(registry)
	host.handler.panel_authority = McpHandler.PanelAuthority.from_environment(registry)
	host.watch({"held": db})
	host.open(secret)
	var source = Remote.new(host, Prefs.new())
	host.source = source
	var r = A.eq([host.session.length(), await source.start()], [64, ""], "the host opened the panel's session and the source reads the process")
	if r is String: return r
	var shell := AppShell.new()
	shell.init(source, true)
	add_child(shell)
	await shell._record_form.load_item(item, "held")
	var asked := [0]
	shell._confirm_reload_dialog.about_to_popup.connect(func(): asked[0] += 1)
	var elsewhere: Array = []
	source.open_item_changed_elsewhere.connect(func(project: String, id: String, deleted: bool):
		elsewhere.append([project, id, deleted]))

	await source.add_comment("held", item, "Tester", "the panel's own")
	r = A.eq([elsewhere, asked[0]], [[], 0], "the panel's own comment is not taken as a change elsewhere")
	if r is String: return r

	# Another writer changes the file itself; the panel's next comment finds
	# it changed and has the project read again before commenting.
	var path := ProjectSettings.globalize_path("%s/held.dct" % DIR)
	var outside := ProjectSettings.globalize_path("%s/outside.dct" % DIR)
	DirAccess.copy_absolute(path, outside)
	var other := DocketDBJsonl.open_jsonl(outside)
	other.update_item_fields(item, {"title": "Changed on disk"})
	other.close()
	DirAccess.copy_absolute(outside, path)
	host.delivered.clear()
	host.hold = "docket_comment"
	source.add_comment("held", item, "Tester", "the panel's own, held")
	await get_tree().process_frame
	var reloads: Array = host.delivered.filter(func(event: Dictionary) -> bool:
		return event.change == "reloaded" and event.cause == "external_reload" and event.origin == "" and event.operation_id == "")
	var comments: Array = host.delivered.filter(func(event: Dictionary) -> bool:
		return event.change == "comment_added" and event.cause == "mutation" and event.origin == "panel:test-panel" and not str(event.operation_id).is_empty())
	r = A.eq([reloads.size(), comments.size(), elsewhere, asked[0]], [1, 1, [], 0],
		"within the panel's comment the file read again is an external reload and the comment the panel's own; nothing is asked while it waits: %s" % [host.delivered])
	if r is String: return r
	host.release()
	for i in 5:
		await get_tree().process_frame
	return A.is_true(elsewhere == [["held", item, false]] and asked[0] == 1 and shell._confirm_reload_dialog.dialog_text.contains("changed elsewhere"),
		"once the panel's own comment is back, the change on disk is reported and asked about once: %s %d %s" % [elsewhere, asked[0], shell._confirm_reload_dialog.dialog_text])
