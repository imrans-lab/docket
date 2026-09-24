class_name CoordGuard
extends RefCounted
## GDScript's way into the native coordination lock (DocketCoordLock in
## native/docket_native). Every call is a logical operation: begin() starts
## one, or a nested step of `within`, and end() gives it back.
##
## The extension is looked up at run time, so scripts that use this still
## load when it is missing; every begin() then fails with kind "no_extension".

const SHARED := 0
const EXCLUSIVE := 1

var _lock: Object = ClassDB.instantiate("DocketCoordLock") if ClassDB.class_exists("DocketCoordLock") else null


## {op} or {error, kind}: kind "busy", "io", "refused" (from the extension) or
## "no_extension".
func begin(mode: int, within: int = 0) -> Dictionary:
	if _lock == null:
		return {"error": "Docket's native extension is not loaded, so projects cannot be coordinated.", "kind": "no_extension"}
	return _lock.begin(mode, within)


## "" or why operation `op` could not be ended.
func end(op: int) -> String:
	return "" if _lock == null else str(_lock.end(op))


## The coordination directory, or "" when it cannot be found.
func directory() -> String:
	var lock_path := "" if _lock == null else str(_lock.lock_path())
	return "" if lock_path.is_empty() else lock_path.get_base_dir()
