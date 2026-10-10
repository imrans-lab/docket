extends Node
## Tests that changing the vault password keeps every secret readable.
##
## A dual-password secret is encrypted twice: an inner layer under a key derived
## from the secondary password, an outer layer under the vault key. A password
## change can only re-wrap the outer layer — the secondary password is never
## stored. That makes the salt and iteration count load-bearing: the secondary
## key is derived from them, so altering either strands the inner layer forever.
##
## Legacy preference checks retain the old algorithm; public controls are
## exercised through real MCP children and the Preferences widgets below.

var A := AssertHelpers
var _test_dir := "user://test_vault_pw_change"
var _path: String
var _db: DocketDBJsonl
var _previous_directory: String

const OLD_PW := "old-vault-password"
const NEW_PW := "new-vault-password"
const SECOND_PW := "secondary-password"
const ITERS := 1000   # keep the suite fast; behaviour under test is unrelated


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func before_each() -> void:
	_previous_directory = DocketRuntimeState.directory
	DocketRuntimeState.directory = ProjectSettings.globalize_path(_test_dir)
	_path = _test_dir + "/pw.dct"
	_cleanup()
	_db = DocketDBJsonl.create_new_jsonl(_path)


func after_each() -> void:
	if _db:
		_db.close()
		_db = null
	DocketRuntimeState.directory = _previous_directory


func _cleanup() -> void:
	for suffix: String in ["", ".cache", ".cache-wal", ".cache-shm", ".v2.cache", ".v2.cache-wal", ".v2.cache-shm", ".lock"]:
		var p := _path + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func teardown() -> void:
	_cleanup()
	DirAccess.remove_absolute(_test_dir)


## Mirrors AppShell._reencrypt_vault_secrets.
func _change_password(old_pw: String, new_pw: String) -> void:
	var old_salt := _db.get_vault_salt()
	var old_key := VaultCrypto.derive_key(old_pw, old_salt, _db.get_vault_iterations())

	var has_2fa := false
	for probe in _db.get_all_secrets_raw():
		if bool(probe.get("requires_2fa", false)):
			has_2fa = true
			break

	var new_salt := old_salt
	var new_iters := _db.get_vault_iterations()
	if not has_2fa:
		new_salt = VaultCrypto.generate_salt()
		new_iters = ITERS

	var new_key := VaultCrypto.derive_key(new_pw, new_salt, new_iters)
	for secret in _db.get_all_secrets_raw():
		var payload := VaultCrypto.decrypt(secret.ciphertext, secret.iv, secret.mac, old_key)
		if payload.is_empty():
			continue
		var enc := VaultCrypto.encrypt(payload, new_key)
		_db.set_secret(secret.handle, enc.ciphertext, enc.iv, enc.mac,
			bool(secret.get("requires_2fa", false)))
	_db.init_vault(new_key, new_salt, new_iters)


func _init_vault(pw: String) -> PackedByteArray:
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key(pw, salt, ITERS)
	_db.init_vault(key, salt, ITERS)
	return key


# -- Ordinary secrets ----------------------------------------------------------

func test_plain_secret_readable_after_password_change() -> Variant:
	var key := _init_vault(OLD_PW)
	var enc := VaultCrypto.encrypt("plain-value", key)
	_db.set_secret("plain", enc.ciphertext, enc.iv, enc.mac, false)

	_change_password(OLD_PW, NEW_PW)

	var new_key := VaultCrypto.derive_key(NEW_PW, _db.get_vault_salt(), _db.get_vault_iterations())
	var raw := _db.get_secret_raw("plain")
	return A.is_true(VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, new_key) == "plain-value",
		"plain secret still decrypts")


func test_old_password_no_longer_works() -> Variant:
	var key := _init_vault(OLD_PW)
	var enc := VaultCrypto.encrypt("plain-value", key)
	_db.set_secret("plain", enc.ciphertext, enc.iv, enc.mac, false)
	_change_password(OLD_PW, NEW_PW)

	var old_key := VaultCrypto.derive_key(OLD_PW, _db.get_vault_salt(), _db.get_vault_iterations())
	return A.is_true(not _db.verify_vault(old_key), "the old password stops working")


# -- Dual-password secrets — the regression -----------------------------------

