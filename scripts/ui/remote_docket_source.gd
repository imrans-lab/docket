extends "docket_source.gd"
## The DocketSource of a host that embeds the Docket UI (such as Minerva):
## the projects live in a separate Docket process that the host reaches over
## MCP, and every call here is one or more of that process's tools.
##
## `connection` is the host's link to that process. It needs one method,
## awaited: call_tool(name: String, arguments: Dictionary, operation_id:
## String) -> Dictionary, answering with the MCP tools/call result ({content:
## [{text}], isError}), or {error} when the call itself failed. A host that
## runs the calls as this panel's (the process's private docket/panel/call,
## given the operation id of a change) offers panel_origin() -> String, the
## origin the process reports for this panel's changes ("panel:<panel>"),
## and answers a change with its operation id, the event stream and the
## event_watermark; without it no change is taken as this source's own. It may also offer list_tools() ->
## Array (the MCP tools/list entries), for tool_count. The host passes each
## item_changed notification the process sends to handle_host_event, and
## awaits start() before showing the UI.
##
## A person's edits do not go through the tools agents use: the host's
## connection may offer panel_call(method, params) -> Dictionary, awaited,
## for its private channel to the process (the docket/panel/ methods), adding
## the grant that names the person itself and answering the method's result
## or {error}: saving the shown item (update_item), moving it to another
## status (transition_item), attaching a file to it (attach_file) and
## creating a new item (create_item). Methods
## with no tool or panel method yet answer UNSUPPORTED (see DocketSource),
## including the vault, so a change carrying secret fields
## is refused, not made without them.

const TypeCatalog := preload("../core/type_catalog.gd")
const NO_CHANNEL := "Editing here needs the host's trusted panel channel, which this host does not provide."

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
# This source's changes: the operation ids of those still waiting for their
# reply, and of the last MAX_COMPLETED answered (whose events may come late).
var _pending_operations: Dictionary = {}
var _completed_operations: Array[String] = []
const MAX_COMPLETED := 64
# Changes made elsewhere are kept per project, as generations: every other
# client's change to a project, and every doubt (a stream seen for the first
# time, a gap in it, a restarted process, events a reply counted that never
# come), makes the project's dirty
# generation newer than its clean one. One worker (_work) looks at dirty
# projects one at a time while nothing holds it, and a project is clean up
# to a generation only once the open item was compared at it. A hold (a form
# settling its save, or one of this source's changes waiting for its reply)
# starts a new epoch: a lookup begun before it is dropped, not applied, and
# its project stays dirty.
var _dirty: Dictionary = {}
var _clean: Dictionary = {}
var _epoch := 0
var _holds := 0
var _working := false
# The worker is to read the snapshot again (a project reloaded, a restart).
var _refresh_due := false
# The shell's open item as {project, id, token}, or {} (watch_open_item).
var _open_item := Callable()
# "project<US>id" → the version of it last asked about (its token, or
# MISSING), so that one version is asked about once.
var _asked: Dictionary = {}
const MISSING := "<missing>"
# The process's event stream (a restart starts a new one) and the last event
# accounted for on it: received, or given up as lost (every project dirty).
var _stream := ""
var _received := 0
# "project<US>id" → the content token this source's last save of it committed.
var _committed_tokens: Dictionary = {}
# The item the host has bound this panel's edits to (item_shown): {project,
# id, binding} once the host has checked it, {} before or without one; and
# the number of the latest item_shown, so an older answer is ignored.
var _bound: Dictionary = {}
# Why the host would not bind the shown item, when it would not: {project,
# id, reason}.
var _bind_refusal: Dictionary = {}
var _showing := 0
var _binding := false
signal _bind_settled

## A snapshot refresh (and any asked for while it ran) finished.
signal _snapshot_refreshed


## `prefs` is the host's per-person settings on this machine, read only:
## get_display_name() for authorship (this source never writes them).
func _init(connection, prefs) -> void:
	_connection = connection
	_prefs = prefs


## Read the schema and the open projects and their types: "" or why not.
func start() -> String:
	# The schema ships beside the UI (data/ next to scripts/), wherever the
	# UI's files are.
	var schema_path: String = get_script().resource_path.get_base_dir().path_join("../../data/schema.json").simplify_path()
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(schema_path))
	if not parsed is Dictionary:
		return "the Docket schema could not be read at %s" % schema_path
	_schema = parsed
	return await _refresh_snapshot()


