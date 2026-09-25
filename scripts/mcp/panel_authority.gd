extends RefCounted
## The private channel through which a host's Docket panel makes a person's
## edits (JSON-RPC methods under PREFIX), apart from the MCP tools agents use.
##
## Only the host holds the bootstrap secret, handed to this process at start
## in the environment (SECRET_VARIABLE, removed once read). With it the host
## registers a panel and gets a grant: an opaque, short-lived token naming
## the person, the project, the item and what may be done there. The host
## adds the grant to the panel's requests; the person making an edit (the
## local user the host identifies, recorded as "human:<person>") is taken
## from the grant, never from a request. The host also opens a session for
## each panel it shows (open_session), with which McpHandler runs the panel's
## other calls as tools on the panel's behalf (docket/panel/call), so their
## changes are known as the panel's. Tool calls may not carry the reserved
## RESERVED_ARGUMENTS names. None of this is an MCP tool: it is
## absent from tools/list and cannot be reached through tools/call.

const PREFIX := "docket/panel/"
const SECRET_VARIABLE := "DOCKET_PANEL_SECRET"
## The shortest bootstrap secret accepted (characters: 256 bits as hex).
const MIN_SECRET_LENGTH := 64
## How long a grant lasts (ms); the host registers again for a new one.
const GRANT_TTL_MS := 15 * 60 * 1000
const ACTIONS := ["update_item"]
## Argument names only this channel uses, refused in any tool call.
const RESERVED_ARGUMENTS := ["panel_secret", "panel_grant", "panel_session"]

var _secret: String
var _registry  # ToolRegistry
# grant → {panel, person, project, item, actions, expires_at}
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
	return _failure(-32601, "Method not found: %s" % method)


## The panel a panel call comes from, as this process knows it: the one
## named by a live panel session (docket/panel/call) or grant (update_item),
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
# open_generation]} → {panel_grant, expires_in_ms}.
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
	if item.is_empty() or not db.has_item(item):
		return _failure(-32602, "no item %s in %s" % [item, project])
	var grant := Crypto.new().generate_random_bytes(32).hex_encode()
	_grants[grant] = {"panel": panel, "person": person, "project": project, "item": item,
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
