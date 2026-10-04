extends RefCounted
class_name DocketRuntimeState
## Process-owned state, configured before any schema, DB or GUI is loaded.
## Project files/caches retain their existing multi-owner locations.

static var directory: String = ""
static var restore_session: bool = false
static var stdio: bool = false
static var hosted: bool = false


static func prepare_shutdown() -> void:
	# Renderer teardown diagnostics must not follow the final protocol frame.
	if stdio:
		Engine.print_to_stdout = false


static func quit(tree: SceneTree, exit_code: int = 0) -> void:
	prepare_shutdown()
	tree.quit(exit_code)


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
	return not hosted and (directory.is_empty() or restore_session)
