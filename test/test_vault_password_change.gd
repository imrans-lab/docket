extends Node
## Tests that changing the vault password keeps every secret readable.
##
## A dual-password secret is encrypted twice: an inner layer under a key derived
## from the secondary password, an outer layer under the vault key. A password
## change can only re-wrap the outer layer — the secondary password is never
## stored. That makes the salt and iteration count load-bearing: the secondary
## key is derived from them, so altering either strands the inner layer forever.
##
## Each drives LocalDocketSource._reencrypt_vault_secrets over one open
## project, then checks the vault with keys derived independently here or
## through LocalDocketSource.read_secret_version.

var A := AssertHelpers
var _test_dir := "user://test_vault_pw_change"
var _path: String
var _db: DocketDBJsonl
var _others: Array[DocketDBJsonl] = []

const OLD_PW := "old-vault-password"
const NEW_PW := "new-vault-password"
const SECOND_PW := "secondary-password"
# Keeps the fixtures fast; a change keeps the vault's iteration count.
const ITERS := 1000


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func before_each() -> void:
	_path = _test_dir + "/pw.dct"
	_cleanup()
	_db = DocketDBJsonl.create_new_jsonl(_path)


func after_each() -> void:
	UserPrefs.clear_vault_password()
	for db in _others:
		db.close()
	_others.clear()
	if _db:
		_db.close()
		_db = null


func _cleanup() -> void:
	for filename in DirAccess.get_files_at(_test_dir):
		DirAccess.remove_absolute("%s/%s" % [_test_dir, filename])


func teardown() -> void:
	_cleanup()
	DirAccess.remove_absolute(_test_dir)


func _change_password(old_pw: String, new_pw: String) -> void:
	var state := AppState.new()
	state._project_dbs = {"pw": _db}
	LocalDocketSource.new(state)._reencrypt_vault_secrets(old_pw, new_pw)


func _init_vault(pw: String, db: DocketDB = null) -> PackedByteArray:
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key(pw, salt, ITERS)
	(db if db != null else _db).init_vault(key, salt, ITERS)
	return key


func _other_project(name: String) -> DocketDBJsonl:
	var db := DocketDBJsonl.create_new_jsonl("%s/%s.dct" % [_test_dir, name])
	_others.append(db)
	return db


# -- Ordinary secrets ----------------------------------------------------------

func test_plain_secret_readable_after_password_change() -> Variant:
	var key := _init_vault(OLD_PW)
	var enc := VaultCrypto.encrypt("plain-value", key)
	_db.set_secret("plain", enc.ciphertext, enc.iv, enc.mac, false)

	_change_password(OLD_PW, NEW_PW)

	var new_key := VaultCrypto.derive_key(NEW_PW, _db.get_vault_salt(), _db.get_vault_iterations())
	var raw := _db.get_secret_raw("plain")
	return A.eq(VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, new_key), "plain-value",
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
	return A.eq(VaultCrypto.decrypt_2fa(raw.ciphertext, raw.iv, raw.mac, new_key, new_second),
		"top-secret", "dual-password secret still decrypts after the change")


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
	var r = A.eq(VaultCrypto.decrypt(p.ciphertext, p.iv, p.mac, nk), "plain-value", "plain ok")
	if r != true:
		return r
	return A.eq(VaultCrypto.decrypt_2fa(d.ciphertext, d.iv, d.mac, nk, ns), "top-secret", "dual ok")


# -- Archived versions ---------------------------------------------------------

