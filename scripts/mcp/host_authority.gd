extends RefCounted
class_name DocketHostAuthority
## Private stdio authority, separate from the agent tool registry. The token is
## per child, not a vault password. Schema declaration precedes every hosted project opening.

const PREFIX := "docket/panel/"
const SECRET_ENV := "DOCKET_PANEL_SECRET"
var _secret := PackedByteArray()
var schema_adopted: Callable
var resolve_vault: Callable
var bootstrap_project: Callable


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
	if method == PREFIX + "bootstrap_project":
		if params.size() != 3 or not params.get("path") is String or not params.get("content") is String:
			return _error(-32602, "Invalid private parameters")
		var path: String = params.path
		if path.is_empty() or not path.is_absolute_path() or path.contains("://") or path.get_file().is_empty():
			return _error(-32602, "Bootstrap requires an absolute file path")
		var refusal := TypeRegistryBootstrap.opening_refusal()
		if not refusal.is_empty(): return _error(-32602, refusal)
		var encoded: String = params.content
		if encoded.is_empty() or encoded.length() % 4 != 0:
			return _error(-32602, "Invalid bootstrap encoding")
		for i in encoded.length():
			var character := encoded.substr(i, 1)
			if not character in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" and not (character == "=" and i >= encoded.length() - 2):
				return _error(-32602, "Invalid bootstrap encoding")
		var bytes := Marshalls.base64_to_raw(encoded)
		if bytes.is_empty() or Marshalls.raw_to_base64(bytes) != encoded:
			return _error(-32602, "Invalid bootstrap encoding")
		var shipment := bytes.get_string_from_utf8()
		if shipment.to_utf8_buffer() != bytes:
			return _error(-32602, "Bootstrap content must be UTF-8")
		if not bootstrap_project.is_valid(): return _error(-32603, "Bootstrap unavailable")
		return bootstrap_project.call(ProjectOpenings.normalized_path(path), shipment)
	if method in [PREFIX + "vault_challenge", PREFIX + "vault_unlock", PREFIX + "vault_lock"]:
		var db: DocketDB = resolve_vault.call(params.get("path")) if resolve_vault.is_valid() else null
		if db == null: return _error(-32602, "Vault request refused")
		return VaultKeySession.handle(method.trim_prefix(PREFIX), params, db)
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
