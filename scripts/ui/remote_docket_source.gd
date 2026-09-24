extends "res://scripts/ui/docket_source.gd"
## The DocketSource of a host that embeds the Docket UI (such as Minerva):
## the projects live in a separate Docket process that the host reaches over
## MCP, and every call here is one or more of that process's tools.
##
## `connection` is the host's link to that process. It needs one method,
## awaited: call_tool(name: String, arguments: Dictionary) -> Dictionary,
## answering with the MCP tools/call result ({content: [{text}], isError}), or
## {error} when the call itself failed. The host passes each item_changed
## notification the process sends to handle_host_event, and awaits start()
## before showing the UI.
##
## Methods with no exact tool yet answer UNSUPPORTED (see DocketSource),
## including every item write and the vault.

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
var _schema: Dictionary = {}
# A snapshot refresh is running, or another was asked for meanwhile.
var _refreshing := false
var _refresh_again := false
var _refresh_error := ""

## A snapshot refresh (and any asked for while it ran) finished.
signal _snapshot_refreshed


## `prefs` answers get_display_name() for authorship (as UserPrefs does).
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
## first content block, or {error} with the text when isError is set.
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


func _read_snapshot() -> String:
	var listed := await _call("docket_project_list", {})
	if listed.has("error"):
		return str(listed.error)
	var projects: Array = listed.get("projects", [])
	projects.sort_custom(func(a, b) -> bool: return str(a.name).nocasecmp_to(str(b.name)) < 0)
	var types := {}
	for project in projects:
		var read := await _read_types(str(project.name))
		# A project whose types cannot be read keeps what was read before.
		types[str(project.name)] = read.get("types", _types.get(str(project.name), []))
	_projects = projects
	_types = types
	return ""


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


func _refresh_types(project: String) -> Dictionary:
	var read := await _read_types(project)
	if not read.has("error"):
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
	for name in paths:
		if name != keep:
			await _call("docket_project_remove", {"name": name})
	await _projects_changed()


func add_project(path: String) -> void:
	var added := await _call("docket_project_add", {"path": path})
	if added.has("error"):
		load_failed.emit(path, str(added.error))
		return
	await _projects_changed()


func create_project(path: String) -> void:
	var added := await _call("docket_project_add", {"path": path, "create": true})
	if added.has("error"):
		load_failed.emit(path, str(added.error))
		return
	await _projects_changed()


## Unlike the standalone app, the process refuses to close its last project,
## which then stays open.
func remove_project(project: String) -> void:
	await _call("docket_project_remove", {"name": project})
	await _projects_changed()


func _projects_changed() -> void:
	await _refresh_snapshot()
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


func item_title(project: String, id: String) -> Dictionary:
	var item := await _get_item(project, id, [])
	return {} if item.has("error") else {"title": str(item.get("title", ""))}


func item_events(project: String, id: String) -> Array:
	var item := await _get_item(project, id, ["events"])
	return [] if item.has("error") else item.get("events", [])


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
	return _all_types(project).filter(func(type) -> bool: return str(type.get("lifecycle", "")) != "deprecated")


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
	return read if read.has("error") else {"types": cached_types(project)}


func types_problem(project: String) -> String:
	if project.is_empty():
		return "Open a project first."
	return _error_text(await _call("docket_type_list", {"project": project}))


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
