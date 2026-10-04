extends Node
## Real encrypted child MCP and AppShell/RecordForm consumers, never key-state-only.
const Fixture := preload("res://test/test_host_vault.gd")
const MCP_WRITES := """
        metadata_before = {k: json.loads(path.read_text().splitlines()[0]).get(k) for k in ('vault_salt','vault_verify','vault_kdf_iterations')}
        call(p, 'docket_secret_set', dict(project=name, handle='written', value=values[0]))
        call(p, 'docket_secret_set', dict(project=name, handle='written', value=values[1]))
        assert call(p, 'docket_secret_get', dict(project=name, handle='written'))['value'] == values[1], 'hosted write current'
        assert call(p, 'docket_secret_get', dict(project=name, handle='written', version=1))['value'] == values[0], 'hosted write archive'
        secondary = secrets.token_hex(16)
        call(p, 'docket_secret_set', dict(project=name, handle='written-dual', value=values[0], requires_2fa=True, secondary_password=secondary), kdf_stage='consumer_secondary_write')
        call(p, 'docket_secret_set', dict(project=name, handle='written-dual', value=values[1], requires_2fa=True, secondary_password=secondary), kdf_stage='consumer_secondary_write')
        assert 'secondary password' in call(p, 'docket_secret_get', dict(project=name, handle='written-dual'), True)['error'], 'hosted written 2FA refusal'
        assert call(p, 'docket_secret_get', dict(project=name, handle='written-dual', secondary_password=secondary), kdf_stage='consumer_secondary_current')['value'] == values[1], 'hosted written 2FA current'
        assert call(p, 'docket_secret_get', dict(project=name, handle='written-dual', secondary_password=secondary, version=1), kdf_stage='consumer_secondary_archive')['value'] == values[0], 'hosted written 2FA archive'
        promoted = call(p, 'docket_secret_promote', dict(project=name, handle='written', title='owned encrypted value'))
        assert 'collides' in call(p, 'docket_secret_set', dict(project=name, handle=promoted['id'], value=values[0]), True)['error'], 'hosted ownership refusal'
        call(p, 'docket_flush', dict(project=name))
        before[i] = path.read_bytes()
        assert {k: json.loads(path.read_text().splitlines()[0]).get(k) for k in metadata_before} == metadata_before, 'hosted write metadata changed'
        fields = {k:d[k] for k in ('path','open_generation','fingerprint')}
        private(p, 'vault_lock', fields)
        assert 'locked' in call(p, 'docket_secret_set', dict(project=name, handle='entry', value=values[0]), True)['error'], 'hosted locked write refusal'
        assert path.read_bytes() == before[i], 'hosted locked write mutated bytes'
        assert 'error' in unlock(p, d, passwords[1-i], kdf_stage='vault_unlock'), 'hosted wrong opening password accepted'
        assert 'locked' in call(p, 'docket_secret_set', dict(project=name, handle='entry', value=values[0]), True)['error'], 'hosted wrong key write refusal'
        assert path.read_bytes() == before[i], 'hosted wrong key write mutated bytes'
        assert unlock(p, d, passwords[i], kdf_stage='vault_unlock')['result']['unlocked'], 'hosted write re-unlock'
"""

func test_actual_child_encrypted_writes() -> Variant:
	var anchor := "        # Authorized response plaintext"
	if Fixture.DRIVER.count(anchor) != 1: return "Host vault consumer insertion anchor missing or duplicated"
	var scenario := Fixture.DRIVER.replace(anchor, MCP_WRITES + anchor)
	if scenario == Fixture.DRIVER: return "Host vault consumer insertion did not change source"
	scenario = scenario.replace("    empty_before = empty_path.read_bytes()", "    call(p, 'docket_flush', dict(project='empty'))\n    empty_before = empty_path.read_bytes()\n    assert 'locked' in call(p, 'docket_secret_set', dict(project='empty', handle='new', value=values[0]), True)['error'], 'vault-less write refusal'\n    assert 'locked' in call(p, 'docket_secret_get', dict(project='empty', handle='new'), True)['error'], 'vault-less read refusal'")
	var fixture := Fixture.new()
	var result: Variant = fixture.run_actual_child(scenario)
	fixture.free()
	return result

var _dbs: Array[DocketDB] = []
var _shell: AppShell
var _server: DocketHttpServer
var _authority: DocketHostAuthority
var _state: AppState
var _old_directory: String
var _old_hosted: bool
var _directory: String
var _token := "a".repeat(64)