## A minerva/plugin_event item_changed payload ({project, id, change, event,
## cause, origin, operation_id, stream, sequence}) from the Docket process.
## A change this source made itself (a mutation from this panel's origin with
## one of its operation ids) only refreshes; any other makes its project
## dirty. A reloaded project has the snapshot read again.
func handle_host_event(payload: Dictionary) -> void:
	var operation := str(payload.get("operation_id", ""))
	var own: bool = (str(payload.get("cause", "")) == "mutation" and not _origin().is_empty()
		and str(payload.get("origin", "")) == _origin() and not operation.is_empty()
		and (_pending_operations.has(operation) or _completed_operations.has(operation)))
	_note_position(str(payload.get("stream", "")), int(payload.get("sequence", 0)))
	if str(payload.get("change", "")) == "reloaded":
		_refresh_due = true
	if not own:
		_mark_dirty(str(payload.get("project", "")))
	data_changed.emit()
	_work()


func watch_open_item(open_item: Callable) -> void:
	_open_item = open_item
	_work()


func stop_watching() -> void:
	_open_item = Callable()
	_epoch += 1


func hold_reconciliation() -> void:
	_holds += 1
	_epoch += 1


func release_reconciliation() -> void:
	_holds = maxi(0, _holds - 1)
	_work()


func committed_token(project: String, id: String) -> String:
	return str(_committed_tokens.get(_key(project, id), ""))


static func _key(project: String, id: String) -> String:
	return "%s\u001f%s" % [project, id]


func _mark_dirty(project: String) -> void:
	if not project.is_empty():
		_dirty[project] = int(_dirty.get(project, 0)) + 1


func _mark_all_dirty() -> void:
	for project in project_names():
		_mark_dirty(project)


# Event `sequence` of `stream` came (0: a reply, which names only its
# stream). A stream not seen before, the first or a restarted process's,
# may have had changes this source never heard of, as may one that skips a
# number: every project is then dirty. A restart also starts a new epoch and
# has the snapshot read again.
func _note_position(stream: String, sequence: int) -> void:
	if stream.is_empty():
		return
	if stream != _stream:
		if not _stream.is_empty():
			_epoch += 1
			_refresh_due = true
			_completed_operations.clear()
		_stream = stream
		_received = sequence
		_mark_all_dirty()
		return
	if sequence > _received + 1:
		_mark_all_dirty()
	_received = maxi(_received, sequence)


# A reply left the event stream at `watermark` events: on a stream first
# seen here that is where counting starts; on a known one, those events
# should come (_expect_events).
func _note_reply(stream: String, watermark: int) -> void:
	var first := stream != _stream
	_note_position(stream, 0)
	if first:
		_received = maxi(_received, watermark)
	elif watermark > _received:
		_expect_events(stream, watermark)


## How long (s) the events a reply counted may take to come before they are
## taken as lost.
const EVENTS_GRACE := 2.0


# The events of `stream` up to `awaited` should come; if they have not after
# EVENTS_GRACE (and the stream is the same), some were lost, and every
# project is dirty.
func _expect_events(stream: String, awaited: int) -> void:
	await (Engine.get_main_loop() as SceneTree).create_timer(EVENTS_GRACE).timeout
	if stream != _stream or _received >= awaited:
		return
	_received = awaited
	_mark_all_dirty()
	_work()


# The one worker: while nothing holds it and a shell watches, it reads the
# snapshot again when that is due, then looks at the dirty projects in turn.
# It stops at an item that could not be looked up, unless more changes came
# during that lookup; the project stays dirty, and the next change or
# release tries again.
func _work() -> void:
	if _working:
		return
	_working = true
	while _holds == 0 and _open_item.is_valid():
		if _refresh_due:
			_refresh_due = false
			await _refresh_snapshot()
			data_changed.emit()
			continue
		var project := _next_dirty()
		if project.is_empty() or not await _look_at(project):
			break
	_working = false


func _next_dirty() -> String:
	for project in _dirty:
		if int(_dirty[project]) > int(_clean.get(project, 0)):
			return project
	return ""


# Compare the open item, when it is in `project`, with the process's: gone,
# or another version than the form loaded, is reported once per version. A
# result that no longer holds (a new epoch, a hold, the form moved on) is
# dropped, and the project looked at again. False when the item could not be
# looked up.
func _look_at(project: String) -> bool:
	var generation: int = _dirty[project]
	var epoch := _epoch
	var open: Dictionary = _open_item.call()
	var id := str(open.get("id", ""))
	if id.is_empty() or str(open.get("project", "")) != project:
		_clean[project] = generation
		return true
	var found := await item_state(project, id)
	if epoch != _epoch or _holds > 0 or not _open_item.is_valid() or _open_item.call() != open:
		return true
	if found.state == "error":
		# Changes that came during the lookup are tried for; an unchanged
		# failure waits for the next change or release.
		if int(_dirty[project]) != generation or _refresh_due:
			return true
		open_item_unchecked.emit(project, id, str(found.error))
		return false
	_clean[project] = generation
	var version := MISSING if found.state == "missing" else str(found.token)
	var key := _key(project, id)
	if version != str(open.get("token", "")) and str(_asked.get(key, "")) != version:
		_asked[key] = version
		open_item_changed_elsewhere.emit(project, id, version == MISSING)
	return true


