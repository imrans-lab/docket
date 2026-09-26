extends RefCounted
class_name MemoryProject
## Owner lease, persistence and spill rules for memory projects (DocketDBMemory).
##
## Owner presence is a lease. An owner-class client (docket.app's GUI, Minerva)
## renews it with docket_project_heartbeat, or on any MCP request that carries
## the header `X-Docket-Client-Class: owner`. The class is what the client
## declares; it is not authenticated. A GUI hosting the server in its own
## process is always present, since its exit is the server's exit.
##
## A memory project is created only while an owner is present. While no owner
## holds the lease, enforce() spills every memory project that has outstanding
## (non-terminal) items to a session_file under SessionProject.default_dir()
## and serves the file in its place. A spill that fails at any step, including
## opening the written file, leaves the project served from memory, logs the
## error, sets last_spill_error (docket_project_list reports it as spill_error),
## and is retried on the next enforce(). A memory
## project with nothing outstanding is left in memory.
##
## Callers: ToolRegistry.enforce_memory_lease() before each tool call and on a
## timer in DocketHttpServer; the project verbs (add, heartbeat, persist, close,
## remove, discard); the GUI quit dialog; DocketHttpServer._exit_tree().

const CLIENT_CLASS_OWNER := "owner"
const HEADER_CLIENT_CLASS := "x-docket-client-class"
const HEADER_CLIENT := "x-docket-client"
const DEFAULT_LEASE_SECONDS := 120
const MAX_LEASE_SECONDS := 3600

static var _lease_until_msec: int = 0
static var _lease_holder: String = ""
## Reason the most recent spill failed; "" once every spill succeeds.
static var last_spill_error: String = ""
## Results of the most recent spill that did something, for docket_project_list.
static var last_spills: Array[Dictionary] = []


# -- Lease --------------------------------------------------------------------

static func renew(client: String, seconds: int = DEFAULT_LEASE_SECONDS) -> void:
	var span := clampi(seconds, 1, MAX_LEASE_SECONDS)
	_lease_until_msec = Time.get_ticks_msec() + span * 1000
	_lease_holder = client if not client.is_empty() else "unnamed owner"


static func renew_from_headers(headers: Dictionary) -> void:
	## Piggybacked renewal: any request that declares the owner class renews.
	if str(headers.get(HEADER_CLIENT_CLASS, "")).to_lower() == CLIENT_CLASS_OWNER:
		renew(str(headers.get(HEADER_CLIENT, "")))


static func in_process_owner() -> bool:
	return SessionProject.role == "gui"


static func owner_present() -> bool:
	return in_process_owner() or Time.get_ticks_msec() < _lease_until_msec


static func lease_status() -> Dictionary:
	var remaining := maxi(0, _lease_until_msec - Time.get_ticks_msec())
	return {
		"owner_present": owner_present(),
		"in_process_owner": in_process_owner(),
		"holder": "in-process GUI" if in_process_owner() else _lease_holder,
		"expires_in_s": snappedf(remaining / 1000.0, 0.1),
		"identity": "declared",
	}


static func creation_refusal() -> String:
	if owner_present():
		return ""
	return "Refused: a memory project needs an owner-class client present (docket.app GUI or Minerva). None holds the lease; an owner renews it with docket_project_heartbeat client_class=owner or the X-Docket-Client-Class: owner header."


# -- Queries ------------------------------------------------------------------

static func outstanding_projects(project_dbs: Dictionary) -> Dictionary:
	## name -> outstanding item count, for memory projects that have any.
	var result := {}
	for proj_name in project_dbs:
		var pdb: DocketDB = project_dbs[proj_name]
		if pdb is DocketDBMemory:
			var count := SessionProject.outstanding_items(pdb).size()
			if count > 0:
				result[str(proj_name)] = count
	return result


static func unload_refusal(pdb: DocketDB, proj_name: String) -> String:
	## Close and remove would drop a memory project; they refuse and name the verbs that keep or drop it explicitly.
	if not pdb is DocketDBMemory:
		return ""
	return "Refused: %s is a memory project and closing it would lose it. Use docket_project_persist (mode=session_file to spill, mode=durable with a path to promote) or docket_project_discard with confirm=true." % proj_name


# -- Persistence --------------------------------------------------------------

static func free_session_path(proj_name: String) -> String:
	## Default session path for `proj_name`, suffixed -2, -3, ... when taken.
	var path := SessionProject.default_path(proj_name)
	var n := 2
	while FileAccess.file_exists(path) and n < 1000:
		path = SessionProject.default_path("%s-%d" % [proj_name, n])
		n += 1
	return path


