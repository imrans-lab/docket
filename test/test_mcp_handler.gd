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