func test_2fa_secret_survives_password_change() -> Variant:
	## Previously unrecoverable: the salt changed, so the secondary key could no
	## longer be re-derived, and requires_2fa was dropped so nothing tried.
	var key := _init_vault(OLD_PW)
	var salt := _db.get_vault_salt()
	var second_key := VaultCrypto.derive_key(SECOND_PW, salt, ITERS)
	var enc := VaultCrypto.encrypt_2fa("top-secret", key, second_key)
	_db.set_secret("dual", enc.ciphertext, enc.iv, enc.mac, true)

	_change_password(OLD_PW, NEW_PW)

	var new_key := VaultCrypto.derive_key(NEW_PW, _db.get_vault_salt(), _db.get_vault_iterations())
	var new_second := VaultCrypto.derive_key(SECOND_PW, _db.get_vault_salt(), _db.get_vault_iterations())
	var raw := _db.get_secret_raw("dual")
	return A.is_true(VaultCrypto.decrypt_2fa(raw.ciphertext, raw.iv, raw.mac, new_key, new_second) == "top-secret",
		"dual-password secret still decrypts after the change")


func test_requires_2fa_flag_survives() -> Variant:
	## Without the flag a reader single-layer-decrypts and returns the inner
	## ciphertext as if it were the secret.
	var key := _init_vault(OLD_PW)
	var second_key := VaultCrypto.derive_key(SECOND_PW, _db.get_vault_salt(), ITERS)
	var enc := VaultCrypto.encrypt_2fa("top-secret", key, second_key)
	_db.set_secret("dual", enc.ciphertext, enc.iv, enc.mac, true)

	_change_password(OLD_PW, NEW_PW)

	return A.is_true(bool(_db.get_secret_raw("dual").get("requires_2fa", false)),
		"requires_2fa is preserved")


func test_salt_is_held_stable_when_2fa_secrets_exist() -> Variant:
	## The constraint that makes the above possible.
	var key := _init_vault(OLD_PW)
	var salt_before := _db.get_vault_salt()
	var second_key := VaultCrypto.derive_key(SECOND_PW, salt_before, ITERS)
	var enc := VaultCrypto.encrypt_2fa("top-secret", key, second_key)
	_db.set_secret("dual", enc.ciphertext, enc.iv, enc.mac, true)

	_change_password(OLD_PW, NEW_PW)

	return A.eq(_db.get_vault_salt(), salt_before,
		"salt is preserved so the secondary key remains derivable")


func test_mixed_vault_keeps_both_kinds_readable() -> Variant:
	var key := _init_vault(OLD_PW)
	var salt := _db.get_vault_salt()
	var second_key := VaultCrypto.derive_key(SECOND_PW, salt, ITERS)

	var plain := VaultCrypto.encrypt("plain-value", key)
	_db.set_secret("plain", plain.ciphertext, plain.iv, plain.mac, false)
	var dual := VaultCrypto.encrypt_2fa("top-secret", key, second_key)
	_db.set_secret("dual", dual.ciphertext, dual.iv, dual.mac, true)

	_change_password(OLD_PW, NEW_PW)

	var nk := VaultCrypto.derive_key(NEW_PW, _db.get_vault_salt(), _db.get_vault_iterations())
	var ns := VaultCrypto.derive_key(SECOND_PW, _db.get_vault_salt(), _db.get_vault_iterations())
	var p := _db.get_secret_raw("plain")
	var d := _db.get_secret_raw("dual")
	var r: Variant = A.is_true(VaultCrypto.decrypt(p.ciphertext, p.iv, p.mac, nk) == "plain-value", "plain ok")
	if r != true:
		return r
	return A.is_true(VaultCrypto.decrypt_2fa(d.ciphertext, d.iv, d.mac, nk, ns) == "top-secret", "dual ok")


# -- The upgrade path is retained where it is safe ----------------------------

func test_salt_is_rotated_when_no_2fa_secrets_exist() -> Variant:
	## With no inner layer to strand, re-salting on a password change is safe and
	## worth keeping.
	var key := _init_vault(OLD_PW)
	var salt_before := _db.get_vault_salt()
	var enc := VaultCrypto.encrypt("plain-value", key)
	_db.set_secret("plain", enc.ciphertext, enc.iv, enc.mac, false)

	_change_password(OLD_PW, NEW_PW)

	return A.is_true(_db.get_vault_salt() != salt_before, "salt rotates when it is safe to")


