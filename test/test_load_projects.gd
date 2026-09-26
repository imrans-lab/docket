extends Node
## AppState.load_projects opens a session's files as one change.
##
## Oracle: counters on AppState's file_changed and load_failed signals, plus the
## number of projects AppState reports open. No load_projects internals are
## consulted.

var A := AssertHelpers
const DIR := "user://test_load_projects"

var _state: AppState
var _file_changed := 0
var _load_failed := 0


func before_each() -> void:
	_remove_tree(DIR)
	DirAccess.make_dir_recursive_absolute(DIR)
	for name in ["Alpha", "Beta", "Gamma"]:
		var created := DocketDBJsonl.create_new_jsonl("%s/%s.dct" % [DIR, name])
		if created != null: created.close()
	# A file of no known .dct format: opening it is refused with load_failed.
	var junk := FileAccess.open(DIR + "/Junk.dct", FileAccess.WRITE)
	junk.store_string("not a docket file\n")
	junk.close()
	_state = AppState.new()
	_state.load_schema()
	_file_changed = 0
	_load_failed = 0
	_state.file_changed.connect(func() -> void: _file_changed += 1)
	_state.load_failed.connect(func(_path: String, _reason: String) -> void: _load_failed += 1)


func after_each() -> void:
	for name in _state.get_project_dbs().keys():
		_state.remove_project(str(name))
	_remove_tree(DIR)


func _remove_tree(path: String) -> void:
	var directory: DirAccess = DirAccess.open(path)
	if directory == null:
		return
	directory.include_hidden = true
	for name in directory.get_directories():
		_remove_tree(path + "/" + name)
	for name in directory.get_files():
		directory.remove(name)
	DirAccess.remove_absolute(path)


func test_three_files_emit_file_changed_once() -> Variant:
	_state.load_projects([DIR + "/Alpha.dct", DIR + "/Beta.dct", DIR + "/Gamma.dct"])
	var r = A.eq(_state.get_project_dbs().size(), 3, "all three projects open")
	if r is String: return r
	r = A.eq(_file_changed, 1, "file_changed fires once for the batch")
	if r is String: return r
	return A.eq(_load_failed, 0, "no load_failed")


func test_refused_file_mid_batch_still_emits_once_and_later_adds_emit_again() -> Variant:
	_state.load_projects([DIR + "/Alpha.dct", DIR + "/Junk.dct", DIR + "/Beta.dct"])
	var r = A.eq(_state.get_project_dbs().size(), 2, "the refused file is not opened")
	if r is String: return r
	r = A.eq(_file_changed, 1, "file_changed fires once despite the refusal")
	if r is String: return r
	r = A.eq(_load_failed, 1, "load_failed fires once for the refused file")
	if r is String: return r
	# After the batch, a single add reports its own change.
	var refusal := _state.add_project(DIR + "/Gamma.dct")
	r = A.eq(refusal, "", "Gamma added")
	if r is String: return r
	return A.eq(_file_changed, 2, "add_project after the batch fires file_changed again")
