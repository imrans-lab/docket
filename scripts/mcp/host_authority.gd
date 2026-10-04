extends RefCounted
class_name DocketHostAuthority
## Private stdio authority, separate from the agent tool registry. The token is
## per child, not a vault password. Schema declaration precedes every hosted project opening.

const PREFIX := "docket/panel/"
const SECRET_ENV := "DOCKET_PANEL_SECRET"
var _secret := PackedByteArray()
var schema_adopted: Callable


func configure_from_environment(enabled: bool, stdio: bool) -> String:
	var token := OS.get_environment(SECRET_ENV)
	OS.unset_environment(SECRET_ENV)
	_secret.clear()
	if not enabled:
		return ""
	if not stdio:
		return "--host-authority requires --stdio"
	if not _valid_token(token):
		return "--host-authority requires a valid per-child authentication token"
	_secret = token.hex_decode()
	return ""


func handle(method: String, params: Variant) -> Dictionary:
	if not params is Dictionary:
		return _error(-32001, "Private authentication refused")
	var token: Variant = params.get("panel_secret")
	if not token is String:
		return _error(-32001, "Private authentication refused")
	if not _valid_token(token) or _secret.size() != 32:
		return _error(-32001, "Private authentication refused")
	var supplied: PackedByteArray = token.hex_decode()
	var difference := 0
	for i in 32:
		difference |= supplied[i] ^ _secret[i]
	if difference != 0:
		return _error(-32001, "Private authentication refused")
	if method == PREFIX + "declare_schema":
		if params.size() != 3 or not params.has("schema") or not params.has("version"):
			return _error(-32602, "Invalid private parameters")
		var declaration := TypeRegistryBootstrap.declare_schema(params.schema, params.version)
		if declaration.has("error"): return _error(-32602, declaration.error)
		if not declaration.idempotent and schema_adopted.is_valid(): schema_adopted.call()
		return {"result":declaration}
	if method != PREFIX + "status":
		return _error(-32601, "Private method not found")
	# status accepts exactly {panel_secret}; no grants, sessions, tool arguments
	# or host-reserved fields are forwarded. It never opens or changes a project.
	if params.size() != 1:
		return _error(-32602, "Invalid private parameters")
	return {"result": {"protocol": "docket_panel_v1", "pid": OS.get_process_id()}}


static func _valid_token(token: String) -> bool:
	if token.length() != 64:
		return false
	for byte in token.to_utf8_buffer():
		if not (byte >= 48 and byte <= 57 or byte >= 97 and byte <= 102):
			return false
	return true


static func _error(code: int, message: String) -> Dictionary:
	return {"error": {"code": code, "message": message}}