const HostFixture := preload("res://test/test_host_vault.gd")
const PUBLIC_ROTATION_DRIVER := """
try:
    paths = []
    secondary = secrets.token_hex(24)
    cases = [('entry', False, False), ('dual', True, True), ('was_dual', True, False), ('now_dual', False, True)]
    passwords.append(secondary)
    for hosted in (False, True):
        name = 'rotate-hosted' if hosted else 'rotate-ordinary'
        p = open_host(name) if hosted else launch(name, [])
        path = base/(name+'.dct')
        call(p, 'docket_project_add', dict(path=str(path), create=True))
        def control(child, action, descriptor=None, failure=False, **extra):
            arguments = dict(action=action, project=name, **extra)
            if descriptor is not None:
                arguments.update({field:descriptor[field] for field in ('open_generation','fingerprint')})
            return call(child, 'docket_vault_control', arguments, failure=failure)
        created = control(p, 'init', control(p, 'status'), password=passwords[0], hint='original portable hint')
        for handle, archived_2fa, current_2fa in cases:
            for value, protected in zip(values, (archived_2fa, current_2fa)):
                extra = dict(requires_2fa=protected, secondary_password=secondary) if protected else {}
                call(p, 'docket_secret_set', dict(project=name, handle=handle, value=value, **extra))
        call(p, 'docket_flush', {})
        before = path.read_bytes()
        original_meta = json.loads(path.read_text().splitlines()[0])
        history = {row['handle']:row for row in map(json.loads, path.read_text().splitlines()) if row.get('_type') == 'secret_version'}
        assert all(history[handle].get('requires_2fa', False) == archived for handle, archived, current in cases), 'canonical history lost per-version protection'
        control(p, 'change_password', created, failure=True, old=passwords[1], new=passwords[0])
        assert control(p, 'status')['unlocked'] and path.read_bytes() == before, 'wrong old password changed rotation state'
        changed = control(p, 'change_password', created, old=passwords[0], new=passwords[1], hint='rotated portable hint')
        assert changed['unlocked'] and changed['hint'] == 'rotated portable hint', 'public rotation state or hint'
        control(p, 'unlock', changed, failure=True, password=passwords[0])
        assert control(p, 'status')['unlocked'], 'old password changed rotated session'
        for handle, archived, current in cases:
            extra = dict(secondary_password=secondary) if current else {}
            assert call(p, 'docket_secret_get', dict(project=name, handle=handle, **extra))['value'] == values[1], 'rotated current value'
            extra = dict(secondary_password=secondary) if archived else {}
            assert call(p, 'docket_secret_get', dict(project=name, handle=handle, version=1, **extra))['value'] == values[0], 'rotated historical value'
            if archived:
                call(p, 'docket_secret_get', dict(project=name, handle=handle, version=1), failure=True)
        call(p, 'docket_secret_get', dict(project=name, handle='dual'), failure=True)
        rotation_bytes = path.read_bytes()
        control(p, 'set_hint', changed, failure=True, hint='refused hint')
        control(p, 'set_hint', changed, failure=True, password=passwords[0], hint='refused hint')
        control(p, 'set_hint', changed, failure=True, password=passwords[1], hint=passwords[1])
        assert path.read_bytes() == rotation_bytes and control(p, 'status')['unlocked'], 'refused hint changed data or authority'
        hinted = control(p, 'set_hint', changed, password=passwords[1], hint='edited portable hint')
        assert hinted['unlocked'] and hinted['hint'] == 'edited portable hint', 'hint edit lost session'
        assert call(p, 'docket_secret_get', dict(project=name, handle='entry'))['value'] == values[1], 'hint edit lost access'
        locked_state = control(p, 'lock', hinted)
        locked_hint = control(p, 'set_hint', locked_state, password=passwords[1], hint='fresh profile hint')
        assert not locked_hint['unlocked'], 'hint edit unlocked a locked opening'
        call(p, 'docket_flush', {})
        meta = json.loads(path.read_text().splitlines()[0])
        assert meta['vault_hint'] == 'fresh profile hint', 'hint not portable'
        assert all(meta[field] == original_meta[field] for field in ('vault_salt','vault_kdf_iterations')), 'rotation changed secondary KDF parameters'
        finish(p)
        # Reuse the reviewed disposable-cache cleanup from the creation fixture.
        # The next child must rebuild from canonical data, not reuse SQLite rows.
        for cache in base.glob(name+'.dct.*cache*'):
            if cache.is_file(): cache.unlink()
        for key in ('XDG_DATA_HOME','XDG_CONFIG_HOME','XDG_CACHE_HOME','APPDATA','LOCALAPPDATA'):
            env[key] = str(base/('fresh-'+name+'-'+key))
            pathlib.Path(env[key]).mkdir()
        q = open_host('fresh-'+name) if hosted else launch('fresh-'+name, [])
        call(q, 'docket_project_add', dict(path=str(path)))
        fresh = control(q, 'status')
        assert fresh['hint'] == 'fresh profile hint' and not fresh['unlocked'], 'fresh profile descriptor'
        control(q, 'unlock', fresh, failure=True, password=passwords[0])
        assert not control(q, 'status')['unlocked'], 'fresh profile old password accepted'
        control(q, 'unlock', fresh, password=passwords[1])
        for handle, archived, current in cases:
            extra = dict(secondary_password=secondary) if current else {}
            assert call(q, 'docket_secret_get', dict(project=name, handle=handle, **extra))['value'] == values[1], 'fresh profile current value'
            extra = dict(secondary_password=secondary) if archived else {}
            assert call(q, 'docket_secret_get', dict(project=name, handle=handle, version=1, **extra))['value'] == values[0], 'fresh profile historical value'
        finish(q)
    assert_private_files()
    print('HOST VAULT receiver-consumer-lifetime-privacy PASS')
except BaseException as error:
    safe_diagnostic(type(error), error, error.__traceback__)
    sys.exit(1)
finally:
    for p, err in children:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=10)
        p.stop_io.set()
        for worker in p.io_threads: worker.join(timeout=1)
        if not p.stdin.closed: p.stdin.close()
        p.stdout.close()
        err.close()
    root.cleanup()
    completed.set()
"""


