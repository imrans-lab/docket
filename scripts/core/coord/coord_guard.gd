class_name CoordGuard
extends RefCounted
## GDScript's way into the native coordination lock (DocketCoordLock in
## native/docket_native). open() starts an operation and returns it as an
## object (DocketCoordOperation) that its owner passes explicitly to the work
## done within it; `nested(mode)` on it starts a step of the same operation and
## `close()` gives a hold back. There is no current operation to borrow.
##
## The extension is looked up at run time, so scripts that use this still
## load when it is missing; every open() then fails with kind "no_extension".

const SHARED := 0
const EXCLUSIVE := 1
const NO_EXTENSION := "Docket's native extension is not loaded, so projects cannot be coordinated."

var _lock: Object = ClassDB.instantiate("DocketCoordLock") if ClassDB.class_exists("DocketCoordLock") else null


## {operation} or {error, kind}: kind "busy", "io", "refused" (from the
## extension) or "no_extension".
func open(mode: int) -> Dictionary:
	if _lock == null:
		return {"error": NO_EXTENSION, "kind": "no_extension"}
	return _lock.open(mode)


## A step of `parent` (an operation from open()) when there is one, else a new
## operation: {operation} or {error, kind}. The extension checks that `parent`
## really is a live operation; anything else is refused.
func open_within(parent: RefCounted, mode: int) -> Dictionary:
	if _lock == null:
		return {"error": NO_EXTENSION, "kind": "no_extension"}
	return _lock.join(parent, mode)


## "" when the coordination directory is `expected`, as this host resolved
## it; otherwise why not, and coordination stays off in this process.
func expect_directory(expected: String) -> String:
	if _lock == null:
		return NO_EXTENSION
	return str(_lock.expect_directory(expected))


## The coordination directory, or "" when it cannot be found.
func directory() -> String:
	var lock_path := "" if _lock == null else str(_lock.lock_path())
	return "" if lock_path.is_empty() else lock_path.get_base_dir()
