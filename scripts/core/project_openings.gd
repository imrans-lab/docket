extends RefCounted
class_name ProjectOpenings
## Opening identity is process-local; clients also bind it to their connection.

static func normalized_path(path: String) -> String:
	if DocketDBMemory.is_memory_path(path): return path
	return ProjectSettings.globalize_path(path).simplify_path()

static func path_refusal(path: String, projects: Dictionary) -> String:
	for name in projects:
		var db: DocketDB = projects[name]
		if normalized_path(db.get_path()) == normalized_path(path):
			return "Project already loaded: %s" % name
	return ""

static func name_refusal(name: String, projects: Dictionary) -> String:
	return "Project name already loaded: %s" % name if projects.has(name) else ""

static func descriptor(name: String, db: DocketDB, primary: DocketDB) -> Dictionary:
	# Copy metadata first: stored values cannot replace routing or live state.
	var entry := db.get_project_meta().duplicate(true)
	entry.merge({"name":name, "display_name":db.get_project_name(), "path":db.get_path(),
		"prefix":db.get_id_prefix(), "primary":db == primary,
		"open_generation":str(db.get_instance_id()), "storage_mode":SessionProject.mode_of(db),
		"read_only_reason":db.get_write_block_reason()}, true)
	entry["stage"] = str(entry.get("stage", ""))
	entry.erase("owner")
	entry.erase("usage")
	if entry.storage_mode == SessionProject.MODE_SESSION_FILE:
		entry["owner"] = SessionProject.read_owner(db.get_path())
	if db is DocketDBMemory: entry["usage"] = (db as DocketDBMemory).usage()
	return entry
