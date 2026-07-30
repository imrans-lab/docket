extends RefCounted
class_name DocketReload


func get_definition() -> Dictionary:
	return {
		"name": "docket_reload",
		"description": (
			"Re-read .dct files from disk, discarding the SQLite cache. Use after "
			+ "a git pull or merge. Usually unnecessary — every tool call already "
			+ "reloads files whose contents changed — but it forces the check and "
			+ "reports what was reloaded."
		),
		"inputSchema": {
			"type": "object",
			"properties": {
				"project": {
					"type": "string",
					"description": "Project name to reload. Omit to reload every loaded project.",
				},
			},
		},
	}


@warning_ignore("unused_parameter")
func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary, _add_fn: Callable = Callable(), _remove_fn: Callable = Callable()) -> Dictionary:
	var target: String = str(args.get("project", ""))

	if not target.is_empty() and not project_dbs.has(target):
		return {"error": "Project not found: %s" % target}

	var reloaded: Array = []
	var failed: Array = []

	for proj_name in project_dbs:
		if not target.is_empty() and proj_name != target:
			continue
		var pdb: DocketDB = project_dbs[proj_name]
		if not pdb is DocketDBJsonl:
			continue  # SQLite-backed project: the file *is* the database
		if (pdb as DocketDBJsonl).reload():
			reloaded.append(proj_name)
		else:
			failed.append({
				"project": proj_name,
				"reason": DocketDBJsonl.last_open_error,
			})

	var result := {"reloaded": reloaded, "count": reloaded.size()}
	if not failed.is_empty():
		result["failed"] = failed
	return result