func _origin() -> String:
	return str(_connection.panel_origin()) if _connection.has_method("panel_origin") else ""


## `work` (called with a new operation id, and awaited) as one of this
## source's changes, which holds reconciliation until its reply: what it
## returns, {result, stream, watermark} — its result, and where the
## process's event stream was when it replied.
func _change(work: Callable) -> Dictionary:
	var operation := Crypto.new().generate_random_bytes(16).hex_encode()
	_pending_operations[operation] = true
	hold_reconciliation()
	var answered: Dictionary = await work.call(operation)
	_pending_operations.erase(operation)
	_completed_operations.append(operation)
	if _completed_operations.size() > MAX_COMPLETED:
		_completed_operations.pop_front()
	_note_reply(str(answered.get("stream", "")), int(answered.get("watermark", 0)))
	release_reconciliation()
	return answered.get("result", {})


## Tool `name` as one of this source's changes.
func _mutate(name: String, arguments: Dictionary) -> Dictionary:
	return await _change(func(operation: String) -> Dictionary:
		var reply: Dictionary = await _connection.call_tool(name, arguments, operation)
		return {"result": decode_tool_result(reply), "stream": reply.get("stream", ""),
			"watermark": reply.get("event_watermark", 0)})


# -- Calls ----------------------------------------------------------------------

## Call tool `name`: its decoded result, or {error}. A reply that names the
## event stream places this source on it (start's first read does, before
## anything is open).
func _call(name: String, arguments: Dictionary) -> Dictionary:
	var reply: Dictionary = await _connection.call_tool(name, arguments, "")
	_note_reply(str(reply.get("stream", "")), int(reply.get("event_watermark", 0)))
	_work()  # the reply may have shown a restart
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


# The error of `result` as a message ("" for none); the private channel may
# give it as {code, message}.
static func _error_text(result: Dictionary) -> String:
	var error = result.get("error", "")
	return str(error.get("message", error)) if error is Dictionary else str(error)


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


## Kept by this source while it lives (never in the host's preferences); a
## value not set yet is taken once from the primary project's file.
func ui_setting(key: String, default_value: String) -> String:
	var settings: Dictionary = _remembered.get_or_add("ui_settings", {})
	if settings.has(key):
		return settings[key]
	var primary := primary_project()
	if primary.is_empty():
		return default_value
	var meta := await _call("docket_project_meta", {"action": "get", "project": primary})
	if settings.has(key):  # set meanwhile, by the user or another read
		return settings[key]
	if primary_project() != primary:  # the value comes from the current primary
		return await ui_setting(key, default_value)
	var inherited := str(meta.get("display", {}).get(key, "")) if meta.get("display") is Dictionary else ""
	if inherited.is_empty():
		return default_value
	settings[key] = inherited
	return inherited


func set_ui_setting(key: String, value: String) -> void:
	_remembered.get_or_add("ui_settings", {})[key] = value


func prefs():
	return _prefs


func schema() -> Dictionary:
	return _schema


## Open the project at `path` beside the others (answered, not opened again,
## when it is open already). The process's host decides which projects stay
## open, so opening one never closes another here; closing is remove_project.
func open_project(path: String) -> void:
	await add_project(path)


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


## A process not run host-managed refuses to close its last project (a
## host-managed one is left with none); a refusal is reported as a
## load_failed for its path.
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


## The process reports each reloaded project as a host event, after which
## the worker reads the snapshot again (once nothing holds it and a shell
## watches).
func reload_all() -> Array:
	var reloaded := await _mutate("docket_reload", {})
	return reloaded.get("reloaded", [])


# -- Items --------------------------------------------------------------------------

## Tell the host's private channel which item the form shows, so it is the
## one the panel may save (see save_item).
func item_shown(project: String, id: String) -> void:
	_showing += 1
	var showing := _showing
	_bound = {}
	_bind_refusal = {}
	if not _connection.has_method("panel_call") or _origin().is_empty():
		_binding = false
		_bind_settled.emit()
		return
	_binding = true
	var answered: Dictionary = await _connection.panel_call("select_item", {"project": project, "id": id})
	if showing != _showing:
		return
	_binding = false
	# The host names the item as its project knows it (its full id).
	if answered.has("error"):
		_bind_refusal = {"project": project, "id": id, "reason": str(answered.error)}
	elif not id.is_empty():
		_bound = {"project": project, "id": id, "canonical": str(answered.get("id", id)),
			"binding": int(answered.get("binding", -1))}
	_bind_settled.emit()


