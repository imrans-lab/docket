extends RefCounted
class_name ToolRegistry
## Maps tool names to handlers. Generates MCP schemas.

var _schema: Dictionary
var _db: DocketDB
var _project_dbs: Dictionary = {}  # selector → DocketDB (ProjectSelectors)
var _type_registries: Dictionary = {}  # selector → project-owned semantics
var _type_registry_diagnostics: Dictionary = {}
var _tools: Dictionary = {}
var add_project_fn: Callable  # func(path: String) -> Dictionary
var remove_project_fn: Callable  # func(name: String) -> Dictionary
var gui_open_fn: Callable  # func(request: Dictionary) -> Dictionary


func _build_tools() -> Dictionary:
	return {
		"docket_create": DocketCreate.new(),
		"docket_get": DocketGet.new(),
		"docket_update": DocketUpdate.new(),
		"docket_transition": DocketTransition.new(),
		"docket_query": DocketQuery.new(),
		"docket_link": DocketLink.new(),
		"docket_context": DocketContext.new(),
		"docket_saved_query": DocketSavedQuery.new(),
		"docket_hint_set": DocketHintSet.new(),
		"docket_hint_get": DocketHintGet.new(),
		"docket_hint_query": DocketHintQuery.new(),
		"docket_attach": DocketAttach.new(),
		"docket_detach": DocketDetach.new(),
		"docket_comment": DocketComment.new(),
		"docket_move": DocketMove.new(),
		"docket_mirror": DocketMirror.new(),
		"docket_delete": DocketDelete.new(),
		"docket_transition_report": DocketTransitionReport.new(),
		"docket_error_report": DocketErrorReport.new(),
		"docket_secret_get": DocketSecretGet.new(),
		"docket_secret_set": DocketSecretSet.new(),
		"docket_secret_list": DocketSecretList.new(),
		"docket_secret_delete": DocketSecretDelete.new(),
		"docket_secret_promote": DocketSecretPromote.new(),
		"docket_project_list": DocketProjectList.new(),
		"docket_project_add": DocketProjectAdd.new(),
		"docket_project_remove": DocketProjectRemove.new(),
		"docket_gui_open": DocketGuiOpen.new(),
		"docket_get_state_machine": DocketGetStateMachine.new(),
		"docket_quality": DocketQuality.new(),
		"docket_project_meta": DocketProjectMeta.new(),
		"docket_skill_list": DocketSkillList.new(),
		"docket_skill_get": DocketSkillGet.new(),
		"docket_reload": DocketReload.new(),
		"docket_flush": DocketFlush.new(),
		"docket_validate": DocketValidate.new(),
		"docket_audit_log": DocketAuditLog.new(),
		"docket_type_list": DocketTypeList.new(),
		"docket_type_get": DocketTypeGet.new(),
		"docket_type_validate": DocketTypeValidate.new(),
		"docket_type_define": DocketTypeDefine.new(),
		"docket_type_activate": DocketTypeActivate.new(),
		"docket_type_evolve": DocketTypeEvolve.new(),
		"docket_item_view": DocketItemView.new(),
		"docket_query_view": DocketQueryView.new(),
		"docket_type_overview": DocketTypeOverview.new(),
	}


## The arguments that name a project, resolved to its selector before a tool
## runs.
const _PROJECT_ARGUMENTS := ["project", "source_project", "target_project"]


