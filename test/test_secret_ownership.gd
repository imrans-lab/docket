extends Node
## Tests for explicit secret ownership.
##
## Ownership used to be inferred from handle text: a Secret item's payload lived
## under handle == item_id, its notes under "<item_id>:notes". Nothing recorded
## that relationship, so standalone agent-created entries were indistinguishable
## from item payloads — invisible in the GUI, and overwritable by an agent that
## happened to use an item id as a handle.

var A := AssertHelpers
var _test_dir := "user://test_secret_ownership"
var _path: String
var _db: DocketDBJsonl

const META := '{"_type":"meta","version":"1.0.0","counter":0,"id_prefix":"OWN"}'


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func before_each() -> void:
	_path = _test_dir + "/own.dct"
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


func _bytes(s: String) -> PackedByteArray:
	return s.to_utf8_buffer()


func _add_item(id: String) -> void:
	_db.insert_item(id, {
		"id": id, "type": "secret", "status": "active", "title": "owned",
		"created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00",
	})


# -- Ownership is recorded and distinguishable --------------------------------

func test_standalone_secret_has_no_owner() -> Variant:
	_db.set_secret("prod/api-token", _bytes("ct"), _bytes("iv"), _bytes("mac"))
	return A.eq(_db.get_secret_owner("prod/api-token"), "", "agent secret is standalone")


func test_item_payload_records_its_owner() -> Variant:
	_add_item("itemA")
	_db.set_secret("itemA", _bytes("ct"), _bytes("iv"), _bytes("mac"), false, "itemA")
	return A.eq(_db.get_secret_owner("itemA"), "itemA", "item payload is owned")


func test_standalone_listing_excludes_item_payloads() -> Variant:
	## This is what makes a GUI Vault view possible: standalone entries have no
	## row in `items`, so the query grid can never show them.
	_add_item("itemA")
	_db.set_secret("itemA", _bytes("ct"), _bytes("iv"), _bytes("mac"), false, "itemA")
	_db.set_secret("prod/token", _bytes("ct"), _bytes("iv"), _bytes("mac"))
	_db.set_secret("staging/token", _bytes("ct"), _bytes("iv"), _bytes("mac"))

	var standalone := _db.list_standalone_secrets()
	var handles: Array = []
	for s in standalone:
		handles.append(str(s.get("handle", "")))
	handles.sort()
	return A.eq(handles, ["prod/token", "staging/token"], "only unowned entries listed")


func test_list_secrets_exposes_ownership() -> Variant:
	_add_item("itemA")
	_db.set_secret("itemA", _bytes("ct"), _bytes("iv"), _bytes("mac"), false, "itemA")
	for s in _db.list_secrets():
		if str(s.get("handle", "")) == "itemA":
			return A.eq(str(s.get("owner_item_id", "")), "itemA", "ownership visible over MCP")
	return "itemA not present in list_secrets"


# -- Ownership must not be clobbered ------------------------------------------

func test_update_without_owner_preserves_it() -> Variant:
	## The vault password change re-encrypts every secret via set_secret without
	## passing an owner. That must not orphan item payloads.
	_add_item("itemA")
	_db.set_secret("itemA", _bytes("ct1"), _bytes("iv"), _bytes("mac"), false, "itemA")
	_db.set_secret("itemA", _bytes("ct2"), _bytes("iv"), _bytes("mac"))
	return A.eq(_db.get_secret_owner("itemA"), "itemA", "owner survives an ownerless update")


func test_rotation_preserves_owner() -> Variant:
	_add_item("itemA")
	_db.set_secret("itemA", _bytes("ct1"), _bytes("iv"), _bytes("mac"), false, "itemA")
	_db.rotate_secret("itemA", _bytes("ct2"), _bytes("iv"), _bytes("mac"), "tester")
	return A.eq(_db.get_secret_owner("itemA"), "itemA", "owner survives rotation")


# -- Round trip ----------------------------------------------------------------

