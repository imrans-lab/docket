class_name CoordLease
extends RefCounted
## The SHARED coordination operation a project write takes when it is given
## none to join: storage code calls these before its first freshness check or
## write, and closes the operation after its commit, file write and any
## cleanup. Ordinary writes do not exclude each other, so a write inside a
## caller's own SHARED operation simply takes another; a caller that must be
## joined (vault administration, later) passes its operation as `parent`.
##
## When no operation can be had (the native extension missing, the lock busy
## past its deadline, coordination switched off) the write is refused with
## the reason; nothing is written without one.


## {operation} or {error, kind}.
static func shared(parent: RefCounted = null) -> Dictionary:
	var opened := CoordGuard.new().open_within(parent, CoordGuard.SHARED)
	if opened.has("error"):
		return {"error": "Docket cannot coordinate with its other processes now: %s" % opened.error, "kind": opened.kind}
	return opened


## `work` run within a SHARED operation: its result ("" or an error), or the
## refusal when there is none to be had.
static func run(work: Callable, parent: RefCounted = null) -> String:
	var opened := shared(parent)
	if opened.has("error"):
		return opened.error
	var result: Variant = work.call()
	opened.operation.close()
	return result if result is String else "project change stopped unexpectedly"