## Through the host's private panel channel, as the person the host names,
## for the item the form shows (once the host has bound it).
func save_item(project: String, id: String, changes: Dictionary, revision: String, token: String,
		secret: Dictionary = {}) -> String:
	if not secret.is_empty():
		return UNSUPPORTED
	return await _bound_change("update_item", project, id, {"changes": changes,
		"expected_revision": revision, "expected_item_token": token})


## Moves the item the form shows to status `target`, with `changes`, as one
## change through the host's private panel channel (see save_item).
func transition_item(project: String, id: String, target: String, note: String, changes: Dictionary,
		revision: String, token: String, secret: Dictionary = {}) -> String:
	if not secret.is_empty():
		return UNSUPPORTED
	return await _bound_change("transition_item", project, id, {"target": target, "note": note,
		"changes": changes, "expected_revision": revision, "expected_item_token": token})


## A new item through the host's private panel channel, as the person the
## host names; the process chooses its id.
func create_item(project: String, fields: Dictionary, secret: Dictionary = {}) -> Dictionary:
	if not secret.is_empty():
		return _unsupported()
	if not _has_channel():
		return {"error": NO_CHANNEL}
	var reply := await _panel_change("create_item", {"project": project, "fields": fields})
	var error := _error_text(reply)
	if not error.is_empty():
		return {"error": error}
	var id := str(reply.get("id", ""))
	if not str(reply.get("item_token", "")).is_empty():
		_committed_tokens[_key(project, id)] = str(reply.item_token)
	return {"id": id}


# A private channel: panel_call, and an origin for this panel.
func _has_channel() -> bool:
	return _connection.has_method("panel_call") and not _origin().is_empty()


## Attaches `data` to the item the form shows, through the host's private
## panel channel, as the person the host names (see save_item).
func attach_file(project: String, id: String, filename: String, data: PackedByteArray, mime: String,
		description: String) -> Dictionary:
	var reply := await _bound_reply("attach_file", project, id, {"filename": filename,
		"data": Marshalls.raw_to_base64(data), "mime_type": mime, "description": description})
	if reply.has("error"):
		return reply
	var record := reply.duplicate()
	for key in ["item_token", "operation_id", "stream", "event_watermark"]:
		record.erase(key)
	return record


# Panel method `method` for item `id` of `project`: "" or the error (see
# _bound_reply).
func _bound_change(method: String, project: String, id: String, params: Dictionary) -> String:
	return str((await _bound_reply(method, project, id, params)).get("error", ""))


# Panel method `method` for item `id` of `project`, the one the host bound
# to the form, with `params` besides: its result, or {error} (a message).
# Refused before any change starts without a private channel or that binding.
func _bound_reply(method: String, project: String, id: String, params: Dictionary) -> Dictionary:
	if not _has_channel():
		return {"error": NO_CHANNEL}
	while _binding:
		await _bind_settled  # the shown item's binding is on its way
	if _bound.get("project") != project or _bound.get("id") != id:
		if _bind_refusal.get("project") == project and _bind_refusal.get("id") == id:
			return {"error": str(_bind_refusal.reason)}
		return {"error": "The host has not made %s ready for editing here; open it again." % id}
	var sent := params.duplicate()
	sent.merge({"binding": _bound.binding, "project": project, "id": _bound.canonical})
	var reply := await _panel_change(method, sent)
	var error := _error_text(reply)
	if not error.is_empty():
		return {"error": error}
	if not str(reply.get("item_token", "")).is_empty():
		_committed_tokens[_key(project, id)] = str(reply.item_token)
	return reply


# Panel method `method` with `params` as one of this source's changes: its
# result, or {error}.
func _panel_change(method: String, params: Dictionary) -> Dictionary:
	return await _change(func(operation: String) -> Dictionary:
		var sent := params.duplicate()
		sent["operation_id"] = operation
		var answered: Dictionary = await _connection.panel_call(method, sent)
		return {"result": answered, "stream": answered.get("stream", ""), "watermark": answered.get("event_watermark", 0)})


func _get_item(project: String, id: String, include: Array) -> Dictionary:
	return await _call("docket_get", {"id": id, "project": project, "include": include})


