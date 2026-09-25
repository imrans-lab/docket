extends RefCounted
class_name McpHandler
## JSON-RPC 2.0 router for MCP Streamable HTTP protocol.

const PROTOCOL_VERSION := "2025-03-26"
## The _meta key under which a failed tools/call keeps the tool's whole
## error result.
const ERROR_RESULT_META := "docket/result"
const PanelAuthority := preload("res://scripts/mcp/panel_authority.gd")

var _registry: ToolRegistry
## The private channel for a host's panel (PanelAuthority), when this
## process has one; without it the panel methods do not exist.
var panel_authority = null
## The events this process sends its host are numbered (DocketHttpServer
## counts them in event_sequence) on one stream, named `stream_id` (new each
## run): a reply to a panel's change says how many had been sent by then.
var event_sequence := 0
var stream_id := Crypto.new().generate_random_bytes(8).hex_encode()

## The longest operation id kept (characters); a longer one is dropped.
const MAX_OPERATION_ID := 128


func init_with_registry(registry: ToolRegistry) -> void:
	_registry = registry


# A panel call the host authenticated (a panel session, or a grant) runs
# within a coordination operation opened here and given its provenance:
# {origin: "panel:<panel>", operation_id} (the caller's label, for correlation
# only), which every change made within that operation, in any project,
# carries (DocketDBConnection.with_provenance). Its reply names the operation
# and the event stream's position (stream, event_watermark). `work` is called
# with that operation; anything else runs without one.
func _as_panel(panel: String, params: Dictionary, work: Callable) -> Dictionary:
	var lease := CoordLease.shared()
	if lease.has("error"):
		return {"error": {"code": -32000, "message": str(lease.error)}}
	var operation_id = params.get("operation_id")
	var provenance := {"origin": "panel:%s" % panel,
		"operation_id": str(operation_id) if operation_id is String and str(operation_id).length() <= MAX_OPERATION_ID else ""}
	var answered: Dictionary = DocketDBConnection.with_provenance(lease.operation, provenance, work)
	lease.operation.close()
	if answered.get("result") is Dictionary:
		answered.result["operation_id"] = provenance.operation_id
		answered.result["stream"] = stream_id
		answered.result["event_watermark"] = event_sequence
	return answered


## The reply to `request` (null for notifications/initialized).
func handle(request: Dictionary) -> Variant:
	var method: String = request.get("method", "")
	var id = request.get("id")
	if id is float:
		id = int(id)
	var params: Dictionary = request.get("params", {}) if request.get("params", {}) is Dictionary else {}

	match method:
		"initialize":
			return _make_result(id, {
				"protocolVersion": PROTOCOL_VERSION,
				"capabilities": {
					"tools": {"listChanged": false},
				},
				"serverInfo": {
					"name": "docket",
					"version": "1.0.0",
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
	if method == PanelAuthority.PREFIX + "call" and panel_authority != null:
		return _handle_panel_tool_call(id, params)
	if panel_authority != null and method.begins_with(PanelAuthority.PREFIX) \
			and method.trim_prefix(PanelAuthority.PREFIX) in PanelAuthority.ACTIONS:
		var granted: String = panel_authority.panel_of("", str(params.get("panel_grant", "")))
		var edited: Dictionary = _as_panel(granted, params, func(operation: RefCounted) -> Dictionary:
			return panel_authority.handle(method, params, operation)) if not granted.is_empty() \
			else panel_authority.handle(method, params)
		if edited.has("error"):
			return _make_error(id, edited.error.code, edited.error.message)
		return _make_result(id, edited.result)
	if method.begins_with(PanelAuthority.PREFIX) and panel_authority != null:
		var answered: Dictionary = panel_authority.handle(method, params)
		if answered.has("error"):
			return _make_error(id, answered.error.code, answered.error.message)
		return _make_result(id, answered.result)
	return _make_error(id, -32601, "Method not found: %s" % method)


# docket/panel/call {panel_session, name, arguments, operation_id}: a tool as
# the panel the host opened the session for, answered as a tools/call would
# be. The changes of a tool that works within its caller's operation
# (ToolRegistry._WITHIN_OPERATION) are that panel's (see _as_panel); any other
# tool opens its own, so its changes name no origin and the panel takes them
# as someone else's (at worst, one question too many).
func _handle_panel_tool_call(id: Variant, params: Dictionary) -> Dictionary:
	var panel: String = panel_authority.panel_of(str(params.get("panel_session", "")), "")
	if panel.is_empty():
		return _make_error(id, -32001, "no such panel session")
	var tool_params := {"name": params.get("name", ""), "arguments": params.get("arguments", {})}
	var answered: Dictionary = _as_panel(panel, params, func(operation: RefCounted) -> Dictionary:
		return _handle_tool_call(id, tool_params, operation))
	return answered if answered.has("jsonrpc") else _make_error(id, answered.error.code, answered.error.message)


func _handle_tool_call(id: Variant, params: Dictionary, op: RefCounted = null) -> Dictionary:
	var tool_name: String = params.get("name", "")
	var arguments: Dictionary = params.get("arguments", {})

	if not _registry.has_tool(tool_name):
		return _make_error(id, -32602, "Unknown tool: %s" % tool_name)
	# The panel channel's own names are never a tool's arguments.
	for reserved in PanelAuthority.RESERVED_ARGUMENTS:
		if arguments.has(reserved):
			return _make_error(id, -32602, "%s is not a tool argument" % reserved)

	var result: Dictionary
	if op == null and DocketDBConnection.BASELINE_EVENTS.has(tool_name):
		# An ordinary call of a baseline tool runs within an operation of its
		# own, which the change describing it is found by.
		# Refused, it is answered as admission answers a busy project.
		var lease := CoordLease.shared()
		if lease.has("error"):
			result = {"error": str(lease.error), "kind": "coordination", "project": "", "retryable": true}
		else:
			result = _registry.call_tool(tool_name, arguments, lease.operation, true)
			lease.operation.close()
	else:
		result = _registry.call_tool(tool_name, arguments, op)

	if result.has("error"):
		var failed := {"content": [{"type": "text", "text": result.error}], "isError": true}
		# An error that carries more than its text (kind, partial_copy...)
		# keeps it whole in _meta, which clients that only read the text skip.
		if result.size() > 1:
			failed["_meta"] = {ERROR_RESULT_META: result}
		return _make_result(id, failed)

	return _make_result(id, {
		"content": [{"type": "text", "text": JSON.stringify(result)}],
	})


func _make_result(id: Variant, result: Variant) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


func _make_error(id: Variant, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
