extends RefCounted
class_name DocketProjectDiscard
## Without confirm=true this only reports the outstanding (non-terminal) items
## and changes nothing. With confirm=true it closes the project and deletes the
## file (a memory project has none and is dropped), returning the outstanding
## items it discarded.


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_discard",
		"description": "Delete a session_file or memory project. Without confirm=true, lists its outstanding (non-terminal) items and does nothing; with confirm=true, closes it and deletes the file, reporting what was discarded.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Session project to discard"},
				"confirm": {"type": "boolean", "description": "Required to delete (default false)"},
			},
			"required": ["name"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, project_dbs: Dictionary, _add_fn: Callable = Callable(), remove_fn: Callable = Callable()) -> Dictionary:
	var target := DocketProjectClose.resolve(args, project_dbs)
	if target.has("error"):
		return target
	if target.storage_mode == SessionProject.MODE_DURABLE:
		return {"error": "%s is a durable project; only session_file and memory projects can be discarded" % target.name}
	var outstanding := SessionProject.outstanding_items(target.db)
	if args.get("confirm", false) != true:
		return {
			"discarded": false,
			"project": target.name,
			"path": target.path,
			"outstanding": outstanding,
			"outstanding_count": outstanding.size(),
			"message": "Not discarded: %d outstanding item(s) listed. Pass confirm=true to delete %s." % [outstanding.size(), target.path],
		}
	var closed := DocketProjectClose.unload(target, remove_fn, project_dbs)
	if closed.has("error"):
		return closed
	if target.storage_mode == SessionProject.MODE_MEMORY:
		return {"discarded": true, "project": target.name, "storage_mode": target.storage_mode, "outstanding_discarded": outstanding, "outstanding_count": outstanding.size()}
	var error := SessionProject.discard_files(target.path)
	if not error.is_empty():
		return {"error": "Closed %s but could not delete it: %s" % [target.name, error]}
	return {"discarded": true, "project": target.name, "path": target.path, "file_exists": FileAccess.file_exists(target.path), "outstanding_discarded": outstanding, "outstanding_count": outstanding.size()}