func test_ownership_survives_cache_rebuild() -> Variant:
	## A field held only in the cache is lost on rebuild — the failure mode that
	## dropped project lifecycle fields and nearly stranded every vault.
	_add_item("itemA")
	_db.set_secret("itemA", _bytes("ct"), _bytes("iv"), _bytes("mac"), false, "itemA")
	_db.set_secret("prod/token", _bytes("ct"), _bytes("iv"), _bytes("mac"))
	_db.close()
	_db = null

	for suffix: String in [".cache", ".cache-wal", ".cache-shm"]:
		if FileAccess.file_exists(_path + suffix):
			DirAccess.remove_absolute(_path + suffix)

	_db = DocketDBJsonl.open_jsonl(_path)
	var r = A.eq(_db.get_secret_owner("itemA"), "itemA", "owned entry survives rebuild")
	if r != true:
		return r
	return A.eq(_db.get_secret_owner("prod/token"), "", "standalone entry stays standalone")


func test_ownership_is_written_to_the_file() -> Variant:
	_add_item("itemA")
	_db.set_secret("itemA", _bytes("ct"), _bytes("iv"), _bytes("mac"), false, "itemA")
	_db.close()
	_db = null
	var text := FileAccess.get_file_as_string(_path)
	return A.contains(text, "owner_item_id", "ownership reaches the JSONL")


func test_standalone_secret_omits_the_field() -> Variant:
	## Omitted rather than written empty, per the format's omit-empty rule.
	_db.set_secret("prod/token", _bytes("ct"), _bytes("iv"), _bytes("mac"))
	_db.close()
	_db = null
	var text := FileAccess.get_file_as_string(_path)
	return A.is_true(not text.contains("owner_item_id"), "no empty field emitted")


# -- Backfill for files written before the column existed ---------------------

func test_derivation_backfills_legacy_files() -> Variant:
	## Old files encoded ownership in the handle. Deriving it reads what was
	## already there — no ciphertext moves, so nothing can be lost.
	_db.close()
	_db = null
	var legacy := (META + "\n"
		+ '{"_type":"item","id":"itemA","type":"secret","status":"active","title":"x",'
		+ '"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}' + "\n"
		+ '{"_type":"secret","handle":"itemA","ciphertext":"Y3Q=","iv":"aXY=","mac":"bWFj",'
		+ '"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}' + "\n"
		+ '{"_type":"secret","handle":"itemA:notes","ciphertext":"Y3Q=","iv":"aXY=","mac":"bWFj",'
		+ '"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}' + "\n"
		+ '{"_type":"secret","handle":"prod/token","ciphertext":"Y3Q=","iv":"aXY=","mac":"bWFj",'
		+ '"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}' + "\n")
	var f := FileAccess.open(_path, FileAccess.WRITE)
	f.store_string(legacy)
	f.close()

	_db = DocketDBJsonl.open_jsonl(_path)
	var r = A.not_null(_db, "legacy file opens")
	if r != true:
		return r
	# Ownership is derived on read from the handle convention, so a file written
	# before the column existed still separates payloads from standalone entries.
	var standalone := _db.list_standalone_secrets()
	var handles: Array = []
	for s in standalone:
		handles.append(str(s.get("handle", "")))
	return A.eq(handles, ["prod/token"], "only the agent secret is standalone")


# -- Unknown-field preservation ------------------------------------------------

func test_unknown_secret_fields_survive_a_real_round_trip() -> Variant:
	## The earlier version of this test only called the parser and inspected its
	## return value. That passed while the field still died: the cache and the
	## serializer wrote fixed columns, so the flush dropped it. A round-trip test
	## has to actually open, flush and re-read the file.
	_db.close()
	_db = null
	var future := (META + "\n"
		+ '{"_type":"secret","handle":"h","ciphertext":"Y3Q=","iv":"aXY=","mac":"bWFj",'
		+ '"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00",'
		+ '"future_field":"keep me"}' + "\n")
	var f := FileAccess.open(_path, FileAccess.WRITE)
	f.store_string(future)
	f.close()

	# open -> build cache -> flush back to disk
	_db = DocketDBJsonl.open_jsonl(_path)
	var r = A.not_null(_db, "file with an unmodelled field still opens")
	if r != true:
		return r
	_db.close()
	_db = null

	var text := FileAccess.get_file_as_string(_path)
	r = A.contains(text, "future_field", "field is written back to the file")
	if r != true:
		return r
	return A.contains(text, "keep me", "its value is preserved verbatim")
