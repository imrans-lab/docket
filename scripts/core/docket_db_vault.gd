extends DocketDBConnection
class_name DocketDBVault
## The vault's storage in a Docket project: the vault's key check, and each
## secret (encrypted value, archived versions, owning item). DocketDB builds
## the rest of the project storage on it.

# -- Vault / Secret storage ---------------------------------------------------

func has_vault() -> bool:
	## True if this docket has a vault salt (i.e. secrets have been initialized).
	var rows := _exec_select("SELECT value FROM docket_meta WHERE key='vault_salt';")
	return rows.size() > 0 and not str(rows[0].value).is_empty()


func init_vault(key: PackedByteArray, salt: PackedByteArray, iterations: int = VaultCrypto.PBKDF2_ITERATIONS) -> void:
	var error := init_vault_checked(key, salt, iterations)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## Stores the vault's salt, the check for `key`, and the KDF cost it uses,
## all or none, within a step of `op` (or an operation of its own): "" or why
## not. Called once, for the first secret, and by rewrap_vault.
func init_vault_checked(key: PackedByteArray, salt: PackedByteArray, iterations: int = VaultCrypto.PBKDF2_ITERATIONS, op: RefCounted = null) -> String:
	return _writing_text(op, _init_vault.bind(key, salt, iterations))


func _init_vault(step: RefCounted, key: PackedByteArray, salt: PackedByteArray, iterations: int) -> String:
	var txn := _begin_transaction(step)
	if txn.has("error"): return txn.error
	var error := set_meta_value_checked("vault_salt", Marshalls.raw_to_base64(salt), step)
	if error.is_empty(): error = set_meta_value_checked("vault_verify", Marshalls.raw_to_base64(VaultCrypto.compute_verify_hash(key)), step)
	if error.is_empty(): error = set_meta_value_checked("vault_kdf_iterations", str(iterations), step)
	return _complete_transaction(step, txn.ticket, error)


func get_vault_iterations() -> int:
	## PBKDF2 iteration count for this vault.
	##
	## Absent means the vault predates the parameter being recorded, so it must
	## keep deriving at the legacy cost — the stored ciphertext was produced with
	## that key and no other. New vaults record the current count explicitly, so
	## raising the default later cannot strand them.
	var stored := get_meta_value("vault_kdf_iterations", "")
	if stored.is_empty():
		return VaultCrypto.LEGACY_PBKDF2_ITERATIONS
	var n := int(stored)
	return n if n > 0 else VaultCrypto.LEGACY_PBKDF2_ITERATIONS


func get_vault_salt() -> PackedByteArray:
	var b64 := get_meta_value("vault_salt", "")
	if b64.is_empty():
		return PackedByteArray()
	return Marshalls.base64_to_raw(b64)


func verify_vault(key: PackedByteArray) -> bool:
	## Check if the given derived key matches the stored verification hash.
	var stored_b64 := get_meta_value("vault_verify", "")
	if stored_b64.is_empty():
		return false
	var stored := Marshalls.base64_to_raw(stored_b64)
	var computed := VaultCrypto.compute_verify_hash(key)
	return stored == computed


func set_secret(handle: String, ciphertext: PackedByteArray, iv: PackedByteArray, mac: PackedByteArray, requires_2fa: bool = false, owner_item_id: String = "") -> void:
	## Insert or update an encrypted secret.
	##
	## owner_item_id names the work item this secret belongs to, or "" for a
	## standalone entry (typically created by an agent over MCP). On update it is
	## only written when supplied, so callers that do not care about ownership
	## cannot accidentally orphan an item's payload.
	var now := Time.get_datetime_string_from_system(true)
	var flag := 1 if requires_2fa else 0
	var existing := _exec_select("SELECT handle FROM docket_secrets WHERE handle=?;", [handle])
	if existing.size() > 0:
		if owner_item_id.is_empty():
			_exec("UPDATE docket_secrets SET ciphertext=?, iv=?, mac=?, updated_at=?, requires_2fa=? WHERE handle=?;",
				[ciphertext, iv, mac, now, flag, handle])
		else:
			_exec("UPDATE docket_secrets SET ciphertext=?, iv=?, mac=?, updated_at=?, requires_2fa=?, owner_item_id=? WHERE handle=?;",
				[ciphertext, iv, mac, now, flag, owner_item_id, handle])
	else:
		_exec("INSERT INTO docket_secrets (handle, ciphertext, iv, mac, created_at, updated_at, requires_2fa, owner_item_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
			[handle, ciphertext, iv, mac, now, now, flag, owner_item_id])


