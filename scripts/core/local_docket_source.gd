extends "res://scripts/ui/docket_source.gd"
class_name LocalDocketSource
## The DocketSource of the standalone app: the projects AppState holds open in
## this process, read and changed directly.

var _state: AppState
# The last vault key verified against the stored password, so the checks and
# the read or write that follows them derive it (600k PBKDF2 rounds) only
# once. Keyed by a digest of (password, salt, iterations); dropped when the
# password is changed here, found cleared or wrong on use, or the open
# projects change (a password changed elsewhere replaces it on next use).
var _key_digest := ""
var _key := PackedByteArray()


func _init(state: AppState) -> void:
	_state = state
	# Bound signals, not lambdas: a lambda would hold this source and, through
	# AppState, form a reference cycle that is never freed.
	_state.file_changed.connect(file_changed.emit)
	_state.data_changed.connect(data_changed.emit)
	_state.load_failed.connect(load_failed.emit)
	_state.open_item_requested.connect(open_item_requested.emit)
	_state.open_query_requested.connect(open_query_requested.emit)
	_state.file_changed.connect(_forget_key)
	# A failed open_project has already closed the projects it was to replace
	# (after a failed add_project, forgetting only costs a re-derivation).
	_state.load_failed.connect(_forget_key.unbind(2))


# -- Projects -------------------------------------------------------------------

func project_names() -> Array[String]:
	var names: Array[String] = []
	for name in _state.get_project_dbs().keys():
		names.append(str(name))
	names.sort_custom(func(a: String, b: String) -> bool: return a.nocasecmp_to(b) < 0)
	return names


func schema() -> Dictionary:
	return _state.schema


func primary_project() -> String:
	return _state.db.get_project_name() if _state.db != null else ""


func primary_path() -> String:
	return _state.dct_path


func project_paths() -> Dictionary:
	var paths := {}
	for name in _state.get_project_dbs():
		paths[str(name)] = (_state.get_project_dbs()[name] as DocketDB).get_path()
	return paths


func prefs():
	return _state.prefs


func open_project(path: String) -> void:
	_state.load_dct(path)


func add_project(path: String) -> void:
	_state.add_project(path)


func create_project(path: String) -> void:
	if _state.get_project_dbs().size() > 0:
		_state.create_and_add_project(path)
	else:
		_state.create_dct(path)


func remove_project(project: String) -> void:
	_state.remove_project(project)


func save_all() -> void:
	_state.save()


func save_primary_as(path: String) -> void:
	_state.dct_path = path
	_state.save()


func change_token() -> String:
	var parts: Array[String] = []
	var projects: Array = _state.get_project_dbs().keys()
	projects.sort()
	for project in projects:
		var path := (_state.get_db_for_project(str(project)) as DocketDB).get_path()
		var canonical_hash := FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "missing"
		var wal := path + "-wal"
		var wal_stamp := str(FileAccess.get_modified_time(wal)) if FileAccess.file_exists(wal) else ""
		parts.append("%s:%s:%s" % [project, canonical_hash, wal_stamp])
	return "|".join(parts)


func reload_stale() -> Array:
	return _state.reload_stale()


func reload_all() -> Array:
	return _state.reload_all()


## Kept per machine (UserPrefs). A value not stored there yet is taken once
## from the primary project's file, where earlier versions kept it.
func ui_setting(key: String, default_value: String) -> String:
	if UserPrefs.has_ui_setting(key):
		return UserPrefs.load_ui_setting(key, default_value)
	var inherited: String = _state.db.get_meta_value(key, "") if _state.db else ""
	if inherited.is_empty():
		return default_value
	UserPrefs.save_ui_setting(key, inherited)
	return inherited


func set_ui_setting(key: String, value: String) -> void:
	UserPrefs.save_ui_setting(key, value)


func tool_count() -> int:
	var registry := ToolRegistry.new()
	registry.init(_state.schema, _state.db, _state.get_project_dbs())
	return registry.list_tools().size()


# -- Items --------------------------------------------------------------------------

func item_token(project: String, id: String) -> String:
	if id.is_empty():
		return ""
	var item_db: DocketDB = _state.get_db_for_project(project)
	if item_db == null:
		return ""
	var item: Dictionary = item_db.get_item(id)
	if item.is_empty():
		return ""
	var registry := _state.get_type_registry(project)
	return registry.item_token(item) if registry != null else ""


