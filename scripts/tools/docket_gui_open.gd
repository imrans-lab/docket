extends RefCounted
class_name DocketGuiOpen


func get_definition() -> Dictionary:
	return {
		"name": "docket_gui_open",
		"description": "Open an item or query in the GUI, focus its process-owned window, or open the New Docket dialog. Only works when the MCP server is embedded in the GUI app.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"new_docket": {"type":"boolean", "description":"Open the existing New Docket file dialog; may be used alone or with focus"},
				"focus": {"type": "boolean", "description": "Bring the GUI window to the foreground; may be used alone"},
				"id": {"type": "string", "description": "Item ID to open in detail view"},
				"filter": {"type": "string", "description": "JSON filter string to open as a new query tab"},
				"label": {"type": "string", "description": "Label for the query tab (used with filter)"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, project_dbs: Dictionary, gui_open_fn: Callable = Callable()) -> Dictionary:
	var item_id: String = str(args.get("id", ""))
	var filter_str: String = str(args.get("filter", ""))

	if args.has("new_docket") and not args.new_docket is bool:
		return {"error":"new_docket must be a boolean"}
	var new_docket: bool = args.get("new_docket", false)
	if new_docket and (not item_id.is_empty() or not filter_str.is_empty()):
		return {"error":"new_docket cannot be combined with id or filter"}

	if item_id.is_empty() and filter_str.is_empty() and not args.get("focus", false) and not new_docket:
		return {"error": "Provide id, filter, focus:true, or new_docket:true"}

	if not gui_open_fn.is_valid():
		return {"error": "GUI not available (headless mode)"}

	if new_docket:
		return gui_open_fn.call({"new_docket":true, "focus":true})

	if item_id.is_empty() and filter_str.is_empty():
		return gui_open_fn.call({"focus": true})

	if not item_id.is_empty():
		var requested_project := str(args.get("project", ""))
		if requested_project.is_empty():
			var matches: Array[String] = []
			for project_value in project_dbs:
				var candidate := str(project_value)
				var candidate_db: DocketDB = project_dbs[candidate]
				if candidate_db.has_item(item_id):
					matches.append(candidate)
			if matches.size() != 1:
				return {"error":"project is required because the item origin is missing or ambiguous"}
			requested_project = matches[0]
		if not project_dbs.has(requested_project):
			return {"error":"Project not found: %s" % requested_project}
		var pdb: DocketDB = project_dbs[requested_project]
		if not pdb.has_item(item_id):
			return {"error": "Item not found: %s" % item_id}
		return gui_open_fn.call({"id":item_id, "project":requested_project, "focus":args.get("focus", false)})
	else:
		var label: String = str(args.get("label", "MCP Query"))
		return gui_open_fn.call({"filter": filter_str, "label": label, "focus":args.get("focus", false)})
