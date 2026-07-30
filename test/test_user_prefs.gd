extends Node
## Tests for UserPrefs session persistence.
## Validates save/load round-trip and guards against empty-state clobbering.

var A := AssertHelpers

# We test against the actual prefs file, so save/restore its contents.
var _original_prefs_data: String = ""
const _PREFS_PATH := "user://docket_prefs.json"


func setup() -> void:
	if FileAccess.file_exists(_PREFS_PATH):
		var f := FileAccess.open(_PREFS_PATH, FileAccess.READ)
		_original_prefs_data = f.get_as_text()
	else:
		_original_prefs_data = ""
	# Start each test with a clean prefs file
	_clear_prefs()


func teardown() -> void:
	# Restore original prefs
	if _original_prefs_data.is_empty():
		if FileAccess.file_exists(_PREFS_PATH):
			DirAccess.remove_absolute(_PREFS_PATH)
	else:
		var f := FileAccess.open(_PREFS_PATH, FileAccess.WRITE)
		f.store_string(_original_prefs_data)


func _clear_prefs() -> void:
	if FileAccess.file_exists(_PREFS_PATH):
		DirAccess.remove_absolute(_PREFS_PATH)


# -- Session save/load round-trip ------------------------------------------

func test_session_save_load_roundtrip() -> Variant:
	var paths := PackedStringArray(["/tmp/a.dct", "/tmp/b.dct"])
	UserPrefs.save_session(paths)
	var loaded := UserPrefs.load_session()
	var r = A.eq(loaded.size(), 2, "loaded count")
	if r != true: return r
	r = A.eq(loaded[0], "/tmp/a.dct", "first path")
	if r != true: return r
	r = A.eq(loaded[1], "/tmp/b.dct", "second path")
	if r != true: return r
	return true


func test_session_empty_save_returns_empty() -> Variant:
	UserPrefs.save_session(PackedStringArray())
	var loaded := UserPrefs.load_session()
	return A.eq(loaded.size(), 0, "empty session")


func test_session_save_does_not_clobber_other_prefs() -> Variant:
	# Save a query first
	UserPrefs.save_last_query("type:bug", "Bugs")
	# Then save session
	UserPrefs.save_session(PackedStringArray(["/tmp/test.dct"]))
	# Query should still be there
	var q := UserPrefs.load_last_query()
	var r = A.eq(q.get("filter", ""), "type:bug", "query filter preserved")
	if r != true: return r
	# Session should also be there
	var s := UserPrefs.load_session()
	r = A.eq(s.size(), 1, "session preserved")
	if r != true: return r
	return true


# -- Regression: empty save must not clobber existing session --------------

func test_empty_session_save_clobbers_existing() -> Variant:
	## Documents that UserPrefs.save_session([]) DOES overwrite.
	## The guard must be in _save_session(), not in UserPrefs.
	UserPrefs.save_session(PackedStringArray(["/tmp/important.dct"]))
	# Verify saved
	var loaded := UserPrefs.load_session()
	var r = A.eq(loaded.size(), 1, "initially saved")
	if r != true: return r
	# Overwrite with empty — this is the raw API behavior (no guard)
	UserPrefs.save_session(PackedStringArray())
	loaded = UserPrefs.load_session()
	r = A.eq(loaded.size(), 0, "clobbered to empty")
	if r != true: return r
	return true


# -- Last query save/load round-trip --------------------------------------

func test_last_query_roundtrip() -> Variant:
	UserPrefs.save_last_query("[{\"field\":\"type\",\"op\":\"eq\",\"value\":\"bug\"}]", "All Bugs")
	var q := UserPrefs.load_last_query()
	var r = A.eq(q.get("label", ""), "All Bugs", "label")
	if r != true: return r
	r = A.is_true(q.get("filter", "").length() > 0, "filter non-empty")
	if r != true: return r
	return true


func test_last_query_empty_returns_empty_dict() -> Variant:
	# Start from clean state (no query saved)
	_clear_prefs()
	var q := UserPrefs.load_last_query()
	return A.eq(q.size(), 0, "empty dict when no query saved")


func test_last_query_does_not_clobber_session() -> Variant:
	UserPrefs.save_session(PackedStringArray(["/tmp/keep.dct"]))
	UserPrefs.save_last_query("type:rca", "RCAs")
	var s := UserPrefs.load_session()
	return A.eq(s.size(), 1, "session not clobbered by query save")


# -- Vault password does not clobber session or query ----------------------

func test_vault_password_does_not_clobber() -> Variant:
	UserPrefs.save_session(PackedStringArray(["/tmp/project.dct"]))
	UserPrefs.save_last_query("type:bug", "Bugs")
	UserPrefs.save_vault_password("hunter2")
	# Everything should coexist
	var s := UserPrefs.load_session()
	var r = A.eq(s.size(), 1, "session intact after vault save")
	if r != true: return r
	var q := UserPrefs.load_last_query()
	r = A.eq(q.get("filter", ""), "type:bug", "query intact after vault save")
	if r != true: return r
	var pw := UserPrefs.load_vault_password()
	r = A.eq(pw, "hunter2", "vault password correct")
	if r != true: return r
	# Cleanup: clear vault password
	UserPrefs.clear_vault_password()
	return true


# -- Vault password hint ----------------------------------------------------

func test_vault_hint_roundtrip() -> Variant:
	UserPrefs.save_vault_password_hint("the usual one plus year")
	var hint := UserPrefs.load_vault_password_hint()
	return A.eq(hint, "the usual one plus year", "hint round-trip")


func test_vault_hint_empty_by_default() -> Variant:
	_clear_prefs()
	var hint := UserPrefs.load_vault_password_hint()
	return A.eq(hint, "", "hint empty when not set")


func test_vault_hint_does_not_clobber() -> Variant:
	UserPrefs.save_vault_password("hunter2")
	UserPrefs.save_session(PackedStringArray(["/tmp/keep.dct"]))
	UserPrefs.save_vault_password_hint("dog name backwards")
	# Everything should coexist
	var pw := UserPrefs.load_vault_password()
	var r = A.eq(pw, "hunter2", "password intact after hint save")
	if r != true: return r
	var s := UserPrefs.load_session()
	r = A.eq(s.size(), 1, "session intact after hint save")
	if r != true: return r
	var hint := UserPrefs.load_vault_password_hint()
	r = A.eq(hint, "dog name backwards", "hint correct")
	if r != true: return r
	UserPrefs.clear_vault_password()
	return true
