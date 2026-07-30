extends Node
## Tests for the revised secrets design:
## - type:secret removed from docket_create
## - secret_set/get are vault-only (no work items)
## - existing type:secret items remain readable (backward compat)
## TDD red phase — some tests will fail until implementation is done.

var A := AssertHelpers
var _db: DocketDB
var _registry: ToolRegistry
var _schema: Dictionary
var _test_dir := "user://test_secret_unified_set"
var _test_file: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_test_file = _test_dir + "/test_unified.dct"
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	_schema = JSON.parse_string(f.get_as_text())


func before_each() -> void:
	_cleanup()
	_db = DocketDB.create_new(_test_file)
	_registry = ToolRegistry.new()
	_registry.init(_schema, _db)
	UserPrefs.save_vault_password("test-password")


func _cleanup() -> void:
	if _db:
		_db.close()
		_db = null
	for suffix: String in ["", "-wal", "-shm"]:
		var p: String = _test_file + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
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


# -- docket_create rejects type:secret -----------------------------------------

func test_create_rejects_type_secret() -> Variant:
	## docket_create should no longer accept type:secret.
	var result := _registry.call_tool("docket_create", {
		"type": "secret",
		"title": "Should Not Work",
		"secret_value": "password123",
	})
	return A.has_key(result, "error")


func test_create_rejects_type_encrypted_note() -> Variant:
	## docket_create should no longer accept type:encrypted_note.
	var result := _registry.call_tool("docket_create", {
		"type": "encrypted_note",
		"title": "Should Not Work",
		"encrypted_body": "secret diary entry",
	})
	return A.has_key(result, "error")


# -- secret_set/get remain functional (vault-only) ----------------------------

func test_secret_set_get_roundtrip() -> Variant:
	## secret_set stores by handle, secret_get retrieves by handle.
	var set_result := _registry.call_tool("docket_secret_set", {
		"handle": "test_cred",
		"value": "my-secret-value",
	})
	var r = A.has_key(set_result, "status")
	if r is String: return r
	r = A.eq(set_result.status, "created", "status is created")
	if r is String: return r

	var get_result := _registry.call_tool("docket_secret_get", {"handle": "test_cred"})
	r = A.has_key(get_result, "value")
	if r is String: return r
	return A.eq(get_result.value, "my-secret-value", "roundtrip value matches")


func test_secret_set_does_not_create_work_item() -> Variant:
	## secret_set should never create a work item — secrets are vault-only.
	_registry.call_tool("docket_secret_set", {
		"handle": "vault_only_cred",
		"value": "no-work-item",
	})

	# Query for any items — there should be none
	var query_result := _registry.call_tool("docket_query", {})
	if query_result.has("items"):
		return A.eq(query_result.items.size(), 0, "no work items created by secret_set")
	return true


func test_secret_update_value() -> Variant:
	## Updating a secret replaces the encrypted value.
	_registry.call_tool("docket_secret_set", {"handle": "cred", "value": "old_pass"})
	var set2 := _registry.call_tool("docket_secret_set", {"handle": "cred", "value": "new_pass"})
	var r = A.eq(set2.get("status", ""), "updated", "second set is updated")
	if r is String: return r

	var get_result := _registry.call_tool("docket_secret_get", {"handle": "cred"})
	return A.eq(get_result.value, "new_pass", "updated value returned")


func test_secret_list_shows_handles() -> Variant:
	## secret_list returns all vault handles.
	_registry.call_tool("docket_secret_set", {"handle": "alpha", "value": "1"})
	_registry.call_tool("docket_secret_set", {"handle": "beta", "value": "2"})

	var list_result := _registry.call_tool("docket_secret_list", {})
	var r = A.has_key(list_result, "secrets")
	if r is String: return r
	r = A.eq(list_result.secrets.size(), 2, "two secrets listed")
	if r is String: return r

	var handles: Array = list_result.secrets.map(func(s: Dictionary) -> String: return s.get("handle", ""))
	r = A.contains(handles, "alpha", "alpha in list")
	if r is String: return r
	return A.contains(handles, "beta", "beta in list")


# -- Plaintext never in vault bytes -------------------------------------------

func test_plaintext_absent_from_vault_bytes() -> Variant:
	## The plaintext secret must not appear anywhere in the stored vault data.
	var test_secret := "FAKE-CREDENTIAL-Qm8xN4pR"
	_registry.call_tool("docket_secret_set", {"handle": "leak_test", "value": test_secret})

	var raw := _db.get_secret_raw("leak_test")
	var r = A.is_false(raw.is_empty(), "secret stored")
	if r is String: return r

	var plaintext_bytes := test_secret.to_utf8_buffer()
	for field in ["ciphertext", "iv", "mac"]:
		var stored: PackedByteArray = raw[field]
		var stored_str := stored.get_string_from_utf8()
		if stored_str.contains(test_secret):
			return "Plaintext found in vault %s column" % field
	return true


# -- Backward compat: existing type:secret items still readable ---------------

func test_existing_secret_items_still_queryable() -> Variant:
	## Old type:secret items already in the DB should still be queryable as items,
	## even though creating new ones is rejected.
	## We simulate by creating via DataModel (which sets created_at etc.)
	## and inserting directly — bypassing docket_create's type rejection.
	var schema := _schema
	var item = DataModel.create_item(schema, "secret", {
		"title": "Legacy AWS Key",
		"key": "aws_key",
		"surfaced_from": "admin@example.com",
		"environment": "console.aws.amazon.com",
	})
	var r = A.is_false(item.has("error"), "item created via DataModel")
	if r is String: return r
	var id := _db.next_uuid7_id()
	var err := _db.insert_item(id, item)
	r = A.is_true(err.is_empty(), "item inserted without error")
	if r is String: return r

	var fetched := _db.get_item(id)
	r = A.eq(str(fetched.get("type", "")), "secret", "type still secret")
	if r is String: return r
	return A.eq(str(fetched.get("title", "")), "Legacy AWS Key", "title preserved")


func test_existing_secret_vault_entry_still_decryptable() -> Variant:
	## Old secrets stored by item ID in the vault should still decrypt.
	## Simulate: encrypt a value, store it under an item-ID-like handle.
	var password := "test-password"
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key(password, salt)
	_db.init_vault(key, salt)

	var fake_id := "019d0000dead0000beef000000000001"
	var encrypted := VaultCrypto.encrypt("legacy-secret-value", key)
	_db.set_secret(fake_id, encrypted.ciphertext, encrypted.iv, encrypted.mac)

	# Retrieve via secret_get using the old item-ID handle
	var get_result := _registry.call_tool("docket_secret_get", {"handle": fake_id})
	var r = A.has_key(get_result, "value")
	if r is String: return r
	return A.eq(get_result.value, "legacy-secret-value", "old ID-based secret still decrypts")
