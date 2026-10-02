extends RefCounted
class_name BuildInfo
## One generated resource supplies runtime identity and platform export metadata.

const RESOURCE := "res://build_info.json"
static var resource_path: String = RESOURCE

static func read() -> Dictionary:
	if not FileAccess.file_exists(resource_path): return {"version":"dev", "commit":""}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(resource_path))
	if parsed is Dictionary and parsed.get("version") is String and parsed.get("commit") is String and not str(parsed.version).is_empty() and not str(parsed.commit).is_empty():
		return parsed
	push_error("Invalid build info resource: %s" % resource_path)
	return {"version":"invalid-build-info", "commit":""}

static func identity() -> String:
	var info: Dictionary = read()
	var commit: String = str(info.commit)
	return str(info.version) + ("+" + commit if not commit.is_empty() else "")
