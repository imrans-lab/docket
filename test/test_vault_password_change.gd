extends Node
## Tests that changing the vault password keeps every secret readable.
##
## A dual-password secret is encrypted twice: an inner layer under a key derived
## from the secondary password, an outer layer under the vault key. A password
## change can only re-wrap the outer layer — the secondary password is never
## stored. That makes the salt and iteration count load-bearing: the secondary
## key is derived from them, so altering either strands the inner layer forever.
##
## These exercise the same sequence AppShell._reencrypt_vault_secrets performs,
## which cannot be driven headlessly.

var A := AssertHelpers
var _test_dir := "user://test_vault_pw_change"
var _path: String
var _db: DocketDBJsonl

const OLD_PW := "old-vault-password"
const NEW_PW := "new-vault-password"
const SECOND_PW := "secondary-password"
const ITERS := 1000   # keep the suite fast; behaviour under test is unrelated


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func before_each() -> void:
	_path = _test_dir + "/pw.dct"
	_cleanup()
	_db = DocketDBJsonl.create_new_jsonl(_path)


func after_each() -> void:
	if _db:
		_db.close()
		_db = null


func _cleanup() -> void:
	for suffix: String in ["", ".cache", ".cache-wal", ".cache-shm", ".lock"]:
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
