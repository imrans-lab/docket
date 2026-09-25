extends RefCounted
## RemoteDocketSource's connection through a host panel's channels, by way of
## the host's helper (the "_MinervaIPC" child it adds to the panel).
##
## Reads go as ordinary tool calls: request_bulk(channel = tool name,
## payload = arguments), whose replies may be large (a query, a type list),
## answered {success: true, result} or {success: false, error_code,
## error_message} and handed on in the MCP tools/call result shape the
## source reads. The host passes on only the text of such a tool's error,
## not its details, so an item deleted elsewhere is reported as one that
## could not be looked up.
##
## When the host runs this plugin's private panel channel (its helper's
## panel_origin() names this panel's origin), the source's changes (a tool
## call given an operation id) go through it as this panel's
## (request_private "call"), and panel_call("update_item") saves as the
## person the host names. Without it, every change is an ordinary tool call,
## which the source takes as another client's, and a save is refused saying
## the host lacks the channel.

## How long (ms) a call may take: reading or reloading a large project is
## slow, and a call given up on may still have made its change.
const TIMEOUT_MS := 120000
const NO_CHANNEL := "Editing here needs the host's trusted panel channel, which this host does not provide."

var _panel: Control


func _init(panel: Control) -> void:
	_panel = panel


## The origin the process gives this panel's changes, or "" when the host
## runs no private channel for it.
func panel_origin() -> String:
	var helper := _helper()
	return str(helper.panel_origin()) if helper != null and helper.has_method("panel_origin") else ""


func call_tool(name: String, arguments: Dictionary, operation_id: String = "") -> Dictionary:
	var helper := _helper()
	if helper == null or not helper.has_method("request_bulk"):
		return {"error": "the host has not connected this panel to Docket"}
	if not operation_id.is_empty() and not panel_origin().is_empty():
		var private_reply: Dictionary = await helper.request_private("call",
			{"name": name, "arguments": arguments, "operation_id": operation_id}, TIMEOUT_MS)
		# The process's own tools/call result, with its operation and stream.
		if bool(private_reply.get("success", false)) and private_reply.get("result") is Dictionary:
			return private_reply.result
		return {"error": _message(private_reply)}
	var reply: Dictionary = await helper.request_bulk(name, arguments, TIMEOUT_MS)
	if bool(reply.get("success", false)):
		return {"content": [{"type": "text", "text": JSON.stringify(reply.get("result", {}))}]}
	var failed := reply.duplicate(true)
	failed["error"] = _message(reply)
	return {"isError": true, "content": [{"type": "text", "text": failed.error}], "_meta": {"docket/result": failed}}


## `method` ("update_item") of the private channel: its result, or {error}.
func panel_call(method: String, params: Dictionary) -> Dictionary:
	var helper := _helper()
	if helper == null or panel_origin().is_empty():
		return {"error": NO_CHANNEL}
	var reply: Dictionary = await helper.request_private(method, params, TIMEOUT_MS)
	if bool(reply.get("success", false)) and reply.get("result") is Dictionary:
		return reply.result
	return {"error": _message(reply)}


func _helper() -> Node:
	return _panel.get_node_or_null("_MinervaIPC") if is_instance_valid(_panel) else null


# A failed reply's message, with any specifics the host keeps apart from it.
static func _message(reply: Dictionary) -> String:
	var message := str(reply.get("error_message", reply.get("error_code", "the host could not reach Docket")))
	var detail = reply.get("detail")
	if (detail is Dictionary or detail is Array) and not detail.is_empty():
		message += " (%s)" % JSON.stringify(detail)
	return message
