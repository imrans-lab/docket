extends Node
## End-to-end tests for the whole secret lifecycle.
##
## The previous round's tests checked units in isolation and missed that a
## promoted secret was unreadable, that deletion could orphan a payload, and that
## the MCP ownership guard did not actually refuse. These drive the real tool
## surface and assert what a caller observes.

var A := AssertHelpers
var _test_dir := "user://test_secret_lifecycle"
var _path: String
var _db: DocketDBJsonl
var _reg: ToolRegistry
var _schema: Dictionary


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	_schema = JSON.parse_string(f.get_as_text())
	f.close()


func before_each() -> void:
	_path = _test_dir + "/life.dct"
	_cleanup()
	_db = DocketDBJsonl.create_new_jsonl(_path)
	_reg = ToolRegistry.new()
	_reg.init(_schema, _db, {})


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


func _b(s: String) -> PackedByteArray:
	return s.to_utf8_buffer()


func _standalone(handle: String) -> void:
	_db.set_secret(handle, _b("CT"), _b("IV"), _b("MAC"))


func _owned_item(id: String) -> void:
	_db.insert_item(id, {
		"id": id, "type": "secret", "status": "active", "title": "tracked",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
	})
	_db.set_secret(id, _b("CT"), _b("IV"), _b("MAC"), false, id)


# -- Promotion -----------------------------------------------------------------

func test_promoted_secret_is_readable_the_way_the_gui_reads_it() -> Variant:
	## The GUI loads a Secret item's payload with get_secret_raw(item_id).
	## Promotion previously left the ciphertext under its original handle, so the
	## item existed, claimed the secret, and the GUI found nothing.
	_standalone("prod/api-token")
	var res: Dictionary = _reg.call_tool("docket_secret_promote",
		{"handle": "prod/api-token", "title": "Prod token"})
	if res.has("error"):
		return "promote failed: %s" % res.error
	var item_id: String = str(res.get("id", ""))
	return A.is_true(not _db.get_secret_raw(item_id).is_empty(),
		"ciphertext is reachable by item id")


func test_promotion_leaves_no_copy_behind() -> Variant:
	_standalone("prod/api-token")
	var res: Dictionary = _reg.call_tool("docket_secret_promote", {"handle": "prod/api-token"})
	if res.has("error"):
		return "promote failed: %s" % res.error
	return A.is_true(_db.get_secret_raw("prod/api-token").is_empty(),
		"old handle no longer holds a duplicate")


func test_promoted_secret_leaves_the_standalone_list() -> Variant:
	_standalone("prod/api-token")
	_reg.call_tool("docket_secret_promote", {"handle": "prod/api-token"})
	return A.eq(_db.list_standalone_secrets().size(), 0, "no longer listed as standalone")


func test_promotion_moves_version_history() -> Variant:
	## History keyed to the old handle would be stranded by a rename.
	_standalone("prod/api-token")
	_db.rotate_secret("prod/api-token", _b("CT2"), _b("IV"), _b("MAC"), "tester")
	var res: Dictionary = _reg.call_tool("docket_secret_promote", {"handle": "prod/api-token"})
	if res.has("error"):
		return "promote failed: %s" % res.error
	var item_id: String = str(res.get("id", ""))
	var r = A.eq(_db.get_secret_versions(item_id).size(), 1, "history follows the secret")
	if r != true:
		return r
	return A.eq(_db.get_secret_versions("prod/api-token").size(), 0, "nothing left behind")


func test_promoting_an_owned_secret_is_refused() -> Variant:
	_owned_item("itemA")
	var res: Dictionary = _reg.call_tool("docket_secret_promote", {"handle": "itemA"})
	return A.is_true(res.has("error"), "already-owned entry cannot be promoted again")


func test_promoting_a_missing_handle_is_refused() -> Variant:
	var res: Dictionary = _reg.call_tool("docket_secret_promote", {"handle": "nope"})
	return A.is_true(res.has("error"), "unknown handle is refused")


# -- Deletion ------------------------------------------------------------------

