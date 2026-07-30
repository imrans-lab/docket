extends RefCounted
class_name DocketSecretSet
## MCP tool: store an encrypted secret in the docket vault.


func get_definition() -> Dictionary:
	return {
		"name": "docket_secret_set",
		"description": "Store an encrypted secret in the docket vault. Requires a vault password configured in preferences. Set requires_2fa=true and provide secondary_password for double encryption.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"handle": {"type": "string", "description": "Unique name for this secret (e.g. 'api_key', 'db_password')"},
				"value": {"type": "string", "description": "The secret value to encrypt and store"},
				"requires_2fa": {"type": "boolean", "description": "Whether to double-encrypt with a secondary password"},
				"secondary_password": {"type": "string", "description": "Secondary password for double encryption (required when requires_2fa=true)"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["handle", "value"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var handle: String = str(args.get("handle", "")).strip_edges()
	var value: String = str(args.get("value", ""))
	var requires_2fa: bool = args.get("requires_2fa", false) == true
	var secondary_pw: String = str(args.get("secondary_password", ""))

	if handle.is_empty():
		return {"error": "'handle' is required"}
	if value.is_empty():
		return {"error": "'value' is required"}
	if requires_2fa and secondary_pw.is_empty():
		return {"error": "'secondary_password' is required when requires_2fa is true"}

	# A Secret work item stores its payload under handle == item_id, and its
	# encrypted notes under "<item_id>:notes". Nothing used to stop an agent from
	# passing an item id as a handle, which silently overwrote that item's
	# encrypted value — and, because this path never rotated, destroyed the
	# previous value rather than archiving it. Using an item id as a key is a
	# natural thing for an agent to do, so this is refused explicitly.
	# Refuse any handle that belongs to a work item, whether the ownership is
	# recorded or merely implied by the convention. The earlier version allowed
	# the write when the recorded owner already matched, which meant an agent
	# could still replace a tracked item's value — the opposite of what the
	# refusal claimed. Owned values are edited through the item, not this tool.
	var owned_by := handle
	if handle.ends_with(":notes"):
		owned_by = handle.substr(0, handle.length() - 6)
	var recorded_owner := db.get_secret_owner(handle)
	if db.has_item(owned_by) or not recorded_owner.is_empty():
		if not recorded_owner.is_empty():
			owned_by = recorded_owner
		return {"error": (
			"Handle '%s' collides with work item %s, whose encrypted value is stored under that key. "
			% [handle, owned_by]
			+ "Choose a different handle, or edit the item directly to change its secret."
		)}

	# Load vault password
	var password := UserPrefs.load_vault_password()
	if password.is_empty():
		var hint := UserPrefs.load_vault_password_hint()
		var hint_msg := " Hint: %s" % hint if not hint.is_empty() else ""
		return {"error": "Vault password not configured. Set it in Preferences first.%s" % hint_msg}

	# Get or create vault salt
	var salt: PackedByteArray
	var key: PackedByteArray

	if db.has_vault():
		salt = db.get_vault_salt()
		key = VaultCrypto.derive_key(password, salt, db.get_vault_iterations())
		if not db.verify_vault(key):
			AuditLog.record(db.get_path(), AuditLog.UNLOCK_FAILED, handle, false, "mcp",
				"vault password did not verify")
			return {"error": "Vault password does not match. Check Preferences."}
	else:
		# First secret — initialize vault
		salt = VaultCrypto.generate_salt()
		key = VaultCrypto.derive_key(password, salt, VaultCrypto.PBKDF2_ITERATIONS)
		db.init_vault(key, salt, VaultCrypto.PBKDF2_ITERATIONS)

	var is_update := not db.get_secret_raw(handle).is_empty()

	# Replacing a value archives the old one. The GUI has always done this
	# (record_form.gd calls rotate_secret when a value exists); this path
	# computed is_update and then called set_secret regardless, so the same
	# operation kept history from the GUI and destroyed it over MCP.
	var ct: PackedByteArray
	var iv: PackedByteArray
	var mac: PackedByteArray
	if requires_2fa:
		var secondary_key := VaultCrypto.derive_key(secondary_pw, salt, db.get_vault_iterations())
		var outer := VaultCrypto.encrypt_2fa(value, key, secondary_key)
		ct = outer.ciphertext
		iv = outer.iv
		mac = outer.mac
	else:
		var encrypted := VaultCrypto.encrypt(value, key)
		ct = encrypted.ciphertext
		iv = encrypted.iv
		mac = encrypted.mac

	if is_update:
		db.rotate_secret(handle, ct, iv, mac, "mcp", requires_2fa)
	else:
		db.set_secret(handle, ct, iv, mac, requires_2fa)

	AuditLog.record(db.get_path(), AuditLog.WRITE, handle, true, "mcp",
		"updated" if is_update else "created")
	return {"handle": handle, "status": "updated" if is_update else "created"}
