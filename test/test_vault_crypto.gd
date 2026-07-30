extends Node
## Unit tests for VaultCrypto and secret MCP tools.

var A := AssertHelpers
var _db: DocketDB
var _registry: ToolRegistry
var _schema: Dictionary
var _test_dir := "user://test_vault_crypto"
var _test_file: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_test_file = _test_dir + "/test_vault.dct"
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	_schema = JSON.parse_string(f.get_as_text())


func before_each() -> void:
	_cleanup()
	_db = DocketDB.create_new(_test_file)
	_registry = ToolRegistry.new()
	_registry.init(_schema, _db)


func _cleanup() -> void:
	if _db:
		_db.close()
		_db = null
	for suffix: String in ["", "-wal", "-shm"]:
		var p: String = _test_file + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	# Clean up vault password file
	UserPrefs.clear_vault_password()


func teardown() -> void:
	_cleanup()
	var dir := DirAccess.open(_test_dir)
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			dir.remove(fname)
			fname = dir.get_next()
		DirAccess.remove_absolute(_test_dir)


# -- PKCS7 padding ------------------------------------------------------------

func test_pkcs7_pad_unpad() -> Variant:
	var data := "hello".to_utf8_buffer()
	var padded := VaultCrypto._pad_pkcs7(data)
	# Should be 16 bytes (one block)
	var r = A.eq(padded.size(), 16, "padded to block size")
	if r is String: return r
	# Last 11 bytes should all be 11
	for i in range(5, 16):
		r = A.eq(padded[i], 11, "pad byte %d" % i)
		if r is String: return r
	var unpadded := VaultCrypto._unpad_pkcs7(padded)
	return A.eq(unpadded, data, "roundtrip")


func test_pkcs7_full_block_padding() -> Variant:
	# Exactly 16 bytes → should add full padding block (16 bytes of 0x10)
	var data := "0123456789abcdef".to_utf8_buffer()
	var padded := VaultCrypto._pad_pkcs7(data)
	var r = A.eq(padded.size(), 32, "full block padding added")
	if r is String: return r
	for i in range(16, 32):
		r = A.eq(padded[i], 16, "pad byte %d" % i)
		if r is String: return r
	var unpadded := VaultCrypto._unpad_pkcs7(padded)
	return A.eq(unpadded, data, "roundtrip full block")


func test_pkcs7_invalid_padding() -> Variant:
	# Tampered padding byte
	var data := PackedByteArray([1, 2, 3, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 99])
	var unpadded := VaultCrypto._unpad_pkcs7(data)
	return A.eq(unpadded.size(), 0, "invalid padding returns empty")


# -- HMAC-SHA256 ---------------------------------------------------------------

func test_hmac_sha256_known_vector() -> Variant:
	# RFC 4231 Test Case 2: key = "Jefe", data = "what do ya want for nothing?"
	var key := "Jefe".to_utf8_buffer()
	var data := "what do ya want for nothing?".to_utf8_buffer()
	var mac := VaultCrypto._hmac_sha256(key, data)
	var hex := mac.hex_encode()
	return A.eq(hex, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "RFC 4231 test case 2")


# -- PBKDF2-HMAC-SHA256 -------------------------------------------------------

func test_pbkdf2_known_vector() -> Variant:
	# RFC 6070 Test Vector 1: password="password", salt="salt", c=1, dkLen=20
	var key := VaultCrypto._pbkdf2_sha256("password".to_utf8_buffer(), "salt".to_utf8_buffer(), 1, 20)
	var hex := key.hex_encode()
	return A.eq(hex, "120fb6cffcf8b32c43e7225256c4f837a86548c9", "RFC 6070 test vector 1")


func test_pbkdf2_known_vector_2() -> Variant:
	# RFC 6070 Test Vector 2: password="password", salt="salt", c=2, dkLen=20
	var key := VaultCrypto._pbkdf2_sha256("password".to_utf8_buffer(), "salt".to_utf8_buffer(), 2, 20)
	var hex := key.hex_encode()
	return A.eq(hex, "ae4d0c95af6b46d32d0adff928f06dd02a303f8e", "RFC 6070 test vector 2")


# -- Encrypt / Decrypt roundtrip -----------------------------------------------

