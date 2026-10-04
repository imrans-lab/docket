extends RefCounted
class_name McpHandler
## JSON-RPC 2.0 router for MCP Streamable HTTP protocol.

const PROTOCOL_VERSION := "2025-03-26"

var _registry: ToolRegistry
var host_authority: DocketHostAuthority


func init_with_registry(registry: ToolRegistry) -> void:
	_registry = registry


func handle(request: Dictionary) -> Variant:
	var method: String = request.get("method", "")
	var id = request.get("id")
	if id is float:
		id = int(id)
	if method.begins_with(DocketHostAuthority.PREFIX):
		if host_authority == null:
			return _make_error(id, -32601, "Private method unavailable")
		var reply := host_authority.handle(method, request.get("params", {}))
		reply.merge({"jsonrpc": "2.0", "id": id})
		return reply
	var params: Dictionary = request.get("params", {})

	match method:
		"initialize":
			return _make_result(id, {
				"protocolVersion": PROTOCOL_VERSION,
				"capabilities": {
					"tools": {"listChanged": false},
				},
				"serverInfo": {
					"name": "docket",
					"version": BuildInfo.identity(),
				},
			})
		"notifications/initialized":
			return null  # Notification — no response
		"ping":
			return _make_result(id, {})
		"tools/list":
			return _make_result(id, {"tools": _registry.list_tools()})
		"tools/call":
			return _handle_tool_call(id, params)
		_:
			return _make_error(id, -32601, "Method not found: %s" % method)


func _handle_tool_call(id: Variant, params: Dictionary) -> Dictionary:
	var tool_name: String = params.get("name", "")
	var arguments: Dictionary = params.get("arguments", {})

	if not _registry.has_tool(tool_name):
		return _make_error(id, -32602, "Unknown tool: %s" % tool_name)

	var result = _registry.call_tool(tool_name, arguments)

	if result.has("error"):
		return _make_result(id, {
			"content": [{"type": "text", "text": result.error}],
			"isError": true,
		})

	return _make_result(id, {
		"content": [{"type": "text", "text": JSON.stringify(result)}],
	})


func _make_result(id: Variant, result: Variant) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


func _make_error(id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
