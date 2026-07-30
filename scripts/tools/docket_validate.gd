extends RefCounted
class_name DocketValidate


func get_definition() -> Dictionary:
	return {
		"name": "docket_validate",
		"description": (
			"Check a .dct file for structural problems without opening it: "
			+ "unresolved git conflict markers, malformed lines, duplicate item IDs, "
			+ "and dangling references. Use this after resolving a merge conflict "
			+ "to confirm the file is well-formed before committing it."
		),
		"inputSchema": {
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "Path to a .dct file. Omit to validate all loaded projects.",
				},
			},
		},
	}


@warning_ignore("unused_parameter")
func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary, _add_fn: Callable = Callable(), _remove_fn: Callable = Callable()) -> Dictionary:
	var paths: Array = []

	var explicit: String = str(args.get("path", ""))
	if not explicit.is_empty():
		paths.append(explicit)
	else:
		for proj_name in project_dbs:
			var pdb: DocketDB = project_dbs[proj_name]
			paths.append(pdb.get_path())

	if paths.is_empty():
		return {"error": "No path given and no projects loaded."}

	var reports: Array = []
	var all_ok := true
	for p in paths:
		var report := JSONLValidator.validate_file(str(p))
		if not report["ok"]:
			all_ok = false
		reports.append(report)

	return {"ok": all_ok, "reports": reports}
