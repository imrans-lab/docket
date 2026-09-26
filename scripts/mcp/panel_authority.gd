extends RefCounted
## The private channel through which a host's Docket panel makes a person's
## edits (JSON-RPC methods under PREFIX), apart from the MCP tools agents use.
##
## Only the host holds the bootstrap secret, handed to this process at start
## in the environment (SECRET_VARIABLE, removed once read). With it the host
## registers a panel and gets a grant: an opaque, short-lived token naming
## the person, the project, the item and what may be done there (save it,
## move it to another status, attach a file), or naming no item but a type,
## to create one new item of it once. The host adds the grant to the panel's
## requests; the person making an edit (the local user the host identifies,
## recorded as "human:<person>") is taken from the grant, never from a
## request. The host also opens a session for each panel it shows
## (open_session), with which McpHandler runs the panel's other calls as
## tools on the panel's behalf (docket/panel/call), so their changes are
## known as the panel's. Tool calls may not carry the reserved
## RESERVED_ARGUMENTS names. None of this is an MCP tool: it is absent from
## tools/list and cannot be reached through tools/call.
##
## The host alone, before it opens any project, may also declare the schema
## this process reads projects by (declare_schema) and have a project it
## ships installed or brought up to date at a path it names
## (bootstrap_project, MasterBootstrap). Their outcome is a result, {error,
## kind} when refused; only a caller that is not the host, or malformed
## parameters, get a JSON-RPC error.

const PREFIX := "docket/panel/"
const SECRET_VARIABLE := "DOCKET_PANEL_SECRET"
## The shortest bootstrap secret accepted (characters: 256 bits as hex).
const MIN_SECRET_LENGTH := 64
## How long a grant lasts (ms); the host registers again for a new one.
const GRANT_TTL_MS := 15 * 60 * 1000
## The methods a grant allows (and is needed for); each runs within the
## request's operation.
const ACTIONS := ["update_item", "transition_item", "create_item", "attach_file"]
## The longest base64 a file may be sent as: that of the largest attachment.
const MAX_ATTACHMENT_BASE64 := (DocketDB.MAX_ATTACHMENT_BYTES + 2) / 3 * 4
## Argument names only this channel uses, refused in any tool call.
const RESERVED_ARGUMENTS := ["panel_secret", "panel_grant", "panel_session"]

var _secret: String
var _registry  # ToolRegistry
# grant → {panel, person, project (its selector), item, type, open_generation,
# path, actions, expires_at}; a create_item grant has no item and is
# its only action.
var _grants: Dictionary = {}
# panel session → the panel it names (see open_session)
var _sessions: Dictionary = {}


## The authority for `registry`'s projects, or null when this process was
## given no usable secret (the panel methods then do not exist).
static func from_environment(registry):
	var secret := OS.get_environment(SECRET_VARIABLE)
	OS.unset_environment(SECRET_VARIABLE)
	if secret.length() < MIN_SECRET_LENGTH:
		return null
	var authority = load("res://scripts/mcp/panel_authority.gd").new()
	authority._secret = secret
	authority._registry = registry
	return authority


## A PREFIX method with its params: {result} or {error: {code, message}}.
## `op` is the operation of the request, which its changes are made within.
func handle(method: String, params: Dictionary, op: RefCounted = null) -> Dictionary:
	var name := method.trim_prefix(PREFIX)
	match name:
		"open_session":
			return _open_session(params)
		"revoke":
			return _revoke(params)
		"register":
			if not _is_host(params):
				return _failure(-32001, "not the host")
			return _admitted(_register.bind(params))
		"declare_schema":
			if not _is_host(params):
				return _failure(-32001, "not the host")
			return _declare_schema(params)
		"bootstrap_project":
			if not _is_host(params):
				return _failure(-32001, "not the host")
			return _bootstrap_project(params)
	# A person's reads and changes, for a grant: each admitted as a tool's is.
	var granted := {"update_item": _update_item, "transition_item": _transition_item,
		"create_item": _create_item, "attach_file": _attach_file}
	if not granted.has(name):
		return _failure(-32601, "Method not found: %s" % method)
	if not _grants.has(str(params.get("panel_grant", ""))):
		return _failure(-32001, "no such grant")
	return _admitted((granted[name] as Callable).bind(params, op), op)


## The panel a panel call comes from, as this process knows it: the one
## named by a live panel session (docket/panel/call) or grant (ACTIONS),
## "" for neither.
func panel_of(session: String, grant: String) -> String:
	if _sessions.has(session):
		return _sessions[session]
	var scope: Dictionary = _grants.get(grant, {})
	return str(scope.get("panel", "")) if not scope.is_empty() and Time.get_ticks_msec() < scope.expires_at else ""


