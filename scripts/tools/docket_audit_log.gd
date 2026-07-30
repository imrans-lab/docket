extends RefCounted
class_name DocketAuditLog


func get_definition() -> Dictionary:
	return {
		"name": "docket_audit_log",
		"description": (
			"Read the vault access audit log for a project: which secrets were read, "
			+ "written, or deleted, when, and whether the attempt succeeded. Records "
			+ "that access happened, never the secret values themselves. Local to this "
			+ "machine and not shared via git."
		),
		"inputSchema": {
			"type": "object",
			"properties": {
				"project": {
					"type": "string",
					"description": "Project name. Defaults to the primary project.",
				},
				"limit": {
					"type": "integer",
					"description": "Maximum entries to return, most recent first (default 50).",
				},
				"failures_only": {
					"type": "boolean",
					"description": "Return only failed attempts — repeated failures suggest password guessing.",
				},
			},
		},
	}


@warning_ignore("unused_parameter")
func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary, _add_fn: Callable = Callable(), _remove_fn: Callable = Callable()) -> Dictionary:
	var target_db := db
	var proj: String = str(args.get("project", ""))
	if not proj.is_empty():
		if not project_dbs.has(proj):
			return {"error": "Project not found: %s" % proj}
		target_db = project_dbs[proj]

	if target_db == null:
		return {"error": "No project loaded."}

	var limit: int = int(args.get("limit", 50))
	var entries := AuditLog.read_entries(target_db.get_path(), 0)

	if bool(args.get("failures_only", false)):
		var failed: Array = []
		for e in entries:
			if not bool(e.get("ok", true)):
				failed.append(e)
		entries = failed

	var total := entries.size()
	if limit > 0 and entries.size() > limit:
		entries.resize(limit)

	return {
		"path": AuditLog.path_for(target_db.get_path()),
		"entries": entries,
		"count": entries.size(),
		"total": total,
	}