func get_secret_owner(handle: String) -> String:
	## Item this secret belongs to, or "" if it is standalone.
	var rows := _exec_select("SELECT owner_item_id FROM docket_secrets WHERE handle=?;", [handle])
	return str(rows[0].get("owner_item_id", "")) if rows.size() > 0 else ""


func set_secret_owner(handle: String, owner_item_id: String) -> void:
	## Attach an existing vault entry to a work item without touching ciphertext.
	## This is what "promote to Secret item" does — no decrypt, no re-encrypt, so
	## it needs no vault password.
	_exec("UPDATE docket_secrets SET owner_item_id=? WHERE handle=?;", [owner_item_id, handle])


func rekey_secret(old_handle: String, new_handle: String) -> String:
	## Move a vault entry to a different handle. Returns "" on success.
	##
	## A pure rename: the handle is never part of the encryption (see
	## VaultCrypto), so no vault password, decryption or re-encryption is needed.
	## Version history moves with it, or rotating a promoted secret would strand
	## its archived values under the old key.
	##
	## This exists so a promoted secret ends up under the handle every consumer
	## already looks for — item payloads live under handle == item_id. Recording
	## ownership while leaving the ciphertext elsewhere makes the metadata and
	## the behaviour disagree, which is exactly how a promoted item became
	## unreadable in the GUI.
	if old_handle == new_handle:
		return ""
	if get_secret_raw(old_handle).is_empty():
		return "No secret found with handle '%s'" % old_handle
	if not get_secret_raw(new_handle).is_empty():
		return "A secret already exists under handle '%s'" % new_handle
	_exec("UPDATE docket_secrets SET handle=? WHERE handle=?;", [new_handle, old_handle])
	_exec("UPDATE docket_secret_versions SET handle=? WHERE handle=?;", [new_handle, old_handle])
	return ""


func get_secret_handle_for_item(item_id: String, suffix: String = "") -> String:
	## Handle holding this item's payload, or "" if it has none.
	##
	## Resolves by recorded ownership first, falling back to the historical
	## convention so files written before owner_item_id existed still work.
	var want := item_id + suffix
	var rows := _exec_select(
		"SELECT handle FROM docket_secrets WHERE owner_item_id=? AND handle=? LIMIT 1;",
		[item_id, want])
	if rows.size() > 0:
		return str(rows[0].get("handle", ""))
	return want if not get_secret_raw(want).is_empty() else ""


func list_secrets_owned_by(item_id: String) -> Array:
	## Every handle belonging to this item, however it is keyed. Used on delete
	## and move so an owned payload cannot be left orphaned.
	var out: Array = []
	for row in _exec_select(
		"SELECT handle FROM docket_secrets WHERE owner_item_id=? ORDER BY handle;", [item_id]):
		out.append(str(row.get("handle", "")))
	return out


func list_standalone_secrets() -> Array:
	## Vault entries with no owning work item. These have no row in `items`, so
	## they cannot appear in the query grid and are otherwise invisible in the GUI.
	var rows := _exec_select(
		"SELECT handle, created_at, updated_at, requires_2fa FROM docket_secrets "
		+ "WHERE owner_item_id IS NULL OR owner_item_id='' ORDER BY handle ASC;"
	)
	var out: Array = []
	for row in rows:
		out.append({
			"handle": str(row.get("handle", "")),
			"created_at": str(row.get("created_at", "")),
			"updated_at": str(row.get("updated_at", "")),
			"requires_2fa": int(row.get("requires_2fa", 0)) == 1,
		})
	return out