func item_title(project: String, id: String) -> Dictionary:
	var item_db: DocketDB = _state.get_db_for_project(project)
	if item_db == null or not item_db.has_item(id):
		return {}
	return {"title": str(item_db.get_item(id).get("title", ""))}


func item_view(project: String, id: String, refresh: bool = false) -> Dictionary:
	var item_db: DocketDB = _state.get_db_for_project(project) if not project.is_empty() else null
	if id.is_empty() or item_db == null:
		return {"error": "the originating project is closed", "kind": "closed"}
	var registry := _state.get_type_registry(project)
	if registry == null:
		return {"error": "type registry unavailable", "kind": "registry"}
	if refresh:
		var refresh_error := registry.refresh_if_changed()
		if not refresh_error.is_empty():
			return {"error": refresh_error, "kind": "refresh"}
	var item: Dictionary = item_db.get_item(id)
	if item.is_empty():
		return {"error": "item no longer exists in %s" % project, "kind": "missing"}
	return {"item": item, "resolved": registry.resolve_item(item), "token": registry.item_token(item),
		"short_id": item_db.short_id(id) if DocketFields.is_uuid7(id) else id}


func item_events(project: String, id: String) -> Array:
	var item_db: DocketDB = _state.get_db_for_project(project)
	if item_db == null or not item_db.has_item(id):
		return []
	return item_db.get_item(id).get("events", [])


func attach_file(project: String, id: String, filename: String, data: PackedByteArray, mime: String,
		description: String) -> Dictionary:
	var item_db: DocketDB = _state.get_db_for_project(project)
	if item_db == null or not item_db.has_item(id):
		return {"error":"originating project is closed or item is missing"}
	return item_db.attach_file(id, filename, data, mime, description)


func children_of(qualified_id: String) -> Dictionary:
	return {"children": _state.find_children_across_projects(qualified_id), "error": ""}


func move_item(project: String, id: String, target_project: String) -> Dictionary:
	return _state.move_item(id, target_project, project)


func save_item(project: String, id: String, changes: Dictionary, revision: String, token: String,
		secret: Dictionary = {}) -> String:
	var item_db: DocketDB = _state.get_db_for_project(project)
	var registry := _state.get_type_registry(project)
	if item_db == null or registry == null:
		return "the originating project is closed"
	var protected := not secret.is_empty()
	var prepared: Dictionary = _vault_operations(item_db, id, secret) if protected else {"operations": []}
	if prepared.has("error"):
		return str(prepared.error)
	var error := registry._begin_item_mutation() if protected else ""
	if error.is_empty():
		error = registry.update_item(id, changes, "user", revision, token)
	if error.is_empty() and protected:
		error = _apply_vault_operations(item_db, prepared.operations)
	if protected:
		error = registry._complete_item_mutation(error)
	return error


func create_item(project: String, fields: Dictionary, secret: Dictionary = {}) -> Dictionary:
	var target_db: DocketDB = _state.get_db_for_project(project)
	var registry := _state.get_type_registry(project)
	if target_db == null or registry == null:
		return {"error": "the originating project is closed"}
	var type_name := str(fields.get("type", ""))
	var type_record: Dictionary = registry.get_type(type_name)
	var definition_protected: bool = not type_record.has("error") and bool(type_record.definition.get("protected", false))
	var protected_payload := not secret.is_empty()
	var regular_allowed: bool = bool(type_record.get("definition", {}).get("protected_behavior", {}).get("regular_creation_allowed", true))
	var prepared: Dictionary = _vault_operations(target_db, "", secret) if protected_payload else {"operations": []}
	if prepared.has("error"):
		return {"error": str(prepared.error)}
	var transaction_error := registry._begin_item_mutation() if protected_payload else ""
	if not transaction_error.is_empty():
		return {"error": transaction_error}
	var created := registry.create_item(fields, "user")
	if created.has("error") and definition_protected and not regular_allowed and protected_payload:
		created = _create_protected_draft(target_db, type_name, fields)
	if created.has("error"):
		if protected_payload:
			registry._complete_item_mutation(str(created.error))
		return {"error": str(created.error)}
	var id := str(created.id)
	if protected_payload:
		for operation_value in prepared.operations:
			var operation: Dictionary = operation_value
			operation.handle = id + str(operation.get("suffix", ""))
			operation.owner = id
		transaction_error = _apply_vault_operations(target_db, prepared.operations)
		transaction_error = registry._complete_item_mutation(transaction_error)
	if not transaction_error.is_empty():
		return {"error": transaction_error, "payload_failed": true}
	return {"id": id}


