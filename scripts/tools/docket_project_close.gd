extends RefCounted
class_name DocketProjectClose
## docket_project_close unloads a project and keeps its file. unload() is the
## shared step for close, archive and discard.


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_close",
		"description": "Close a loaded project and keep its file on disk (durable or session_file). Releases this server's ownership of a session_file project. Refuses a memory project, which has no file.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Project name to close"},
			},
			"required": ["name"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, project_dbs: Dictionary, _add_fn: Callable = Callable(), remove_fn: Callable = Callable()) -> Dictionary:
	var target := resolve(args, project_dbs)
	if target.has("error"):
		return target
	var refusal := MemoryProject.unload_refusal(target.db, target.name)
	if not refusal.is_empty():
		return {"error": refusal}
	return unload(target, remove_fn, project_dbs)


## {"name", "path", "db", "storage_mode"} for args.name, or {"error"}.
static func resolve(args: Dictionary, project_dbs: Dictionary) -> Dictionary:
	var proj_name: String = str(args.get("name", ""))
	if proj_name.is_empty():
		return {"error": "name is required"}
	if not project_dbs.has(proj_name):
		return {"error": "Project not found: %s" % proj_name}
	var pdb: DocketDB = project_dbs[proj_name]
	return {"name": proj_name, "path": pdb.get_path(), "db": pdb, "storage_mode": SessionProject.mode_of(pdb)}


static func unload(target: Dictionary, remove_fn: Callable, project_dbs: Dictionary) -> Dictionary:
	if project_dbs.size() <= 1:
		return {"error": "Cannot close the last project"}
	if not remove_fn.is_valid():
		return {"error": "Project management not available in this mode"}
	var removed: Dictionary = remove_fn.call(str(target.name))
	if removed.has("error"):
		return removed
	var path: String = target.path
	return {"closed": target.name, "path": path, "storage_mode": target.storage_mode, "file_exists": FileAccess.file_exists(path)}
