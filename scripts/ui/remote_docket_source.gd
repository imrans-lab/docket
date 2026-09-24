extends "res://scripts/ui/docket_source.gd"
## The DocketSource of a host that embeds the Docket UI (such as Minerva):
## the projects live in a separate Docket process that the host reaches over
## MCP, and every call here is one or more of that process's tools.
##
## `connection` is the host's link to that process. It needs one method,
## awaited: call_tool(name: String, arguments: Dictionary) -> Dictionary,
## answering with the MCP tools/call result ({content: [{text}], isError}), or
## {error} when the call itself failed. It may also offer list_tools() ->
## Array (the MCP tools/list entries), for tool_count. The host passes each
## item_changed notification the process sends to handle_host_event, and
## awaits start() before showing the UI.
##
## Methods with no exact tool yet answer UNSUPPORTED (see DocketSource),
## including every item write, attachments and the vault.

var _connection
var _prefs
# The open projects as docket_project_list reported them: [{name, path,
# primary}], sorted by name.
var _projects: Array = []
# Per project, all its types with definitions, deprecated ones included (as
# get_type finds them). Refreshed with _projects by start, project changes and
# reloads, and per project by this source's own type writes; changes another
# client makes to types or projects show only after one of those.
var _types: Dictionary = {}
# Per project, the number of the latest type read started (_refresh_types).
var _type_reads: Dictionary = {}
var _schema: Dictionary = {}
# A snapshot refresh is running, or another was asked for meanwhile.
var _refreshing := false
var _refresh_again := false
var _refresh_error := ""

## A snapshot refresh (and any asked for while it ran) finished.
signal _snapshot_refreshed


## `prefs` is the host's per-person settings on this machine, as UserPrefs:
## get_display_name() for authorship, and has_ui_setting(key),
## load_ui_setting(key, default) and save_ui_setting(key, value) for display
## settings (without these, display settings are not kept).
func _init(connection, prefs) -> void:
	_connection = connection
	_prefs = prefs


## Read the open projects and their types: "" or why the process could not
## be read.
func start() -> String:
	var schema_text := FileAccess.get_file_as_string("res://data/schema.json")
	var parsed = JSON.parse_string(schema_text)
	_schema = parsed if parsed is Dictionary else {}
	return await _refresh_snapshot()


## A minerva/plugin_event item_changed payload ({project, id, change, event})
## from the Docket process.
func handle_host_event(payload: Dictionary) -> void:
	if str(payload.get("change", "")) == "reloaded":
		await _refresh_snapshot()
	data_changed.emit()


# -- Calls ----------------------------------------------------------------------

## Call tool `name`: its decoded result, or {error}.
func _call(name: String, arguments: Dictionary) -> Dictionary:
	var reply: Dictionary = await _connection.call_tool(name, arguments)
	return decode_tool_result(reply)


## An MCP tools/call result as the tool's own result: the JSON text of its
## first content block or, when isError is set, the whole error result from
## _meta if present, else {error} with the text.
static func decode_tool_result(reply: Dictionary) -> Dictionary:
	if reply.has("error"):
		var error = reply.error
		var message := str(error.get("message", error)) if error is Dictionary else str(error)
		return {"error": message if not message.is_empty() else "Docket could not be reached"}
	var content = reply.get("content")
	var text := ""
	if content is Array and not content.is_empty() and content[0] is Dictionary:
		text = str(content[0].get("text", ""))
	if bool(reply.get("isError", false)):
		# Mirrors McpHandler.ERROR_RESULT_META; the literal keeps the UI free of
		# a dependency on the MCP server code.
		var meta = reply.get("_meta")
		var whole = meta.get("docket/result") if meta is Dictionary else null
		if whole is Dictionary and not str(whole.get("error", "")).is_empty():
			return whole
		return {"error": text if not text.is_empty() else "Docket reported an error without a message"}
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {"error": "unreadable reply from Docket: %s" % text.left(200)}


func _error_text(result: Dictionary) -> String:
	return str(result.get("error", ""))


# -- Projects -------------------------------------------------------------------

## Read the open projects and their types again: "" or why not. Requests
## made while one runs wait for one more run after it.
func _refresh_snapshot() -> String:
	if _refreshing:
		_refresh_again = true
		await _snapshot_refreshed
		return _refresh_error
	_refreshing = true
	_refresh_error = await _read_snapshot()
	while _refresh_again:
		_refresh_again = false
		_refresh_error = await _read_snapshot()
	_refreshing = false
	_snapshot_refreshed.emit()
	return _refresh_error