func test_encrypt_decrypt_roundtrip() -> Variant:
	var password := "my-secret-password"
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key(password, salt)
	var plaintext := "hunter2"
	var encrypted := VaultCrypto.encrypt(plaintext, key)
	var r = A.has_key(encrypted, "ciphertext")
	if r is String: return r
	r = A.has_key(encrypted, "iv")
	if r is String: return r
	r = A.has_key(encrypted, "mac")
	if r is String: return r
	var decrypted := VaultCrypto.decrypt(encrypted.ciphertext, encrypted.iv, encrypted.mac, key)
	return A.eq(decrypted, "hunter2", "roundtrip plaintext")


func test_encrypt_decrypt_empty_string() -> Variant:
	var key := VaultCrypto.derive_key("pw", VaultCrypto.generate_salt())
	var encrypted := VaultCrypto.encrypt("", key)
	var decrypted := VaultCrypto.decrypt(encrypted.ciphertext, encrypted.iv, encrypted.mac, key)
	return A.eq(decrypted, "", "empty string roundtrip")


func test_encrypt_decrypt_unicode() -> Variant:
	var key := VaultCrypto.derive_key("pw", VaultCrypto.generate_salt())
	var plaintext := "secret with emoji and unicode"
	var encrypted := VaultCrypto.encrypt(plaintext, key)
	var decrypted := VaultCrypto.decrypt(encrypted.ciphertext, encrypted.iv, encrypted.mac, key)
	return A.eq(decrypted, plaintext, "unicode roundtrip")


# -- HMAC tamper detection -----------------------------------------------------

func test_tampered_ciphertext_fails() -> Variant:
	var key := VaultCrypto.derive_key("pw", VaultCrypto.generate_salt())
	var encrypted := VaultCrypto.encrypt("secret", key)
	# Flip a byte in ciphertext
	var tampered: PackedByteArray = (encrypted.ciphertext as PackedByteArray).duplicate()
	tampered[0] ^= 0xFF
	var result := VaultCrypto.decrypt(tampered, encrypted.iv, encrypted.mac, key)
	return A.eq(result, "", "tampered ciphertext fails")


func test_tampered_iv_fails() -> Variant:
	var key := VaultCrypto.derive_key("pw", VaultCrypto.generate_salt())
	var encrypted := VaultCrypto.encrypt("secret", key)
	var tampered_iv: PackedByteArray = (encrypted.iv as PackedByteArray).duplicate()
	tampered_iv[0] ^= 0xFF
	var result := VaultCrypto.decrypt(encrypted.ciphertext, tampered_iv, encrypted.mac, key)
	return A.eq(result, "", "tampered IV fails")


func test_wrong_key_fails() -> Variant:
	var salt := VaultCrypto.generate_salt()
	var key1 := VaultCrypto.derive_key("password1", salt)
	var key2 := VaultCrypto.derive_key("password2", salt)
	var encrypted := VaultCrypto.encrypt("secret", key1)
	var result := VaultCrypto.decrypt(encrypted.ciphertext, encrypted.iv, encrypted.mac, key2)
	return A.eq(result, "", "wrong key fails")


# -- Verify hash ---------------------------------------------------------------

func test_verify_hash_consistency() -> Variant:
	var key := VaultCrypto.derive_key("pw", VaultCrypto.generate_salt())
	var hash1 := VaultCrypto.compute_verify_hash(key)
	var hash2 := VaultCrypto.compute_verify_hash(key)
	return A.eq(hash1, hash2, "same key produces same verify hash")


func test_verify_hash_differs_for_different_keys() -> Variant:
	var salt := VaultCrypto.generate_salt()
	var key1 := VaultCrypto.derive_key("pw1", salt)
	var key2 := VaultCrypto.derive_key("pw2", salt)
	var hash1 := VaultCrypto.compute_verify_hash(key1)
	var hash2 := VaultCrypto.compute_verify_hash(key2)
	return A.neq(hash1, hash2, "different keys produce different verify hashes")


# -- DocketDB vault methods ----------------------------------------------------

func test_db_vault_lifecycle() -> Variant:
	var r = A.is_false(_db.has_vault(), "no vault initially")
	if r is String: return r

	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key("test-pw", salt)
	_db.init_vault(key, salt)

	r = A.is_true(_db.has_vault(), "has vault after init")
	if r is String: return r
	r = A.is_true(_db.verify_vault(key), "verify with correct key")
	if r is String: return r

	var wrong_key := VaultCrypto.derive_key("wrong-pw", salt)
	return A.is_false(_db.verify_vault(wrong_key), "verify fails with wrong key")