func test_archived_values_stay_readable_after_password_change() -> Variant:
	## History is re-encrypted with the current values, and the salt is kept
	## even when no current value is 2FA, because an archived one may be.
	var key := _init_vault(OLD_PW)
	var second_key := VaultCrypto.derive_key(SECOND_PW, _db.get_vault_salt(), ITERS)
	var first := VaultCrypto.encrypt_2fa("first", key, second_key)
	_db.set_secret("h", first.ciphertext, first.iv, first.mac, true)
	var second := VaultCrypto.encrypt("second", key)
	_db.rotate_secret("h", second.ciphertext, second.iv, second.mac, "tester", false)
	var third := VaultCrypto.encrypt("third", key)
	_db.rotate_secret("h", third.ciphertext, third.iv, third.mac, "tester", false)

	_change_password(OLD_PW, NEW_PW)

	UserPrefs.save_vault_password(NEW_PW)
	var state := AppState.new()
	state._project_dbs = {"pw": _db}
	var source := LocalDocketSource.new(state)
	var read := [
		source.read_secret_version("pw", "h", 1).get("kind", ""),
		source.read_secret_version("pw", "h", 1, SECOND_PW).get("value", ""),
		source.read_secret_version("pw", "h", 2).get("value", ""),
	]
	return A.eq(read, ["needs_secondary", "first", "second"],
		"the 2FA version asks for its secondary password and both versions decrypt under the new password")


# -- A change that cannot finish -------------------------------------------------

func test_a_failed_change_keeps_the_old_password_everywhere() -> Variant:
	## An archived value of project b does not decrypt, so b cannot be
	## re-encrypted; project a, re-encrypted before it, must be put back and
	## the old password kept.
	var key := _init_vault(OLD_PW)
	var enc := VaultCrypto.encrypt("plain-value", key)
	_db.set_secret("plain", enc.ciphertext, enc.iv, enc.mac, false)
	var b := _other_project("b")
	var b_key := _init_vault(OLD_PW, b)
	var broken := VaultCrypto.encrypt("broken", b_key)
	b.set_secret("h", broken.ciphertext, broken.iv, VaultCrypto.generate_iv() + VaultCrypto.generate_iv(), false)
	var current := VaultCrypto.encrypt("current", b_key)
	b.rotate_secret("h", current.ciphertext, current.iv, current.mac, "tester", false)

	UserPrefs.save_vault_password(OLD_PW)
	var state := AppState.new()
	state._project_dbs = {"a": _db, "b": b}
	var error := LocalDocketSource.new(state).set_vault_settings(NEW_PW, "")

	var raw := _db.get_secret_raw("plain")
	return A.eq([error.contains("'b' could not be re-encrypted"), UserPrefs.load_vault_password(),
			VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, key)],
		[true, OLD_PW, "plain-value"],
		"b's re-encryption fails, the old password stays saved and project a still opens with it")


func test_a_change_reaches_a_vault_added_on_disk_since_opening() -> Variant:
	## Project b had no vault when opened; its file on disk now has one, with
	## an empty value, under the current password. Both must move to the new
	## password.
	_init_vault(OLD_PW)
	var b := _other_project("b")
	var replacement := _other_project("replacement")
	var replacement_key := _init_vault(OLD_PW, replacement)
	var empty := VaultCrypto.encrypt("", replacement_key)
	replacement.set_secret("empty", empty.ciphertext, empty.iv, empty.mac, false)
	var replaced := FileAccess.open(_test_dir + "/b.dct", FileAccess.WRITE)
	replaced.store_buffer(FileAccess.get_file_as_bytes(_test_dir + "/replacement.dct"))
	replaced.close()

	UserPrefs.save_vault_password(OLD_PW)
	var state := AppState.new()
	state._project_dbs = {"a": _db, "b": b}
	var error := LocalDocketSource.new(state).set_vault_settings(NEW_PW, "")

	var new_key := VaultCrypto.derive_key(NEW_PW, b.get_vault_salt(), b.get_vault_iterations())
	var raw := b.get_secret_raw("empty")
	return A.eq([error, b.verify_vault(new_key), VaultCrypto.decrypt_checked(raw.ciphertext, raw.iv, raw.mac, new_key)],
		["", true, {"value": ""}],
		"b is re-read and re-encrypted, its empty value included")