## Read the project list, then each project's types (_refresh_types): "" or
## why not, including any project whose types could not be read.
func _read_snapshot() -> String:
	var listed := await _call("docket_project_list", {})
	if listed.has("error"):
		return str(listed.error)
	var projects: Array = listed.get("projects", [])
	projects.sort_custom(func(a, b) -> bool: return str(a.name).nocasecmp_to(str(b.name)) < 0)
	_projects = projects
	for name in _types.keys():
		if not project_names().has(name):
			_types.erase(name)
	var problems: Array[String] = []
	for name in project_names():
		var read := await _refresh_types(name)
		if read.has("error"):
			problems.append(str(read.error))
	return "; ".join(problems)


## Every type of `project` with its definition: {types} or {error}.
func _read_types(project: String) -> Dictionary:
	var listed := await _call("docket_type_list", {"project": project, "include_deprecated": true})
	if listed.has("error"):
		return listed
	var types: Array = []
	for summary in listed.get("types", []):
		var type := await _call("docket_type_get", {"project": project, "type": str(summary.get("slug", ""))})
		if type.has("error"):
			return {"error": "Type %s of %s could not be read: %s" % [summary.get("slug", ""), project, type.error]}
		types.append(type)
	return {"types": types}


## Read `project`'s types and keep them, unless another read of the same
## project started after this one (whether or not it succeeds), or this one
## failed (the project keeps what was read before): {types} or {error}.
func _refresh_types(project: String) -> Dictionary:
	var ticket: int = _type_reads.get(project, 0) + 1
	_type_reads[project] = ticket
	var read := await _read_types(project)
	if not read.has("error") and _type_reads.get(project, 0) == ticket and project_names().has(project):
		_types[project] = read.types
	return read


func project_names() -> Array[String]:
	var names: Array[String] = []
	for project in _projects:
		names.append(str(project.name))
	return names


func primary_project() -> String:
	for project in _projects:
		if bool(project.get("primary", false)):
			return str(project.name)
	return ""


func primary_path() -> String:
	for project in _projects:
		if bool(project.get("primary", false)):
			return str(project.get("path", ""))
	return ""


func project_paths() -> Dictionary:
	var paths := {}
	for project in _projects:
		paths[str(project.name)] = str(project.get("path", ""))
	return paths


## Answered by the connection's optional list_tools() (the MCP tools/list
## entries); 0 when it has none.
func tool_count() -> int:
	if not _connection.has_method("list_tools"):
		return 0
	var tools: Array = await _connection.list_tools()
	return tools.size()


## Kept in the host's per-machine prefs. A value not stored there yet is taken
## once from the primary project's file, where earlier versions kept it.
func ui_setting(key: String, default_value: String) -> String:
	if not _prefs.has_method("has_ui_setting"):
		return default_value
	if _prefs.has_ui_setting(key):
		return _prefs.load_ui_setting(key, default_value)
	var primary := primary_project()
	if primary.is_empty():
		return default_value
	var meta := await _call("docket_project_meta", {"action": "get", "project": primary})
	if _prefs.has_ui_setting(key):  # the user set it while the file was read
		return _prefs.load_ui_setting(key, default_value)
	var inherited := str(meta.get("display", {}).get(key, "")) if meta.get("display") is Dictionary else ""
	if inherited.is_empty():
		return default_value
	_prefs.save_ui_setting(key, inherited)
	return inherited


func set_ui_setting(key: String, value: String) -> void:
	if _prefs.has_method("save_ui_setting"):
		_prefs.save_ui_setting(key, value)


func prefs():
	return _prefs


func schema() -> Dictionary:
	return _schema


## Replace the open projects with the one at `path` (kept if already open):
## it is opened first, as the process refuses to close its last project.
func open_project(path: String) -> void:
	var keep := ""
	var paths := project_paths()
	for name in paths:
		if paths[name] == path:
			keep = name
	if keep.is_empty():
		var added := await _call("docket_project_add", {"path": path})
		if added.has("error"):
			load_failed.emit(path, str(added.error))
			return
		keep = str(added.get("name", ""))
	var still_open: Array[String] = []
	for name in paths:
		if name != keep:
			var removed := await _call("docket_project_remove", {"name": name})
			if removed.has("error"):
				still_open.append("%s (%s)" % [name, removed.error])
	if not still_open.is_empty():
		load_failed.emit(path, "Opened, but these projects could not be closed: %s" % ", ".join(still_open))
	await _projects_changed(path)