func get_secret_raw(handle: String) -> Dictionary:
	## Returns {ciphertext, iv, mac, requires_2fa} or empty dict if not found.
	var rows := _exec_select("SELECT ciphertext, iv, mac, requires_2fa FROM docket_secrets WHERE handle=?;", [handle])
	if rows.is_empty():
		return {}
	var row: Dictionary = rows[0]
	return {
		"ciphertext": row.ciphertext as PackedByteArray,
		"iv": row.iv as PackedByteArray,
		"mac": row.mac as PackedByteArray,
		"requires_2fa": int(row.get("requires_2fa", 0)) == 1,
	}


func list_secrets() -> Array:
	## Returns [{handle, created_at, updated_at, owner_item_id}] — no decryption.
	## owner_item_id is "" for standalone entries, which is what distinguishes an
	## agent-created secret from a Secret work item's payload.
	var rows := _exec_select(
		"SELECT handle, created_at, updated_at, owner_item_id FROM docket_secrets ORDER BY handle;")
	var result: Array = []
	for row in rows:
		result.append({
			"handle": str(row.handle),
			"created_at": str(row.created_at),
			"updated_at": str(row.updated_at),
			"owner_item_id": str(row.get("owner_item_id", "")),
		})
	return result


func delete_secret(handle: String) -> bool:
	var result := delete_secret_checked(handle)
	if not str(result.error).is_empty(): push_error("DocketDB: %s" % result.error)
	return bool(result.deleted)


## Deletes the vault entry `handle` (not its archived versions) within a step
## of `op` (or an operation of its own): {deleted, error}, `deleted` false
## when there was none or the deletion failed.
func delete_secret_checked(handle: String, op: RefCounted = null) -> Dictionary:
	var result: Variant = _writing(op, _delete_secret.bind(handle))
	return result if result is Dictionary else {"deleted": false, "error": _last_sql_error}


func _delete_secret(step: RefCounted, handle: String) -> Dictionary:
	var txn := _begin_transaction(step)
	if txn.has("error"): return {"deleted": false, "error": txn.error}
	var found := not _exec_select("SELECT handle FROM docket_secrets WHERE handle=?;", [handle]).is_empty()
	if found: _write(step, "DELETE FROM docket_secrets WHERE handle=?;", [handle])
	var error := _complete_transaction(step, txn.ticket)
	return {"deleted": found and error.is_empty(), "error": error}


func get_all_secrets_raw() -> Array:
	## Returns all secrets with raw encrypted data — for re-encryption on password change.
	var rows := _exec_select("SELECT handle, ciphertext, iv, mac, requires_2fa FROM docket_secrets;")
	var result: Array = []
	for row in rows:
		result.append({
			"handle": str(row.handle),
			"ciphertext": row.ciphertext as PackedByteArray,
			"iv": row.iv as PackedByteArray,
			"mac": row.mac as PackedByteArray,
			"requires_2fa": int(row.get("requires_2fa", 0)) == 1,
		})
	return result


func rotate_secret(handle: String, new_ct: PackedByteArray, new_iv: PackedByteArray, new_mac: PackedByteArray, rotated_by: String = "", requires_2fa: bool = false) -> void:
	## Archive current secret value into versions table, then store new value.
	var now := Time.get_datetime_string_from_system(true)
	# Get current value to archive
	var current := get_secret_raw(handle)
	if not current.is_empty():
		# Determine next version number
		var ver_rows := _exec_select("SELECT COALESCE(MAX(version), 0) AS max_ver FROM docket_secret_versions WHERE handle=?;", [handle])
		var next_ver: int = int(ver_rows[0].get("max_ver", 0)) + 1 if ver_rows.size() > 0 else 1
		# requires_2fa describes the value being archived, so it is read from the
		# row being replaced rather than from the incoming one.
		var was_2fa := 1 if bool(current.get("requires_2fa", false)) else 0
		_exec("INSERT INTO docket_secret_versions (handle, version, ciphertext, iv, mac, created_at, rotated_by, requires_2fa) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
			[handle, next_ver, current.ciphertext, current.iv, current.mac, now, rotated_by, was_2fa])
	# Store new value
	set_secret(handle, new_ct, new_iv, new_mac, requires_2fa)


