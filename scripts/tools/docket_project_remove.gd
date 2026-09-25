extends RefCounted
class_name DocketProjectRemove


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_remove",
		"description": "Close and unload a docket project by name.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Project name to remove"},
			},
			"required": ["name"],
		},
	}


## `allow_last`: the server can run with no project (a host-managed one).
func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, project_dbs: Dictionary, _add_fn: Callable = Callable(), remove_fn: Callable = Callable(), allow_last: bool = false) -> Dictionary:
	var proj_name: String = str(args.get("name", ""))

	if proj_name.is_empty():
		return {"error": "name is required"}

	var named := ProjectSelectors.resolve(project_dbs, proj_name)
	if named.has("error"):
		return {"error": named.error}
	proj_name = named.selector

	if project_dbs.size() <= 1 and not allow_last:
		return {"error": "Cannot remove the last project"}

	if not remove_fn.is_valid():
		return {"error": "Project management not available in this mode"}

	return remove_fn.call(proj_name)