func init(schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> void:
	_schema = schema
	_db = db
	_project_dbs = project_dbs
	_rebuild_type_registries()
	_tools = _build_tools()
	_init_schema_dependent_tools(schema)


func update_db(schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> void:
	_schema = schema
	_db = db
	_project_dbs = project_dbs
	_rebuild_type_registries()
	_tools = _build_tools()
	_init_schema_dependent_tools(schema)

func _rebuild_type_registries() -> void:
	_type_registries.clear()
	_type_registry_diagnostics.clear()
	for project in _project_dbs:
		_type_registries[project] = TypeRegistry.for_db(_project_dbs[project], str(project))
	if _db != null and not _db in _project_dbs.values():
		var project_name := _db.get_project_name()
		_type_registries[project_name] = TypeRegistry.for_db(_db, project_name)

## The open project named `project_name`, or null.
func project_db(project_name: String) -> DocketDB:
	return _project_dbs.get(project_name)


func get_type_registry(project_name: String) -> TypeRegistry:
	var registry: TypeRegistry = _type_registries.get(project_name)
	if registry != null:
		var error: String = registry.refresh_if_changed()
		if error.is_empty(): _type_registry_diagnostics.erase(project_name)
		else: _type_registry_diagnostics[project_name] = error
	return registry

func get_type_registry_diagnostics() -> Dictionary:
	return _type_registry_diagnostics.duplicate(true)


func has_tool(name: String) -> bool:
	return _tools.has(name)


func list_tools() -> Array:
	var result: Array = []
	for tool_name in _tools:
		result.append(_tools[tool_name].get_definition())
	return result


const _ID_FIELDS := ["id", "item_id", "from", "to", "source_id", "target_id"]


## The tools that work with no project open; any other then answers
## {error, kind: "no_project"}.
const _WITHOUT_PROJECT := ["docket_project_list", "docket_project_add", "docket_project_remove",
	"docket_reload", "docket_flush"]
## Whether the last project may be closed, leaving none (a host-managed server).
var allow_no_project := false


## The tools that can run within a caller's coordination operation (`op` of
## call_tool); any other opens its own.
const _WITHIN_OPERATION := ["docket_comment", "docket_move", "docket_type_evolve"]


## Tool `name` with `arguments`: its result, or {error}. `op`, for a tool in
## _WITHIN_OPERATION, is the operation of the request it serves, its changes
## being made within it.
func call_tool(name: String, arguments: Dictionary, op: RefCounted = null) -> Dictionary:
	if not _tools.has(name):
		var err := {"error": "Unknown tool: %s" % name}
		_log_error(name, arguments, err)
		return err
	# Pick up external edits (git pull, another Docket instance) before doing
	# anything, and answer nothing from a cache that is not its file as it is
	# (ProjectAdmission): the next write would rewrite the file from it. Only
	# the tools that list, open, close or reread projects run without.
	if name in _WITHOUT_PROJECT:
		refresh_stale_dbs()
		return _dispatch(name, arguments, op)
	var admitted := admit(func(_reloaded: Array) -> Dictionary: return _dispatch(name, arguments, op), op)
	if not admitted.has("refused"):
		return admitted
	var uerr: Dictionary = admitted.refused
	_log_error(name, arguments, uerr)
	return uerr


## `work` (called with the selectors read again, returning a Dictionary) run
## once every open project is admitted (ProjectAdmission), their type
## registries refreshed first: its value, or {refused: {error, kind,
## project, retryable}}.
func admit(work: Callable, op: RefCounted = null) -> Dictionary:
	var dbs := _admission_dbs()
	var admitted_work := func(reloaded: Array) -> Dictionary:
		_refresh_registries(dbs.keys(), reloaded)
		return work.call(reloaded)
	var access := ProjectAdmission.access(dbs, admitted_work, op)
	if access.ok:
		return access.value
	return {"refused": {"error": access.message, "kind": access.kind, "project": access.project, "retryable": access.retryable}}


# Every open database, a standalone one under its stored name.
func _admission_dbs() -> Dictionary:
	var dbs := _project_dbs.duplicate()
	if _db != null and not _db in _project_dbs.values():
		dbs[_db.get_project_name()] = _db
	return dbs


# The type registries of `admitted` projects follow their databases: one
# read again (`reloaded`) is reloaded, the others refreshed if their
# definitions changed.
func _refresh_registries(admitted: Array, reloaded: Array) -> void:
	for proj_name in admitted:
		var registry: TypeRegistry = _type_registries.get(proj_name)
		if registry == null: continue
		var error: String = registry.reload() if proj_name in reloaded else registry.refresh_if_changed()
		if error.is_empty(): _type_registry_diagnostics.erase(proj_name)
		else: _type_registry_diagnostics[proj_name] = error


func _dispatch(name: String, arguments: Dictionary, op: RefCounted) -> Dictionary:
	if _db == null and _project_dbs.is_empty() and not name in _WITHOUT_PROJECT:
		var nerr := {"error": "no project is open", "kind": "no_project"}
		_log_error(name, arguments, nerr)
		return nerr

	# The projects a request names, as their selectors: an unknown or
	# ambiguous name is refused rather than answered from another project.
	var bad_project := _resolve_project_args(arguments)
	if not bad_project.is_empty():
		var perr := {"error": bad_project}
		_log_error(name, arguments, perr)
		return perr

	# Pre-resolve short ID prefixes to full IDs before dispatching
	var id_err := _resolve_id_args(name, arguments)
	if not id_err.is_empty():
		var ierr := {"error": id_err}
		_log_error(name, arguments, ierr)
		return ierr
	# These tools need access to all project DBs for cross-project operations
	var execute_args: Array
	if name in ["docket_move", "docket_mirror", "docket_link"]:
		execute_args = [arguments, _schema, _db, _project_dbs]
	elif name.begins_with("docket_type_") or name in ["docket_saved_query", "docket_item_view"]:
		var typed_db: DocketDB = _resolve_db(arguments)
		execute_args = [arguments, _schema, typed_db, TypeRegistry.for_db(typed_db, _selector_of(typed_db))]
	elif name in ["docket_project_list", "docket_project_add", "docket_project_remove", "docket_project_meta",
			"docket_reload", "docket_flush", "docket_validate", "docket_audit_log"]:
		execute_args = [arguments, _schema, _db, _project_dbs, add_project_fn, remove_project_fn]
	elif name == "docket_query_view":
		execute_args = [arguments, _schema, _db, _project_dbs, get_type_registry]
	elif name == "docket_gui_open":
		execute_args = [arguments, _schema, _db, _project_dbs, gui_open_fn]
	else:
		execute_args = [arguments, _schema, _resolve_db(arguments)]
	if name in _WITHIN_OPERATION:
		execute_args.append(op)
	elif name == "docket_project_remove":
		execute_args.append(allow_no_project)
	var result: Dictionary = _tools[name].callv("execute", execute_args)
	if result.has("error"):
		_log_error(name, arguments, result)
	return result


func refresh_stale_dbs() -> Array:
	## Reload any JSONL-backed project whose file changed on disk, for those
	## that watch for it: the names reloaded. A project that is not ready is
	## refused again by the next admission; its registry is left as it was.
	var reloaded: Array = []
	var dbs := _admission_dbs()
	for proj_name in dbs:
		var access := ProjectAdmission.access({proj_name: dbs[proj_name]}, func(read_again: Array) -> Array:
			_refresh_registries([proj_name], read_again)
			return read_again)
		if not access.ok:
			_type_registry_diagnostics[proj_name] = str(access.message)
		else:
			reloaded.append_array(access.value)
	return reloaded


func _log_error(tool_name: String, args: Dictionary, result: Dictionary) -> void:
	if _db and _db.is_open():
		var arg_keys := ",".join(PackedStringArray(args.keys()))
		_db.log_mcp_error(tool_name, str(result.error), arg_keys)


func _resolve_id_args(tool_name: String, args: Dictionary) -> String:
	## Returns "" on success, or an error describing an ambiguous short ID.
	## Try to resolve short hex prefixes in ID fields to full IDs.
	var fields: Array = _ID_FIELDS.duplicate()
	# Transition targets and type references are domain keys, even when they look
	# like hexadecimal item prefixes.
	if tool_name == "docket_transition": fields.erase("to")
	if tool_name.begins_with("docket_type_"): fields.clear()
	for field in fields:
		if not args.has(field):
			continue
		var val: String = str(args[field])
		if val.is_empty():
			continue
		# Skip if it's already a full UUID7 or a known legacy ID
		if DocketDB._is_uuid7(val):
			continue
		# Skip legacy-format IDs (PREFIX-NNNN) — they use exact match
		if val.contains("-"):
			continue
		# Try resolving as a short hex prefix (min 4 chars)
		if val.length() >= 4 and val.is_valid_hex_number(false):
			# Collect every project that matches rather than stopping at the
			# first. Breaking early made an ambiguous prefix resolve to whichever
			# project happened to come first in iteration order — silently acting
			# on the wrong item, in the wrong project.
			var matches := {}  # full_id -> project name
			var requested_project: String = str(args.get("project", ""))
			if field == "source_id" or (tool_name == "docket_move" and field == "id"): requested_project = str(args.get("source_project", requested_project))
			elif field == "target_id": requested_project = str(args.get("target_project", requested_project))
			var candidates: Dictionary = _project_dbs
			if not requested_project.is_empty():
				candidates = {requested_project: _project_dbs[requested_project]} if _project_dbs.has(requested_project) else {}
			for proj_name in candidates:
				var pdb: DocketDB = candidates[proj_name]
				var r := pdb.resolve_short_id(val)
				if not r.is_empty():
					matches[r] = proj_name
			if matches.is_empty() and _db != null and requested_project.is_empty():
				var fallback := _db.resolve_short_id(val)
				if not fallback.is_empty():
					matches[fallback] = _db.get_project_name()

			if matches.size() > 1:
				var where: Array = []
				for full_id in matches:
					where.append("%s:%s" % [matches[full_id], full_id])
				where.sort()
				return ("Ambiguous ID '%s' — matches %d items: %s. Use a longer prefix or the full ID."
					% [val, matches.size(), ", ".join(PackedStringArray(where))])
			if matches.size() == 1:
				args[field] = matches.keys()[0]
	return ""


# The project `arguments` names (call_tool has made it a selector), or the
# primary when it names none.
func _resolve_db(arguments: Dictionary) -> DocketDB:
	var proj_name: String = str(arguments.get("project", ""))
	return _db if proj_name.is_empty() else _project_dbs.get(proj_name)


# The selector `db` is open under, or its stored name when it is not in the
# project map (a single-project caller's).
func _selector_of(db: DocketDB) -> String:
	for selector in _project_dbs:
		if _project_dbs[selector] == db:
			return str(selector)
	return db.get_project_name()


# Replaces each project argument with the selector it names
# (ProjectSelectors.resolve): "", or why one names no single open project.
func _resolve_project_args(arguments: Dictionary) -> String:
	for key in _PROJECT_ARGUMENTS:
		var asked := str(arguments.get(key, ""))
		if asked.is_empty():
			continue
		var resolved := ProjectSelectors.resolve(_project_dbs, asked)
		if resolved.has("error"):
			return str(resolved.error)
		arguments[key] = resolved.selector
	return ""


func _init_schema_dependent_tools(schema: Dictionary) -> void:
	## Initialize tools that need the schema for their definitions
	if _tools.has("docket_transition"):
		(_tools["docket_transition"] as DocketTransition).init(schema)
