extends RefCounted
class_name UserPrefs
## Persistent per-user preferences stored in user://docket_prefs.json.
## Provides display name and initials for comments/authorship.

const _PREFS_PATH := "user://docket_prefs.json"
const MAX_QUERY_TYPE_PINS := 50
const MAX_QUERY_TYPE_RECENTS := 12

var first_name: String = ""
var last_name: String = ""


static func _load_data() -> Dictionary:
	if not FileAccess.file_exists(_PREFS_PATH):
		return {}
	var f := FileAccess.open(_PREFS_PATH, FileAccess.READ)
	if not f:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	return {}


static func _save_data(data: Dictionary) -> void:
	var f := FileAccess.open(_PREFS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))


static func load_prefs() -> UserPrefs:
	var prefs := UserPrefs.new()
	var data := _load_data()
	prefs.first_name = str(data.get("first_name", ""))
	prefs.last_name = str(data.get("last_name", ""))
	return prefs


func save() -> void:
	var data := _load_data()
	data["first_name"] = first_name
	data["last_name"] = last_name
	_save_data(data)


func get_display_name() -> String:
	var parts := PackedStringArray()
	if not first_name.is_empty():
		parts.append(first_name)
	if not last_name.is_empty():
		parts.append(last_name)
	if parts.is_empty():
		return OS.get_environment("USER")
	return " ".join(parts)


# -- Vault password -----------------------------------------------------------

static func load_vault_password() -> String:
	return str(_load_data().get("vault_password", ""))


static func save_vault_password(pw: String) -> void:
	var data := _load_data()
	data["vault_password"] = pw
	_save_data(data)


static func clear_vault_password() -> void:
	save_vault_password("")


static func load_vault_password_hint() -> String:
	return str(_load_data().get("vault_password_hint", ""))


static func save_vault_password_hint(hint: String) -> void:
	var data := _load_data()
	data["vault_password_hint"] = hint
	_save_data(data)


# -- Session restore (list of .dct paths) ------------------------------------

static func load_session() -> PackedStringArray:
	var data := _load_data()
	var paths := PackedStringArray()
	var arr = data.get("session_paths", [])
	if arr is Array:
		for p in arr:
			paths.append(str(p))
	return paths


static func save_session(paths: PackedStringArray) -> void:
	var data := _load_data()
	var arr: Array = []
	for p in paths:
		arr.append(p)
	data["session_paths"] = arr
	_save_data(data)


# -- Last query restore ----------------------------------------------------

static func save_last_query(filter: String, label: String) -> void:
	var data := _load_data()
	data["last_query_filter"] = filter
	data["last_query_label"] = label
	_save_data(data)


static func load_last_query() -> Dictionary:
	var data := _load_data()
	var filter_val = data.get("last_query_filter", "")
	var label_val = data.get("last_query_label", "")
	if str(filter_val).is_empty() and str(label_val).is_empty():
		return {}
	return {"filter": str(filter_val), "label": str(label_val)}


# -- Query type shortcuts -------------------------------------------------

static func load_type_shortcuts(project: String) -> Dictionary:
	var all_shortcuts = _load_data().get("query_type_shortcuts", {})
	if not all_shortcuts is Dictionary:
		return {"pinned": [], "recent": []}
	var project_data = all_shortcuts.get(project, {})
	if not project_data is Dictionary:
		return {"pinned": [], "recent": []}
	return {
		"pinned": _normalized_shortcuts(project_data.get("pinned", []), MAX_QUERY_TYPE_PINS),
		"recent": _normalized_shortcuts(project_data.get("recent", []), MAX_QUERY_TYPE_RECENTS),
	}


static func save_type_shortcuts(project: String, pinned: Array, recent: Array) -> void:
	var data := _load_data()
	var all_shortcuts = data.get("query_type_shortcuts", {})
	if not all_shortcuts is Dictionary:
		all_shortcuts = {}
	all_shortcuts[project] = {
		"pinned": _normalized_shortcuts(pinned, MAX_QUERY_TYPE_PINS),
		"recent": _normalized_shortcuts(recent, MAX_QUERY_TYPE_RECENTS),
	}
	data["query_type_shortcuts"] = all_shortcuts
	_save_data(data)


static func _string_array(value: Variant) -> Array:
	var result: Array = []
	if value is Array:
		for entry in value:
			result.append(str(entry))
	return result


static func _unique_strings(values: Array) -> Array:
	var result: Array = []
	for value in values:
		var text := str(value)
		if not text.is_empty() and not result.has(text):
			result.append(text)
	return result


static func _normalized_shortcuts(value: Variant, limit: int) -> Array:
	var values: Array = value if value is Array else []
	var result := _unique_strings(values)
	if result.size() > limit:
		result.resize(limit)
	return result