func _create_protected_draft(target_db: DocketDB, type_name: String, fields: Dictionary) -> Dictionary:
	var flat := fields.duplicate(true)
	flat.erase("type")
	flat.erase("unset_fields")
	var custom: Dictionary = flat.get("fields", {})
	flat.erase("fields")
	for key in custom:
		flat[key] = custom[key]
	var item := DataModel.create_item(_state.schema, type_name, flat)
	if item.has("error"):
		return item
	var id := target_db.next_uuid7_id()
	var error := target_db.insert_item(id, item)
	if error is String and not error.is_empty():
		return {"error":error}
	return {"id":id, "item":target_db.get_item(id)}


func transition_item(project: String, id: String, target: String, note: String, changes: Dictionary,
		revision: String, token: String, secret: Dictionary = {}) -> String:
	var trans_db: DocketDB = _state.get_db_for_project(project)
	var registry := _state.get_type_registry(project)
	if trans_db == null or registry == null:
		return "The originating project is closed."
	var protected := not secret.is_empty()
	var prepared: Dictionary = _vault_operations(trans_db, id, secret) if protected else {"operations": []}
	if prepared.has("error"):
		return str(prepared.error)
	var error := registry._begin_item_mutation() if protected else ""
	if error.is_empty():
		error = registry.transition_item(id, target, "user", note, changes, revision, token)
	if error.is_empty() and protected:
		error = _apply_vault_operations(trans_db, prepared.operations)
	if protected:
		error = registry._complete_item_mutation(error)
	return error


# -- Comments -------------------------------------------------------------------------

func list_comments(project: String, id: String) -> Array:
	var db: DocketDB = _state.get_db_for_project(project)
	return [] if db == null else db.list_comments(id)


func add_comment(project: String, id: String, author: String, text: String, parent_id: int = 0) -> Dictionary:
	var db: DocketDB = _state.get_db_for_project(project)
	return {"error": "the originating project is closed"} if db == null else db.add_comment(id, author, text, parent_id)


func resolve_comment(project: String, comment_id: int, resolution: String, by: String) -> Dictionary:
	var db: DocketDB = _state.get_db_for_project(project)
	return {"error": "the originating project is closed"} if db == null else db.resolve_comment(comment_id, resolution, by)


# -- Type snapshot --------------------------------------------------------------------

func cached_types(project: String) -> Array:
	var registry := _state.get_type_registry(project)
	if registry == null:
		return []
	return registry.list_types(false).filter(func(type) -> bool: return type is Dictionary and not type.has("error"))


func cached_type(project: String, slug: String) -> Dictionary:
	var registry := _state.get_type_registry(project)
	return {"error": "type registry unavailable"} if registry == null else registry.get_type(slug)


func cached_resolve(project: String, item: Dictionary) -> Dictionary:
	var registry := _state.get_type_registry(project)
	return {"error": "type registry unavailable"} if registry == null else registry.resolve_item(item)


# -- Vault ----------------------------------------------------------------------------

func vault_problem(project: String) -> String:
	var db: DocketDB = _state.get_db_for_project(project)
	if db == null:
		return "the originating project is closed"
	var stored := _stored_key(db)
	return "" if stored.has("key") or stored.get("no_vault", false) else str(stored.error)


## `db`'s vault key from the stored password, creating the vault when it has
## none: {key} or {error}.
func _ensure_vault(db: DocketDB) -> Dictionary:
	var stored := _stored_key(db)
	if not stored.get("no_vault", false):
		return stored
	var salt := VaultCrypto.generate_salt()
	var new_key := _derive_key(UserPrefs.load_vault_password(), salt, VaultCrypto.PBKDF2_ITERATIONS)
	db.init_vault(new_key, salt, VaultCrypto.PBKDF2_ITERATIONS)
	return {"key": new_key}


## VaultCrypto.derive_key, reusing the last key when the inputs repeat.
func _derive_key(password: String, salt: PackedByteArray, iterations: int) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(("%d:%s:" % [iterations, salt.hex_encode()]).to_utf8_buffer() + password.to_utf8_buffer())
	var digest := ctx.finish().hex_encode()
	if digest != _key_digest:
		_key = VaultCrypto.derive_key(password, salt, iterations)
		_key_digest = digest
	return _key


