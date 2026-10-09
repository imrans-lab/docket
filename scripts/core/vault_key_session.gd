extends RefCounted
class_name VaultKeySession
## Process memory only. Entries hold no DB references; close/reload erases them.
static var _entries: Dictionary = {}
## Managed openings never fall back to a saved credential, even while locked.
static var _managed: Dictionary[int, bool] = {}

static func is_managed(db: DocketDB) -> bool:
	return _managed.has(db.get_instance_id())

static func uses_session(db: DocketDB, hosted: bool) -> bool:
	return hosted or is_managed(db)

static func mark_managed(db: DocketDB) -> void:
	_managed[db.get_instance_id()] = true

static func release(db: DocketDB) -> void:
	forget(db)
	_managed.erase(db.get_instance_id())

static func forget(db: DocketDB) -> void:
	_entries.erase(db.get_instance_id())

static func descriptor(db: DocketDB) -> Dictionary:
	if db is DocketDBJsonl:
		(db as DocketDBJsonl).ensure_fresh()
	if not db.is_open() or not db.get_write_block_reason().is_empty():
		forget(db)
		return {}
	var metadata := db.get_all_meta()
	var raw := [str(metadata.get("vault_salt", "")), str(metadata.get("vault_kdf_iterations", "")), str(metadata.get("vault_verify", ""))]
	var initialized := not db.vault_creation_refusal().is_empty()
	if not db._last_sql_error.is_empty() or (initialized and (db.get_vault_salt().size() != 16 or Marshalls.base64_to_raw(raw[2]).size() != 32)):
		forget(db)
		return {}
	# Do not let the legacy fallback silently accept corrupt/unsupported costs.
	if raw[1] not in ["", "10000", "600000"]:
		forget(db)
		return {}
	if initialized and metadata.has("vault_kdf_iterations") and raw[1].is_empty():
		forget(db)
		return {}
	return {"path":ProjectOpenings.normalized_path(db.get_path()), "open_generation":str(db.get_instance_id()),
		"fingerprint":JSON.stringify(raw).sha256_text(), "initialized":initialized, "hint":db.get_meta_value("vault_hint", "")}

static func key_for(db: DocketDB) -> PackedByteArray:
	var current := descriptor(db)
	var entry: Dictionary = _entries.get(db.get_instance_id(), {})
	if current.is_empty() or not current.initialized or entry.get("descriptor", {}) != current:
		forget(db)
		return PackedByteArray()
	return entry.get("key", PackedByteArray()).duplicate()

static func control(args: Dictionary, db: DocketDB) -> Dictionary:
	## Public project-scoped controls reuse the private crypto contract, but a
	## refused public request preserves an existing, still-valid session.
	var requested: Variant = args.get("action")
	if not requested is String or requested not in ["status", "init", "unlock", "lock", "forget", "change_password", "set_hint"]:
		return {"error":"Vault action refused"}
	var action: String = requested
	var allowed: Array[String] = ["action", "project"]
	if action != "status": allowed.append_array(["open_generation", "fingerprint"])
	if action in ["init", "unlock", "set_hint"]: allowed.append("password")
	if action in ["init", "change_password", "set_hint"]: allowed.append("hint")
	if action == "change_password": allowed.append_array(["old", "new"])
	for field: String in args:
		if field not in allowed or not args[field] is String:
			return {"error":"Vault request refused"}
	var current := descriptor(db)
	if current.is_empty(): return {"error":"Vault opening unavailable"}
	if action == "status":
		current["unlocked"] = not key_for(db).is_empty()
		current["managed"] = is_managed(db)
		return current
	if args.get("open_generation") != current.open_generation or args.get("fingerprint") != current.fingerprint:
		return {"error":"Vault binding is stale; read status again"}
	if action in ["change_password", "set_hint"]:
		if not current.initialized: return {"error":"Vault is not initialized"}
		var previous: Dictionary = _entries.get(db.get_instance_id(), {}).duplicate(true)
		var changed: Dictionary
		if action == "change_password":
			if not args.has("old") or not args.has("new"): return {"error":"Both passwords are required"}
			changed = VaultMutations.change_password(db, args.old, args.get("new"), current, args.get("hint"))
		else:
			if not args.has("hint") or not args.has("password"): return {"error":"Vault hint refused"}
			changed = VaultMutations.set_hint(db, args.password, args.hint, current)
		var updated := descriptor(db)
		if changed.has("error") or updated.is_empty():
			if not previous.is_empty() and previous.get("descriptor") == updated: _entries[db.get_instance_id()] = previous
			return {"error":"Vault %s refused" % action}
		if action == "change_password":
			_entries[db.get_instance_id()] = {"descriptor":updated.duplicate(), "key":changed.key}
			mark_managed(db)
		elif not previous.is_empty() and previous.get("descriptor") == current:
			previous["descriptor"] = updated.duplicate()
			_entries[db.get_instance_id()] = previous
		updated["unlocked"] = not key_for(db).is_empty()
		updated["managed"] = is_managed(db)
		return updated
	var fields := {"panel_secret":"", "path":current.path,
		"open_generation":current.open_generation, "fingerprint":current.fingerprint}
	if action in ["init", "unlock"]: fields["password"] = args.get("password")
	if action == "init" and args.has("hint"): fields["hint"] = args.hint
	var previous: Dictionary = _entries.get(db.get_instance_id(), {}).duplicate(true)
	# Forget retains all vault data; its authority effect is the existing lock.
	var reply := handle("vault_lock" if action == "forget" else "vault_" + action, fields, db)
	if reply.has("error"):
		if not previous.is_empty() and previous.get("descriptor") == descriptor(db):
			_entries[db.get_instance_id()] = previous
		return {"error":"Vault %s refused" % action}
	mark_managed(db)
	reply.result["managed"] = true
	return reply.result

