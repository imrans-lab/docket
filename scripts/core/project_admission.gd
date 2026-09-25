class_name ProjectAdmission
extends RefCounted
## The one gate every read and change of open projects' data passes, for
## tools, the private panel channel and the local UI alike: each project is
## judged as it is now (DocketDBConnection.admission), never as a poll last
## saw it, and the work runs only when every one it may touch is its file.
## A JSONL project whose file changed is read again first; one that cannot be
## (a change kept unsaved, a commit whose outcome is unknown, a file that
## cannot be written as the project, a replaced SQLite file) is refused,
## naming the project and why. Listing, opening, closing and rereading
## projects do not pass through it.


## `work` (called with the selectors read again, and returning its value)
## run within one coordination operation (a step of `parent` when given)
## once every project of `dbs`
## (name → DocketDB; each database judged once) is admitted: {ok: true,
## value, reloaded} or {ok: false, kind, project, message, retryable}. `work`
## must not await: what continues after an await asks again.
static func access(dbs: Dictionary, work: Callable = Callable(), parent: RefCounted = null) -> Dictionary:
	var lease := CoordLease.shared(parent)
	if lease.has("error"):
		return {"ok": false, "kind": "coordination", "project": "", "message": str(lease.error), "retryable": true}
	var reloaded: Array = []
	var judged := {}
	for name in dbs:
		var db: DocketDB = dbs[name]
		if db == null or judged.has(db):
			continue
		judged[db] = true
		var admitted: Dictionary = db.admission(lease.operation)
		if admitted.has("kind"):
			lease.operation.close()
			return {"ok": false, "kind": admitted.kind, "project": str(name), "retryable": bool(admitted.retryable),
				"message": "project '%s' is not ready: %s" % [name, admitted.message]}
		if bool(admitted.get("reloaded", false)):
			reloaded.append(str(name))
	var value: Variant = work.call(reloaded) if work.is_valid() else null
	lease.operation.close()
	return {"ok": true, "value": value, "reloaded": reloaded}
