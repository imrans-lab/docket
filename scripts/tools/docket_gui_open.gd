extends RefCounted
class_name DocketGuiOpen


func get_definition() -> Dictionary:
	return {
		"name": "docket_gui_open",
		"description": "Open an item or query in the GUI. Only works when the MCP server is embedded in the GUI app.",
		"inputSchema": {
			"type": "object",
			"properties": {
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

	if item_id.is_empty() and filter_str.is_empty():
		return {"error": "Provide either 'id' (to open an item) or 'filter' (to open a query)"}

	if not gui_open_fn.is_valid():
		return {"error": "GUI not available (headless mode)"}

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
		return gui_open_fn.call({"id":item_id, "project":requested_project})
	else:
		var label: String = str(args.get("label", "MCP Query"))
		return gui_open_fn.call({"filter": filter_str, "label": label})
