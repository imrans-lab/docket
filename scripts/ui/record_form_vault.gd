extends RefCounted
## The vault part of the item form (RecordForm): showing, copying and
## generating a secret or encrypted note, its version history, and the vault
## input a protected save sends (DocketSource.vault_problem). It works on the
## form's own controls.

var _form  # RecordForm


func _init(form) -> void:
	_form = form


func _show_vault_error(msg: String) -> void:
	_form._secret_vault_error_label.text = msg
	_form._secret_vault_error_label.visible = true


func _load_secret_value() -> void:
	## Decrypt and display secret value for current item.
	_form._secret_vault_error_label.visible = false
	var project: String = _form._current_project
	var id: String = _form._current_id
	var info: Dictionary = await _form._src.secret_info(project, id)
	if info.vault != "ok":
		_form._secret_value_edit.text = ""
		_form._secret_value_decrypted = ""
		if info.vault == "unavailable":
			_show_vault_error("Vault password mismatch or no vault.")
		return
	if not info.exists:
		_form._secret_value_edit.text = ""
		_form._secret_value_decrypted = ""
		return

	_form._secret_2fa_check.button_pressed = info.requires_2fa
	var secondary_pw := ""
	if info.requires_2fa:
		secondary_pw = await _prompt_secondary_password()
		if secondary_pw.is_empty():
			_form._secret_value_edit.text = "********"
			_form._secret_value_decrypted = ""
			_show_vault_error("Secondary password required to view secret.")
			return
	var read: Dictionary = await _form._src.read_secret(project, id, secondary_pw, true)
	if read.has("error"):
		_show_vault_error(str(read.error))
		return

	_form._secret_value_decrypted = str(read.value)
	_form._secret_value_edit.text = "********"
	_form._secret_value_edit.secret = true
	_form._secret_show_btn.text = "Show"
	_form._secret_show_btn.button_pressed = false


func _load_encrypted_notes(handle: String) -> void:
	## Decrypt and display encrypted notes.
	var read: Dictionary = await _form._src.read_secret(_form._current_project, handle)
	if read.has("error") or str(read.value).is_empty():
		_form._encrypted_notes_edit.text = ""
		_form._encrypted_notes_decrypted = ""
		return
	_form._encrypted_notes_decrypted = str(read.value)
	_form._encrypted_notes_edit.text = "********"


func _populate_secret_history() -> void:
	## Show version history for current secret.
	for child in _form._secret_history_container.get_children():
		child.queue_free()

	var versions: Array = await _form._src.secret_versions(_form._current_project, _form._current_id)
	var toggle_prefix := "v" if _form._secret_history_container.visible else ">"
	if versions.size() > 0:
		_form._secret_history_toggle.text = "%s Version History (%d)" % [toggle_prefix, versions.size()]
	else:
		_form._secret_history_toggle.text = "%s Version History" % toggle_prefix

	for ver in versions:
		var row := HBoxContainer.new()
		var ver_label := Label.new()
		ver_label.text = "v%d — %s" % [ver.version, ver.created_at]
		ver_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(ver_label)

		if not str(ver.get("rotated_by", "")).is_empty():
			var by_label := Label.new()
			by_label.text = "by %s" % ver.rotated_by
			by_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			row.add_child(by_label)

		var show_btn := Button.new()
		show_btn.text = "Show"
		show_btn.add_theme_font_size_override("font_size", 11)
		show_btn.pressed.connect(_on_history_show.bind(ver, show_btn))
		row.add_child(show_btn)

		var copy_btn := Button.new()
		copy_btn.text = "Copy"
		copy_btn.add_theme_font_size_override("font_size", 11)
		copy_btn.pressed.connect(_on_history_copy.bind(ver))
		row.add_child(copy_btn)

		_form._secret_history_container.add_child(row)


func _on_history_show(ver: Dictionary, btn: Button) -> void:
	var read: Dictionary = await _form._src.read_secret_version(_form._current_project, _form._current_id, int(ver.version))
	if str(read.get("kind", "")) == "no_key":
		return
	if read.has("error"):
		btn.text = "(failed)"
		return
	if btn.text == "Show":
		btn.text = str(read.value)
	else:
		btn.text = "Show"


func _on_history_copy(ver: Dictionary) -> void:
	var read: Dictionary = await _form._src.read_secret_version(_form._current_project, _form._current_id, int(ver.version))
	if read.has("value"):
		DisplayServer.clipboard_set(str(read.value))


