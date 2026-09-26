extends RefCounted
class_name DocketProjectAdd


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_add",
		"description": "Load a docket project by file path. Creates the file if it doesn't exist and create=true. mode=session_file makes a project outside any Git checkout (default path under the user's Docket data dir), owned by one server at a time. mode=memory (with name) makes a project with no file that lives in this server while an owner-class client holds the lease; it is bounded by max_items and spilled to a session file when the lease lapses.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "Absolute path to the .dct file. Optional for mode=session_file (defaults to <user data dir>/docket/sessions/<name>.dct)"},
				"create": {"type": "boolean", "description": "Create file if missing (default false)"},
				"mode": {"type": "string", "enum": SessionProject.MODES, "description": "Storage mode: durable (default, an ordinary project file), session_file (outside any Git checkout) or memory (no file)"},
				"name": {"type": "string", "description": "Project name for a new session_file or memory project; names the default path"},
				"max_items": {"type": "integer", "description": "mode=memory only: item limit (default 1000); creating past it is refused"},
			},
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, project_dbs: Dictionary, add_fn: Callable = Callable(), _remove_fn: Callable = Callable()) -> Dictionary:
	var path: String = str(args.get("path", ""))
	var create: bool = args.get("create", false) == true
	var mode: String = str(args.get("mode", ""))
	var proj_name: String = str(args.get("name", ""))

	if not mode.is_empty() and not SessionProject.MODES.has(mode):
		return {"error": "mode must be one of %s" % str(SessionProject.MODES)}
	if mode == SessionProject.MODE_MEMORY:
		return _add_memory(proj_name, int(args.get("max_items", DocketDBMemory.DEFAULT_MAX_ITEMS)), project_dbs, add_fn)
	if path.is_empty() and mode == SessionProject.MODE_SESSION_FILE and not proj_name.is_empty():
		path = SessionProject.default_path(proj_name)
	if path.is_empty():
		return {"error": "path is required (or mode=session_file with name)"}

	# Check if already loaded
	for loaded_name in project_dbs:
		var pdb: DocketDB = project_dbs[loaded_name]
		if pdb.get_path() == path:
			return {"error": "Project already loaded: %s" % loaded_name}

	if mode == SessionProject.MODE_SESSION_FILE:
		var placement := SessionProject.path_error(path)
		if not placement.is_empty():
			return {"error": placement}

	if FileAccess.file_exists(path):
		var recorded := _recorded_mode(path)
		if not mode.is_empty() and mode != recorded:
			return {"error": "%s already exists as a %s project; its storage mode is fixed at creation" % [path, recorded]}
	elif not create:
		return {"error": "File not found: %s (pass create=true to create)" % path}
	elif mode == SessionProject.MODE_SESSION_FILE:
		var seeded := _create_session_file(path, proj_name)
		if not seeded.is_empty():
			return {"error": seeded}

	if not add_fn.is_valid():
		return {"error": "Project management not available in this mode"}

	return add_fn.call(path)


func _add_memory(proj_name: String, max_items: int, project_dbs: Dictionary, add_fn: Callable) -> Dictionary:
	if proj_name.is_empty():
		return {"error": "name is required for mode=memory"}
	if project_dbs.has(proj_name):
		return {"error": "Project already loaded: %s" % proj_name}
	if max_items < 1:
		return {"error": "max_items must be at least 1"}
	var refusal := MemoryProject.creation_refusal()
	if not refusal.is_empty():
		return {"error": refusal}
	if not add_fn.is_valid():
		return {"error": "Project management not available in this mode"}
	var added: Dictionary = add_fn.call(DocketDBMemory.PATH_SCHEME + proj_name)
	if added.has("error"):
		return added
	var memory_db := project_dbs.get(str(added.get("name", proj_name))) as DocketDBMemory
	if memory_db == null:
		return {"error": "Memory project did not load: %s" % proj_name}
	memory_db.max_items = max_items
	added["usage"] = memory_db.usage()
	return added


func _create_session_file(path: String, proj_name: String) -> String:
	## Writes the new file with its mode recorded, so every server that opens it
	## sees session_file before admitting it.
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var created := DocketDBJsonl.create_new_jsonl(path)
	if created == null:
		return "Failed to create: %s" % path
	var error := created.set_meta_value_checked(SessionProject.META_KEY, SessionProject.MODE_SESSION_FILE)
	if error.is_empty() and not proj_name.is_empty():
		error = created.set_project_name_checked(proj_name)
	created.close()
	return error


func _recorded_mode(path: String) -> String:
	if JSONLMigration.detect_format(path) != "jsonl":
		return SessionProject.MODE_DURABLE
	var meta: Dictionary = JSONLParser.parse_file(path).get("meta", {})
	var stored := str(meta.get(SessionProject.META_KEY, ""))
	return stored if SessionProject.MODES.has(stored) else SessionProject.MODE_DURABLE