func add_project(path: String) -> void:
	var added := await _call("docket_project_add", {"path": path})
	if added.has("error"):
		load_failed.emit(path, str(added.error))
		return
	await _projects_changed(path)


func create_project(path: String) -> void:
	var added := await _call("docket_project_add", {"path": path, "create": true})
	if added.has("error"):
		load_failed.emit(path, str(added.error))
		return
	await _projects_changed(path)


## Unlike the standalone app, the process refuses to close its last project;
## the refusal is reported as a load_failed for its path.
func remove_project(project: String) -> void:
	var path := str(project_paths().get(project, project))
	var removed := await _call("docket_project_remove", {"name": project})
	if removed.has("error"):
		load_failed.emit(path, "Could not close %s: %s" % [project, removed.error])
	await _projects_changed(path)


## Re-read the snapshot after a change to the project set made for `path`,
## reporting a failed read as a load_failed for it.
func _projects_changed(path: String) -> void:
	var error := await _refresh_snapshot()
	if not error.is_empty():
		load_failed.emit(path, "Docket's projects could not be fully read: %s" % error)
	file_changed.emit()


func save_all() -> void:
	await _call("docket_flush", {})


## The process reports each reloaded project as a host event, which refreshes
## the snapshot.
func reload_all() -> Array:
	var reloaded := await _call("docket_reload", {})
	return reloaded.get("reloaded", [])


# -- Items --------------------------------------------------------------------------

func _get_item(project: String, id: String, include: Array) -> Dictionary:
	return await _call("docket_get", {"id": id, "project": project, "include": include})


func item_view(project: String, id: String, refresh: bool = false) -> Dictionary:
	if id.is_empty() or not project_names().has(project):
		return {"error": "the originating project is closed", "kind": "closed"}
	return await _call("docket_item_view", {"id": id, "project": project, "refresh": refresh})


func item_token(project: String, id: String) -> String:
	var view := await item_view(project, id)
	return "" if view.has("error") else str(view.get("token", ""))


func item_title(project: String, id: String) -> Dictionary:
	var item := await _get_item(project, id, [])
	return {} if item.has("error") else {"title": str(item.get("title", ""))}


func item_events(project: String, id: String) -> Array:
	var item := await _get_item(project, id, ["events"])
	return [] if item.has("error") else item.get("events", [])


## Items whose parent is `qualified_id` ("project:id") in every open project;
## a bare parent id counts only in the parent's own project, as in the
## standalone app.
func children_of(qualified_id: String) -> Array:
	var separator := qualified_id.find(":")
	var owner := qualified_id.left(separator) if separator > 0 else ""
	var bare_id := qualified_id.substr(separator + 1) if separator > 0 else qualified_id
	var children: Array = []
	for project in project_names():
		var parents: Array = [{"field": "parent", "op": "eq", "value": qualified_id}]
		if owner.is_empty() or project == owner:
			parents.append({"field": "parent", "op": "eq", "value": bare_id})
		var listed := await _call("docket_query", {"project": project, "filter": {"$or": parents}, "detail": "full"})
		for item in listed.get("items", []):
			item["project"] = project
			children.append(item)
	return children


func run_query(query: Dictionary) -> Dictionary:
	return await _call("docket_query_view", query)


func move_item(project: String, id: String, target_project: String) -> Dictionary:
	return await _call("docket_move", {"id": id, "source_project": project, "target_project": target_project})


# -- Comments -------------------------------------------------------------------------

func list_comments(project: String, id: String) -> Array:
	var listed := await _call("docket_comment", {"action": "list", "item_id": id, "project": project})
	return [] if listed.has("error") else listed.get("comments", [])


func add_comment(project: String, id: String, author: String, text: String, parent_id: int = 0) -> Dictionary:
	if parent_id > 0:
		return await _call("docket_comment", {"action": "reply", "comment_id": parent_id, "text": text,
			"author": author, "project": project})
	return await _call("docket_comment", {"action": "add", "item_id": id, "text": text, "author": author,
		"project": project})


func resolve_comment(project: String, comment_id: int, resolution: String, by: String) -> Dictionary:
	var action := "accept" if resolution == "accepted" else "reject"
	return await _call("docket_comment", {"action": action, "comment_id": comment_id, "addressed_by": by,
		"project": project})


# -- Type snapshot ---------------------------------------------------------------------

func cached_types(project: String) -> Array:
	return _not_deprecated(_all_types(project))