## `db`'s vault key from the stored password, or empty when there is no
## password, no vault, or it does not match.
func _vault_key(db: DocketDB) -> PackedByteArray:
	return _stored_key(db).get("key", PackedByteArray())


## `db`'s vault key from the stored password, verified: {key}, {no_vault}
## when `db` has no vault yet, or {error}.
func _stored_key(db: DocketDB) -> Dictionary:
	var password := UserPrefs.load_vault_password()
	if password.is_empty():
		_forget_key()
		return {"error": "Vault password not set. Go to Preferences first."}
	if not db.has_vault():
		return {"no_vault": true}
	var key := _derive_key(password, db.get_vault_salt(), db.get_vault_iterations())
	if not db.verify_vault(key):
		_forget_key()
		return {"error": "Vault password does not match."}
	return {"key": key}


func _forget_key() -> void:
	_key = PackedByteArray()
	_key_digest = ""


## The encrypted writes `secret` (see DocketSource.vault_problem) asks of item
## `item_id` ("" for one being created): {operations} or {error}.
func _vault_operations(db: DocketDB, item_id: String, secret: Dictionary) -> Dictionary:
	var ensured := _ensure_vault(db)
	if ensured.has("error"):
		return ensured
	var key: PackedByteArray = ensured.key
	var operations: Array = []
	if secret.get("type") == "secret":
		var requires_2fa := bool(secret.get("requires_2fa", false))
		if secret.has("value"):
			var encrypted: Dictionary
			if requires_2fa:
				var secondary_key := VaultCrypto.derive_key(str(secret.get("secondary_password", "")), db.get_vault_salt(), db.get_vault_iterations())
				encrypted = VaultCrypto.encrypt_2fa(str(secret.value), key, secondary_key)
			else:
				encrypted = VaultCrypto.encrypt(str(secret.value), key)
			operations.append({"handle":item_id, "owner":item_id, "suffix":"", "ciphertext":encrypted.ciphertext, "iv":encrypted.iv, "mac":encrypted.mac, "requires_2fa":requires_2fa, "rotate":not item_id.is_empty() and not db.get_secret_raw(item_id).is_empty()})
		elif bool(secret.get("masked", false)) and not item_id.is_empty():
			var current := db.get_secret_raw(item_id)
			# The flag must describe how the stored value is encrypted: turning a
			# secondary password on or off means encrypting the value again.
			if not current.is_empty() and bool(current.get("requires_2fa", false)) != requires_2fa:
				return {"error": "Changing whether this secret needs a secondary password requires entering its value again."}
		_notes_operation(operations, key, item_id, ":notes", secret)
	elif secret.get("type") == "encrypted_note":
		_notes_operation(operations, key, item_id, "", secret)
	return {"operations":operations}


func _notes_operation(operations: Array, key: PackedByteArray, item_id: String, suffix: String, secret: Dictionary) -> void:
	if not secret.has("notes"):
		return
	var encrypted: Dictionary = VaultCrypto.encrypt(str(secret.notes), key)
	operations.append({"handle":item_id + suffix, "owner":item_id, "suffix":suffix, "ciphertext":encrypted.ciphertext, "iv":encrypted.iv, "mac":encrypted.mac, "requires_2fa":false, "rotate":false})


func _apply_vault_operations(db: DocketDB, operations: Array) -> String:
	for operation_value in operations:
		var operation: Dictionary = operation_value
		var handle := str(operation.handle)
		var error := ""
		if bool(operation.get("rotate", false)):
			if db is DocketDBJsonl:
				error = (db as DocketDBJsonl).rotate_secret_checked(handle, operation.ciphertext, operation.iv, operation.mac, _state.prefs.get_display_name(), bool(operation.requires_2fa))
			else:
				db.rotate_secret(handle, operation.ciphertext, operation.iv, operation.mac, _state.prefs.get_display_name(), bool(operation.requires_2fa))
				error = db._last_sql_error
		elif db is DocketDBJsonl:
			error = (db as DocketDBJsonl).set_secret_checked(handle, operation.ciphertext, operation.iv, operation.mac, bool(operation.requires_2fa), str(operation.owner))
		else:
			db.set_secret(handle, operation.ciphertext, operation.iv, operation.mac, bool(operation.requires_2fa), str(operation.owner))
			error = db._last_sql_error
		if not error.is_empty():
			return error
	return ""