static func write_file(pdb: DocketDBMemory, mode: String, path: String) -> String:
	## Write the project to a new file at `path` with storage mode `mode`.
	## Returns "" or the refusal. The memory project is left unchanged.
	if mode != SessionProject.MODE_SESSION_FILE and mode != SessionProject.MODE_DURABLE:
		return "mode must be session_file or durable"
	if path.is_empty():
		return "path is required for mode=durable"
	if FileAccess.file_exists(path):
		return "Refused: %s already exists; choose a new path" % path
	if mode == SessionProject.MODE_SESSION_FILE:
		var placement := SessionProject.path_error(path)
		if not placement.is_empty():
			return placement
	var text := pdb.serialize_as(mode)
	if text.is_empty():
		return "could not serialize memory project %s" % pdb.get_project_name()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	return DocketDBJsonl._atomic_write(path, text)


static func persist(project_dbs: Dictionary, proj_name: String, mode: String, path: String, add_fn: Callable, remove_fn: Callable) -> Dictionary:
	## Write memory project `proj_name` to a file, then serve the file in its place.
	var pdb := project_dbs.get(proj_name) as DocketDBMemory
	if pdb == null:
		return {"error": "%s is not a loaded memory project" % proj_name}
	if not add_fn.is_valid() or not remove_fn.is_valid():
		return {"error": "Project management not available in this mode"}
	var target := path
	if target.is_empty() and mode == SessionProject.MODE_SESSION_FILE:
		target = free_session_path(proj_name)
	var usage := pdb.usage()
	var outstanding := SessionProject.outstanding_items(pdb).size()
	var error := write_file(pdb, mode, target)
	if not error.is_empty():
		return {"error": error}
	# Open the file before dropping the memory copy: loading a project under a
	# name already served replaces that entry, so a failed open leaves the memory
	# project served and listed. The unserved file is removed so a retry does
	# not leave a trail of copies.
	var added: Dictionary = add_fn.call(target)
	if added.has("error"):
		DirAccess.remove_absolute(target)
		var failure := "Wrote %s but could not open it here, so %s stays in memory: %s" % [target, proj_name, added.error]
		push_error("Docket: %s" % failure)
		return {"error": failure, "kept_in_memory": proj_name}
	if str(added.get("name", proj_name)) == proj_name:
		pdb.close()
	else:
		var removed: Dictionary = remove_fn.call(proj_name)
		if removed.has("error"):
			push_error("Docket: %s is served from %s but its memory copy did not unload: %s" % [proj_name, target, removed.error])
	return {"persisted": proj_name, "name": added.get("name", proj_name), "storage_mode": mode, "path": target, "items": usage.items, "outstanding_count": outstanding, "file_exists": FileAccess.file_exists(target)}


static func spill_outstanding(project_dbs: Dictionary, add_fn: Callable, remove_fn: Callable) -> Array[Dictionary]:
	## Spill every memory project with outstanding items to a session file.
	var results: Array[Dictionary] = []
	var errors: PackedStringArray = []
	for proj_name: String in outstanding_projects(project_dbs).keys():
		var result := persist(project_dbs, proj_name, SessionProject.MODE_SESSION_FILE, "", add_fn, remove_fn)
		results.append(result)
		if result.has("error"):
			errors.append("%s: %s" % [proj_name, result.error])
	last_spill_error = "; ".join(errors)
	if not results.is_empty():
		last_spills = results
	if not errors.is_empty():
		push_error("Docket: memory project spill failed, keeping it in memory: %s" % last_spill_error)
	return results


static func enforce(project_dbs: Dictionary, add_fn: Callable, remove_fn: Callable) -> Array[Dictionary]:
	## Lease rule: without an owner, outstanding memory work moves to session files.
	if owner_present():
		return []
	return spill_outstanding(project_dbs, add_fn, remove_fn)


static func spill_on_exit(project_dbs: Dictionary) -> void:
	## Last step at process exit: write outstanding memory projects to session
	## files without reopening them, and add those files to the saved session
	## list so the next start opens them. Failures are reported on stderr.
	var spilled := PackedStringArray()
	for proj_name: String in outstanding_projects(project_dbs).keys():
		var pdb: DocketDBMemory = project_dbs[proj_name]
		var path := free_session_path(proj_name)
		var error := write_file(pdb, SessionProject.MODE_SESSION_FILE, path)
		if error.is_empty():
			spilled.append(path)
			print("Docket: spilled memory project %s to %s" % [proj_name, path])
		else:
			printerr("Docket: could not spill memory project %s at exit: %s" % [proj_name, error])
	if not spilled.is_empty():
		UserPrefs.save_session(UserPrefs.load_session() + spilled)
