extends Node

var A := AssertHelpers
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
