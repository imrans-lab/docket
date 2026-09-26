extends RefCounted
class_name DocketProjectArchive


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_archive",
		"description": "Archive a session_file project: set its lifecycle stage to archived, close it, keep the file.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Session project to archive"},
			},
			"required": ["name"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, project_dbs: Dictionary, _add_fn: Callable = Callable(), remove_fn: Callable = Callable()) -> Dictionary:
	var target := DocketProjectClose.resolve(args, project_dbs)
	if target.has("error"):
		return target
	if target.storage_mode != SessionProject.MODE_SESSION_FILE:
		return {"error": "%s is a %s project; archive durable projects with docket_project_meta" % [target.name, target.storage_mode]}
	var jsonl_db := target.db as DocketDBJsonl
	if jsonl_db == null:
		return {"error": "%s is not a JSONL project" % target.name}
	# The verb sets the stage directly; the durable-project transition table does not apply.
	var error := jsonl_db.set_project_meta_checked({"stage": "archived"})
	if not error.is_empty():
		return {"error": error}
	var result := DocketProjectClose.unload(target, remove_fn, project_dbs)
	if not result.has("error"):
		result["stage"] = "archived"
	return result
