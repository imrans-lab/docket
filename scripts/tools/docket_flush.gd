extends RefCounted
class_name DocketFlush


func get_definition() -> Dictionary:
	return {
		"name": "docket_flush",
		"description": (
			"Force every loaded project to serialize to its .dct file. Writes are "
			+ "already immediate, so this is normally a no-op — call it as an explicit "
			+ "'settle the files' step before running git add/commit."
		),
		"inputSchema": {
			"type": "object",
			"properties": {
				"project": {
					"type": "string",
					"description": "Project name to flush. Omit to flush every loaded project.",
				},
			},
		},
	}


@warning_ignore("unused_parameter")
func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary, _add_fn: Callable = Callable(), _remove_fn: Callable = Callable()) -> Dictionary:
	var target: String = str(args.get("project", ""))

	if not target.is_empty() and not project_dbs.has(target):
		return {"error": "Project not found: %s" % target}

	var flushed: Array = []
	for proj_name in project_dbs:
		if not target.is_empty() and proj_name != target:
			continue
		var pdb: DocketDB = project_dbs[proj_name]
		if not pdb is DocketDBJsonl:
			continue  # SQLite-backed project: nothing to serialize
		(pdb as DocketDBJsonl).flush()
		flushed.append({"project": proj_name, "path": pdb.get_path()})

	return {"flushed": flushed, "count": flushed.size()}