## The vault input for saving a protected item (DocketSource.vault_problem):
## what the form holds for its secret value and notes, asking for the
## secondary password when a new 2FA value is set. {error} when the vault
## cannot take it or no secondary password is given.
func _secret_input(item_id: String, type_name: String) -> Dictionary:
	var problem: String = await _form._src.vault_problem(_form._current_project if not _form._current_project.is_empty() else _form._selected_project())
	if not problem.is_empty():
		_show_vault_error(problem)
		return {"error": problem}
	var secret := {"type": type_name, "requires_2fa": _form._secret_2fa_check.button_pressed}
	if type_name == "secret":
		var new_value: String = _form._secret_value_edit.text
		if not new_value.is_empty() and new_value != "********":
			secret["value"] = new_value
			if _form._secret_2fa_check.button_pressed:
				var secondary_password := await _prompt_secondary_password()
				if secondary_password.is_empty():
					return {"error":"Secondary password required for 2FA secret."}
				secret["secondary_password"] = secondary_password
		secret["masked"] = new_value == "********" and not item_id.is_empty()
	var notes: String = _form._encrypted_notes_edit.text
	if not notes.is_empty() and notes != "********":
		secret["notes"] = notes
	return secret


func _prompt_secondary_password() -> String:
	## Show a blocking dialog for secondary password input. Returns empty on cancel.
	_form._secret_2fa_input.text = ""
	if not _form._secret_2fa_dialog.is_inside_tree():
		_form.add_child(_form._secret_2fa_dialog)
	_form._secret_2fa_dialog.popup_centered(Vector2i(300, 150))
	var result: Array = await _wait_for_2fa_dialog()
	if result[0]:
		return _form._secret_2fa_input.text
	return ""


func _wait_for_2fa_dialog() -> Array:
	## Helper: returns [true] on confirm, [false] on cancel.
	var state := {"confirmed": false, "done": false}
	var on_confirm := func():
		state.confirmed = true
		state.done = true
	var on_cancel := func():
		state.done = true
	_form._secret_2fa_dialog.confirmed.connect(on_confirm, CONNECT_ONE_SHOT)
	_form._secret_2fa_dialog.canceled.connect(on_cancel, CONNECT_ONE_SHOT)
	while not state.done:
		await _form.get_tree().process_frame
	return [state.confirmed]


func _on_secret_show_toggle() -> void:
	if _form._secret_show_btn.button_pressed:
		if not _form._secret_value_decrypted.is_empty():
			_form._secret_value_edit.text = _form._secret_value_decrypted
		_form._secret_value_edit.secret = false
		_form._secret_show_btn.text = "Hide"
	else:
		if not _form._secret_value_decrypted.is_empty():
			_form._secret_value_edit.text = "********"
		_form._secret_value_edit.secret = true
		_form._secret_show_btn.text = "Show"


func _on_secret_copy() -> void:
	if not _form._secret_value_decrypted.is_empty():
		DisplayServer.clipboard_set(_form._secret_value_decrypted)
	elif not _form._secret_value_edit.text.is_empty() and _form._secret_value_edit.text != "********":
		DisplayServer.clipboard_set(_form._secret_value_edit.text)


func _on_secret_generate() -> void:
	## Generate a random password.
	var length := 24
	var bytes := Crypto.new().generate_random_bytes(length)
	var chars := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
	var result := ""
	for i in range(length):
		result += chars[bytes[i] % chars.length()]
	_form._secret_value_edit.text = result
	_form._secret_value_edit.secret = false
	_form._secret_show_btn.text = "Hide"
	_form._secret_show_btn.button_pressed = true
	_form._secret_value_decrypted = ""  # Clear cached, user should save


func _on_encrypted_notes_show_toggle() -> void:
	if _form._encrypted_notes_show_btn.button_pressed:
		if not _form._encrypted_notes_decrypted.is_empty():
			_form._encrypted_notes_edit.text = _form._encrypted_notes_decrypted
		_form._encrypted_notes_show_btn.text = "Hide"
	else:
		if not _form._encrypted_notes_decrypted.is_empty():
			_form._encrypted_notes_edit.text = "********"
		_form._encrypted_notes_show_btn.text = "Show"


func _on_encrypted_notes_copy() -> void:
	if not _form._encrypted_notes_decrypted.is_empty():
		DisplayServer.clipboard_set(_form._encrypted_notes_decrypted)


func _on_secret_history_toggle() -> void:
	_form._secret_history_container.visible = not _form._secret_history_container.visible
	var count: int = _form._secret_history_container.get_child_count()
	var prefix := "v" if _form._secret_history_container.visible else ">"
	if count > 0:
		_form._secret_history_toggle.text = "%s Version History (%d)" % [prefix, count]
	else:
		_form._secret_history_toggle.text = "%s Version History" % prefix