## Grants for the opening `open_generation` of a project end with it (it
## was closed); another opening, even under the same selector, keeps its own.
func revoke_opening(open_generation: String) -> void:
	for grant in _grants.keys():
		if _grants[grant].open_generation == open_generation:
			_grants.erase(grant)


# Host: {panel_secret, panel} → {panel_session}, naming that panel while it
# is shown (revoke ends it).
func _open_session(params: Dictionary) -> Dictionary:
	if not _is_host(params):
		return _failure(-32001, "not the host")
	var panel := str(params.get("panel", ""))
	if panel.is_empty():
		return _failure(-32602, "a panel is required")
	var session := Crypto.new().generate_random_bytes(32).hex_encode()
	_sessions[session] = panel
	return {"result": {"panel_session": session}}


# Host (handle checks it is): {panel_secret, panel, person, project, item,
# actions[, open_generation]}, or for a new item {..., type, actions:
# ["create_item"]} with no item → {panel_grant, expires_in_ms}.
func _register(params: Dictionary) -> Dictionary:
	var panel := str(params.get("panel", ""))
	var person := str(params.get("person", "")).strip_edges()
	var project := str(params.get("project", ""))
	var item := str(params.get("item", ""))
	var actions = params.get("actions", [])
	if panel.is_empty() or person.is_empty():
		return _failure(-32602, "a panel and a person are required")
	if not actions is Array or actions.is_empty():
		return _failure(-32602, "at least one action is required")
	for action in actions:
		if not str(action) in ACTIONS:
			return _failure(-32602, "unknown action: %s" % action)
	var db: DocketDB = _registry.project_db(project)
	if db == null:
		return _failure(-32602, "no open project %s" % project)
	# The host may name the opening it checked (docket_project_list's
	# open_generation): a project opened again since is not it.
	if params.has("open_generation") and str(params.open_generation) != str(db.get_instance_id()):
		return _failure(-32001, "%s was opened again since" % project)
	var type := ""
	if "create_item" in actions:
		# Creating names no item, and only creating: the new item's id is
		# this process's to choose.
		if actions.size() != 1 or not item.is_empty():
			return _failure(-32602, "a create_item grant names a type and no item, and allows nothing else")
		type = str(params.get("type", ""))
		var types: TypeRegistry = _registry.get_type_registry(project)
		var resolved: Dictionary = types.get_type(type) if types != null and not type.is_empty() else {"error": "a type is required"}
		if resolved.has("error"):
			return _failure(-32602, str(resolved.error))
	elif item.is_empty() or not db.has_item(item):
		return _failure(-32602, "no item %s in %s" % [item, project])
	var grant := Crypto.new().generate_random_bytes(32).hex_encode()
	_grants[grant] = {"panel": panel, "person": person, "project": project, "item": item, "type": type,
		"open_generation": str(db.get_instance_id()), "path": db.get_path(),
		"actions": actions.map(func(a): return str(a)), "expires_at": Time.get_ticks_msec() + GRANT_TTL_MS}
	return {"result": {"panel_grant": grant, "expires_in_ms": GRANT_TTL_MS}}


# Host: {panel_secret, panel} ends every grant and session of that panel (it
# was unloaded), or {panel_secret, panel_grant} that grant. → {revoked}
# (grants).
func _revoke(params: Dictionary) -> Dictionary:
	if not _is_host(params):
		return _failure(-32001, "not the host")
	var revoked := 0
	if params.has("panel_grant"):
		revoked = 1 if _grants.erase(str(params.panel_grant)) else 0
	else:
		var panel := str(params.get("panel", ""))
		for grant in _grants.keys():
			if _grants[grant].panel == panel:
				_grants.erase(grant)
				revoked += 1
		for session in _sessions.keys():
			if _sessions[session] == panel:
				_sessions.erase(session)
	return {"result": {"revoked": revoked}}


# Panel, through the host: {panel_grant, project, id, changes, expected_revision,
# expected_item_token} → {id, item_token}. The edit is the grant's person's.
func _update_item(params: Dictionary, op: RefCounted) -> Dictionary:
	var scope := _granted(params, "update_item")
	if scope.has("error"):
		return _failure(-32001, scope.error)
	var changes = params.get("changes", {})
	if not changes is Dictionary:
		return _failure(-32602, "changes must be an object")
	var registry: TypeRegistry = _registry.get_type_registry(scope.project)
	if registry == null:
		return _failure(-32602, "no open project %s" % scope.project)
	changes = changes.duplicate()
	DocketUpdate.qualify_parent(changes, _registry.project_db(scope.project))
	var error := registry.update_item(scope.item, changes, "human:%s" % scope.person,
		str(params.get("expected_revision", "")), str(params.get("expected_item_token", "")), op)
	if not error.is_empty():
		return _failure(-32002, error)
	return {"result": {"id": scope.item, "item_token": registry.item_token(scope.item)}}


