extends RefCounted
class_name DocketFields
## Facts about items that need no project open: shared by the storage classes
## and the UI, which must run where they are not loaded (a host embedding it).

## Fields every item type may change, whatever its definition declares.
const UNIVERSAL_MUTABLE := ["title", "description", "assigned_to", "directed_to", "priority", "severity", "tags", "parent", "blocked_by"]


## Whether `id` looks like a UUID7 (32 lowercase hex characters).
static func is_uuid7(id: String) -> bool:
	return id.length() == 32 and id.is_valid_hex_number(false)