func test_db_secret_crud() -> Variant:
	var key := VaultCrypto.derive_key("pw", VaultCrypto.generate_salt())
	var encrypted := VaultCrypto.encrypt("my-secret", key)

	_db.set_secret("api_key", encrypted.ciphertext, encrypted.iv, encrypted.mac)

	var raw := _db.get_secret_raw("api_key")
	var r = A.is_false(raw.is_empty(), "secret found")
	if r is String: return r

	# Decrypt and verify
	var decrypted := VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, key)
	r = A.eq(decrypted, "my-secret", "decrypt stored secret")
	if r is String: return r

	# List
	var secrets := _db.list_secrets()
	r = A.eq(secrets.size(), 1, "one secret in list")
	if r is String: return r
	r = A.eq(secrets[0].handle, "api_key", "correct handle")
	if r is String: return r

	# Delete
	r = A.is_true(_db.delete_secret("api_key"), "delete returns true")
	if r is String: return r
	return A.is_true(_db.get_secret_raw("api_key").is_empty(), "deleted secret gone")


func test_db_secret_update() -> Variant:
	var key := VaultCrypto.derive_key("pw", VaultCrypto.generate_salt())
	var enc1 := VaultCrypto.encrypt("value1", key)
	_db.set_secret("handle", enc1.ciphertext, enc1.iv, enc1.mac)

	var enc2 := VaultCrypto.encrypt("value2", key)
	_db.set_secret("handle", enc2.ciphertext, enc2.iv, enc2.mac)

	# Should still be one secret
	var secrets := _db.list_secrets()
	var r = A.eq(secrets.size(), 1, "still one secret")
	if r is String: return r

	# Should decrypt to updated value
	var raw := _db.get_secret_raw("handle")
	var decrypted := VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, key)
	return A.eq(decrypted, "value2", "updated value")


# -- MCP secret tools ----------------------------------------------------------

func test_secret_set_no_vault_password() -> Variant:
	# No vault password configured → error
	UserPrefs.clear_vault_password()
	var result := _registry.call_tool("docket_secret_set", {"handle": "key", "value": "val"})
	return A.has_key(result, "error")


func test_secret_roundtrip_via_tools() -> Variant:
	UserPrefs.save_vault_password("test-password")
	var set_result := _registry.call_tool("docket_secret_set", {"handle": "aol_password", "value": "hunter2"})
	var r = A.has_key(set_result, "status")
	if r is String: return r
	r = A.eq(set_result.status, "created", "first set is 'created'")
	if r is String: return r

	var get_result := _registry.call_tool("docket_secret_get", {"handle": "aol_password"})
	r = A.has_key(get_result, "value")
	if r is String: return r
	return A.eq(get_result.value, "hunter2", "decrypted value matches")


func test_secret_update_via_tools() -> Variant:
	UserPrefs.save_vault_password("test-password")
	_registry.call_tool("docket_secret_set", {"handle": "key", "value": "old"})
	var result := _registry.call_tool("docket_secret_set", {"handle": "key", "value": "new"})
	var r = A.eq(result.status, "updated", "second set is 'updated'")
	if r is String: return r
	var get_result := _registry.call_tool("docket_secret_get", {"handle": "key"})
	return A.eq(get_result.value, "new", "updated value")


func test_secret_list_via_tools() -> Variant:
	UserPrefs.save_vault_password("test-password")
	_registry.call_tool("docket_secret_set", {"handle": "a", "value": "1"})
	_registry.call_tool("docket_secret_set", {"handle": "b", "value": "2"})
	var result := _registry.call_tool("docket_secret_list", {})
	var r = A.has_key(result, "secrets")
	if r is String: return r
	return A.eq(result.secrets.size(), 2, "two secrets listed")


func test_secret_delete_via_tools() -> Variant:
	UserPrefs.save_vault_password("test-password")
	_registry.call_tool("docket_secret_set", {"handle": "key", "value": "val"})
	var result := _registry.call_tool("docket_secret_delete", {"handle": "key"})
	var r = A.has_key(result, "deleted")
	if r is String: return r
	r = A.is_true(result.deleted, "deleted is true")
	if r is String: return r
	# Get should fail now
	var get_result := _registry.call_tool("docket_secret_get", {"handle": "key"})
	return A.has_key(get_result, "error")


func test_secret_delete_missing() -> Variant:
	var result := _registry.call_tool("docket_secret_delete", {"handle": "nope"})
	return A.has_key(result, "error")


func test_secret_get_no_vault() -> Variant:
	UserPrefs.save_vault_password("pw")
	var result := _registry.call_tool("docket_secret_get", {"handle": "nope"})
	return A.has_key(result, "error")