func test_public_rotation_history_2fa_and_fresh_profile_hint() -> Variant:
	var anchor := "\ntry:\n    # Producer and consumer"
	var helpers := HostFixture.DRIVER.replace("\r\n", "\n")
	if helpers.count(anchor) != 1: return "Vault helper slice marker missing"
	var fixture := HostFixture.new()
	var result: Variant = fixture.run_actual_child(helpers.get_slice(anchor, 0) + PUBLIC_ROTATION_DRIVER.replace("\r\n", "\n"))
	fixture.free()
	return result


func _public_tool(mcp: McpHandler, tool: String, args: Dictionary) -> Dictionary:
	# Exercise the actual public MCP boundary, including a JSON round trip.
	var request := {"jsonrpc":"2.0", "id":1, "method":"tools/call", "params":{"name":tool, "arguments":args}}
	var response: Dictionary = mcp.handle(JSON.parse_string(JSON.stringify(request)))
	if not response.has("result") or response.result.get("isError", false):
		return {"error":"Public vault tool refused"}
	var result: Variant = JSON.parse_string(response.result.content[0].text)
	return result if result is Dictionary else {"error":"Public vault tool result invalid"}


func test_locked_public_mutations_preserve_secret_until_password_reentry() -> Variant:
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key(OLD_PW, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	_db.init_vault(key, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	var encrypted := VaultCrypto.encrypt("preserved standalone value", key)
	_db.set_secret("standalone", encrypted.ciphertext, encrypted.iv, encrypted.mac)
	_db.flush()
	var registry := ToolRegistry.new()
	registry.init(TypeRegistryBootstrap.effective_schema(), _db, {"fixture":_db})
	var mcp := McpHandler.new()
	mcp.init_with_registry(registry)
	var status := _public_tool(mcp, "docket_vault_control", {"action":"status", "project":"fixture"})
	var binding := {"project":"fixture", "open_generation":status.open_generation, "fingerprint":status.fingerprint}
	var unlock := binding.duplicate()
	unlock.merge({"action":"unlock", "password":OLD_PW})
	if not _public_tool(mcp, "docket_vault_control", unlock).get("unlocked", false): return "Fixture unlock failed"
	var forget := binding.duplicate()
	forget["action"] = "forget"
	for _repeat in 2:
		status = _public_tool(mcp, "docket_vault_control", forget)
		if not status.get("managed", false) or status.get("unlocked", true): return "Forget did not retain a locked managed opening"
	var before := FileAccess.get_file_as_bytes(_path)
	var mutations := {
		"docket_secret_delete":{"project":"fixture", "handle":"standalone"},
		"docket_secret_set":{"project":"fixture", "handle":"standalone", "value":"replacement"},
		"docket_secret_promote":{"project":"fixture", "handle":"standalone", "title":"Refused promotion"},
	}
	for tool: String in mutations:
		var request := {"jsonrpc":"2.0", "id":1, "method":"tools/call", "params":{"name":tool, "arguments":mutations[tool]}}
		var response: Dictionary = mcp.handle(JSON.parse_string(JSON.stringify(request)))
		if not response.get("result", {}).get("isError", false): return "Locked mutation was accepted: " + tool
		if response.result.content[0].text != "Vault is locked. Unlock this opening through its vault controls.": return "Locked mutation did not give the read refusal: " + tool
		_db.flush()
		if FileAccess.get_file_as_bytes(_path) != before: return "Locked mutation changed canonical data: " + tool
	if not _public_tool(mcp, "docket_vault_control", unlock).get("unlocked", false): return "Password re-entry failed"
	if _public_tool(mcp, "docket_secret_get", {"project":"fixture", "handle":"standalone"}).get("value") != "preserved standalone value": return "Password re-entry did not recover the original secret"
	_public_tool(mcp, "docket_vault_control", forget)
	var change := binding.duplicate()
	change.merge({"action":"change_password", "old":OLD_PW, "new":NEW_PW})
	if not _public_tool(mcp, "docket_vault_control", change).get("unlocked", false): return "Password change stopped being an unlock path"
	return A.is_true(_public_tool(mcp, "docket_secret_get", {"project":"fixture", "handle":"standalone"}).get("value") == "preserved standalone value", "password change preserves the locked secret")


func test_public_rotation_write_failure_preserves_all_rows() -> Variant:
	var password := Crypto.new().generate_random_bytes(24).hex_encode()
	var next_password := Crypto.new().generate_random_bytes(24).hex_encode()
	var secondary := Crypto.new().generate_random_bytes(24).hex_encode()
	var salt := VaultCrypto.generate_salt()
	# Seed a supported legacy vault to keep fault testing cheap; creation at
	# the current KDF cost is exercised by the independent real-child oracle.
	var key := VaultCrypto.derive_key(password, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	var next_key := VaultCrypto.derive_key(next_password, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	var second_key := VaultCrypto.derive_key(secondary, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	_db.init_vault(key, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	for handle: String in ["entry", "dual"]:
		for value: String in ["fault-old", "fault-current"]:
			var encrypted := VaultCrypto.encrypt_2fa(value, key, second_key) if handle == "dual" else VaultCrypto.encrypt(value, key)
			_db.rotate_secret(handle, encrypted.ciphertext, encrypted.iv, encrypted.mac, "fixture", handle == "dual")
	var registry := ToolRegistry.new()
	registry.init(TypeRegistryBootstrap.effective_schema(), _db, {"fixture":_db})
	var mcp := McpHandler.new()
	mcp.init_with_registry(registry)
	var descriptor := _public_tool(mcp, "docket_vault_control", {"action":"status", "project":"fixture"})
	var binding := {"project":"fixture", "open_generation":descriptor.open_generation, "fingerprint":descriptor.fingerprint}
	var unlock_args := binding.duplicate()
	unlock_args.merge({"action":"unlock", "password":password})
	if _public_tool(mcp, "docket_vault_control", unlock_args).has("error"): return "Fault fixture unlock failed"
	var change_args := binding.duplicate()
	change_args.merge({"action":"change_password", "old":password, "new":next_password, "hint":"fault-safe hint"})
	var before := FileAccess.get_file_as_bytes(_path)
	var rows := _ciphertext_by_handle(_db.get_all_secrets_raw())
	var entry_versions := _db.get_secret_versions("entry")
	var dual_versions := _db.get_secret_versions("dual")
	var stale := VaultKeySession.descriptor(_db)
	stale["fingerprint"] = "stale"
	var previous_error := _db.last_write_error
	if _db.change_vault_key_checked(key, next_key, stale).is_empty() or _db.last_write_error != previous_error or not _public_tool(mcp, "docket_vault_control", {"action":"status", "project":"fixture"}).get("unlocked", false):
		return "Pre-write rotation refusal rebuilt cache or changed write state"
	if _db.set_vault_hint_checked(key, stale, "refused hint").is_empty() or _db.last_write_error != previous_error or FileAccess.get_file_as_bytes(_path) != before or not _public_tool(mcp, "docket_vault_control", {"action":"status", "project":"fixture"}).get("unlocked", false):
		return "Stale hint proof changed data or authority"
	var failure := ""
	for after_temp_write: bool in [false, true]:
		var reached := {"fault":false}
		if after_temp_write:
			JSONLCheckedCommit.stage_hook = func(stage: String, _target: String, _temp: String) -> String:
				if stage != "before_rename": return ""
				reached.fault = true
				return "injected rotation write failure"
		else:
			_db._atomic_write_hook = func(_target: String, _text: String) -> String:
				reached.fault = true
				return "injected rotation write failure"
		var refused := _public_tool(mcp, "docket_vault_control", change_args)
		_db._atomic_write_hook = Callable()
		JSONLCheckedCommit.stage_hook = Callable()
		if not refused.has("error") or not reached.fault or not _db.verify_vault(key) or _db.verify_vault(next_key):
			failure = "Rotation failure did not preserve old key verification"
			break
		if FileAccess.get_file_as_bytes(_path) != before:
			failure = "Rotation failure changed canonical bytes"
		elif _ciphertext_by_handle(_db.get_all_secrets_raw()) != rows:
			failure = "Rotation failure changed current row"
		elif _db.get_secret_versions("entry") != entry_versions:
			failure = "Rotation failure changed ordinary history row"
		elif _db.get_secret_versions("dual") != dual_versions:
			failure = "Rotation failure changed 2FA history row"
		if not failure.is_empty():
			break
		if not _public_tool(mcp, "docket_vault_control", {"action":"status", "project":"fixture"}).get("unlocked", false):
			failure = "Rotation failure lost the valid memory session"
			break
	if failure.is_empty() and _public_tool(mcp, "docket_vault_control", change_args).has("error"):
		failure = "Rotation did not succeed after clearing the injected failure"
	return true if failure.is_empty() else failure


func _ciphertext_by_handle(rows: Array) -> Dictionary:
	# A cache rebuild may reorder SQL rows; handle identity and every encrypted
	# field must survive, independently of that unspecified SELECT order.
	var result := {}
	for row: Dictionary in rows: result[row.handle] = row
	return result


func test_preferences_project_rotation_and_hint_controls() -> Variant:
	if DocketRuntimeState.directory != ProjectSettings.globalize_path(_test_dir): return "Preferences fixture directory is not isolated"
	var password := Crypto.new().generate_random_bytes(24).hex_encode()
	var next_password := Crypto.new().generate_random_bytes(24).hex_encode()
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key(password, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	var next_key := VaultCrypto.derive_key(next_password, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	_db.init_vault(key, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	var state := AppState.new()
	state.schema = TypeRegistryBootstrap.effective_schema()
	state.prefs = UserPrefs.new()
	state.load_dct(_path)
	var shell := AppShell.new()
	shell.init(state)
	add_child(shell)
	shell.menu_builder().action_triggered.emit("preferences")
	var current := shell.find_child("ProjectVaultCurrentPassword", true, false) as LineEdit
	var replacement := shell.find_child("ProjectVaultNewPassword", true, false) as LineEdit
	var hint := shell.find_child("ProjectVaultHint", true, false) as LineEdit
	var change := shell.find_child("ProjectVaultChangePassword", true, false) as Button
	var edit_hint := shell.find_child("ProjectVaultSetHint", true, false) as Button
	var failure := ""
	if current == null or replacement == null or hint == null or change == null or edit_hint == null:
		failure = "Preferences public project vault controls missing"
	else:
		current.text = password
		replacement.text = next_password
		hint.text = "GUI portable hint"
		change.pressed.emit()
		var selected_db := state.db
		if not selected_db.verify_vault(next_key) or selected_db.verify_vault(key) or selected_db.get_meta_value("vault_hint") != "GUI portable hint":
			failure = "Preferences project password change did not persist"
		else:
			hint.text = "GUI edited hint"
			current.text = next_password
			edit_hint.pressed.emit()
			if selected_db.get_meta_value("vault_hint") != "GUI edited hint": failure = "Preferences project hint edit did not persist"
		if not current.text.is_empty() or not replacement.text.is_empty(): failure = "Preferences retained project password input"
	shell.free()
	if state.db != null: state.db.close()
	return true if failure.is_empty() else failure


func _answer_history_prompt(form: RecordForm, password: String, confirm: bool, observed: Dictionary) -> void:
	# Bounded UI driver: a missing prompt must fail instead of hanging the test.
	for _frame in 8:
		await get_tree().process_frame
		if not form._secret_2fa_dialog.visible: continue
		observed["prompt"] = true
		form._secret_2fa_input.text = password
		form._secret_2fa_dialog.hide()
		if confirm: form._secret_2fa_dialog.confirmed.emit()
		else: form._secret_2fa_dialog.canceled.emit()
		return


func test_preferences_rotated_2fa_history_show_and_copy() -> Variant:
	if DocketRuntimeState.directory != ProjectSettings.globalize_path(_test_dir): return "Preferences history fixture directory is not isolated"
	var password := Crypto.new().generate_random_bytes(24).hex_encode()
	var secondary := Crypto.new().generate_random_bytes(24).hex_encode()
	var value := Crypto.new().generate_random_bytes(24).hex_encode()
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key(password, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	_db.init_vault(key, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	var registry := ToolRegistry.new()
	registry.init(TypeRegistryBootstrap.effective_schema(), _db, {"fixture":_db})
	var mcp := McpHandler.new()
	mcp.init_with_registry(registry)
	var status := _public_tool(mcp, "docket_vault_control", {"action":"status", "project":"fixture"})
	_public_tool(mcp, "docket_vault_control", {"action":"unlock", "project":"fixture", "open_generation":status.open_generation, "fingerprint":status.fingerprint, "password":password})
	_public_tool(mcp, "docket_secret_set", {"project":"fixture", "handle":"history", "value":value, "requires_2fa":true, "secondary_password":secondary})
	_public_tool(mcp, "docket_secret_set", {"project":"fixture", "handle":"history", "value":"current ordinary value"})
	var promoted := _public_tool(mcp, "docket_secret_promote", {"project":"fixture", "handle":"history", "title":"Protected history fixture"})
	if not promoted.has("id"): return "GUI historical fixture promotion failed"
	var notes := VaultCrypto.encrypt(value, key)
	_db.set_secret(promoted.id + ":notes", notes.ciphertext, notes.iv, notes.mac, false, promoted.id)
	_db.flush()
	var state := AppState.new()
	state.schema = TypeRegistryBootstrap.effective_schema()
	state.prefs = UserPrefs.new()
	state.load_dct(_path)
	var shell := AppShell.new()
	shell.init(state)
	add_child(shell)
	var db := state.db
	status = VaultKeySession.control({"action":"status", "project":db.get_project_name()}, db)
	VaultKeySession.control({"action":"unlock", "project":db.get_project_name(), "open_generation":status.open_generation, "fingerprint":status.fingerprint, "password":password}, db)
	var form: RecordForm = shell._record_form
	form.load_item(promoted.id, db.get_project_name())
	shell.menu_builder().action_triggered.emit("preferences")
	var next_password := Crypto.new().generate_random_bytes(24).hex_encode()
	(shell.find_child("ProjectVaultCurrentPassword", true, false) as LineEdit).text = password
	(shell.find_child("ProjectVaultNewPassword", true, false) as LineEdit).text = next_password
	(shell.find_child("ProjectVaultChangePassword", true, false) as Button).pressed.emit()
	await _close_project_preferences(shell)
	var show: Button
	var copy: Button
	for widget: Node in form._secret_history_container.get_child(0).get_children():
		if widget is Button and widget.text == "Show": show = widget
		if widget is Button and widget.text == "Copy": copy = widget
	var failure := ""
	for confirm: bool in [false, true]:
		var observed := {}
		_answer_history_prompt(form, secondary, confirm, observed)
		show.pressed.emit()
		for _frame in 10: await get_tree().process_frame
		if not observed.get("prompt", false) or show.text != (value if confirm else "Show"):
			failure = "GUI 2FA history Show did not honor secondary password or cancellation"
			break
	if failure.is_empty():
		var sentinel := "history clipboard sentinel"
		DisplayServer.clipboard_set(sentinel)
		var clipboard_available := DisplayServer.clipboard_get() == sentinel
		for confirm: bool in [false, true]:
			var observed := {}
			_answer_history_prompt(form, secondary, confirm, observed)
			copy.pressed.emit()
			for _frame in 10: await get_tree().process_frame
			if not observed.get("prompt", false) or (clipboard_available and DisplayServer.clipboard_get() != (value if confirm else sentinel)):
				failure = "GUI 2FA history Copy did not honor secondary password or cancellation"
				break
		if not clipboard_available: print("C1A_GUI_CLIPBOARD_UNAVAILABLE")
		DisplayServer.clipboard_set("")
	if failure.is_empty():
		form._secret_show_btn.button_pressed = true
		form._secret_show_btn.pressed.emit()
		form._encrypted_notes_show_btn.button_pressed = true
		form._encrypted_notes_show_btn.pressed.emit()
		var before := FileAccess.get_file_as_bytes(_path)
		shell.menu_builder().action_triggered.emit("preferences")
		var forget := shell.find_child("ProjectVaultForget", true, false) as Button
		if forget == null:
			failure = "GUI Forget control missing"
		else:
			form._title_edit.text = "unsaved title fixture"
			form._desc_edit.text = "unsaved description fixture"
			forget.pressed.emit()
			if not _form_vault_is_cleared(form) or show.text != "Show" or not db.has_item(promoted.id) or FileAccess.get_file_as_bytes(_path) != before:
				failure = "GUI Forget did not clear presentation and preserve encrypted data"
			(shell.find_child("ProjectVaultCurrentPassword", true, false) as LineEdit).text = next_password
			(shell.find_child("ProjectVaultUnlock", true, false) as Button).pressed.emit()
			await _close_project_preferences(shell)
			if form._secret_vault_error_label.visible or form._title_edit.text != "unsaved title fixture" or form._desc_edit.text != "unsaved description fixture":
				failure = "GUI Unlock did not preserve edits and clear locked status"
			if form._secret_value_decrypted != "current ordinary value" or form._encrypted_notes_decrypted != value:
				failure = "GUI unlock did not restore forgotten ciphertext"
			await get_tree().process_frame
			var latest_row := form._secret_history_container.get_child(form._secret_history_container.get_child_count() - 1)
			for widget: Node in latest_row.get_children():
				if widget is Button and widget.text == "Show": show = widget
			var observed := {}
			_answer_history_prompt(form, secondary, true, observed)
			show.pressed.emit()
			for _frame in 10: await get_tree().process_frame
			if show.text != value: failure = "MCP Forget fixture did not display protected history"
			registry = ToolRegistry.new()
			registry.init(state.schema, db, {db.get_project_name():db})
			mcp.init_with_registry(registry)
			status = _public_tool(mcp, "docket_vault_control", {"action":"status", "project":db.get_project_name()})
			var args := {"project":db.get_project_name(), "open_generation":status.open_generation, "fingerprint":status.fingerprint, "action":"forget"}
			var forgotten := _public_tool(mcp, "docket_vault_control", args)
			shell._poll_timer.timeout.emit()
			if forgotten.has("error") or forgotten.get("unlocked", true) or not _form_vault_is_cleared(form) or show.text != "Show" or FileAccess.get_file_as_bytes(_path) != before:
				failure = "MCP Forget did not clear presentation and retain canonical data"
			args.merge({"action":"unlock", "password":next_password}, true)
			_public_tool(mcp, "docket_vault_control", args)
			shell._poll_timer.timeout.emit()
			if form._secret_value_decrypted != "current ordinary value" or form._encrypted_notes_decrypted != value or form._secret_vault_error_label.visible:
				failure = "MCP Unlock did not restore existing-form presentation"
			var restored := _public_tool(mcp, "docket_secret_get", {"project":db.get_project_name(), "handle":promoted.id, "version":1, "secondary_password":secondary})
			if restored.get("value", "") != value: failure = "MCP unlock did not restore forgotten history"
			# Seed a real protected current row, then exercise existing-form Unlock.
			var current_key := VaultCrypto.derive_key(next_password, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
			var second_key := VaultCrypto.derive_key(secondary, salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
			var encrypted := VaultCrypto.encrypt_2fa(value, current_key, second_key)
			db.rotate_secret(promoted.id, encrypted.ciphertext, encrypted.iv, encrypted.mac, "fixture", true)
			db.flush()
			status = _public_tool(mcp, "docket_vault_control", {"action":"status", "project":db.get_project_name()})
			var lock_args := {"action":"forget", "project":db.get_project_name(), "open_generation":status.open_generation, "fingerprint":status.fingerprint}
			_public_tool(mcp, "docket_vault_control", lock_args)
			shell._poll_timer.timeout.emit()
			shell.menu_builder().action_triggered.emit("preferences")
			(shell.find_child("ProjectVaultCurrentPassword", true, false) as LineEdit).text = next_password
			(shell.find_child("ProjectVaultUnlock", true, false) as Button).pressed.emit()
			if form._secret_2fa_dialog.visible:
				failure = "Current 2FA recovery competed with modal Preferences"
			observed = {}
			_answer_history_prompt(form, secondary, true, observed)
			await _close_project_preferences(shell)
			for _frame in 10: await get_tree().process_frame
			if not observed.get("prompt", false) or form._secret_value_decrypted != value or form._encrypted_notes_decrypted != value:
				failure = "Current 2FA recovery did not resume after Preferences closed"
			if form._title_edit.text != "unsaved title fixture" or form._desc_edit.text != "unsaved description fixture":
				failure = "Current 2FA recovery discarded unrelated edits"

	shell.free()
	db.close()
	return true if failure.is_empty() else failure


func _form_vault_is_cleared(form: RecordForm) -> bool:
	return form._secret_value_decrypted.is_empty() and form._encrypted_notes_decrypted.is_empty() and form._secret_value_edit.text.is_empty() and form._encrypted_notes_edit.text.is_empty()


func _close_project_preferences(shell: AppShell) -> void:
	shell._prefs_dialog.get_cancel_button().pressed.emit()
	for _frame in 2: await get_tree().process_frame
