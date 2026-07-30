extends Node

var A := AssertHelpers
var _test_dir := "user://test_file_manager"
var _test_file: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_test_file = _test_dir + "/test.dct"


func teardown() -> void:
	# Clean up test files
	var dir := DirAccess.open(_test_dir)
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			dir.remove(fname)
			fname = dir.get_next()
		DirAccess.remove_absolute(_test_dir)


func test_create_new_file() -> Variant:
	var data = FileManager.create_new(_test_file)
	var r = A.eq(data.version, "1.0.0", "version")
	if r is String: return r
	r = A.eq(data.counter, 0, "counter starts at 0")
	if r is String: return r
	r = A.eq(data.items.size(), 0, "no items")
	if r is String: return r
	return A.eq(data.queries.size(), 0, "no queries")


func test_save_load_roundtrip() -> Variant:
	var data = FileManager.create_new(_test_file)
	data.items["DKT-0001"] = {"type": "bug", "title": "Test", "status": "new"}
	data.counter = 1
	FileManager.save(_test_file, data)

	var loaded = FileManager.load_file(_test_file)
	var r = A.has_key(loaded, "items", "has items")
	if r is String: return r
	r = A.has_key(loaded.items, "DKT-0001", "has item")
	if r is String: return r
	r = A.eq(int(loaded.counter), 1, "counter preserved")
	if r is String: return r
	return A.eq(loaded.items["DKT-0001"].title, "Test", "title preserved")


func test_saved_queries() -> Variant:
	var data = FileManager.create_new(_test_file)
	data.queries["my-query"] = {"filter": {"status": "active"}, "sort": ["priority"]}
	FileManager.save(_test_file, data)

	var loaded = FileManager.load_file(_test_file)
	var r = A.has_key(loaded.queries, "my-query", "query present")
	if r is String: return r
	return A.eq(loaded.queries["my-query"].filter.status, "active")


func test_pretty_print() -> Variant:
	var data = FileManager.create_new(_test_file)
	data.items["DKT-0001"] = {"type": "bug", "title": "A"}
	data.items["DKT-0002"] = {"type": "chore", "title": "B"}
	FileManager.save(_test_file, data)

	var f := FileAccess.open(_test_file, FileAccess.READ)
	var text := f.get_as_text()
	# Tab-indented JSON should have newlines
	return A.is_true(text.contains("\n"), "pretty printed with newlines")


func test_load_missing_file() -> Variant:
	var loaded = FileManager.load_file(_test_dir + "/nonexistent.dct")
	return A.has_key(loaded, "error", "error for missing file")
