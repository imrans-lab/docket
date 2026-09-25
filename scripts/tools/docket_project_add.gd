extends RefCounted
class_name DocketProjectAdd


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_add",
		"description": "Load a docket project by file path. Creates the file if it doesn't exist and create=true. Answers the project as docket_project_list describes it; its `name` is the selector to pass as `project`. A file already open is not opened again: it answers that project, with already_open.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "Absolute path to the .dct file"},
				"create": {"type": "boolean", "description": "Create file if missing (default false)"},
			},
			"required": ["path"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, project_dbs: Dictionary, add_fn: Callable = Callable(), _remove_fn: Callable = Callable()) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var create: bool = args.get("create", false) == true

	if path.is_empty():
		return {"error": "path is required"}

	var located := ProjectFile.locate(path)
	if located.has("error"):
		return located
	var open_as := ProjectSelectors.selector_for(project_dbs, located)
	if not open_as.is_empty():
		return ProjectSelectors.describe(project_dbs, open_as, _db).merged({"already_open": true})

	if not located.has("id") and not create:
		return {"error": "File not found: %s (pass create=true to create)" % path}

	if not add_fn.is_valid():
		return {"error": "Project management not available in this mode"}

	return add_fn.call(located.path)
