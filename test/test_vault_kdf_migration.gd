extends Node
## Tests for the PBKDF2 iteration count being recorded per vault.
##
## The failure this guards against is silent and unrecoverable: derive a key at
## the wrong iteration count and every secret reads as "wrong password", with no
## way to tell that from an actually wrong password.

var A := AssertHelpers
var _test_dir := "user://test_vault_kdf"
var _path: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func before_each() -> void:
	_path = _test_dir + "/kdf.dct"
	_cleanup()


func _cleanup() -> void:
	for suffix: String in ["", ".cache", ".cache-wal", ".cache-shm", ".lock"]:
		var p := _path + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func teardown() -> void:
	_cleanup()
	DirAccess.remove_absolute(_test_dir)


# Keep tests fast: the behaviour under test is that the *recorded* count is used,
# not what those counts are.
const OLD_ITERS := 1000
const NEW_ITERS := 4000


# -- Recording ----------------------------------------------------------------

func test_new_vault_records_current_iterations() -> Variant:
	var db := DocketDBJsonl.create_new_jsonl(_path)
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key("pw", salt, VaultCrypto.PBKDF2_ITERATIONS)
	db.init_vault(key, salt, VaultCrypto.PBKDF2_ITERATIONS)
	var got := db.get_vault_iterations()
	db.close()
	return A.eq(got, VaultCrypto.PBKDF2_ITERATIONS, "new vault records the current count")


func test_vault_without_recorded_count_reports_legacy() -> Variant:
	## A vault created before the parameter existed has no meta entry, and must
	## fall back to the legacy count or its secrets become undecryptable.
	var db := DocketDBJsonl.create_new_jsonl(_path)
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key("pw", salt, VaultCrypto.LEGACY_PBKDF2_ITERATIONS)
	# Deliberately bypass init_vault's iteration recording, as an old file would.
	db.set_meta_value("vault_salt", Marshalls.raw_to_base64(salt))
	db.set_meta_value("vault_verify", Marshalls.raw_to_base64(VaultCrypto.compute_verify_hash(key)))
	var got := db.get_vault_iterations()
	db.close()
	return A.eq(got, VaultCrypto.LEGACY_PBKDF2_ITERATIONS, "absent count means legacy")


func test_current_default_is_at_least_owasp_guidance() -> Variant:
	## Guards against the constant being lowered for convenience.
	return A.is_true(VaultCrypto.PBKDF2_ITERATIONS >= 600000,
		"default iterations meet OWASP guidance (600k)")


# -- Round trip through the file ----------------------------------------------

func test_iterations_survive_serialization() -> Variant:
	## The count lives in the JSONL meta line. If serialization dropped it, a
	## cache rebuild would silently fall back to legacy and strand the vault.
	var db := DocketDBJsonl.create_new_jsonl(_path)
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key("pw", salt, NEW_ITERS)
	db.init_vault(key, salt, NEW_ITERS)
	db.close()

	var text := FileAccess.get_file_as_string(_path)
	var r = A.contains(text, "vault_kdf_iterations", "count is written to the JSONL")
	if r != true:
		return r

	var reopened := DocketDBJsonl.open_jsonl(_path)
	var got := reopened.get_vault_iterations()
	reopened.close()
	return A.eq(got, NEW_ITERS, "count survives a reopen")


func test_iterations_survive_cache_rebuild() -> Variant:
	var db := DocketDBJsonl.create_new_jsonl(_path)
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key("pw", salt, NEW_ITERS)
	db.init_vault(key, salt, NEW_ITERS)
	db.close()

	# Drop the cache entirely, forcing a rebuild from the JSONL text.
	for suffix: String in [".cache", ".cache-wal", ".cache-shm"]:
		if FileAccess.file_exists(_path + suffix):
			DirAccess.remove_absolute(_path + suffix)

	var rebuilt := DocketDBJsonl.open_jsonl(_path)
	var got := rebuilt.get_vault_iterations()
	rebuilt.close()
	return A.eq(got, NEW_ITERS, "count survives a full cache rebuild")


# -- The failure this prevents ------------------------------------------------

func test_wrong_iteration_count_produces_wrong_key() -> Variant:
	## Demonstrates why the count must be stored: same password, same salt,
	## different cost gives a different key and a failed verify.
	var salt := VaultCrypto.generate_salt()
	var key_a := VaultCrypto.derive_key("same-password", salt, OLD_ITERS)
	var key_b := VaultCrypto.derive_key("same-password", salt, NEW_ITERS)
	return A.is_true(key_a != key_b, "differing iteration counts yield different keys")


func test_secret_decrypts_only_at_its_recorded_count() -> Variant:
	var salt := VaultCrypto.generate_salt()
	var right := VaultCrypto.derive_key("pw", salt, OLD_ITERS)
	var wrong := VaultCrypto.derive_key("pw", salt, NEW_ITERS)

	var enc := VaultCrypto.encrypt("hunter2", right)
	var ok := VaultCrypto.decrypt(enc.ciphertext, enc.iv, enc.mac, right)
	var r = A.eq(ok, "hunter2", "decrypts with the matching count")
	if r != true:
		return r
	var bad := VaultCrypto.decrypt(enc.ciphertext, enc.iv, enc.mac, wrong)
	return A.eq(bad, "", "fails closed with a mismatched count")
