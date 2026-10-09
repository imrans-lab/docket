extends RefCounted
class_name VaultMutations
## Password rotation preserves the vault salt/cost and every secondary layer.


static func change_password(db: DocketDB, old_password: String, new_password: String, expected: Dictionary, hint: Variant = null) -> Dictionary:
	for password: String in [old_password, new_password]:
		if password.is_empty() or password.to_utf8_buffer().size() > 1024:
			return {"error":"Vault password change refused"}
	if hint != null and (not hint is String or hint.to_utf8_buffer().size() > 1024 or hint.contains(old_password) or hint.contains(new_password)):
		return {"error":"Vault hint refused"}
	var salt := db.get_vault_salt()
	var iterations := db.get_vault_iterations()
	var old_key := VaultCrypto.derive_key(old_password, salt, iterations)
	if not db.verify_vault(old_key): return {"error":"Vault password change refused"}
	var new_key := VaultCrypto.derive_key(new_password, salt, iterations)
	var error := db.change_vault_key_checked(old_key, new_key, expected, hint)
	return {"key":new_key} if error.is_empty() else {"error":"Vault password change refused"}


static func reencrypt(rows: Array, old_key: PackedByteArray, new_key: PackedByteArray) -> Dictionary:
	## Only the outer layer changes. An empty/invalid payload refuses the whole
	## operation instead of silently skipping a current or historical secret.
	var rewritten: Array[Dictionary] = []
	for raw: Dictionary in rows:
		for field: String in ["ciphertext", "iv", "mac"]:
			if not raw.get(field) is PackedByteArray: return {"error":"Vault ciphertext could not be re-encrypted"}
		if raw.iv.size() != VaultCrypto.IV_LENGTH or raw.mac.size() != 32 or raw.ciphertext.is_empty() or raw.ciphertext.size() % VaultCrypto.BLOCK_SIZE != 0:
			return {"error":"Vault ciphertext could not be re-encrypted"}
		var payload := VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, old_key)
		if payload.is_empty(): return {"error":"Vault ciphertext could not be re-encrypted"}
		var row := raw.duplicate()
		row.merge(VaultCrypto.encrypt(payload, new_key), true)
		rewritten.append(row)
	return {"rows":rewritten}
