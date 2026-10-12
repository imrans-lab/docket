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


func test_public_schema_and_bootstrap_contracts() -> Variant:
	var saved_schema := TypeRegistryBootstrap._declared_schema.duplicate(true)
	var saved_version := TypeRegistryBootstrap._declared_version
	TypeRegistryBootstrap._declared_schema = {}
	TypeRegistryBootstrap._declared_version = ""
	var registry := ToolRegistry.new()
	registry.init(TypeRegistryBootstrap.load_shipped_schema(), null)
	var handler := McpHandler.new()
	handler.init_with_registry(registry)
	var schema := TypeRegistryBootstrap.load_shipped_schema()
	var arguments: Dictionary = JSON.parse_string(JSON.stringify({"schema":schema, "version":"public-test"}))
	var first := registry.call_tool("docket_schema_declare", arguments)
	var retry := registry.call_tool("docket_schema_declare", arguments)
	arguments.version = ""
	var refused: Dictionary = handler.handle({"id":1, "method":"tools/call", "params":{"name":"docket_schema_declare", "arguments":arguments}})
	var bootstrap: Dictionary = handler.handle({"id":2, "method":"tools/call", "params":{"name":"docket_project_bootstrap", "arguments":{"path":"relative.dct", "content":"YQ=="}}})
	TypeRegistryBootstrap._declared_schema = saved_schema
	TypeRegistryBootstrap._declared_version = saved_version
	if first != {"version":"public-test", "idempotent":false, "projects":[]} or retry != {"version":"public-test", "idempotent":true, "projects":[]}: return "Public declaration contract changed"
	if not refused.result.get("isError", false) or not refused.result.content[0].text is String: return "Declaration refusal is not MCP text"
	if not bootstrap.result.get("isError", false) or not bootstrap.result.content[0].text is String: return "Bootstrap refusal is not MCP text"
	if JSON.parse_string(bootstrap.result.content[0].text).code != -32602: return "Bootstrap error detail lost"
	return true
