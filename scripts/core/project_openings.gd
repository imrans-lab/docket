extends RefCounted
class_name ProjectOpenings
## Opening identity is process-local; clients also bind it to their connection.

static func normalized_path(path: String) -> String:
	if DocketDBMemory.is_memory_path(path): return path
	if OS.get_name() == "Windows": path = path.replace("\\", "/")
	return ProjectSettings.globalize_path(path).simplify_path()

## Native queries keep dot segments: simplifying across symlink parents can
## change which physical file is queried. Dynamic construction tolerates absence.
static func inspect(path: String) -> Dictionary:
	if DocketDBMemory.is_memory_path(path): return {"state":"PRESENT", "token":path}
	if not ClassDB.class_exists("DocketFileIdentity"): return {"state":"ERROR", "token":""}
	var helper: Object = ClassDB.instantiate("DocketFileIdentity")
	return helper.call("inspect", ProjectSettings.globalize_path(path))

static func compare(left: String, right: String) -> Dictionary:
	if DocketDBMemory.is_memory_path(left) or DocketDBMemory.is_memory_path(right):
		return {"state":"SAME" if left == right else "DIFFERENT"}
	if not ClassDB.class_exists("DocketFileIdentity"): return {"state":"ERROR"}
	var helper: Object = ClassDB.instantiate("DocketFileIdentity")
	return helper.call("compare", ProjectSettings.globalize_path(left), ProjectSettings.globalize_path(right))

static func capture(db: DocketDB) -> void:
	db.set_meta("physical_opening", inspect(db.get_path()))

static func opening_refusal(db: DocketDB) -> String:
	if db is DocketDBMemory: return ""
	var current := inspect(db.get_path())
	var opened: Dictionary = db.get_meta("physical_opening", {})
	if current.get("state") != "PRESENT" or opened.get("state") != "PRESENT":
		return "Cannot prove project opening identity"
	return "Project file was replaced after opening" if current.token != opened.token else ""

static func move_refusal(source: DocketDB, target: DocketDB) -> String:
	for db in [source, target]:
		var refusal := opening_refusal(db)
		if not refusal.is_empty(): return refusal
		if db is DocketDBJsonl:
			refusal = DocketDBJsonl.temp_refusal(db.get_path())
			if not refusal.is_empty(): return refusal
	var state: String = compare(source.get_path(), target.get_path()).state
	return "" if state == "DIFFERENT" else "Move refused: project identity is " + state

static func path_refusal(path: String, projects: Dictionary) -> String:
	for name in projects:
		var db: DocketDB = projects[name]
		if normalized_path(db.get_path()) == normalized_path(path):
			return "Project already loaded: %s" % name
		var result := compare(db.get_path(), path)
		if result.state == "SAME": return "Project already loaded: %s" % name
		# A genuinely absent candidate remains eligible for ordinary creation.
		if result.state == "ABSENT" and result.get("right", {}).get("state") == "ABSENT" and result.get("left", {}).get("state") == "PRESENT": continue
		if result.state != "DIFFERENT": return "Cannot prove distinct project identity"
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