# Panel, through the host: {panel_grant, project, id, target, note, changes,
# expected_item_token[, expected_revision]} → {id, status, item_token}. The
# status and the field changes are one change, the grant's person's, made
# only to the item as the panel last saw it (its token is required); the
# item's lifecycle decides which moves need a note or are refused.
func _transition_item(params: Dictionary, op: RefCounted) -> Dictionary:
	var scope := _granted(params, "transition_item")
	if scope.has("error"):
		return _failure(-32001, scope.error)
	if str(params.get("expected_item_token", "")).is_empty():
		return _failure(-32602, "a move names the item's token as the panel last saw it")
	var changes = params.get("changes", {})
	if not changes is Dictionary:
		return _failure(-32602, "changes must be an object")
	var registry: TypeRegistry = _registry.get_type_registry(scope.project)
	if registry == null:
		return _failure(-32602, "no open project %s" % scope.project)
	changes = changes.duplicate()
	DocketUpdate.qualify_parent(changes, _registry.project_db(scope.project))
	var error := registry.transition_item(scope.item, str(params.get("target", "")), "human:%s" % scope.person,
		str(params.get("note", "")), changes, str(params.get("expected_revision", "")),
		str(params.get("expected_item_token", "")), op)
	if not error.is_empty():
		return _failure(-32002, error)
	var item: Dictionary = _registry.project_db(scope.project).get_item(scope.item)
	return {"result": {"id": scope.item, "status": str(item.get("status", "")), "item_token": registry.item_token(item)}}


# Panel, through the host: {panel_grant, project, fields} → {id, item_token}.
# One new item of the grant's type, with an id this process chooses, as the
# grant's person's; the grant ends once it is made.
func _create_item(params: Dictionary, op: RefCounted) -> Dictionary:
	var scope := _granted(params, "create_item")
	if scope.has("error"):
		return _failure(-32001, scope.error)
	var fields = params.get("fields", {})
	if not fields is Dictionary:
		return _failure(-32602, "fields must be an object")
	if fields.has("id") or (fields.has("type") and str(fields.type) != scope.type):
		return _failure(-32602, "a new item's id is chosen here, and its type is the grant's")
	var registry: TypeRegistry = _registry.get_type_registry(scope.project)
	if registry == null:
		return _failure(-32602, "no open project %s" % scope.project)
	fields = fields.duplicate()
	fields["type"] = scope.type
	DocketUpdate.qualify_parent(fields, _registry.project_db(scope.project))
	var created := registry.create_item(fields, "human:%s" % scope.person, op)
	if created.has("error"):
		return _failure(-32002, str(created.error))
	_grants.erase(str(params.panel_grant))
	return {"result": {"id": str(created.id), "item_token": registry.item_token(str(created.id))}}


# Panel, through the host: {panel_grant, project, id, filename, data (base64),
# mime_type, description} → the attachment's record and the item's new
# item_token. The file and its "attached" event are one change, the grant's
# person's.
func _attach_file(params: Dictionary, op: RefCounted) -> Dictionary:
	var scope := _granted(params, "attach_file")
	if scope.has("error"):
		return _failure(-32001, scope.error)
	# The name is kept exactly as given, like any attachment's.
	var filename := str(params.get("filename", ""))
	var encoded := str(params.get("data", ""))
	if filename.strip_edges().is_empty():
		return _failure(-32602, "an attachment is named")
	if encoded.length() > MAX_ATTACHMENT_BASE64:
		return _failure(-32602, "File too large (max %d bytes)" % DocketDB.MAX_ATTACHMENT_BYTES)
	var data := Marshalls.base64_to_raw(encoded)
	if data.is_empty() and not encoded.is_empty():
		return _failure(-32602, "the file is not valid base64")
	var db: DocketDB = _registry.project_db(scope.project)
	var registry: TypeRegistry = _registry.get_type_registry(scope.project)
	if db == null or registry == null:
		return _failure(-32602, "no open project %s" % scope.project)
	var attached := db.attach_file(scope.item, filename, data, str(params.get("mime_type", "application/octet-stream")),
		str(params.get("description", "")), op, "human:%s" % scope.person)
	if attached.has("error"):
		return _failure(-32002, str(attached.error))
	attached["item_token"] = registry.item_token(scope.item)
	return {"result": attached}


