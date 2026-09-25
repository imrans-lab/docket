extends Node

var A := AssertHelpers
const QueryTypeScope := preload("res://scripts/core/query_type_scope.gd")
const TypeCatalog := preload("res://scripts/core/type_catalog.gd")
var _handler: McpHandler


func setup() -> void:
	_handler = McpHandler.new()
	# Give it a mock registry with no tools for basic protocol tests
	_handler.init_with_registry(ToolRegistry.new())


func test_initialize() -> Variant:
	var req := {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
		"protocolVersion": "2025-03-26",
		"capabilities": {},
		"clientInfo": {"name": "test", "version": "1.0"}
	}}
	var resp = _handler.handle(req)
	var r = A.eq(resp.id, 1)
	if r is String: return r
	r = A.has_key(resp, "result")
	if r is String: return r
	r = A.eq(resp.result.protocolVersion, "2025-03-26")
	if r is String: return r
	return A.has_key(resp.result, "serverInfo")


func test_initialized_notification() -> Variant:
	var req := {"jsonrpc": "2.0", "method": "notifications/initialized"}
	var resp = _handler.handle(req)
	return A.is_null(resp, "notification returns null")


func test_tools_list() -> Variant:
	var req := {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
	var resp = _handler.handle(req)
	var r = A.has_key(resp, "result")
	if r is String: return r
	return A.has_key(resp.result, "tools")


func test_unknown_tool() -> Variant:
	var req := {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
		"name": "nonexistent_tool", "arguments": {}
	}}
	var resp = _handler.handle(req)
	var r = A.has_key(resp, "error")
	if r is String: return r
	return A.eq(resp.error.code, -32602, "invalid params error code")


func test_bad_method() -> Variant:
	var req := {"jsonrpc": "2.0", "id": 4, "method": "bogus/method"}
	var resp = _handler.handle(req)
	return A.has_key(resp, "error")


func test_ping() -> Variant:
	var req := {"jsonrpc": "2.0", "id": 5, "method": "ping"}
	var resp = _handler.handle(req)
	var r = A.has_key(resp, "result")
	if r is String: return r
	return A.eq(resp.result, {}, "ping returns empty result")


## The private panel channel as a host uses it, over a real project. The host
## registers a grant for one item and the person it names; an edit through
## it is recorded as that person exactly once, whatever the request says,
## while the same edit as a tool stays an agent's. Every way around the grant
## (none, guessed, another item or project, no secret, the private method as
## a tool, a reserved argument on a tool, a grant revoked with its panel)
## changes nothing.
func test_panel_channel_edits_only_as_the_granted_person() -> Variant:
	return _on_panel_project(_panel_channel_checks)


## Creating and moving items through the private channel, over a real
## project. A create grant names a type and no item: it makes one item, with
## an id the process chooses, as the person, and can neither name an
## existing item nor move one. An item grant moves its item to another status
## with a field edit as one committed change, the person's, which a second
## client opening the file sees whole, and answers with the committed token;
## a move with a stale, missing or empty token changes nothing.
func test_panel_channel_creates_and_moves_items_as_the_person() -> Variant:
	return _on_panel_project(_panel_create_and_transition_checks)


## A file attached through the private channel, over a real project: the
## person's bytes and metadata (its name exactly as given), with one
## "attached" event of theirs, in one committed change that a second client
## opening the file sees exactly; a file too large (as base64 or as bytes),
## data that is not base64, or an item the grant does not cover changes
## nothing; the same attach as a tool is still the agent's.
func test_panel_channel_attaches_files_as_the_person() -> Variant:
	return _on_panel_project(_panel_attach_checks)