func get_secret_versions(handle: String) -> Array:
	## Returns [{version, ciphertext, iv, mac, created_at, rotated_by}] ordered by version desc.
	var rows := _exec_select("SELECT version, ciphertext, iv, mac, created_at, rotated_by, requires_2fa FROM docket_secret_versions WHERE handle=? ORDER BY version DESC;", [handle])
	var result: Array = []
	for row in rows:
		result.append({
			"version": int(row.version),
			"ciphertext": row.ciphertext as PackedByteArray,
			"iv": row.iv as PackedByteArray,
			"mac": row.mac as PackedByteArray,
			"created_at": str(row.created_at),
			"rotated_by": str(row.get("rotated_by", "")),
			"requires_2fa": int(row.get("requires_2fa", 0)) == 1,
		})
	return result


func get_all_secret_versions_raw() -> Array:
	## Every archived value, including those of deleted secrets: [{handle,
	## version, ciphertext, iv, mac}].
	var rows := _exec_select("SELECT handle, version, ciphertext, iv, mac FROM docket_secret_versions;")
	var result: Array = []
	for row in rows:
		result.append({
			"handle": str(row.handle),
			"version": int(row.version),
			"ciphertext": row.ciphertext as PackedByteArray,
			"iv": row.iv as PackedByteArray,
			"mac": row.mac as PackedByteArray,
		})
	return result


## Re-encrypts this vault from `old_key` to `new_key`, current and archived
## values alike, in one transaction, keeping its salt and cost and each value's
## requires_2fa flag and owner. Only the outer layer is re-wrapped, which is
## right for 2FA values too. Returns "" or the error, and on an error nothing
## is changed — including when a value does not decrypt under `old_key`,
## which the new key must not be installed over. Within a step of `op` (or an
## operation of its own).
func rewrap_vault(old_key: PackedByteArray, new_key: PackedByteArray, op: RefCounted = null) -> String:
	return _writing_text(op, _rewrap_vault.bind(old_key, new_key))


func _rewrap_vault(step: RefCounted, old_key: PackedByteArray, new_key: PackedByteArray) -> String:
	var txn := _begin_transaction(step)
	if txn.has("error"): return txn.error
	return _complete_transaction(step, txn.ticket, _rewrap_vault_rows(step, old_key, new_key))


# The rows are read here, inside the transaction, so they are the ones being
# replaced. A failed write fails the transaction (see _write).
func _rewrap_vault_rows(step: RefCounted, old_key: PackedByteArray, new_key: PackedByteArray) -> String:
	if not verify_vault(old_key):
		return "The vault password does not match."
	for secret: Dictionary in get_all_secrets_raw():
		var opened := VaultCrypto.decrypt_checked(secret.ciphertext, secret.iv, secret.mac, old_key)
		if opened.is_empty():
			return "Secret '%s' does not decrypt with the current password." % secret.handle
		var encrypted := VaultCrypto.encrypt(opened.value, new_key)
		_write(step, "UPDATE docket_secrets SET ciphertext=?, iv=?, mac=? WHERE handle=?;",
			[encrypted.ciphertext, encrypted.iv, encrypted.mac, secret.handle])
	for version: Dictionary in get_all_secret_versions_raw():
		var opened := VaultCrypto.decrypt_checked(version.ciphertext, version.iv, version.mac, old_key)
		if opened.is_empty():
			return "Version %d of secret '%s' does not decrypt with the current password." % [version.version, version.handle]
		var encrypted := VaultCrypto.encrypt(opened.value, new_key)
		_write(step, "UPDATE docket_secret_versions SET ciphertext=?, iv=?, mac=? WHERE handle=? AND version=?;",
			[encrypted.ciphertext, encrypted.iv, encrypted.mac, version.handle, version.version])
	return init_vault_checked(new_key, get_vault_salt(), get_vault_iterations(), step)
