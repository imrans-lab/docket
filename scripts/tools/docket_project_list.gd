extends RefCounted
class_name DocketProjectList


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_list",
		"description": "List all currently loaded docket projects with storage_mode (durable | session_file | memory) beside the lifecycle stage. Memory projects report usage against their item limit; the reply carries the memory owner lease and any spill result or failure.",
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
		var entry := {
			"name": proj_name,
			"path": pdb.get_path(),
			"prefix": pdb.get_id_prefix(),
			"primary": pdb == db,
		}
		var meta := pdb.get_project_meta()
		for key in meta:
			entry[key] = meta[key]
		# Storage mode is reported beside the lifecycle stage, never folded into it.
		entry["storage_mode"] = SessionProject.mode_of(pdb)
		entry["stage"] = str(meta.get("stage", ""))
		if entry.storage_mode == SessionProject.MODE_SESSION_FILE:
			entry["owner"] = SessionProject.read_owner(pdb.get_path())
		if pdb is DocketDBMemory:
			entry["usage"] = (pdb as DocketDBMemory).usage()
		projects.append(entry)
	var result := {"projects": projects, "count": projects.size(), "memory_lease": MemoryProject.lease_status()}
	if not MemoryProject.last_spills.is_empty():
		result["last_spill"] = MemoryProject.last_spills
	if not MemoryProject.last_spill_error.is_empty():
		result["spill_error"] = MemoryProject.last_spill_error
	return result
