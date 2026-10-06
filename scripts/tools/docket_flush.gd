extends RefCounted
class_name DocketFlush


func get_definition() -> Dictionary:
	return {
		"name": "docket_flush",
		"description": (
			"Settle every loaded project: rewrite its .dct from the current state and "
			+ "empty its write-ahead sidecar (<file>.dct.log). Mutations append to the "
			+ "sidecar and the .dct settles on its own after a short idle period — call "
			+ "this as an explicit 'settle the files' step before running git add/commit."
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
	var failed: Array = []
	for proj_name in project_dbs:
		if not target.is_empty() and proj_name != target:
			continue
		var pdb: DocketDB = project_dbs[proj_name]
		if not pdb is DocketDBJsonl:
			continue  # SQLite-backed project: nothing to serialize
		var error := (pdb as DocketDBJsonl).flush_checked()
		if not error.is_empty():
			failed.append({"project": proj_name, "path": pdb.get_path(), "error": error})
			continue
		flushed.append({"project": proj_name, "path": pdb.get_path()})

	var result := {"flushed": flushed, "count": flushed.size()}
	if not failed.is_empty():
		result["error"] = "Could not flush %d project(s)" % failed.size()
		result["failed"] = failed
	return result
