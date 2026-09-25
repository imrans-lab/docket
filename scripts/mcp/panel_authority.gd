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
# grant → {panel, person, project, item, type, actions, expires_at}; a
# create_item grant has no item and is its only action.
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
	match method.trim_prefix(PREFIX):
		"open_session":
			return _open_session(params)
		"register":
			return _register(params)
		"revoke":
			return _revoke(params)
		"update_item":
			return _update_item(params, op)
		"transition_item":
			return _transition_item(params, op)
		"create_item":
			return _create_item(params, op)
		"attach_file":
			return _attach_file(params, op)
	return _failure(-32601, "Method not found: %s" % method)


## The panel a panel call comes from, as this process knows it: the one
## named by a live panel session (docket/panel/call) or grant (ACTIONS),
## "" for neither.
func panel_of(session: String, grant: String) -> String:
	if _sessions.has(session):
		return _sessions[session]
	var scope: Dictionary = _grants.get(grant, {})
	return str(scope.get("panel", "")) if not scope.is_empty() and Time.get_ticks_msec() < scope.expires_at else ""


## Grants for `project` end with it (the project was closed).
func revoke_project(project: String) -> void:
	for grant in _grants.keys():
		if _grants[grant].project == project:
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


# Host: {panel_secret, panel, person, project, item, actions[,
# open_generation]}, or for a new item {..., type, actions: ["create_item"]}
# with no item → {panel_grant, expires_in_ms}.
func _register(params: Dictionary) -> Dictionary:
	if not _is_host(params):
		return _failure(-32001, "not the host")
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
	return scope


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


static func _failure(code: int, message: String) -> Dictionary:
	return {"error": {"code": code, "message": message}}
