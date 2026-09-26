extends RefCounted
class_name GuiPrincipal
## The principal the Docket GUI declares for its own claim operations
## (W1 KB docket:01a0dc3549bc s5): `human:<machine-id8>`. It is a declaration,
## not proof that a person acted.


## `human:` plus the first 8 characters of /etc/machine-id, or of
## OS.get_unique_id() where that file does not exist.
static func id() -> String:
	var raw: String = ""
	if FileAccess.file_exists("/etc/machine-id"):
		raw = FileAccess.get_file_as_string("/etc/machine-id")
	if raw.strip_edges().is_empty():
		raw = OS.get_unique_id()
	var compact: String = raw.strip_edges().replace("-", "").replace("{", "").to_lower()
	return "human:%s" % (compact.left(8) if not compact.is_empty() else "unknown")