func _private(method: String, db: DocketDB, password: String = "") -> Dictionary:
	var params := {"panel_secret":_token, "path":ProjectOpenings.normalized_path(db.get_path())}
	if method != "vault_challenge":
		var challenge := _authority.handle("docket/panel/vault_challenge", params)
		if challenge.has("error"): return challenge
		params.merge({"open_generation":challenge.result.open_generation, "fingerprint":challenge.result.fingerprint})
	if method == "vault_unlock": params.password = password
	return _authority.handle("docket/panel/" + method, params)

func _decrypt(raw: Dictionary, key: PackedByteArray, secondary: PackedByteArray = PackedByteArray()) -> String:
	if raw.is_empty(): return ""
	if secondary.is_empty(): return VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, key)
	return VaultCrypto.decrypt_2fa(raw.ciphertext, raw.iv, raw.mac, key, secondary)

func _produce(name: String, password: String, iterations: int) -> DocketDBJsonl:
	var db := DocketDBJsonl.create_new_jsonl(_directory.path_join(name + ".dct"))
	_dbs.append(db)
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key(password, salt, iterations)
	db.init_vault(key, salt, iterations)
	# Existing ordinary tool produces genuine ciphertext and rotation; promotion
	# makes its real owned item, rather than bypassing the GUI's type registry.
	UserPrefs.save_vault_password(password)
	var tools := ToolRegistry.new()
	tools.init(_state.schema, db, {name:db})
	tools.call_tool("docket_secret_set", {"handle":"seed", "value":"synthetic-old-" + name})
	tools.call_tool("docket_secret_set", {"handle":"seed", "value":"synthetic-current-" + name})
	var promoted: Dictionary = tools.call_tool("docket_secret_promote", {"handle":"seed", "title":"Secret " + name})
	db.set_meta_value("fixture_secret", str(promoted.get("id", "")))
	var notes := VaultCrypto.encrypt("synthetic-notes-" + name, key)
	var id := str(promoted.get("id", ""))
	db.set_secret(id + ":notes", notes.ciphertext, notes.iv, notes.mac, false, id)
	# Existing compatibility item route; Encrypted Note is no longer creatable.
	var note_id := DocketDB.generate_uuid7()
	db.insert_item(note_id, {"id":note_id, "type":"encrypted_note", "status":"draft", "title":"Encrypted Note", "created_at":"2026-01-01T00:00:00", "updated_at":"2026-01-01T00:00:00"})
	db.set_secret(note_id, notes.ciphertext, notes.iv, notes.mac, false, note_id)
	db.set_meta_value("fixture_note", note_id)
	db.flush()
	return db

func _respond_secondary(form: RecordForm, confirm: bool, password: String, count: int = 1) -> void:
	for _prompt in count:
		await get_tree().process_frame
		while not form._secret_2fa_dialog.visible:
			await get_tree().process_frame
		form._secret_2fa_input.text = password
		form._secret_2fa_dialog.hide()
		if confirm: form._secret_2fa_dialog.confirmed.emit()
		else: form._secret_2fa_dialog.canceled.emit()

func _secret_form_snapshot(form: RecordForm) -> Dictionary:
	return {"id":form._current_id, "project":form._current_project, "generation":form._form_generation,
		"title":form._title_edit.text, "description":form._desc_edit.text, "id_label":form._id_label.text,
		"secret":form._secret_value_edit.text, "notes":form._encrypted_notes_edit.text,
		"secret_cache":form._secret_value_decrypted, "notes_cache":form._encrypted_notes_decrypted,
		"error":form._secret_vault_error_label.text, "error_visible":form._secret_vault_error_label.visible}

func _invalidate_pending_prompt(form: RecordForm, db: DocketDB, action: String, other_id: String = "", project: String = "", preserved: Dictionary = {}) -> void:
	await get_tree().process_frame
	while not form._secret_2fa_dialog.visible:
		await get_tree().process_frame
	if action == "lock":
		_private("vault_lock", db)
	elif action == "switch":
		form.load_item(other_id, project)
		form._title_edit.text = "synthetic-new-title-edit"
		form._desc_edit.text = "synthetic-new-description-edit"
		form._secret_value_edit.text = "synthetic-new-secret-edit"
		form._encrypted_notes_edit.text = "synthetic-new-notes-edit"
		preserved.merge(_secret_form_snapshot(form))
	elif action == "close":
		db.close()
	form._secret_2fa_input.text = "synthetic-secondary"
	form._secret_2fa_dialog.hide()
	form._secret_2fa_dialog.confirmed.emit()