func secret_info(project: String, handle: String) -> Dictionary:
	var db: DocketDB = _state.get_db_for_project(project)
	if UserPrefs.load_vault_password().is_empty():
		_forget_key()
		return {"vault": "no_password", "exists": false, "requires_2fa": false}
	if db == null or _vault_key(db).is_empty():
		return {"vault": "unavailable", "exists": false, "requires_2fa": false}
	var raw := db.get_secret_raw(handle)
	return {"vault": "ok", "exists": not raw.is_empty(), "requires_2fa": bool(raw.get("requires_2fa", false))}


func read_secret(project: String, handle: String, secondary_password: String = "", audit: bool = false) -> Dictionary:
	var db: DocketDB = _state.get_db_for_project(project)
	var key := _vault_key(db) if db != null else PackedByteArray()
	if key.is_empty():
		return {"error": "Vault password mismatch or no vault."}
	var raw := db.get_secret_raw(handle)
	if raw.is_empty():
		return {"value": ""}
	var plaintext: String
	if raw.get("requires_2fa", false):
		if secondary_password.is_empty():
			return {"error": "Secondary password required to view secret."}
		var secondary_key := VaultCrypto.derive_key(secondary_password, db.get_vault_salt(), db.get_vault_iterations())
		plaintext = VaultCrypto.decrypt_2fa(raw.ciphertext, raw.iv, raw.mac, key, secondary_key)
		if plaintext.is_empty():
			if audit:
				AuditLog.record(db.get_path(), AuditLog.READ, handle, false, "gui", "2FA decryption failed")
			return {"error": "Decryption failed. Wrong secondary password or corrupted data."}
		if audit:
			AuditLog.record(db.get_path(), AuditLog.READ, handle, true, "gui", "2fa")
	else:
		plaintext = VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, key)
		if plaintext.is_empty():
			if audit:
				AuditLog.record(db.get_path(), AuditLog.READ, handle, false, "gui", "decryption failed")
			return {"error": "Decryption failed. Data may be corrupted."}
		if audit:
			AuditLog.record(db.get_path(), AuditLog.READ, handle, true, "gui")
	return {"value": plaintext}


func secret_versions(project: String, handle: String) -> Array:
	var db: DocketDB = _state.get_db_for_project(project)
	if db == null:
		return []
	return db.get_secret_versions(handle).map(func(version: Dictionary) -> Dictionary:
		return {"version": version.version, "created_at": version.created_at, "rotated_by": version.get("rotated_by", "")})


func read_secret_version(project: String, handle: String, version: int, secondary_password: String = "") -> Dictionary:
	var db: DocketDB = _state.get_db_for_project(project)
	var key := _vault_key(db) if db != null else PackedByteArray()
	if key.is_empty():
		return {"error": "no vault key", "kind": "no_key"}
	for row in db.get_secret_versions(handle):
		if int(row.version) != version:
			continue
		if not bool(row.requires_2fa):
			var plaintext := VaultCrypto.decrypt(row.ciphertext, row.iv, row.mac, key)
			return {"value": plaintext} if not plaintext.is_empty() else {"error": "decryption failed", "kind": "failed"}
		if secondary_password.is_empty():
			return {"error": "This version needs its secondary password.", "kind": "needs_secondary"}
		var secondary_key := VaultCrypto.derive_key(secondary_password, db.get_vault_salt(), db.get_vault_iterations())
		var inner := VaultCrypto.decrypt_2fa(row.ciphertext, row.iv, row.mac, key, secondary_key)
		return {"value": inner} if not inner.is_empty() else {"error": "Wrong secondary password or corrupted data.", "kind": "failed"}
	return {"error": "no such version", "kind": "failed"}

func standalone_secrets() -> Dictionary:
	var listed := {}
	for project in _state.get_project_dbs():
		var entries: Array = (_state.get_project_dbs()[project] as DocketDB).list_standalone_secrets()
		if not entries.is_empty():
			listed[str(project)] = entries
	return listed


func vault_settings() -> Dictionary:
	return {"password": UserPrefs.load_vault_password(), "hint": UserPrefs.load_vault_password_hint()}


func set_vault_settings(password: String, hint: String) -> String:
	UserPrefs.save_vault_password_hint(hint)
	var old_password := UserPrefs.load_vault_password()
	if password == old_password:
		return ""
	var error := _reencrypt_vault_secrets(old_password, password)
	if not error.is_empty():
		return error
	_forget_key()
	if password.is_empty():
		UserPrefs.clear_vault_password()
	else:
		UserPrefs.save_vault_password(password)
	return ""


