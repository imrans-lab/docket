extends Node
## Tests for attachment functionality.

var A := AssertHelpers
var _db: DocketDB
var _registry: ToolRegistry
var _schema: Dictionary
var _test_dir := "user://test_attachments"
var _test_file: String
var _item_id: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_test_file = _test_dir + "/test_attach.dct"
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	_schema = JSON.parse_string(f.get_as_text())


func before_each() -> void:
	_cleanup()
	_db = DocketDB.create_new(_test_file)
	_registry = ToolRegistry.new()
	_registry.init(_schema, _db)
	# Create a test item and capture its actual ID
	var create_result = _registry.call_tool("docket_create", {"type": "bug", "title": "Bug with attachments"})
	_item_id = str(create_result.get("id", ""))


func _cleanup() -> void:
	if _db:
		_db.close()
		_db = null
	for suffix: String in ["", "-wal", "-shm"]:
		var p: String = _test_file + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


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


# -- DB-level attachment tests ------------------------------------------------

func test_attach_file_db() -> Variant:
	var data := PackedByteArray([0x89, 0x50, 0x4E, 0x47])  # fake PNG header
	var result := _db.attach_file(_item_id, "screenshot.png", data, "image/png", "A screenshot")
	var r = A.has_key(result, "id")
	if r is String: return r
	r = A.eq(result.filename, "screenshot.png")
	if r is String: return r
	return A.eq(result.size_bytes, 4)


func test_list_attachments_db() -> Variant:
	var data := PackedByteArray([1, 2, 3])
	_db.attach_file(_item_id, "file1.txt", data)
	_db.attach_file(_item_id, "file2.txt", data)
	var atts := _db.list_attachments(_item_id)
	return A.eq(atts.size(), 2, "two attachments")


func test_get_attachment_db() -> Variant:
	var data := PackedByteArray([0xDE, 0xAD, 0xBE, 0xEF])
	var result := _db.attach_file(_item_id, "binary.bin", data, "application/octet-stream")
	var att := _db.get_attachment(result.id)
	var r = A.eq(att.filename, "binary.bin")
	if r is String: return r
	var att_data = att.get("data")
	if att_data is PackedByteArray:
		return A.eq(att_data.size(), 4, "data size matches")
	return "data is not PackedByteArray"


func test_detach_file_db() -> Variant:
	var data := PackedByteArray([1, 2, 3])
	var result := _db.attach_file(_item_id, "temp.txt", data)
	_db.detach_file(result.id)
	var atts := _db.list_attachments(_item_id)
	return A.eq(atts.size(), 0, "attachment removed")


# -- MCP tool tests -----------------------------------------------------------

func test_attach_tool() -> Variant:
	var b64_data := Marshalls.raw_to_base64(PackedByteArray([0x48, 0x65, 0x6C, 0x6C, 0x6F]))  # "Hello"
	var result = _registry.call_tool("docket_attach", {
		"item_id": _item_id,
		"filename": "hello.txt",
		"data": b64_data,
		"mime_type": "text/plain",
		"description": "Test file",
	})
	var r = A.has_key(result, "id")
	if r is String: return r
	return A.eq(result.filename, "hello.txt")


func test_detach_list_tool() -> Variant:
	var b64 := Marshalls.raw_to_base64(PackedByteArray([1, 2, 3]))
	_registry.call_tool("docket_attach", {"item_id": _item_id, "filename": "a.bin", "data": b64})
	_registry.call_tool("docket_attach", {"item_id": _item_id, "filename": "b.bin", "data": b64})
	var result = _registry.call_tool("docket_detach", {"action": "list", "item_id": _item_id})
	return A.eq(result.count, 2, "two attachments listed")


func test_detach_get_tool() -> Variant:
	var original := PackedByteArray([0xCA, 0xFE])
	var b64 := Marshalls.raw_to_base64(original)
	var attach_result = _registry.call_tool("docket_attach", {"item_id": _item_id, "filename": "cafe.bin", "data": b64})
	var result = _registry.call_tool("docket_detach", {"action": "get", "attachment_id": attach_result.id})
	var r = A.has_key(result, "data")
	if r is String: return r
	# Data should come back as base64
	var decoded := Marshalls.base64_to_raw(result.data)
	return A.eq(decoded.size(), 2, "roundtrip data size")


func test_detach_delete_tool() -> Variant:
	var b64 := Marshalls.raw_to_base64(PackedByteArray([1]))
	var attach_result = _registry.call_tool("docket_attach", {"item_id": _item_id, "filename": "del.bin", "data": b64})
	var del_result = _registry.call_tool("docket_detach", {"action": "delete", "attachment_id": attach_result.id})
	var r = A.has_key(del_result, "deleted")
	if r is String: return r
	var list_result = _registry.call_tool("docket_detach", {"action": "list", "item_id": _item_id})
	return A.eq(list_result.count, 0, "attachment deleted")


func test_attach_missing_item() -> Variant:
	var b64 := Marshalls.raw_to_base64(PackedByteArray([1]))
	var result = _registry.call_tool("docket_attach", {"item_id": "NONEXISTENT-9999", "filename": "x.bin", "data": b64})
	return A.has_key(result, "error")
