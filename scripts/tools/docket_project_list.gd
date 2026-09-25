extends RefCounted
class_name DocketProjectList


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_list",
		"description": "List all currently loaded docket projects. Each project's `name` is its selector for this session: the `project` argument other tools take. It is the project's stored name (display_name) unless another open project has that name, when it is \"name~2\" and so on; path (the file's own, links resolved) and open_generation identify the file and this opening of it.",
		"inputSchema": {
			"type": "object",
			"properties": {},
		},
	}


@warning_ignore("unused_parameter")
func execute(_args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary, _add_fn: Callable = Callable(), _remove_fn: Callable = Callable()) -> Dictionary:
	var projects: Array = []
	for proj_name in project_dbs:
		var pdb: DocketDB = project_dbs[proj_name]
		var entry := ProjectSelectors.describe(project_dbs, str(proj_name), db)
		var meta := pdb.get_project_meta()
		for key in meta:
			if not entry.has(key):
				entry[key] = meta[key]
		projects.append(entry)
	return {"projects": projects, "count": projects.size()}