## Re-encrypts every open project's vault, current and archived values alike,
## when the vault password changes. Returns "" or why the password must stay
## as it is: nothing is re-encrypted while an open vault does not open with
## the old password, and when one project cannot be re-encrypted (a value in
## it does not decrypt, or its file changed to another password meanwhile),
## those already done are put back under the old password. Projects that are
## not open are not reached.
##
## A dual-password (2FA) value is encrypted twice: an inner layer under a key
## derived from the SECONDARY password, which is never stored, and an outer
## layer under the vault key. Only the outer layer can be re-wrapped, which is
## right for both kinds of value. The secondary key is derived from the vault's
## salt and iteration count too, so both stay as they are: changing either
## would leave every inner layer undecryptable, and an archived value may be
## double-encrypted even where its flag was lost.
func _reencrypt_vault_secrets(old_password: String, new_password: String) -> String:
	if old_password.is_empty() or new_password.is_empty():
		return ""
	var vaults: Array[Dictionary] = []
	for proj_name in _state.get_project_dbs():
		var pdb: DocketDB = _state.get_project_dbs()[proj_name]
		# Whether it has a vault, and under which password, is decided on what
		# the file holds now, not on what was last loaded from it.
		if pdb is DocketDBJsonl:
			(pdb as DocketDBJsonl).ensure_fresh()
		if not pdb.is_open() or (pdb is DocketDBJsonl and (pdb as DocketDBJsonl).is_stale()):
			return "The vault password was not changed: project '%s' could not be read again from disk." % proj_name
		if not pdb.has_vault():
			continue
		var salt := pdb.get_vault_salt()
		var iterations := pdb.get_vault_iterations()
		var old_key := VaultCrypto.derive_key(old_password, salt, iterations)
		if not pdb.verify_vault(old_key):
			return "The vault password was not changed: project '%s' does not open with the current password. Close it, or set the password it uses, first." % proj_name
		vaults.append({"project": proj_name, "db": pdb, "old_key": old_key,
			"new_key": VaultCrypto.derive_key(new_password, salt, iterations)})
	for i in vaults.size():
		var error := (vaults[i].db as DocketDB).rewrap_vault(vaults[i].old_key, vaults[i].new_key)
		if error.is_empty():
			continue
		var message := "The vault password was not changed: project '%s' could not be re-encrypted (%s)." % [vaults[i].project, error]
		for done: Dictionary in vaults.slice(0, i):
			var undo_error := (done.db as DocketDB).rewrap_vault(done.new_key, done.old_key)
			if not undo_error.is_empty():
				message += "\nProject '%s' could not be put back and now opens only with the new password (%s)." % [done.project, undo_error]
		return message
	return ""


# -- Queries ----------------------------------------------------------------------

func run_query(query: Dictionary) -> Dictionary:
	return _state.project_query().run_with_details(query, _state.db)


func type_catalog() -> Dictionary:
	var projects: Array = _state.get_project_dbs().keys()
	projects.sort()
	if projects.is_empty():
		return {"records": TypeCatalog.from_schema(_state.schema), "diagnostic": ""}
	var records: Array = []
	var diagnostic := ""
	for project_value in projects:
		var project := str(project_value)
		var counts := {}
		var project_db = _state.get_db_for_project(project)
		if project_db != null:
			for item in project_db.execute_query({"filter": {}}):
				var slug: String = str(item.get("type", ""))
				counts[slug] = int(counts.get(slug, 0)) + 1
		var registry: TypeRegistry = _state.get_type_registry(project)
		var catalog_result: Dictionary = TypeCatalog.from_registry_checked(registry, counts) if registry != null else {"records":[],"error":"type registry is unavailable"}
		if registry != null and registry.get_diagnostic().is_empty() and str(catalog_result.error).is_empty():
			records.append_array(catalog_result.records)
		else:
			var reason: String = registry.get_diagnostic() if registry != null and not registry.get_diagnostic().is_empty() else str(catalog_result.error)
			diagnostic = "Type catalog unavailable for %s: %s" % [project, reason]
	return {"records": TypeCatalog.sorted(records), "diagnostic": diagnostic}


func resolve_type_ref(project: String, type_ref: String) -> Dictionary:
	var registry := _registry(project)
	return {"error": "The selected project is no longer open."} if registry == null \
		else registry.resolve_type_ref(type_ref)


# -- Type registry --------------------------------------------------------------