func test_deleting_the_item_removes_its_payload() -> Variant:
	_standalone("prod/api-token")
	var res: Dictionary = _reg.call_tool("docket_secret_promote", {"handle": "prod/api-token"})
	var item_id: String = str(res.get("id", ""))
	_db.delete_item(item_id)
	var r = A.is_true(_db.get_secret_raw(item_id).is_empty(), "payload removed with the item")
	if r != true:
		return r
	return A.is_true(_db.get_secret_raw("prod/api-token").is_empty(), "no orphan under the old handle")


func test_agent_cannot_delete_an_owned_payload() -> Variant:
	## Worse than overwriting: there is no rotation history to recover from.
	_owned_item("itemA")
	var res: Dictionary = _reg.call_tool("docket_secret_delete", {"handle": "itemA"})
	var r = A.is_true(res.has("error"), "delete of an owned handle is refused")
	if r != true:
		return r
	return A.is_true(not _db.get_secret_raw("itemA").is_empty(), "payload still present")


func test_agent_can_delete_its_own_standalone_secret() -> Variant:
	_standalone("prod/api-token")
	var res: Dictionary = _reg.call_tool("docket_secret_delete", {"handle": "prod/api-token"})
	var r = A.is_true(not res.has("error"), "standalone delete still allowed")
	if r != true:
		return r
	return A.is_true(_db.get_secret_raw("prod/api-token").is_empty(), "entry removed")


# -- The MCP ownership boundary ------------------------------------------------

func test_agent_cannot_overwrite_an_owned_value() -> Variant:
	## The earlier guard permitted the write when the recorded owner matched,
	## which is precisely the case it was meant to stop.
	_owned_item("itemA")
	var res: Dictionary = _reg.call_tool("docket_secret_set",
		{"handle": "itemA", "value": "hijacked"})
	return A.is_true(res.has("error"), "owned handle is refused by docket_secret_set")


func test_agent_cannot_target_encrypted_notes() -> Variant:
	_owned_item("itemA")
	_db.set_secret("itemA:notes", _b("CT"), _b("IV"), _b("MAC"), false, "itemA")
	var res: Dictionary = _reg.call_tool("docket_secret_set",
		{"handle": "itemA:notes", "value": "hijacked"})
	return A.is_true(res.has("error"), "notes handle is refused too")


# -- Rotated 2FA history -------------------------------------------------------

func test_archived_version_records_whether_it_was_2fa() -> Variant:
	## Without this, a history reader single-layer-decrypts a double-encrypted
	## value and returns the inner encrypted blob as if it were the secret.
	_db.set_secret("h", _b("CT1"), _b("IV"), _b("MAC"), true)
	_db.rotate_secret("h", _b("CT2"), _b("IV"), _b("MAC"), "tester", false)
	var versions := _db.get_secret_versions("h")
	var r = A.eq(versions.size(), 1, "one archived version")
	if r != true:
		return r
	return A.is_true(bool(versions[0].get("requires_2fa", false)),
		"archived version remembers it was double-encrypted")


func test_archived_non_2fa_version_is_marked_plain() -> Variant:
	_db.set_secret("h", _b("CT1"), _b("IV"), _b("MAC"), false)
	_db.rotate_secret("h", _b("CT2"), _b("IV"), _b("MAC"), "tester", true)
	var versions := _db.get_secret_versions("h")
	return A.is_true(not bool(versions[0].get("requires_2fa", true)),
		"flag describes the archived value, not the replacement")


func test_version_history_survives_a_round_trip() -> Variant:
	_db.set_secret("h", _b("CT1"), _b("IV"), _b("MAC"), true)
	_db.rotate_secret("h", _b("CT2"), _b("IV"), _b("MAC"), "tester", true)
	_db.close()
	_db = null
	for suffix: String in [".cache", ".cache-wal", ".cache-shm"]:
		if FileAccess.file_exists(_path + suffix):
			DirAccess.remove_absolute(_path + suffix)
	_db = DocketDBJsonl.open_jsonl(_path)
	var versions := _db.get_secret_versions("h")
	return A.eq(versions.size(), 1, "archived version survives a cache rebuild")