# `checks` (handler, db, secret, item, other) over a new project "panel" with
# two bugs, served by a handler with the private channel; the project is
# removed afterwards.
func _on_panel_project(checks: Callable) -> Variant:
	var dir := OS.get_cache_dir().path_join("docket_panel_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var db := DocketDBJsonl.create_new_jsonl(dir.path_join("panel.dct"))
	db.set_project_name("panel")
	var registry := ToolRegistry.new()
	registry.init(TypeRegistryBootstrap.load_shipped_schema(), db, {"panel": db})
	var item := str(registry.call_tool("docket_create", {"type": "bug", "title": "Before", "project": "panel"}).get("id", ""))
	var other := str(registry.call_tool("docket_create", {"type": "bug", "title": "Other", "project": "panel"}).get("id", ""))
	var secret := Crypto.new().generate_random_bytes(32).hex_encode()
	OS.set_environment(McpHandler.PanelAuthority.SECRET_VARIABLE, secret)
	var handler := McpHandler.new()
	handler.init_with_registry(registry)
	handler.panel_authority = McpHandler.PanelAuthority.from_environment(registry)
	var result: Variant = checks.call(handler, db, secret, item, other)
	db.close()
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
	return result


func _panel_create_and_transition_checks(handler: McpHandler, db: DocketDB, secret: String, item: String, _other: String) -> Variant:
	var send := func(method: String, params: Dictionary) -> Dictionary:
		return handler.handle({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	var host := {"panel_secret": secret, "panel": "panel-1", "person": "imran", "project": "panel"}
	var misregistered := {
		"a create grant naming an item": send.call("docket/panel/register", host.merged({"item": item, "type": "bug", "actions": ["create_item"]})),
		"a create grant allowing more": send.call("docket/panel/register", host.merged({"type": "bug", "actions": ["create_item", "update_item"]})),
		"a create grant with no type": send.call("docket/panel/register", host.merged({"actions": ["create_item"]})),
	}
	for why in misregistered:
		var r = A.is_true(misregistered[why].has("error"), "%s is refused: %s" % [why, misregistered[why]])
		if r is String: return r
	var create_grant := str(send.call("docket/panel/register", host.merged({"type": "bug", "actions": ["create_item"]}))
		.get("result", {}).get("panel_grant", ""))
	var count_items := func() -> int:
		return int(handler._registry.call_tool("docket_query", {"project": "panel"}).get("count", -1))
	var count: int = count_items.call()
	var before := [db.get_item(item).title, db.get_item(item).status, db.get_events(item).size()]
	var misused := {
		"creating over an existing item": send.call("docket/panel/create_item", {"panel_grant": create_grant, "project": "panel",
			"id": item, "fields": {"title": "Over"}}),
		"choosing the new item's id": send.call("docket/panel/create_item", {"panel_grant": create_grant, "project": "panel",
			"fields": {"title": "Chosen", "id": item}}),
		"moving an item with a create grant": send.call("docket/panel/transition_item", {"panel_grant": create_grant,
			"project": "panel", "id": item, "target": "closed"}),
	}
	for why in misused:
		var r = A.is_true(misused[why].has("error"), "%s is refused: %s" % [why, misused[why]])
		if r is String: return r
	var r = A.is_true(count_items.call() == count and [db.get_item(item).title, db.get_item(item).status,
		db.get_events(item).size()] == before, "a refused create changes nothing")
	if r is String: return r

	var created: Dictionary = send.call("docket/panel/create_item", {"panel_grant": create_grant, "project": "panel",
		"fields": {"title": "Made here"}, "operation_id": "op-create"}).get("result", {})
	var id := str(created.get("id", ""))
	var made := db.get_item(id)
	r = A.is_true(not id.is_empty() and id != item and made.get("title") == "Made here"
		and str(created.get("item_token", "")) == handler._registry.get_type_registry("panel").item_token(id)
		and db.get_events(id).map(func(e: Dictionary) -> Array: return [e.event_type, e.actor]) == [["created", "human:imran"]],
		"the create grant makes one new item, its id chosen here, as the person: %s %s" % [created, made])
	if r is String: return r
	var again: Dictionary = send.call("docket/panel/create_item", {"panel_grant": create_grant, "project": "panel", "fields": {"title": "Twice"}})
	r = A.is_true(again.has("error") and count_items.call() == count + 1, "and only once: %s" % [again])
	if r is String: return r

	var lifecycle: Dictionary = handler._registry.get_type_registry("panel").get_type("bug").definition.lifecycle
	var target := str(lifecycle.transitions.get(made.status, [""])[0])
	var item_grant := str(send.call("docket/panel/register", host.merged({"item": id, "actions": ["update_item", "transition_item"]}))
		.get("result", {}).get("panel_grant", ""))
	var move := {"panel_grant": item_grant, "project": "panel", "id": id, "target": target}
	before = [db.get_item(id).title, db.get_item(id).status, db.get_events(id).size()]
	var unchecked := {
		"a stale token": send.call("docket/panel/transition_item", move.merged({"changes": {"title": "Alternate"},
			"expected_item_token": "stale"})),
		"no token": send.call("docket/panel/transition_item", move.merged({"changes": {"title": "Alternate"}})),
		"an empty token": send.call("docket/panel/transition_item", move.merged({"changes": {"title": "Alternate"},
			"expected_item_token": ""})),
	}
	for why in unchecked:
		r = A.is_true(unchecked[why].has("error") and [db.get_item(id).title, db.get_item(id).status, db.get_events(id).size()] == before,
			"a move with %s changes nothing: %s" % [why, unchecked[why]])
		if r is String: return r
	var batches: Array = []
	var note_batch := func(changes: Array) -> void: batches.append(changes)
	db.items_changed.connect(note_batch)
	var moved: Dictionary = send.call("docket/panel/transition_item", move.merged({"changes": {"title": "Moved here"},
		"expected_item_token": str(created.item_token), "operation_id": "op-move"}))
	db.items_changed.disconnect(note_batch)
	var reader := DocketDBJsonl.open_jsonl(db.get_path())
	var seen := reader.get_item(id)
	reader.close()
	var events := db.get_events(id).map(func(e: Dictionary) -> Array: return [e.event_type, e.actor])
	var answer: Dictionary = moved.get("result", {})
	return A.is_true(not target.is_empty() and answer.get("status") == target and answer.get("operation_id") == "op-move"
		and answer.get("item_token") == handler._registry.get_type_registry("panel").item_token(id) and batches.size() == 1
		and seen.get("status") == target and seen.get("title") == "Moved here"
		and events == [["created", "human:imran"], ["transition", "human:imran"]],
		"the move and the edit are one committed change, the person's, seen whole by another client: %s %s %s %s"
		% [moved, batches, seen, events])


func _panel_attach_checks(handler: McpHandler, db: DocketDB, secret: String, item: String, other: String) -> Variant:
	var send := func(method: String, params: Dictionary) -> Dictionary:
		return handler.handle({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	var grant := str(send.call("docket/panel/register", {"panel_secret": secret, "panel": "panel-1", "person": "imran",
		"project": "panel", "item": item, "actions": ["attach_file"]}).get("result", {}).get("panel_grant", ""))
	var attached := func(id: String) -> Array:
		return db.get_events(id).filter(func(e: Dictionary) -> bool: return e.event_type == "attached") \
			.map(func(e: Dictionary) -> String: return str(e.actor))
	var state := func() -> Array:
		return [db.list_attachments(item).size(), db.get_events(item).size(), db.list_attachments(other).size(), db.get_events(other).size()]
	var before: Array = state.call()
	var file := PackedByteArray()
	for i in 70000:
		file.append((i * 7919) % 256)  # binary, every byte value, across base64 padding boundaries
	var attach := {"panel_grant": grant, "project": "panel", "id": item, "filename": " scan 1.bin ",
		"mime_type": "application/octet-stream", "description": "a scan"}
	var over_encoded := PackedByteArray()
	over_encoded.resize(DocketDB.MAX_ATTACHMENT_BYTES + 3)  # its base64 is longer than the largest allowed
	var over_decoded := PackedByteArray()
	over_decoded.resize(DocketDB.MAX_ATTACHMENT_BYTES + 1)  # its base64 is not, the bytes are
	var refused := {
		"a file whose base64 is too long": send.call("docket/panel/attach_file", attach.merged({"data": Marshalls.raw_to_base64(over_encoded)}, true)),
		"a file one byte too large": send.call("docket/panel/attach_file", attach.merged({"data": Marshalls.raw_to_base64(over_decoded)}, true)),
		"data that is not base64": send.call("docket/panel/attach_file", attach.merged({"data": "not base64!"}, true)),
		"another item": send.call("docket/panel/attach_file", attach.merged({"id": other, "data": Marshalls.raw_to_base64(file)}, true)),
		"no grant": send.call("docket/panel/attach_file", attach.merged({"panel_grant": "", "data": Marshalls.raw_to_base64(file)}, true)),
	}
	for why in refused:
		var r = A.is_true(refused[why].has("error") and state.call() == before, "attaching %s changes nothing: %s" % [why, str(refused[why]).left(300)])
		if r is String: return r

	var batches: Array = []
	var note_batch := func(changes: Array) -> void: batches.append(changes)
	db.items_changed.connect(note_batch)
	var answer: Dictionary = send.call("docket/panel/attach_file", attach.merged({"data": Marshalls.raw_to_base64(file),
		"operation_id": "op-attach"}, true)).get("result", {})
	db.items_changed.disconnect(note_batch)
	var reader := DocketDBJsonl.open_jsonl(db.get_path())
	var seen: Array = reader.list_attachments(item)
	var bytes: PackedByteArray = reader.get_attachment(int(seen[0].id)).get("data", PackedByteArray()) if seen.size() == 1 else PackedByteArray()
	var kept: Array = reader.get_events(item).filter(func(e: Dictionary) -> bool: return e.event_type == "attached") \
		.map(func(e: Dictionary) -> String: return str(e.actor))
	reader.close()
	var r = A.is_true(answer.get("size_bytes") == file.size() and answer.get("filename") == " scan 1.bin "
		and answer.get("operation_id") == "op-attach"
		and answer.get("item_token") == handler._registry.get_type_registry("panel").item_token(item)
		and batches.size() == 1 and attached.call(item) == ["human:imran"]
		and seen.size() == 1 and seen[0].filename == " scan 1.bin " and seen[0].mime_type == "application/octet-stream"
		and seen[0].description == "a scan" and bytes == file and kept == ["human:imran"],
		"the file, its record and one event of the person's are one committed change, seen exactly by another client: %s %s %s"
		% [str(answer).left(300), batches, attached.call(item)])
	if r is String: return r
	var by_tool: Dictionary = send.call("tools/call", {"name": "docket_attach", "arguments": {"item_id": other,
		"filename": "log.txt", "data": Marshalls.raw_to_base64("log".to_utf8_buffer()), "project": "panel"}})
	return A.is_true(not by_tool.get("result", {}).get("isError", false) and attached.call(other) == ["agent"],
		"the same attach as a tool is the agent's, with one event: %s %s" % [by_tool, attached.call(other)])


## Two files with one stored name and the same item IDs (a project and its
## copy) open side by side in a host-managed server, through its own add and
## remove: the first stays "work" (adding its path again answers it, opened
## once), the copy is "work~2", and each selector reads and writes only its
## own file; a name matching both, case aside, is refused. A reference from
## another project to their shared stored name, or to a selector, is refused
## unwritten, while the copy's reference to its own name is its own. A panel
## grant for "work" outlives the copy's closing, but not a close and reopen
## of "work".
func test_copies_of_a_project_open_side_by_side() -> Variant:
	var dir := OS.get_cache_dir().path_join("docket_copies_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var original := dir.path_join("a.dct")
	var copy := dir.path_join("b.dct")
	var other := dir.path_join("c.dct")
	# A project whose stored name is literally the copy's selector.
	var lookalike := dir.path_join("d.dct")
	var lookalike_db := DocketDBJsonl.create_new_jsonl(lookalike)
	lookalike_db.set_project_name("work~2")
	var lookalike_tools := ToolRegistry.new()
	lookalike_tools.init(TypeRegistryBootstrap.load_shipped_schema(), lookalike_db, {"work~2": lookalike_db})
	lookalike_tools.call_tool("docket_create", {"type": "bug", "title": "Lookalike"})
	lookalike_db.close()
	var seeded := DocketDBJsonl.create_new_jsonl(original)
	seeded.set_project_name("work")
	var seeding := ToolRegistry.new()
	seeding.init(TypeRegistryBootstrap.load_shipped_schema(), seeded, {"work": seeded})
	var item := str(seeding.call_tool("docket_create", {"type": "bug", "title": "Original"}).get("id", ""))
	seeded.close()
	DirAccess.copy_absolute(original, copy)
	var other_db := DocketDBJsonl.create_new_jsonl(other)
	other_db.set_project_name("other")
	other_db.close()
	var secret := Crypto.new().generate_random_bytes(32).hex_encode()
	OS.set_environment(McpHandler.PanelAuthority.SECRET_VARIABLE, secret)
	# The server's own project handling, without its transport.
	var server := DocketHttpServer.new()
	server.host_managed = true
	server._schema = TypeRegistryBootstrap.load_shipped_schema()
	server._registry = ToolRegistry.new()
	server._registry.init(server._schema, null, server._project_dbs)
	server._registry.allow_no_project = true
	server._registry.add_project_fn = server._headless_add_project
	server._registry.remove_project_fn = server._headless_remove_project
	server._handler = McpHandler.new()
	server._handler.init_with_registry(server._registry)
	server._handler.panel_authority = McpHandler.PanelAuthority.from_environment(server._registry)
	var result: Variant = _copies_checks(server._handler, server._project_dbs, secret, item, original, copy, other, lookalike)
	for open_db: DocketDB in server._project_dbs.values():
		open_db.close()
	server.free()
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
	return result


# Other spellings of the existing file `original`, at least one, each checked
# to name it before it is used: a symbolic link to it (required except on
# Windows, where creating one needs a privilege), and its name in another case
# when its directory ignores case (as Windows directories do by default).
# Which were used, and which not, is printed; a required spelling that could
# not be made fails the test, never passes it.
func _aliases_of(original: String) -> Variant:
	var dir := original.get_base_dir()
	var identity: String = str(ProjectFile.locate(original).get("id", ""))
	var aliases: Array = []
	var used: Array = []
	var linked := dir.path_join("linked.dct")
	var linking := DirAccess.open(dir).create_link(original, linked)
	if linking == OK:
		aliases.append(linked); used.append("symbolic link")
	elif OS.get_name() != "Windows":
		return "setup failed: could not create a symbolic link (error %d)" % linking
	else:
		print("alias: symbolic link not exercised, creating one failed (error %d)" % linking)
	var other_case := dir.path_join(original.get_file().to_upper())
	if FileAccess.file_exists(other_case):
		aliases.append(other_case); used.append("letter case")
	else:
		print("alias: letter case not exercised, %s tells case apart" % dir)
	if aliases.is_empty():
		return "setup failed: %s neither ignores case nor allows a symbolic link, so no alias can be made here" % dir
	for alias in aliases:
		if identity.is_empty() or str(ProjectFile.locate(alias).get("id", "")) != identity:
			return "setup failed: %s is not identified as %s" % [alias, original]
	print("alias mechanisms exercised: %s" % ", ".join(PackedStringArray(used)))
	return aliases


func _copies_checks(handler: McpHandler, dbs: Dictionary, secret: String, item: String, original: String, copy: String, other: String, lookalike: String) -> Variant:
	# A tool's answer; when it refused, its error: whole (with its kind) as the
	# reply's _meta carries it, else {error} (its text); a JSON-RPC error as
	# {error, protocol}.
	var tool := func(name: String, arguments: Dictionary) -> Dictionary:
		var reply: Dictionary = handler.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}})
		if reply.has("error"):
			return {"error": str(reply.error.get("message", reply.error)), "protocol": true}
		var text := str(reply.result.get("content", [{}])[0].get("text", ""))
		if bool(reply.result.get("isError", false)):
			var whole = reply.result.get("_meta", {}).get(McpHandler.ERROR_RESULT_META)
			return whole if whole is Dictionary else {"error": text}
		var parsed = JSON.parse_string(text)
		return parsed if parsed is Dictionary else {"error": "unreadable: %s" % text}
	var panel := func(method: String, params: Dictionary) -> Dictionary:
		var reply: Dictionary = handler.handle({"jsonrpc": "2.0", "id": 1, "method": "docket/panel/" + method, "params": params})
		return reply.result if reply.has("result") else {"error": str(reply.get("error", {}).get("message", ""))}
	var first: Dictionary = tool.call("docket_project_add", {"path": original})
	var again: Dictionary = tool.call("docket_project_add", {"path": original})
	var aliases = _aliases_of(original)
	if aliases is String: return aliases
	var through_aliases: Array = aliases.map(func(alias: String) -> Dictionary: return tool.call("docket_project_add", {"path": alias}))
	var second: Dictionary = tool.call("docket_project_add", {"path": copy})
	tool.call("docket_project_add", {"path": other})
	var listed: Array = tool.call("docket_project_list", {}).get("projects", []).map(func(p: Dictionary) -> String: return str(p.name))
	listed.sort()
	var r = A.eq([first.get("name"), again.get("already_open"), again.get("open_generation") == first.get("open_generation"),
		through_aliases.all(func(added: Dictionary) -> bool: return added.get("already_open") == true and added.get("open_generation") == first.get("open_generation")),
		second.get("name"), second.get("display_name"), second.get("path") != first.get("path"), listed],
		["work", true, true, true, "work~2", "work", true, ["other", "work", "work~2"]],
		"the copy opens beside its original under a name of its own; adding the original again, or by another spelling, answers it: %s %s %s %s" % [first, again, through_aliases, second])
	if r is String: return r

	var edited: Dictionary = tool.call("docket_update", {"id": item, "title": "Copy edit", "project": "work~2"})
	var titles := [str(tool.call("docket_get", {"id": item, "project": "work"}).get("title", "")),
		str(tool.call("docket_get", {"id": item, "project": "work~2"}).get("title", ""))]
	var ambiguous: Dictionary = tool.call("docket_get", {"id": item, "project": "WORK"})
	r = A.is_true(not edited.has("error") and titles == ["Original", "Copy edit"] and str(ambiguous.get("error", "")).contains("ambiguous"),
		"each selector reads and writes its own file, and a name matching both is refused: %s %s %s" % [edited, titles, ambiguous])
	if r is String: return r

	var to_both: Dictionary = tool.call("docket_create", {"type": "bug", "title": "Ambiguous", "parent": "work:" + item, "project": "other"})
	var to_selector: Dictionary = tool.call("docket_create", {"type": "bug", "title": "Selector", "parent": "work~2:" + item, "project": "other"})
	var own: Dictionary = tool.call("docket_create", {"type": "bug", "title": "Own", "parent": "work:" + item, "project": "work~2"})
	var in_other := int(tool.call("docket_query", {"project": "other"}).get("count", -1))
	r = A.is_true(to_both.has("error") and to_selector.has("error") and not own.has("error") and in_other == 0,
		"references to the shared stored name, or to a selector, are refused unwritten; the copy's to itself is written: %s %s %s" % [to_both, to_selector, own])
	if r is String: return r
	# Read back as the owner reads children: the copy's "work:<id>" parent is
	# the copy's own item, not the original's.
	var state := AppState.new()
	state._project_dbs = dbs
	var children_of := func(project: String) -> Array:
		return state.find_children_across_projects("%s:%s" % [project, item]).map(func(child: Dictionary) -> Array: return [child.project, child.title])
	r = A.eq([children_of.call("work~2"), children_of.call("work")], [[["work~2", "Own"]], []],
		"the copy's reference to its own stored name is a child in the copy only")
	if r is String: return r

	# Queries: `project` means a stored name, so "work" matches both copies and
	# "work~2" the project stored under that name; project_selector means this
	# session's selectors exactly. A query naming a selector cannot be saved.
	var looked: Dictionary = tool.call("docket_project_add", {"path": lookalike})
	var projects_of := func(filter: Dictionary) -> Variant:
		var viewed: Dictionary = tool.call("docket_query_view", {"filter": filter})
		if viewed.has("error"): return viewed.error
		var names: Array = viewed.get("rows", []).map(func(row: Dictionary) -> String: return str(row.project))
		names.sort()
		return names
	var by_name := {"field": "project", "op": "eq", "value": "work~2"}
	var by_selector := {"field": "project_selector", "op": "eq", "value": "work~2"}
	var queried := [projects_of.call({"conditions": [by_name]}), projects_of.call({"conditions": [by_selector]}), projects_of.call(by_selector),
		projects_of.call({"conditions": [{"field": "project", "op": "eq", "value": "work"}]}),
		projects_of.call({"$and": [{"field": "project", "op": "eq", "value": "work"}, {"field": "project_selector", "op": "neq", "value": "work"}]}),
		projects_of.call({"conditions": [{"field": "project_selector", "op": "in", "value": ["work", "work~2~2"]}]}),
		str(projects_of.call({"conditions": [{"field": "project_selector", "op": "eq", "value": "nowhere"}]})).contains("Unknown project_selector")]
	var saved_selector: Dictionary = tool.call("docket_saved_query", {"action": "save", "name": "by selector", "project": "other",
		"filter": {"conditions": [by_selector]}})
	var saved_name: Dictionary = tool.call("docket_saved_query", {"action": "save", "name": "by name", "project": "other",
		"filter": {"conditions": [by_name]}})
	var loaded: Dictionary = tool.call("docket_saved_query", {"action": "load", "name": "by name", "project": "other"})
	r = A.eq([looked.get("name"), queried, saved_selector.has("error"), saved_name.get("saved"), loaded.get("filter")],
		["work~2~2", [["work~2~2"], ["work~2", "work~2"], ["work~2", "work~2"], ["work", "work~2", "work~2"], ["work~2", "work~2"], ["work", "work~2~2"], true],
			true, "by name", {"conditions": [by_name]}],
		"a stored name and a selector select different projects even when their text is the same; only the name is saved: %s %s %s %s" % [
			queried, saved_selector, saved_name, loaded])
	if r is String: return r
	# A type and status chosen from the copy's catalog (the grid's compiler)
	# select the copy's rows only, and such an exact choice is not saved.
	var bug: Dictionary = tool.call("docket_get", {"id": item, "project": "work~2"})
	var copy_bug := TypeCatalog.identity("work~2", str(bug.get("type_id", "")))
	var catalog: Array = [{"id": str(bug.get("type_id", "")), "key": copy_bug, "slug": "bug", "project": "work~2"}]
	var chosen: Dictionary = QueryTypeScope.compile_catalog_conditions([{"field": "status", "op": "catalog_status",
		"value": {"key": copy_bug, "status": str(bug.get("status", ""))}}], catalog)
	var saved_choice: Dictionary = tool.call("docket_saved_query", {"action": "save", "name": "chosen", "project": "work~2", "filter": chosen})
	r = A.is_true(not str(bug.get("type_id", "")).is_empty() and projects_of.call(chosen) == ["work~2", "work~2"] and saved_choice.has("error"),
		"a catalog choice from the copy selects only the copy, and is not saved: %s %s" % [projects_of.call(chosen), saved_choice])
	if r is String: return r
	tool.call("docket_project_remove", {"name": "work~2~2"})

	var grant := str(panel.call("register", {"panel_secret": secret, "panel": "p1", "person": "imran", "project": "work", "item": item,
		"actions": ["update_item"], "open_generation": first.get("open_generation")}).get("panel_grant", ""))
	var save := func(title: String) -> Dictionary:
		return panel.call("update_item", {"panel_grant": grant, "project": "work", "id": item, "changes": {"title": title}})
	var before_close: Dictionary = save.call("Person edit")
	# Saving replaced the original's file; its other spellings still reach it.
	var after_save: Array = aliases.map(func(alias: String) -> Dictionary: return tool.call("docket_project_add", {"path": alias}))
	var closed: Dictionary = tool.call("docket_project_remove", {"name": "work~2"})
	var after_close: Dictionary = save.call("Person again")
	tool.call("docket_project_remove", {"name": "work"})
	var reopened: Dictionary = tool.call("docket_project_add", {"path": original})
	var after_reopen: Dictionary = save.call("After reopening")
	r = A.is_true(not before_close.has("error") and closed.has("closed") and not after_close.has("error")
		and after_save.all(func(added: Dictionary) -> bool: return added.get("already_open") == true and added.get("open_generation") == first.get("open_generation"))
		and reopened.get("name") == "work" and reopened.get("open_generation") != first.get("open_generation") and after_reopen.has("error"),
		"the grant outlives the copy's closing, not the original's reopening: %s %s %s %s %s" % [before_close, after_save, after_close, reopened, after_reopen])
	if r is String: return r

	# Reading "other" again when its file changes: a read overtaken by an
	# edit in place, or a failed rebuild, keeps the cache as it was and refuses
	# reads until the file is read whole; a failed save over a file another
	# writer replaced keeps the change here, unsaved, and the replacement as
	# it is.
	var other_db: DocketDBJsonl = dbs["other"]
	var other_item := str(tool.call("docket_create", {"type": "bug", "title": "First", "project": "other"}).get("id", ""))
	var rewrite := func(from: String, to: String) -> void:
		var text := FileAccess.get_file_as_string(other)
		var file := FileAccess.open(other, FileAccess.WRITE)
		file.store_string(text.replace(from, to))
		file.close()
	var title_of := func() -> String: return str(tool.call("docket_get", {"id": other_item, "project": "other"}).get("title", ""))
	var other_events: Array = []
	var note_events := func(changes: Array) -> void: other_events.append_array(changes)
	other_db.items_changed.connect(note_events)
	rewrite.call("First", "Second")
	JSONLCache.rebuild_failure_hook = func() -> String:
		rewrite.call("Second", "Third")
		return ""
	var overtaken: Dictionary = tool.call("docket_get", {"id": other_item, "project": "other"})
	JSONLCache.rebuild_failure_hook = Callable()
	var after_overtaken := [other_db.get_item(other_item).get("title"), other_events.size(), title_of.call()]
	rewrite.call("Third", "Fourth")
	JSONLCache.rebuild_failure_hook = func() -> String: return "injected rebuild failure"
	var failed_rebuild: Dictionary = tool.call("docket_query", {"project": "work"})
	JSONLCache.rebuild_failure_hook = Callable()
	var after_failed := [other_db.get_item(other_item).get("title"), title_of.call()]
	var replacement := other + ".replacement"
	other_db._atomic_write_hook = func(_path: String, _text: String, _staged: Dictionary) -> String:
		DirAccess.copy_absolute(other, replacement)
		DirAccess.rename_absolute(replacement, other)
		return "injected write failure"
	var before_unsaved := FileAccess.get_file_as_string(other)
	var unsaved: Dictionary = tool.call("docket_update", {"id": other_item, "title": "Unsaved", "project": "other"})
	other_db._atomic_write_hook = Callable()
	var refused_read: Dictionary = tool.call("docket_query", {"project": "work"})
	# As a client sees it: an error result with its text, and its kind in _meta.
	var envelope: Dictionary = handler.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
		"params": {"name": "docket_query", "arguments": {"project": "work"}}}).get("result", {})
	var raw_refusal := [envelope.get("isError"), not str(envelope.get("content", [{}])[0].get("text", "")).is_empty(),
		envelope.get("_meta", {}).get(McpHandler.ERROR_RESULT_META, {}).get("kind")]
	# The person's own reads refuse at once too, before any poll, and say why.
	var local := LocalDocketSource.new(state)
	var told: Array = []
	local.unavailable.connect(func(failure: Dictionary) -> void: told.append(failure.kind))
	var local_reads := [str(local.item_title("other", other_item).get("kind", "")), local.item_events("other", other_item),
		str(local.children_of("other:" + other_item).get("kind", "")), told]
	var kept := [other_db.get_item(other_item).get("title"), FileAccess.get_file_as_string(other) == before_unsaved]
	other_db.items_changed.disconnect(note_events)
	tool.call("docket_project_remove", {"name": "other"})
	r = A.is_true(str(overtaken.get("kind", "")) == "stale" and after_overtaken == ["First", 0, "Third"]
		and str(failed_rebuild.get("kind", "")) == "stale" and after_failed == ["Third", "Fourth"]
		and str(unsaved.get("error", "")).contains("kept here") and str(refused_read.get("kind", "")) == "unsaved" and kept == ["Unsaved", true]
		and local_reads[0] == "unsaved" and local.refusal(local_reads[1]).contains("not ready") and local_reads[2] == "unsaved"
		and local_reads[3] == ["unsaved", "unsaved", "unsaved"] and raw_refusal == [true, true, "unsaved"],
		"an overtaken or failed read refuses and keeps the cache; a failed save over a replacement keeps the change unsaved: %s %s %s %s %s %s %s %s %s" % [
			overtaken, after_overtaken, failed_rebuild, after_failed, unsaved, refused_read, kept, local_reads, raw_refusal])
	if r is String: return r

	# A SQLite project with another file put in its place stays on the file it
	# opened, so tools, the panel and the person's own reads are all refused
	# until it is opened again.
	var legacy := original.get_base_dir().path_join("legacy.dct")
	var legacy_db := DocketDB.create_new(legacy)
	legacy_db.set_project_name("legacy")
	legacy_db.close()
	tool.call("docket_project_add", {"path": legacy})
	var swapped := legacy + ".swap"
	if OS.get_name() == "Windows":
		# Windows keeps an open file in its place, so this cannot happen there.
		print("replacement: SQLite file replacement not exercised on Windows")
		tool.call("docket_project_remove", {"name": "legacy"})
	elif DirAccess.copy_absolute(legacy, swapped) != OK or DirAccess.rename_absolute(swapped, legacy) != OK:
		DirAccess.remove_absolute(swapped)
		return "setup failed: could not put another file in place of %s" % legacy
	if OS.get_name() != "Windows":
		var by_tool: Dictionary = tool.call("docket_query", {"project": "work"})
		var by_panel: Dictionary = panel.call("register", {"panel_secret": secret, "panel": "p2", "person": "imran", "project": "work",
			"item": item, "actions": ["update_item"]})
		var by_person: Dictionary = LocalDocketSource.new(state).item_title("work", item)
		tool.call("docket_project_remove", {"name": "legacy"})
		r = A.is_true(str(by_tool.get("kind", "")) == "reopen_required" and str(by_panel.get("error", "")).contains("'legacy' is not ready")
			and str(by_person.get("kind", "")) == "reopen_required", "a replaced SQLite file is refused everywhere: %s %s %s" % [by_tool, by_panel, by_person])
		if r is String: return r

	# Another writer's save (the same bytes in another file renamed over the
	# open original) is read as the project, reported as a reload, and the
	# next change is written into it. A link put in its place is never
	# written through.
	var events: Array = []
	var record := func(changes: Array) -> void: events.append_array(changes)
	(dbs["work"] as DocketDB).items_changed.connect(record)
	var outside := original.get_base_dir().path_join("outside.tmp")
	if DirAccess.copy_absolute(original, outside) != OK or DirAccess.rename_absolute(outside, original) != OK:
		DirAccess.remove_absolute(outside)
		return "setup failed: could not save the same bytes over %s from outside" % original
	var over_save: Dictionary = tool.call("docket_update", {"id": item, "title": "After an outside save", "project": "work"})
	(dbs["work"] as DocketDB).items_changed.disconnect(record)
	var held := original.get_base_dir().path_join("held.dct")
	if DirAccess.rename_absolute(original, held) != OK:
		return "setup failed: could not move %s aside" % original
	var substituted := DirAccess.open(original.get_base_dir()).create_link(held, original)
	var through_link := {}
	if substituted == OK:
		through_link = tool.call("docket_update", {"id": item, "title": "Through a link", "project": "work"})
		DirAccess.remove_absolute(original)
	else:
		print("replacement: link substitution not exercised, creating one failed (error %d)" % substituted)
	var restored := DirAccess.rename_absolute(held, original)
	if substituted != OK and OS.get_name() != "Windows":
		return "setup failed: could not put a symbolic link in place of %s (error %d)" % [original, substituted]
	r = A.is_true(restored == OK and not over_save.has("error") and events.has({"id": "", "event": "reloaded"})
		and (substituted != OK or str(through_link.get("error", "")).contains("external replacement")),
		"an outside save is read as the project and reported, a link in the file's place refused: %s %s %s" % [over_save, events, through_link])
	if r is String: return r

	var reader_a := DocketDBJsonl.open_jsonl(original)
	var reader_b := DocketDBJsonl.open_jsonl(copy)
	var files := [str(reader_a.get_item(item).get("title", "")), str(reader_b.get_item(item).get("title", "")),
		reader_b.execute_query({"filter": {"parent": "work:" + item}}).size()]
	reader_a.close()
	reader_b.close()
	return A.eq(files, ["After an outside save", "Copy edit", 1], "each file holds only its own changes")


func _panel_channel_checks(handler: McpHandler, db: DocketDB, secret: String, item: String, other: String) -> Variant:
	var r = A.is_true(handler.panel_authority != null
		and OS.get_environment(McpHandler.PanelAuthority.SECRET_VARIABLE).is_empty(),
		"the secret is taken from the environment and removed from it")
	if r is String: return r
	var send := func(method: String, params: Dictionary) -> Dictionary:
		return handler.handle({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	var registered: Dictionary = send.call("docket/panel/register", {"panel_secret": secret, "panel": "panel-1",
		"person": "imran", "project": "panel", "item": item, "actions": ["update_item"]})
	var grant := str(registered.get("result", {}).get("panel_grant", ""))
	r = A.eq(grant.length(), 64, "the host gets a 256-bit grant: %s" % [registered])
	if r is String: return r
	var typed_updates := func() -> Array:
		return db.get_events(item).filter(func(event: Dictionary) -> bool: return event.event_type == "typed_update") \
			.map(func(event: Dictionary) -> String: return str(event.actor))
	var state := func() -> Array:
		return [db.get_item(item).title, db.get_events(item).size(), db.get_item(other).title, db.get_events(other).size()]

	var before: Array = state.call()
	var edit := {"project": "panel", "id": item, "changes": {"title": "Denied"}}
	var denials := {
		"no grant": send.call("docket/panel/update_item", edit),
		"a guessed grant": send.call("docket/panel/update_item", edit.merged({"panel_grant": "0".repeat(64)})),
		"another item": send.call("docket/panel/update_item", edit.merged({"panel_grant": grant, "id": other}, true)),
		"another project": send.call("docket/panel/update_item", edit.merged({"panel_grant": grant, "project": "elsewhere"}, true)),
		"registering without the secret": send.call("docket/panel/register", {"panel_secret": "guess", "panel": "panel-2",
			"person": "imran", "project": "panel", "item": item, "actions": ["update_item"]}),
		"the private method as a tool": send.call("tools/call", {"name": "docket/panel/update_item",
			"arguments": edit.merged({"panel_grant": grant})}),
		"a reserved argument on a tool": send.call("tools/call", {"name": "docket_update",
			"arguments": {"id": item, "title": "Denied", "project": "panel", "panel_grant": grant}}),
	}
	for why in denials:
		r = A.is_true(denials[why].has("error"), "%s is refused: %s" % [why, denials[why]])
		if r is String: return r
	r = A.eq(state.call(), before, "no refused request changed an item or its events")
	if r is String: return r

	var saved: Dictionary = send.call("docket/panel/update_item", {"panel_grant": grant, "project": "panel", "id": item,
		"changes": {"title": "By the person"}, "actor": "agent", "person": "someone else", "_meta": {"actor": "forged"}})
	r = A.is_true(saved.has("result") and db.get_item(item).title == "By the person" and typed_updates.call() == ["human:imran"],
		"the granted edit is the person's, once, whatever the request claims: %s %s" % [saved, typed_updates.call()])
	if r is String: return r
	var by_tool: Dictionary = send.call("tools/call", {"name": "docket_update", "arguments": {"id": item, "title": "By an agent", "project": "panel"}})
	r = A.eq([by_tool.get("result", {}).get("isError", false), typed_updates.call()], [false, ["human:imran", "agent"]],
		"the same edit as a tool stays an agent's: %s" % [by_tool])
	if r is String: return r

	var revoked: Dictionary = send.call("docket/panel/revoke", {"panel_secret": secret, "panel": "panel-1"})
	before = state.call()
	var after_revoke: Dictionary = send.call("docket/panel/update_item", edit.merged({"panel_grant": grant}))
	return A.is_true(revoked.get("result", {}).get("revoked", 0) == 1 and after_revoke.has("error") and state.call() == before,
		"a grant revoked with its panel edits nothing: %s %s" % [revoked, after_revoke])
