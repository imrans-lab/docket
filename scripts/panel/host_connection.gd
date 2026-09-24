extends RefCounted
## RemoteDocketSource's connection through a host panel's generic channel:
## each tool call goes through the host's helper (the "_MinervaIPC" child it
## adds to the panel) as request_bulk(channel = tool name, payload =
## arguments), whose replies may be large (a query, a type list), answered
## {success: true, result} or {success: false, error_code, error_message}; it
## is answered in the MCP tools/call result shape the source reads. These
## are ordinary tool calls: this connection has no private panel channel
## (panel_origin, panel_call), so the source takes every change as another
## client's and says item edits need the host's trusted channel. The host
## passes on only the text of a tool's error, not its details, so an item
## deleted elsewhere is reported as one that could not be looked up.

## How long (ms) a call may take: reading or reloading a large project is
## slow, and a call given up on may still have made its change.
const TIMEOUT_MS := 120000

var _panel: Control


func _init(panel: Control) -> void:
	_panel = panel


func call_tool(name: String, arguments: Dictionary, _operation_id: String = "") -> Dictionary:
	var helper := _panel.get_node_or_null("_MinervaIPC")
	if helper == null or not helper.has_method("request_bulk"):
		return {"error": "the host has not connected this panel to Docket"}
	var reply: Dictionary = await helper.request_bulk(name, arguments, TIMEOUT_MS)
	if bool(reply.get("success", false)):
		return {"content": [{"type": "text", "text": JSON.stringify(reply.get("result", {}))}]}
	var failed := reply.duplicate(true)
	var message := str(reply.get("error_message", reply.get("error_code", "the host could not reach Docket")))
	# Some host errors keep their specifics apart from a generic message.
	var detail = reply.get("detail")
	if (detail is Dictionary or detail is Array) and not detail.is_empty():
		message += " (%s)" % JSON.stringify(detail)
	failed["error"] = message
	return {"isError": true, "content": [{"type": "text", "text": failed.error}], "_meta": {"docket/result": failed}}