# The grant's scope when it is live, allows `action`, and covers the project
# and item the request names; else {error}.
func _granted(params: Dictionary, action: String) -> Dictionary:
	var scope: Dictionary = _grants.get(str(params.get("panel_grant", "")), {})
	if scope.is_empty():
		return {"error": "no such grant"}
	if Time.get_ticks_msec() >= scope.expires_at:
		_grants.erase(str(params.panel_grant))
		return {"error": "the grant has expired"}
	if not action in scope.actions:
		return {"error": "the grant does not allow %s" % action}
	if str(params.get("project", "")) != scope.project or str(params.get("id", "")) != scope.item:
		return {"error": "the grant does not cover that item"}
	# Only the opening it was registered for: not a later one under the same
	# selector, nor another file given that selector since.
	var db: DocketDB = _registry.project_db(scope.project)
	if db == null or str(db.get_instance_id()) != scope.open_generation \
			or db.get_path() != scope.path:
		_grants.erase(str(params.panel_grant))
		return {"error": "the project the grant named is no longer open"}
	return scope


# declare_schema {panel_secret, schema, version}: {version} once `schema` is
# the one projects are read by. Once projects are open only the version
# already declared is accepted again (a host reconnecting), and changes
# nothing.
func _declare_schema(params: Dictionary) -> Dictionary:
	var schema = params.get("schema")
	var version := str(params.get("version", ""))
	if not schema is Dictionary:
		return _failure(-32602, "schema must be an object")
	if not _registry.open_projects().is_empty():
		if not version.is_empty() and version == TypeRegistryBootstrap.declared_version():
			return {"result": {"version": version}}
		return {"result": {"error": "a schema is declared before any project is opened", "kind": "projects_open"}}
	var problem := TypeRegistryBootstrap.declare_schema(schema, version)
	if not problem.is_empty():
		return {"result": {"error": problem, "kind": "invalid_schema"}}
	_registry.adopt_effective_schema()
	return {"result": {"version": version}}


# bootstrap_project {panel_secret, path, content (base64)}: the project the
# host ships (`content`) installed or updated at `path` (MasterBootstrap),
# then opened: its report with `project` (as docket_project_list describes
# it) and `capability_gaps` (MasterBootstrap.capability_gaps), or {error,
# kind} (with `report` when the file was brought up to date but could not be
# opened).
func _bootstrap_project(params: Dictionary) -> Dictionary:
	var encoded := str(params.get("content", ""))
	var path := str(params.get("path", ""))
	if encoded.is_empty() or encoded.length() > MAX_ATTACHMENT_BASE64:
		return _failure(-32602, "content must be the shipped project, base64, at most %d characters" % MAX_ATTACHMENT_BASE64)
	var shipped := Marshalls.base64_to_raw(encoded)
	if shipped.is_empty():
		return _failure(-32602, "content is not base64")
	if not _registry.add_project_fn.is_valid():
		return {"result": {"error": "projects cannot be opened in this mode", "kind": "open_failed"}}
	var report := MasterBootstrap.apply(path, shipped, _registry.open_projects())
	if report.has("error"):
		return {"result": report}
	var opened: Dictionary = _registry.add_project_fn.call(report.path)
	if opened.has("error"):
		return {"result": {"error": "%s could not be opened: %s" % [report.path, opened.error], "kind": "open_failed", "report": report}}
	report["project"] = opened
	report["capability_gaps"] = MasterBootstrap.capability_gaps(_registry.get_type_registry(str(opened.get("name", ""))))
	return {"result": report}


# The request carries the bootstrap secret (compared in constant time).
func _is_host(params: Dictionary) -> bool:
	var offered := str(params.get("panel_secret", "")).to_utf8_buffer()
	var expected := _secret.to_utf8_buffer()
	if offered.size() != expected.size():
		return false
	var difference := 0
	for i in expected.size():
		difference |= offered[i] ^ expected[i]
	return difference == 0


# `work` (returning a reply) run as a tool's work is, once every open
# project's cache is its file as it is (ToolRegistry.admit); else the refusal.
func _admitted(work: Callable, op: RefCounted = null) -> Dictionary:
	var admitted: Dictionary = _registry.admit(func(_reloaded: Array) -> Dictionary: return work.call(), op)
	if admitted.has("refused"):
		return _failure(-32002, str(admitted.refused.error))
	return admitted


static func _failure(code: int, message: String) -> Dictionary:
	return {"error": {"code": code, "message": message}}
