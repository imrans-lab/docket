extends RefCounted
class_name VaultKeySession
## Process memory only. Entries hold no DB references; close/reload erases them.
static var _entries: Dictionary = {}

static func forget(db: DocketDB) -> void:
	_entries.erase(db.get_instance_id())

static func descriptor(db: DocketDB) -> Dictionary:
	if db is DocketDBJsonl:
		(db as DocketDBJsonl).ensure_fresh()
	if not db.is_open() or not db.get_write_block_reason().is_empty():
		forget(db)
		return {}
	var raw := [db.get_meta_value("vault_salt", ""), db.get_meta_value("vault_kdf_iterations", ""), db.get_meta_value("vault_verify", "")]
	if db.get_vault_salt().size() != 16 or Marshalls.base64_to_raw(raw[2]).size() != 32:
		forget(db)
		return {}
	# Do not let the legacy fallback silently accept corrupt/unsupported costs.
	if raw[1] not in ["", "10000", "600000"]:
		forget(db)
		return {}
	return {"path":ProjectOpenings.normalized_path(db.get_path()), "open_generation":ProjectOpenings.generation(db),
		"fingerprint":JSON.stringify(raw).sha256_text()}

static func key_for(db: DocketDB) -> PackedByteArray:
	var current := descriptor(db)
	var entry: Dictionary = _entries.get(db.get_instance_id(), {})
	if current.is_empty() or entry.get("descriptor", {}) != current:
		forget(db)
		return PackedByteArray()
	return entry.get("key", PackedByteArray()).duplicate()

static func handle(method: String, params: Dictionary, db: DocketDB) -> Dictionary:
	var current := descriptor(db)
	var expected := 5 if method == "vault_unlock" else (2 if method == "vault_challenge" else 4)
	var fields := ["panel_secret", "path"]
	if method != "vault_challenge": fields.append_array(["open_generation", "fingerprint"])
	if method == "vault_unlock": fields.append("password")
	var valid := params.size() == expected
	for field in params:
		if field not in fields or not params[field] is String: valid = false
	if method == "vault_unlock":
		var password: Variant = params.get("password")
		if not password is String or password.is_empty() or password.to_utf8_buffer().size() > 1024: valid = false
	if not valid or current.is_empty():
		forget(db)
		return {"error":{"code":-32602, "message":"Vault request refused"}}
	if method != "vault_challenge" and (params.open_generation != current.open_generation or params.fingerprint != current.fingerprint):
		forget(db)
		return {"error":{"code":-32602, "message":"Vault request refused"}}
	if method == "vault_unlock":
		forget(db)
		var key := VaultCrypto.derive_key(params.password, db.get_vault_salt(), db.get_vault_iterations())
		if not db.verify_vault(key):
			return {"error":{"code":-32002, "message":"Vault unlock refused"}}
		_entries[db.get_instance_id()] = {"descriptor":current.duplicate(), "key":key}
	elif method == "vault_lock":
		forget(db)
	current["unlocked"] = not key_for(db).is_empty()
	return {"result":current}