func item_view(project: String, id: String, refresh: bool = false) -> Dictionary:
	if id.is_empty() or not project_names().has(project):
		return {"error": "the originating project is closed", "kind": "closed"}
	return await _call("docket_item_view", {"id": id, "project": project, "refresh": refresh})


func item_token(project: String, id: String) -> String:
	var view := await item_view(project, id)
	return "" if view.has("error") else str(view.get("token", ""))


## Whether item `id` is there, as {state: "found", token}, {state:
## "missing"}, or {state: "error", error} when that could not be told:
## missing only when the process says the item is not there; any other
## failure (the process unreachable, a malformed reply) is an error.
func item_state(project: String, id: String) -> Dictionary:
	var view := await item_view(project, id)
	if not view.has("error"):
		var token := str(view.get("token", ""))
		return {"state": "found", "token": token} if not token.is_empty() \
			else {"state": "error", "error": "the reply for %s had no token" % id}
	if str(view.get("kind", "")) == "missing":
		return {"state": "missing"}
	return {"state": "error", "error": str(view.error)}


func item_title(project: String, id: String) -> Dictionary:
	var item := await _get_item(project, id, [])
	return {} if item.has("error") else {"title": str(item.get("title", ""))}


func item_events(project: String, id: String) -> Array:
	var item := await _get_item(project, id, ["events"])
	return [] if item.has("error") else item.get("events", [])


func stored_name(project: String) -> String:
	for listed in _projects:
		if str(listed.get("name", "")) == project:
			return str(listed.get("display_name", project))
	return project


## Items whose parent is `qualified_id` ("project:id", the project as its
## selector) in every open project; a bare parent id counts only in the
## parent's own project, as in the standalone app.
func children_of(qualified_id: String) -> Dictionary:
	var separator := qualified_id.find(":")
	var owner := qualified_id.left(separator) if separator > 0 else ""
	var bare_id := qualified_id.substr(separator + 1) if separator > 0 else qualified_id
	var stored := stored_name(owner)
	var children: Array = []
	var unread: Array[String] = []
	for project in project_names():
		# A stored parent reference names the parent's project by its stored
		# name; it counts only where that name reads back as the parent's
		# project (ProjectSelectors.resolve_reference, here from the list).
		var parents: Array = []
		if owner.is_empty() or _reads_back(stored, project) == owner:
			parents.append({"field": "parent", "op": "eq", "value": "%s:%s" % [stored, bare_id] if not owner.is_empty() else qualified_id})
		if owner.is_empty() or project == owner:
			parents.append({"field": "parent", "op": "eq", "value": bare_id})
		if parents.is_empty():
			continue
		var listed := await _call("docket_query", {"project": project, "filter": {"$or": parents}, "detail": "full"})
		if listed.has("error"):
			unread.append("%s (%s)" % [project, listed.error])
			continue
		for item in listed.get("items", []):
			item["project"] = project
			children.append(item)
	var error := "" if unread.is_empty() else "Children could not be read in: %s" % ", ".join(unread)
	return {"children": children, "error": error}


func run_query(query: Dictionary) -> Dictionary:
	return await _call("docket_query_view", query)


# The project a reference to stored name `stored` means, read from project
# `from`: its own when that is its stored name, else the one project listed
# under it, or "" when none or several are.
func _reads_back(stored: String, from: String) -> String:
	if stored_name(from) == stored:
		return from
	var found: Array = []
	for listed in _projects:
		if str(listed.get("display_name", listed.get("name", ""))) == stored:
			found.append(str(listed.get("name", "")))
	return found[0] if found.size() == 1 else ""


func move_item(project: String, id: String, target_project: String) -> Dictionary:
	return await _mutate("docket_move", {"id": id, "source_project": project, "target_project": target_project})


# -- Comments -------------------------------------------------------------------------

func list_comments(project: String, id: String) -> Array:
	var listed := await _call("docket_comment", {"action": "list", "item_id": id, "project": project})
	return [] if listed.has("error") else listed.get("comments", [])


func add_comment(project: String, id: String, author: String, text: String, parent_id: int = 0) -> Dictionary:
	if parent_id > 0:
		return await _mutate("docket_comment", {"action": "reply", "comment_id": parent_id, "text": text,
			"author": author, "project": project})
	return await _mutate("docket_comment", {"action": "add", "item_id": id, "text": text, "author": author,
		"project": project})


func resolve_comment(project: String, comment_id: int, resolution: String, by: String) -> Dictionary:
	var action := "accept" if resolution == "accepted" else "reject"
	return await _mutate("docket_comment", {"action": action, "comment_id": comment_id, "addressed_by": by,
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
	var applied := await _mutate("docket_type_evolve", {"project": project, "type": str(preview.get("slug", "")),
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