static func handle(method: String, params: Dictionary, db: DocketDB) -> Dictionary:
	var current := descriptor(db)
	var with_password := method in ["vault_unlock", "vault_init"]
	var expected := 5 if with_password else (2 if method == "vault_challenge" else 4)
	if method == "vault_init" and params.has("hint"): expected += 1
	var fields := ["panel_secret", "path"]
	if method != "vault_challenge": fields.append_array(["open_generation", "fingerprint"])
	if with_password: fields.append("password")
	if method == "vault_init": fields.append("hint")
	var valid := params.size() == expected
	for field in params:
		if field not in fields or not params[field] is String: valid = false
	if with_password:
		var password: Variant = params.get("password")
		if not password is String or password.is_empty() or password.to_utf8_buffer().size() > 1024: valid = false
	if method == "vault_init" and params.has("hint"):
		var hint: Variant = params.hint
		if not hint is String or hint.to_utf8_buffer().size() > 1024: valid = false
		elif valid and hint.contains(params.password): valid = false
	if not valid or current.is_empty():
		forget(db)
		return {"error":{"code":-32602, "message":"Vault request refused"}}
	if method != "vault_challenge" and (params.open_generation != current.open_generation or params.fingerprint != current.fingerprint):
		forget(db)
		return {"error":{"code":-32602, "message":"Vault request refused"}}
	if method == "vault_init":
		if current.initialized: return {"error":{"code":-32602, "message":"Vault creation refused"}}
		forget(db)
		var salt := VaultCrypto.generate_salt()
		var key := VaultCrypto.derive_key(params.password, salt, VaultCrypto.PBKDF2_ITERATIONS)
		if not db.init_vault_if_absent_checked(key, salt, params.get("hint", "")).is_empty():
			return {"error":{"code":-32002, "message":"Vault creation refused"}}
		current = descriptor(db)
		if current.is_empty() or not current.initialized or not db.verify_vault(key): return {"error":{"code":-32002, "message":"Vault creation refused"}}
		_entries[db.get_instance_id()] = {"descriptor":current.duplicate(), "key":key}
	elif method == "vault_unlock":
		forget(db)
		if not current.initialized: return {"error":{"code":-32602, "message":"Vault request refused"}}
		var key := VaultCrypto.derive_key(params.password, db.get_vault_salt(), db.get_vault_iterations())
		if not db.verify_vault(key):
			AuditLog.record(db.get_path(), AuditLog.UNLOCK_FAILED, "", false, "host", "vault password did not verify")
			return {"error":{"code":-32002, "message":"Vault unlock refused"}}
		_entries[db.get_instance_id()] = {"descriptor":current.duplicate(), "key":key}
	elif method == "vault_lock":
		forget(db)
	current["unlocked"] = not key_for(db).is_empty()
	return {"result":current}
