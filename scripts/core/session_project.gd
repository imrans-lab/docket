extends RefCounted
class_name SessionProject
## Storage mode and single-owner rules for projects.
##
## A project's storage mode is kept in its own file as the meta key
## `project_storage_mode`; a missing key means durable. Durable projects are the
## ordinary files that live in repositories. A session_file project lives outside
## any Git checkout, on non-volatile storage, and is served by exactly one Docket
## server process at a time.
##
## Ownership: the server that admits a session_file project writes
## `<path>.owner` = {pid, role, port, claimed_at}. Another process that tries to
## admit the same file while that pid is alive is refused with a message naming
## the owner and its MCP endpoint, so the client can connect there instead. The
## record is removed when the owning process closes the project or exits cleanly;
## a record whose pid is gone is taken over. This is the per-file claim; the
## per-user server discovery record belongs to server-ownership DCR 01a0b0f12c15.
##
## A memory project (DocketDBMemory) has no file and no owner record; its lease
## and spill rules live in MemoryProject.
##
## Callers: AppState and DocketHttpServer call admit() after opening any project
## and release() when unloading it; the project verbs (add/close/archive/discard)
## use the path checks and outstanding_items().

const MODE_DURABLE := "durable"
const MODE_SESSION_FILE := "session_file"
const MODE_MEMORY := "memory"
const MODES: Array[String] = [MODE_DURABLE, MODE_SESSION_FILE, MODE_MEMORY]
const META_KEY := "project_storage_mode"
const OWNER_SUFFIX := ".owner"
const VOLATILE_FS: Array[String] = ["tmpfs", "ramfs"]
## Environment variable that replaces default_dir(), e.g. for a container or a test.
const SESSION_DIR_ENV := "DOCKET_SESSION_DIR"

## How this process describes itself in owner records: "gui" or "serve".
static var role: String = "serve"
## MCP port this process listens on; 0 while it has no endpoint.
static var endpoint_port: int = 0
## Paths this process currently owns.
static var _held: PackedStringArray = PackedStringArray()


# -- Mode ---------------------------------------------------------------------

static func mode_of(db: DocketDB) -> String:
	var stored := db.get_meta_value(META_KEY, "")
	return stored if MODES.has(stored) else MODE_DURABLE


static func default_dir() -> String:
	## Per-user data directory: ~/.local/share/docket/sessions on Linux,
	## ~/Library/Application Support/docket/sessions on macOS, %APPDATA% on Windows.
	## DOCKET_SESSION_DIR, when set, is used instead.
	var override := OS.get_environment(SESSION_DIR_ENV)
	if not override.is_empty():
		return override
	return OS.get_data_dir().path_join("docket").path_join("sessions")


static func default_path(project_name: String) -> String:
	return default_dir().path_join(project_name + ".dct")


# -- Path rules ---------------------------------------------------------------

static func path_error(path: String) -> String:
	## "" when `path` may hold a session_file project, else the refusal text.
	var absolute := _absolute(path)
	var repo := repository_root(absolute)
	if not repo.is_empty():
		return "Refused: session_file path %s is inside the Git checkout %s. Session projects live outside any repository; omit path to use %s." % [absolute, repo, default_dir()]
	var fs := volatile_filesystem(absolute)
	if not fs.is_empty():
		return "Refused: session_file path %s is on %s, which a reboot clears. Use non-volatile storage such as %s." % [absolute, fs, default_dir()]
	return ""


static func repository_root(path: String) -> String:
	## Nearest ancestor of `path` that holds a .git directory or file, else "".
	var dir := _absolute(path).get_base_dir()
	while not dir.is_empty():
		var marker := dir.path_join(".git")
		if DirAccess.dir_exists_absolute(marker) or FileAccess.file_exists(marker):
			return dir
		var parent := dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return ""


static func volatile_filesystem(path: String) -> String:
	## Filesystem type when `path` sits on a RAM-backed mount, else "".
	## Reads /proc/mounts, so detection exists only on Linux.
	if OS.get_name() != "Linux" or not FileAccess.file_exists("/proc/mounts"):
		return ""
	var absolute := _absolute(path)
	var best_mount := ""
	var best_type := ""
	for line in FileAccess.get_file_as_string("/proc/mounts").split("\n", false):
		var fields := line.split(" ", false)
		if fields.size() < 3:
			continue
		var mount := fields[1].replace("\\040", " ")
		var inside := absolute == mount or absolute.begins_with(mount.trim_suffix("/") + "/")
		if inside and mount.length() > best_mount.length():
			best_mount = mount
			best_type = fields[2]
	return best_type if VOLATILE_FS.has(best_type) else ""


