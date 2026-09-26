extends RefCounted
class_name DocketProjectPersist
## Writes a memory project to a file and serves the file in its place:
## mode=session_file spills it (default path under the session directory),
## mode=durable promotes it to an ordinary project file at `path`.


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_persist",
		"description": "Write a memory project to disk and keep serving it from the file under the same name. mode=session_file spills it to the session directory (path optional); mode=durable promotes it to a project file at path. Refuses to overwrite an existing file.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Memory project to persist"},
				"mode": {"type": "string", "enum": [SessionProject.MODE_SESSION_FILE, SessionProject.MODE_DURABLE], "description": "session_file (spill) or durable (promote)"},
				"path": {"type": "string", "description": "Target .dct path; required for durable, optional for session_file"},
			},
			"required": ["name", "mode"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, project_dbs: Dictionary, add_fn: Callable = Callable(), remove_fn: Callable = Callable()) -> Dictionary:
	var proj_name := str(args.get("name", ""))
	if not project_dbs.has(proj_name):
		return {"error": "Project not found: %s" % proj_name}
	return MemoryProject.persist(project_dbs, proj_name, str(args.get("mode", "")), str(args.get("path", "")), add_fn, remove_fn)
