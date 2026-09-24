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
	var result: Variant = _panel_channel_checks(handler, db, secret, item, other)
	db.close()
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
	return result


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