static func _not_deprecated(types: Array) -> Array:
	return types.filter(func(type) -> bool: return str(type.get("lifecycle", "")) != "deprecated")


func _all_types(project: String) -> Array:
	return _types.get(project if not project.is_empty() else primary_project(), [])


func cached_type(project: String, slug: String) -> Dictionary:
	for type in _all_types(project):
		if str(type.get("slug", "")) == slug:
			return type
	return {"error": "unknown type '%s' in %s" % [slug, project]}


# -- Type registry --------------------------------------------------------------

func resolve_type_ref(project: String, type_ref: String) -> Dictionary:
	return await _call("docket_type_get", {"project": project, "type": type_ref})


func get_type(project: String, slug: String) -> Dictionary:
	return await resolve_type_ref(project, slug)


func list_types(project: String) -> Dictionary:
	var read := await _refresh_types(project)
	if read.has("error"):
		return read
	return {"types": _not_deprecated(read.types)}


func types_problem(project: String) -> String:
	if project.is_empty():
		return "Open a project first."
	return _error_text(await _call("docket_type_list", {"project": project}))


func types_overview(project: String, include_deprecated: bool) -> Dictionary:
	if project.is_empty():
		return {"error": "Open a project to manage its types.", "kind": "no_project"}
	if not project_names().has(project):
		return {"error": "The selected project is no longer open.", "kind": "closed"}
	return await _call("docket_type_overview", {"project": project, "include_deprecated": include_deprecated})


func type_catalog() -> Dictionary:
	if _projects.is_empty():
		return {"records": TypeCatalog.from_schema(_schema), "diagnostic": ""}
	var names := project_names()
	names.sort()
	var records: Array = []
	var diagnostic := ""
	for project in names:
		var overview := await _call("docket_type_overview", {"project": project, "include_deprecated": true})
		var catalog: Dictionary = {"records": [], "error": str(overview.get("reason", overview.get("error", "")))}
		if not overview.has("error"):
			catalog = TypeCatalog.from_descriptors(project, overview.types, overview.counts)
		if str(catalog.error).is_empty():
			records.append_array(catalog.records)
		else:
			diagnostic = "Type catalog unavailable for %s: %s" % [project, catalog.error]
	return {"records": TypeCatalog.sorted(records), "diagnostic": diagnostic}


func type_with_history(project: String, slug: String) -> Dictionary:
	if project.is_empty() or not project_names().has(project):
		return {"error": "Open a project before selecting a type."}
	return await _call("docket_type_get", {"project": project, "type": slug, "history": true})


func validate_type_definition(project: String, definition: Dictionary) -> String:
	var problem := await types_problem(project)
	if not problem.is_empty():
		return problem
	return _error_text(await _call("docket_type_validate", {"project": project,
		"slug": str(definition.get("slug", "")), "definition": definition, "as_stored": true}))


func type_revision(project: String, revision_id: String) -> Dictionary:
	return await _call("docket_type_get", {"project": project, "revision": revision_id})


func preview_type_evolution(project: String, slug: String, definition: Dictionary,
		expected_revision: String, item_ids: Array) -> Dictionary:
	return await _call("docket_type_evolve", {"project": project, "type": slug, "definition": definition,
		"expected_revision": expected_revision, "item_ids": item_ids})


func define_type(project: String, slug: String, definition: Dictionary, author: String,
		reason: String) -> Dictionary:
	var defined := await _call("docket_type_define", {"project": project, "slug": slug, "definition": definition,
		"author": author, "reason": reason})
	await _refresh_types(project)
	return defined


## Apply a preview_type_evolution result; the process checks it again against
## the current revision before writing.
func apply_type_evolution(project: String, preview: Dictionary, author: String, reason: String) -> String:
	var applied := await _call("docket_type_evolve", {"project": project, "type": str(preview.get("slug", "")),
		"definition": preview.get("definition", {}), "expected_revision": str(preview.get("expected_current", "")),
		"item_ids": preview.get("items", []), "apply": true, "author": author, "reason": reason})
	await _refresh_types(project)
	return _error_text(applied)


func set_type_lifecycle(project: String, slug: String, lifecycle: String, expected_revision: String,
		author: String, reason: String) -> String:
	var changed := await _call("docket_type_activate", {"project": project, "type": slug,
		"action": "activate" if lifecycle == "active" else "deprecate", "expected_revision": expected_revision,
		"author": author, "reason": reason})
	await _refresh_types(project)
	return _error_text(changed)
