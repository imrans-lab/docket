extends RefCounted
class_name DocketRuntimeState
## Process-owned state, configured before any schema, DB or GUI is loaded.
## Project files/caches retain their existing multi-owner locations.

static var directory: String = ""
static var restore_session: bool = false


static func configure(path: String, restore: bool) -> String:
	if not path.is_empty():
		if not path.is_absolute_path() or path.contains("://"):
			return "--state-dir must be a private absolute filesystem directory"
		var error := DirAccess.make_dir_recursive_absolute(path)
		if error != OK:
			return "Cannot create --state-dir: %s" % error_string(error)
	directory = path
	restore_session = restore
	return ""


static func path_for(default_path: String) -> String:
	return default_path if directory.is_empty() else directory.path_join(default_path.get_file())


static func may_restore_session() -> bool:
	return directory.is_empty() or restore_session