func test_real_gui_current_edit_history_and_refusals() -> Variant:
	_old_directory = DocketRuntimeState.directory
	_old_hosted = DocketRuntimeState.hosted
	_directory = ProjectSettings.globalize_path("user://host-vault-consumers")
	DirAccess.make_dir_recursive_absolute(_directory)
	DocketRuntimeState.directory = _directory
	DocketRuntimeState.hosted = false
	_state = AppState.new()
	_state.schema = TypeRegistryBootstrap.load_shipped_schema()
	_state.prefs = UserPrefs.new()
	var passwords := ["synthetic-consumer-legacy", "synthetic-consumer-current"]
	for i in 2:
		var name := "legacy" if i == 0 else "current"
		var db := _produce(name, passwords[i], 10000 if i == 0 else 600000)
		_state._project_dbs[name] = db
		_state._type_registries[name] = TypeRegistry.for_db(db, name)
	_state.db = _dbs[0]
	# Producer-only credential exception ends before hosted operations.
	UserPrefs.clear_vault_password()
	var empty := DocketDBJsonl.create_new_jsonl(_directory.path_join("empty.dct"))
	_dbs.append(empty)
	_state._project_dbs.empty = empty
	_state._type_registries.empty = TypeRegistry.for_db(empty, "empty")
	_shell = AppShell.new()
	_shell.init(_state)
	add_child(_shell)
	_server = DocketHttpServer.new()
	_server.external_state = _state
	_authority = DocketHostAuthority.new()
	OS.set_environment(DocketHostAuthority.SECRET_ENV, _token)
	if not _authority.configure_from_environment(true, true).is_empty(): return "private authority configuration"
	_authority.resolve_vault = _server._resolve_vault
	DocketRuntimeState.hosted = true
	var form := _shell._record_form
	if form._secret_2fa_dialog.get_parent() != form: return "secondary dialog ownership"
	for i in 2:
		var name := "legacy" if i == 0 else "current"
		var db := _dbs[i]
		var id := db.get_meta_value("fixture_secret", "")
		var note_id := db.get_meta_value("fixture_note", "")
		var metadata := VaultKeySession.descriptor(db)
		var key := VaultCrypto.derive_key(passwords[i], db.get_vault_salt(), db.get_vault_iterations())
		if _server._resolve_vault(ProjectOpenings.normalized_path(db.get_path())) != _state.get_db_for_project(name): return "GUI/private resolver opening mismatch"
		_private("vault_lock", db)
		form.load_item(id, name)
		if not form._secret_vault_error_label.visible or not form._secret_vault_error_label.text.contains("locked"): return "locked GUI secret read invisible"
		form.load_item(note_id, name)
		if not form._secret_vault_error_label.visible or not form._secret_vault_error_label.text.contains("locked"): return "locked GUI note read invisible"
		for password in [passwords[1-i], passwords[i]]:
			var reply := _private("vault_unlock", db, password)
			if password == passwords[1-i]:
				if not reply.has("error"): return "wrong opening key accepted"
				db.flush()
				var before := FileAccess.get_file_as_bytes(db.get_path())
				form._encrypted_notes_edit.text = "synthetic-refused"
				var refused: Variant = await form._save_changes()
				if str(refused).is_empty() or not form._secret_vault_error_label.visible or FileAccess.get_file_as_bytes(db.get_path()) != before: return "wrong key GUI write changed bytes"
			elif reply.has("error"): return "GUI private unlock failed"
		form.load_item(id, name)
		if form._secret_value_decrypted != "synthetic-current-" + name or form._encrypted_notes_decrypted != "synthetic-notes-" + name: return "real GUI secret/notes load"
		var versions := db.get_secret_versions(id)
		if versions.size() != 1: return "producer archive missing"
		var history_button := form._secret_history_container.get_child(form._secret_history_container.get_child_count()-1).get_child(1) as Button
		# Find the actual history Show button (optional author label precedes it).
		for widget in form._secret_history_container.get_child(form._secret_history_container.get_child_count()-1).get_children():
			if widget is Button and widget.text == "Show": history_button = widget
		history_button.pressed.emit()
		if history_button.text != "synthetic-old-" + name: return "actual GUI history decrypt"
		form._secret_value_edit.text = "synthetic-edited-" + name
		form._encrypted_notes_edit.text = "synthetic-edited-notes-" + name
		var saved: Variant = await form._save_changes()
		if not str(saved).is_empty(): return "GUI secret edit refused"
		if _decrypt(db.get_secret_raw(id), key) != "synthetic-edited-" + name or _decrypt(db.get_secret_raw(id + ":notes"), key) != "synthetic-edited-notes-" + name: return "independent GUI secret ciphertext decrypt"
		versions = db.get_secret_versions(id)
		if versions.size() != 2 or _decrypt(versions[0], key) != "synthetic-current-" + name: return "GUI edit archive ciphertext"
		form.load_item(note_id, name)
		if form._encrypted_notes_decrypted != "synthetic-notes-" + name: return "real GUI encrypted note load"
		form._encrypted_notes_edit.text = "synthetic-edited-body-" + name
		saved = await form._save_changes()
		if not str(saved).is_empty() or _decrypt(db.get_secret_raw(note_id), key) != "synthetic-edited-body-" + name: return "independent GUI note edit ciphertext"
		# Reloading the same item changes generation even though id/project match.
		form.load_item(id, name)
		db.flush()
		var reload_before := FileAccess.get_file_as_bytes(db.get_path())
		form._secret_value_edit.text = "synthetic-stale-reload"
		form._secret_2fa_check.button_pressed = true
		var reloaded := {}
		_invalidate_pending_prompt(form, db, "switch", id, name, reloaded)
		saved = await form._save_changes()
		if str(saved).is_empty() or reloaded.is_empty() or _secret_form_snapshot(form) != reloaded or FileAccess.get_file_as_bytes(db.get_path()) != reload_before: return "pending secondary write erased reloaded form edits"
		form.load_item(id, name)
		form._secret_value_edit.text = "synthetic-dual-" + name
		form._secret_2fa_check.button_pressed = true
		_respond_secondary(form, false, "")
		saved = await form._save_changes()
		if str(saved).is_empty(): return "secondary cancel accepted write"
		_respond_secondary(form, true, "synthetic-secondary", 2)
		saved = await form._save_changes()
		var secondary := VaultCrypto.derive_key("synthetic-secondary", db.get_vault_salt(), db.get_vault_iterations())
		if not str(saved).is_empty() or _decrypt(db.get_secret_raw(id), key, secondary) != "synthetic-dual-" + name: return "secondary confirm real encryption"
		await get_tree().process_frame
		await get_tree().process_frame
		_respond_secondary(form, false, "")
		await form._load_secret_value(db)
		if not form._secret_vault_error_label.visible or not form._secret_value_decrypted.is_empty(): return "secondary read cancel invisible"
		_respond_secondary(form, true, "synthetic-secondary")
		await form._load_secret_value(db)
		if form._secret_value_decrypted != "synthetic-dual-" + name: return "secondary read confirm failed"
		# Lock wins even after the real dialog has acquired a primary key.
		db.flush()
		var pending_before := FileAccess.get_file_as_bytes(db.get_path())
		_invalidate_pending_prompt(form, db, "lock")
		await form._load_secret_value(db)
		if not form._secret_vault_error_label.visible or not form._secret_vault_error_label.text.contains("locked") or not form._secret_value_decrypted.is_empty(): return "pending secondary read ignored lock"
		for legacy_save in [false, true]:
			if _private("vault_unlock", db, passwords[i]).has("error"): return "pending save unlock"
			form._secret_value_edit.text = "synthetic-pending-refused"
			form._secret_2fa_check.button_pressed = true
			_invalidate_pending_prompt(form, db, "lock")
			saved = await form._save_encrypted_secret(db, id) if legacy_save else await form._save_changes()
			if str(saved).is_empty() or not form._secret_vault_error_label.visible or not form._secret_vault_error_label.text.contains("locked") or FileAccess.get_file_as_bytes(db.get_path()) != pending_before: return "pending secondary write ignored lock"
		if _private("vault_unlock", _dbs[1-i], passwords[1-i]).has("error"): return "new form opening unlock"
		# Every prompt consumer and prepared-payload caller preserves the new form.
		for consumer in ["read", "save", "transition", "legacy", "draft"]:
			if _private("vault_unlock", db, passwords[i]).has("error"): return "pending switch unlock"
			_respond_secondary(form, false, "")
			form.load_item(id, name)
			await get_tree().process_frame
			await get_tree().process_frame
			if consumer == "draft": form.load_draft("secret", {"title":"synthetic-draft", "status":"draft"}, name)
			form._secret_value_edit.text = "synthetic-pending-refused"
			form._secret_2fa_check.button_pressed = true
			var preserved := {}
			var other_project := "current" if i == 0 else "legacy"
			var other_note := _dbs[1-i].get_meta_value("fixture_note", "")
			_invalidate_pending_prompt(form, db, "switch", other_note, other_project, preserved)
			if consumer == "read":
				await form._load_secret_value(db)
			elif consumer == "legacy":
				saved = await form._save_encrypted_secret(db, id)
			elif consumer == "transition":
				saved = await form._do_status_transition("active", "")
			else:
				saved = await form._save_changes()
			if consumer != "read" and (bool(saved) if consumer == "transition" else str(saved).is_empty()): return "pending secondary write followed switched form"
			if preserved.is_empty() or _secret_form_snapshot(form) != preserved or FileAccess.get_file_as_bytes(db.get_path()) != pending_before: return "old secondary prompt mutated new form or edits: " + consumer
		_private("vault_lock", db)
		form.load_item(id, name)
		db.flush()
		var before := FileAccess.get_file_as_bytes(db.get_path())
		form._secret_value_edit.text = "synthetic-refused"
		saved = await form._save_changes()
		if str(saved).is_empty() or not form._secret_vault_error_label.visible or FileAccess.get_file_as_bytes(db.get_path()) != before: return "locked GUI write changed bytes"
		form._on_history_show(db.get_secret_versions(id)[0], form._secret_history_container.get_child(form._secret_history_container.get_child_count()-1).get_child(2))
		if not form._secret_vault_error_label.visible: return "locked history refusal invisible"
		if VaultKeySession.descriptor(db) != metadata: return "GUI consumer changed vault metadata"
		var text := FileAccess.get_file_as_string(db.get_path())
		for needle in [passwords[i], "synthetic-current-" + name, "synthetic-edited-" + name, "synthetic-edited-notes-" + name, "synthetic-edited-body-" + name, "synthetic-dual-" + name]:
			if text.contains(needle): return "GUI persisted plaintext"
	var closing_db := _dbs[1]
	var closing_id := closing_db.get_meta_value("fixture_secret", "")
	if _private("vault_unlock", closing_db, passwords[1]).has("error"): return "pending close unlock"
	_respond_secondary(form, false, "")
	form.load_item(closing_id, "current")
	await get_tree().process_frame
	await get_tree().process_frame
	closing_db.flush()
	var closed_before := FileAccess.get_file_as_bytes(closing_db.get_path())
	_invalidate_pending_prompt(form, closing_db, "close")
	await form._load_secret_value(closing_db)
	if not form._secret_vault_error_label.visible or not form._secret_vault_error_label.text.contains("changed") or not form._secret_value_decrypted.is_empty() or FileAccess.get_file_as_bytes(closing_db.get_path()) != closed_before: return "pending secondary read ignored close"
	empty.flush()
	var empty_before := FileAccess.get_file_as_bytes(empty.get_path())
	form._load_secret_value(empty)
	form._load_encrypted_notes(empty, "absent")
	var missing: Dictionary = await form._prepare_protected_payload(empty, "absent", "encrypted_note")
	if not missing.has("error") or not form._secret_vault_error_label.visible or empty.has_vault() or FileAccess.get_file_as_bytes(empty.get_path()) != empty_before: return "missing GUI vault initialized or silent"
	print("HOST VAULT actual GUI encrypted consumers PASS")
	return true

func teardown() -> void:
	if _shell: _shell.free()
	if _server: _server.free()
	for db in _dbs:
		if db.is_open(): db.close()
	_dbs.clear()
	if not _directory.is_empty():
		for filename in DirAccess.get_files_at(_directory): DirAccess.remove_absolute(_directory.path_join(filename))
		DirAccess.remove_absolute(_directory)
		DocketRuntimeState.directory = _old_directory
		DocketRuntimeState.hosted = _old_hosted