static func _absolute(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.contains("://") else path


# -- Ownership ----------------------------------------------------------------

static func admit(db: DocketDB) -> String:
	## Claim a just-opened project for this process when it is session_file.
	## Returns "" to proceed, or the refusal text naming the current owner.
	if mode_of(db) != MODE_SESSION_FILE:
		return ""
	var path := db.get_path()
	var placement := path_error(path)
	if not placement.is_empty():
		return placement
	var lock := FileLock.acquire(path + OWNER_SUFFIX)
	if lock == null:
		return "Refused: could not lock the owner record of %s; another Docket server is claiming it now." % path
	var owner := read_owner(path)
	var pid := int(owner.get("pid", 0))
	if pid > 0 and pid != OS.get_process_id() and FileLock.is_pid_running(pid):
		lock.release()
		return owner_refusal(path, owner)
	var error := _write_owner(path)
	lock.release()
	if error.is_empty() and not _held.has(path):
		_held.append(path)
	return error


static func release(path: String) -> void:
	## Drop this process's claim on `path`; a record owned by another pid is left alone.
	var index := _held.find(path)
	if index < 0:
		return
	_held.remove_at(index)
	if int(read_owner(path).get("pid", 0)) == OS.get_process_id():
		DirAccess.remove_absolute(_absolute(path + OWNER_SUFFIX))


static func release_all() -> void:
	for path in _held.duplicate():
		release(path)


static func set_endpoint(port: int) -> void:
	## Record the listening port in every claim this process holds.
	endpoint_port = port
	for path in _held:
		_write_owner(path)


static func read_owner(path: String) -> Dictionary:
	var owner_path := path + OWNER_SUFFIX
	if not FileAccess.file_exists(owner_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(owner_path))
	return parsed if parsed is Dictionary else {}


static func owner_refusal(path: String, owner: Dictionary) -> String:
	var port := int(owner.get("port", 0))
	var endpoint := "MCP at http://127.0.0.1:%d/mcp" % port if port > 0 else "no MCP endpoint"
	return "Refused: session project %s is owned by another Docket server: pid %d (%s, %s, since %s). Connect to that server instead of opening the file here." % [path, int(owner.get("pid", 0)), str(owner.get("role", "?")), endpoint, str(owner.get("claimed_at", "?"))]


static func _write_owner(path: String) -> String:
	var f := FileAccess.open(path + OWNER_SUFFIX, FileAccess.WRITE)
	if f == null:
		return "Refused: could not write the owner record for %s (%s)." % [path, error_string(FileAccess.get_open_error())]
	f.store_string(JSON.stringify({"pid": OS.get_process_id(), "role": role, "port": endpoint_port, "claimed_at": Time.get_datetime_string_from_system(true)}))
	f.close()
	return ""


# -- Contents -----------------------------------------------------------------

static func outstanding_items(db: DocketDB) -> Array[Dictionary]:
	## Items not in a terminal status of their pinned state machine. An item whose
	## semantics cannot be resolved counts as outstanding.
	var registry := TypeRegistry.for_db(db, db.get_project_name())
	var result: Array[Dictionary] = []
	for item: Dictionary in db.execute_query({}):
		var resolved := registry.resolve_item(item)
		if resolved.has("error") or not bool(resolved.get("is_terminal", false)):
			result.append({"id": item.get("id", ""), "type": item.get("type", ""), "status": item.get("status", ""), "title": item.get("title", "")})
	return result


static func discard_files(path: String) -> String:
	## Remove a closed session_file project's canonical file and its cache family.
	var cache_error := JSONLCache.delete_cache_family(path)
	if not cache_error.is_empty():
		return cache_error
	var absolute := _absolute(path)
	if FileAccess.file_exists(absolute) and DirAccess.remove_absolute(absolute) != OK:
		return "could not delete %s" % absolute
	return ""