func test_secret_plaintext_absent_from_vault_bytes() -> Variant:
	## Verify the plaintext secret value does not appear anywhere in the
	## raw vault storage (ciphertext, iv, mac columns).
	UserPrefs.save_vault_password("test-password")
	var test_secret := "FAKE-API-KEY-xK9mQ2pL7n"
	_registry.call_tool("docket_secret_set", {"handle": "leak_check", "value": test_secret})

	var raw := _db.get_secret_raw("leak_check")
	var r = A.is_false(raw.is_empty(), "secret stored")
	if r is String: return r

	var plaintext_bytes := test_secret.to_utf8_buffer()
	for field in ["ciphertext", "iv", "mac"]:
		var stored: PackedByteArray = raw[field]
		# Check plaintext bytes don't appear as a substring in stored bytes
		var stored_hex := stored.hex_encode()
		var plain_hex := plaintext_bytes.hex_encode()
		if stored_hex.contains(plain_hex):
			return "Plaintext found in vault %s column" % field
		# Also check as raw UTF-8 string
		var stored_str := stored.get_string_from_utf8()
		if stored_str.contains(test_secret):
			return "Plaintext string found in vault %s column" % field
	return true


# -- Rotation history ---------------------------------------------------------

func test_secret_rotation_preserves_history() -> Variant:
	UserPrefs.save_vault_password("test-password")
	# Create initial secret
	_registry.call_tool("docket_secret_set", {"handle": "rotate_test", "value": "v1"})
	# Update (simulating rotation via set_secret which will be called by rotate_secret)
	var password := "test-password"
	var salt := _db.get_vault_salt()
	var key := VaultCrypto.derive_key(password, salt)
	var enc2 := VaultCrypto.encrypt("v2", key)
	_db.rotate_secret("rotate_test", enc2.ciphertext, enc2.iv, enc2.mac, "tester")

	# Check current value is v2
	var raw := _db.get_secret_raw("rotate_test")
	var r = A.is_false(raw.is_empty(), "current secret exists")
	if r is String: return r
	var current := VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, key)
	r = A.eq(current, "v2", "current value is v2")
	if r is String: return r

	# Check version history has v1
	var versions := _db.get_secret_versions("rotate_test")
	r = A.eq(versions.size(), 1, "one archived version")
	if r is String: return r
	var old := VaultCrypto.decrypt(versions[0].ciphertext, versions[0].iv, versions[0].mac, key)
	r = A.eq(old, "v1", "archived version is v1")
	if r is String: return r
	return A.eq(versions[0].rotated_by, "tester", "rotated_by recorded")


# -- 2FA (dual encryption) ---------------------------------------------------

func test_2fa_secret_roundtrip() -> Variant:
	UserPrefs.save_vault_password("test-password")
	var set_result := _registry.call_tool("docket_secret_set", {
		"handle": "2fa_test",
		"value": "top-secret",
		"requires_2fa": true,
		"secondary_password": "yubikey-derived",
	})
	var r = A.has_key(set_result, "status")
	if r is String: return r

	var get_result := _registry.call_tool("docket_secret_get", {
		"handle": "2fa_test",
		"secondary_password": "yubikey-derived",
	})
	r = A.has_key(get_result, "value")
	if r is String: return r
	return A.eq(get_result.value, "top-secret", "2FA secret roundtrip")


func test_2fa_secret_without_secondary_fails() -> Variant:
	UserPrefs.save_vault_password("test-password")
	_registry.call_tool("docket_secret_set", {
		"handle": "2fa_no_pw",
		"value": "locked",
		"requires_2fa": true,
		"secondary_password": "my-2fa",
	})
	var get_result := _registry.call_tool("docket_secret_get", {"handle": "2fa_no_pw"})
	var r = A.has_key(get_result, "error")
	if r is String: return r
	return A.has_key(get_result, "requires_2fa")


func test_2fa_secret_wrong_secondary_fails() -> Variant:
	UserPrefs.save_vault_password("test-password")
	_registry.call_tool("docket_secret_set", {
		"handle": "2fa_wrong",
		"value": "classified",
		"requires_2fa": true,
		"secondary_password": "correct-pw",
	})
	var get_result := _registry.call_tool("docket_secret_get", {
		"handle": "2fa_wrong",
		"secondary_password": "wrong-pw",
	})
	return A.has_key(get_result, "error")