func _registry(project: String) -> TypeRegistry:
	return null if project.is_empty() else _state.get_type_registry(project)


func list_types(project: String) -> Dictionary:
	var registry := _registry(project)
	if registry == null:
		return {"error": "Type registry unavailable for %s." % project}
	var listed: Array = registry.list_types(false)
	if not listed.is_empty() and listed[0] is Dictionary and listed[0].has("error"):
		return {"error": "Type registry error: %s" % str(listed[0].error)}
	return {"types": listed}


func get_type(project: String, slug: String) -> Dictionary:
	var registry := _state.get_type_registry(project)
	return {"error": "Type registry unavailable for %s." % project} if registry == null else registry.get_type(slug)


func types_overview(project: String, include_deprecated: bool) -> Dictionary:
	var registry := _registry(project)
	if registry == null:
		return {"error": "Open a project to manage its types.", "kind": "no_project"}
	var db: DocketDB = _state.get_db_for_project(project)
	if db == null:
		return {"error": "The selected project is no longer open.", "kind": "closed"}
	return DocketTypeOverview.overview(registry, db, project, include_deprecated)


func types_problem(project: String) -> String:
	var registry := _registry(project)
	return "Open a project first." if registry == null else registry.get_diagnostic()


func type_with_history(project: String, slug: String) -> Dictionary:
	var registry := _registry(project)
	if registry == null:
		return {"error": "Open a project before selecting a type."}
	var type: Dictionary = registry.get_type(slug)
	if type.has("error"):
		return type
	var described := type.duplicate(true)
	described["revisions"] = registry.revisions_for_type(type.id)
	return described


func type_revision(project: String, revision_id: String) -> Dictionary:
	var registry := _registry(project)
	return {"error": "The selected project is no longer open."} if registry == null \
		else registry.get_revision(revision_id)


func validate_type_definition(project: String, definition: Dictionary) -> String:
	var problem := types_problem(project)
	if not problem.is_empty():
		return problem
	return _registry(project).validate_definition(definition)


func preview_type_evolution(project: String, slug: String, definition: Dictionary,
		expected_revision: String, item_ids: Array) -> Dictionary:
	var registry := _registry(project)
	if registry == null:
		return {"error": "The selected project is no longer open."}
	return registry.preview_evolution(slug, definition, expected_revision, item_ids)


func define_type(project: String, slug: String, definition: Dictionary, author: String,
		reason: String) -> Dictionary:
	var registry := _registry(project)
	if registry == null:
		return {"error": "The selected project is no longer open."}
	return registry.define_type(slug, definition, author, reason)


func apply_type_evolution(project: String, preview: Dictionary, author: String, reason: String) -> String:
	var registry := _registry(project)
	return "The selected project is no longer open." if registry == null \
		else registry.apply_evolution(preview, author, reason)


func set_type_lifecycle(project: String, slug: String, lifecycle: String, expected_revision: String,
		author: String, reason: String) -> String:
	var registry := _registry(project)
	if registry == null:
		return "Open a project before changing a type lifecycle."
	if lifecycle == "active":
		return registry.activate_type(slug, expected_revision, author, reason)
	return registry.deprecate_type(slug, expected_revision, author, reason)


# -- Project format migrations ----------------------------------------------------

func promote_project(project: String) -> Dictionary:
	return _state.promote_project_to_jsonl(project, true)


func preview_project_upgrade(project: String) -> Dictionary:
	var db: DocketDB = _state.get_db_for_project(project)
	if db == null:
		return {"ok": false, "error": "Open a project before previewing an upgrade."}
	if not db is DocketDBJsonl:
		return {"ok": false, "error": "Promote this SQLite project to JSONL first using the explicit action above."}
	var preview: Dictionary = JSONLTypeUpgrade.preview(db.get_path(), _state.schema)
	if bool(preview.get("ok", false)):
		preview["project"] = project
		preview["path"] = db.get_path()
	return preview


func apply_project_upgrade(project: String, preview: Dictionary) -> Dictionary:
	var db: DocketDB = _state.get_db_for_project(project)
	if preview.get("project") != project or db == null or preview.get("path") != db.get_path() \
			or preview.get("source_hash") != FileAccess.get_sha256(db.get_path()):
		return {"ok": false, "stale": true,
			"error": "The project or canonical source changed. Preview this project again before applying."}
	return _state.upgrade_project_to_jsonl_v2(project, preview, true)
