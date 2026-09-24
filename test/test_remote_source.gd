extends Node
## The item form over RemoteDocketSource, answered by the real tool registry
## through McpHandler as a host's connection would, with some replies held
## back: a reply for an item the form has since moved away from must leave
## nothing of that item on screen — not its fields, and not its children.

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

	func call_tool(name: String, arguments: Dictionary) -> Dictionary:
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
