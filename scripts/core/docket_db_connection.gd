extends RefCounted
class_name DocketDBConnection
## A Docket project's SQLite connection, used from the thread that opened it:
## the SQL helpers its writes go through, within an explicit coordination
## operation, the transactions they run in, the item changes reported once
## those are durable, and the project's metadata (docket_meta). DocketDBVault
## and DocketDB build the project storage on it.


const READ_ONLY_QUERY := &"query_read_only"

var _db: SQLite
var _path: String
var _is_open: bool = false
var _last_sql_error: String = ""
# Item changes waiting for the open transaction to commit (items_changed).
var _pending_changes: Array = []
var _transaction_open := false
# The thread that opened the connection. A connection, its transaction state
# and its result buffers are used from that thread only; a call from any
# other is refused before it touches them.
var _owner_thread: int = 0

## Emitted once item changes are durable, in order: [{id, event}], `event`
## being the item event recorded (e.g. "created", "transition",
## "comment_added"), "deleted", or "references_updated" for an item whose
## references were rewritten. Outside a transaction a change is reported at
## once; inside one, when it commits (nothing if it rolls back or its commit
## fails). DocketDBJsonl reports only once its file is saved.
signal items_changed(changes: Array)


# -- Internal SQL helpers -----------------------------------------------------
#
# Writes run within a coordination operation their caller supplies
# explicitly (a DocketCoordOperation, see CoordGuard). A public method opens a
# step of the operation it was given, or an operation of its own, before its
# prechecks (_writing), and passes that step to every write it makes
# (_write, _write_checked, _write_rows, _begin_transaction). A write without
# a live step, from another thread, or into a transaction another operation
# owns is refused and executes nothing. The step is checked by the native
# extension (a live operation of this process's coordination domain), never
# by asking the object itself. A failed or refused write inside a
# transaction is that transaction's failure, unless it came from another
# operation; outside one it is kept in _last_sql_error.

## `work` called with the step it must pass to every write (first argument,
## before any bound ones), within a step of `parent` or, when that is null, a
## SHARED operation of its own. Returns what `work` returns, or the reason
## it was refused (a String; see _refused), which for a failed coordination
## step is also kept in _last_sql_error. `work` must not await. Changes a
## settled transaction left to report are reported once the step is given
## back, so a listener that makes a change starts it separately.
##
## From another thread nothing is touched, not even the coordination objects
## (which are for the main thread only); the refusal is only returned.
func _writing(parent: RefCounted, work: Callable) -> Variant:
	var refusal := _thread_refusal()
	if not refusal.is_empty(): return refusal
	var opened := CoordLease.shared(parent)
	if opened.has("error"):
		_last_sql_error = opened.error
		return str(opened.error)
	var result: Variant = work.call(opened.operation)
	opened.operation.close()
	if not _change_in_progress(): _report_changes()
	return result


## _writing for work that returns "" or an error.
func _writing_text(parent: RefCounted, work: Callable) -> String:
	var result: Variant = _writing(parent, work)
	return result if result is String else _last_sql_error


## For work returning a Dictionary with an "error" entry: `result` of
## _writing as such, a refusal included.
static func _refused(result: Variant) -> Dictionary:
	return result if result is Dictionary else {"error": str(result)}


## `work`, called with its step and returning "" or why it failed, as one
## change within a step of `op` (or an operation of its own): one
## transaction, which a change made within it (given its step) joins.
## Returns "" or why not, and then nothing `work` wrote is kept. Changes are
## reported once the outermost change has committed (DocketDBJsonl: once its
## file is saved).
func run_change(op: RefCounted, work: Callable) -> String:
	return str(_change(op, _text_change.bind(work)).error)


static func _text_change(step: RefCounted, work: Callable) -> Dictionary:
	return {"error": str(work.call(step))}


# run_change for `work` returning a Dictionary with an "error" entry: what
# `work` returns, its "error" being the change's outcome.
func _change(op: RefCounted, work: Callable) -> Dictionary:
	return _refused(_writing(op, _change_step.bind(work)))


func _change_step(step: RefCounted, work: Callable) -> Dictionary:
	var txn := _begin_transaction(step)
	if txn.has("error"): return {"error": txn.error}
	var result: Dictionary = work.call(step)
	result.error = _complete_transaction(step, txn.ticket, str(result.get("error", "")))
	return result


var _guard := CoordGuard.new()


# {step} for a new step of `step`, which the native extension has checked to
# be a live operation of this process's coordination domain, or {error}.
# The caller closes the step it gets.
func _joined(step: RefCounted) -> Dictionary:
	if step == null:
		return {"error": "a write to %s was attempted outside a coordination operation" % _path}
	var joined := _guard.open_within(step, CoordGuard.SHARED)
	if joined.has("error"):
		return {"error": "a write to %s was attempted outside a coordination operation: %s" % [_path, joined.error]}
	return {"step": joined.operation}


# From the owning thread: {} when `step` may write now, else {error, foreign},
# `foreign` when it is a genuine step of an operation other than the one
# owning the open transaction (its failure is its own, not the transaction's).
func _write_admission(step: RefCounted, sql: String) -> Dictionary:
	var joined := _joined(step)
	var refusal := {}
	if joined.has("error"):
		refusal = {"error": joined.error, "foreign": false}
	else:
		joined.step.close()
		if _txn_depth > 0 and not _txn_owner.same_operation(step):
			refusal = {"error": "a write to %s was attempted into another operation's change" % _path, "foreign": true}
	if not refusal.is_empty():
		push_error("DocketDB: %s — %s" % [refusal.error, sql.left(120)])
	return refusal


# Records the failure of a write made on the owning thread by the open
# transaction's operation (or by no genuine operation): in that transaction,
# or else in _last_sql_error.
func _note_write_failure(error: String) -> void:
	if _txn_depth > 0:
		if _txn_error.is_empty(): _txn_error = error
	elif _last_sql_error.is_empty():
		_last_sql_error = error


func _write(step: RefCounted, sql: String, bindings: Array = []) -> void:
	_write_checked(step, sql, bindings)


func _write_checked(step: RefCounted, sql: String, bindings: Array = []) -> String:
	var refusal := _thread_refusal()
	if not refusal.is_empty(): return refusal
	var admission := _write_admission(step, sql)
	if admission.get("foreign", false): return admission.error
	var error: String = admission.get("error", "")
	if error.is_empty(): error = _exec_checked(sql, bindings)
	if not error.is_empty(): _note_write_failure(error)
	return error


## A write that answers rows (such as a checkpoint PRAGMA): its rows, or []
## with the reason in _last_sql_error. Not for use inside a transaction.
func _write_rows(step: RefCounted, sql: String, bindings: Array = []) -> Array:
	if not _thread_refusal().is_empty(): return []
	var admission := _write_admission(step, sql)
	if admission.is_empty(): return _exec_rows(sql, bindings)
	if not admission.foreign: _note_write_failure(admission.error)
	return []


# -- Transactions ------------------------------------------------------------
#
# A transaction belongs to the operation that began it, and holds a step of
# that operation of its own until it is settled. Each scope admitted into it
# gets a single-use ticket, which only a step of the owning operation can
# complete; only the outermost completion commits (or rolls back after any
# failure, which is sticky). The changes it made are reported only after it
# commits, by _writing once the step that began it is given back.

var _txn_owner: RefCounted = null
var _txn_depth := 0
var _txn_error := ""
var _txn_tickets: Dictionary = {}
var _txn_next_ticket := 1


## {ticket, outermost} or {error}: admits a scope of `step` into the open
## transaction, or begins one (BEGIN IMMEDIATE, `outermost` true) owned by
## `step`'s operation. Refused, changing nothing, while a change begun some
## other way is in progress.
func _begin_transaction(step: RefCounted) -> Dictionary:
	var refusal := _thread_refusal()
	if not refusal.is_empty(): return {"error": refusal}
	var admission := _write_admission(step, "BEGIN")
	if not admission.is_empty(): return {"error": admission.error}
	if _txn_depth == 0:
		if _change_in_progress(): return {"error": "%s already has a change in progress" % _path}
		var hold := _joined(step)
		if hold.has("error"): return {"error": hold.error}
		_pending_changes = []
		var error := _exec_checked("BEGIN IMMEDIATE TRANSACTION;")
		if not error.is_empty():
			hold.step.close()
			return {"error": error}
		_txn_owner = hold.step
		_txn_error = ""
	elif not _txn_error.is_empty():
		return {"error": _txn_error}
	_txn_depth += 1
	var ticket := _txn_next_ticket
	_txn_next_ticket += 1
	_txn_tickets[ticket] = true
	return {"ticket": ticket, "outermost": _txn_depth == 1}


## Completes the scope admitted with `ticket`, recording `error` if it
## failed: "" or the transaction's error. `step` is a live step of the
## operation that owns the transaction. A ticket completes once; an unknown
## ticket, or a step of another operation or thread, changes nothing.
func _complete_transaction(step: RefCounted, ticket: int, error: String = "") -> String:
	var refusal := _thread_refusal()
	if not refusal.is_empty(): return refusal
	if not _txn_tickets.has(ticket):
		return "that change was not admitted or has already completed"
	# The native same_operation also refuses anything but a live operation.
	# Not a join: a coordination-directory mismatch arising meanwhile must not
	# leave the transaction impossible to settle.
	if not _txn_owner.same_operation(step):
		return "only the operation that owns a change on %s can complete it" % _path
	_txn_tickets.erase(ticket)
	if not error.is_empty() and _txn_error.is_empty(): _txn_error = error
	_txn_depth -= 1
	if _txn_depth > 0: return _txn_error
	# Held back until the transaction is settled below.
	var changes := _pending_changes
	_pending_changes = []
	var outcome := _txn_error
	if outcome.is_empty(): outcome = _exec_checked("COMMIT;")
	if not outcome.is_empty():
		var rollback := _exec_checked("ROLLBACK;")
		if not rollback.is_empty(): outcome += "; rolling back failed too: %s" % rollback
	_txn_owner.close()
	_txn_owner = null
	_txn_error = ""
	# Committed changes wait for _writing to report them; rolled back ones go.
	if outcome.is_empty(): _pending_changes = changes
	return outcome


## Whether a change is in progress on this connection: a transaction,
## however it was begun.
func _change_in_progress() -> bool:
	return _txn_depth > 0 or _transaction_open


# "" on the thread that opened the connection; otherwise why not, touching
# nothing that thread uses.
func _thread_refusal() -> String:
	if _owner_thread == 0 or OS.get_thread_caller_id() == _owner_thread:
		return ""
	var message := "%s is used only from the thread that opened it" % _path
	push_error("DocketDB: %s" % message)
	return message


## _thread_refusal for the older helpers (_exec, _exec_select). The refusal
## is only reported (push_error): _last_sql_error belongs to the owning
## thread, whose change in progress it would otherwise fail.
func _on_owner_thread() -> bool:
	return _thread_refusal().is_empty()


func _exec(sql: String, bindings: Array = []) -> void:
	if not _on_owner_thread(): return
	var ok: bool
	if bindings.is_empty():
		ok = _db.query(sql)
	else:
		ok = _db.query_with_bindings(sql, bindings)
	if not ok and _last_sql_error.is_empty():
		_last_sql_error = _db.error_message if _db.error_message else "SQL execution failed"
	_track_transaction(sql, ok)


func _exec_checked(sql: String, bindings: Array = []) -> String:
	## Like _exec but returns "" on success, error message on failure.
	var refusal := _thread_refusal()
	if not refusal.is_empty(): return refusal
	var ok: bool
	if bindings.is_empty():
		ok = _db.query(sql)
	else:
		ok = _db.query_with_bindings(sql, bindings)
	_track_transaction(sql, ok)
	if not ok:
		var msg: String = _db.error_message if _db.error_message else "SQL execution failed"
		if _last_sql_error.is_empty(): _last_sql_error = msg
		push_error("DocketDB: %s — %s" % [msg, sql.left(120)])
		return msg
	return ""


## Record that item `id` changed (`event`): reported now, or when the open
## transaction commits (items_changed).
func _record_change(id: String, event: String) -> void:
	_pending_changes.append({"id": id, "event": event})
	if not _transaction_open:
		_report_changes()


## Emit and forget the recorded changes (DocketDBJsonl reports them only once
## its file is saved).
func _report_changes() -> void:
	if _pending_changes.is_empty():
		return
	var changes := _pending_changes
	_pending_changes = []
	items_changed.emit(changes)


func _track_transaction(sql: String, ok: bool) -> void:
	if sql.begins_with("BEGIN"):
		# A failed BEGIN inside a transaction left open does not close it.
		_transaction_open = _transaction_open or ok
	elif sql.begins_with("COMMIT"):
		if ok:
			_transaction_open = false
			_report_changes()
		else:
			_pending_changes = []  # those changes were not made durable
	elif sql.begins_with("ROLLBACK"):
		_transaction_open = false
		_pending_changes = []


## Rows of one statement that only reads (a SELECT, or PRAGMA table_info /
## foreign_key_list), with exactly one binding per parameter: SQLite's own
## query_read_only (third_party/patches), which refuses anything else before
## it runs. [] with the reason in _last_sql_error otherwise.
func _exec_select(sql: String, bindings: Array = []) -> Array:
	if not _on_owner_thread(): return []
	# Called by name: DocketDB checks the method is there when it connects.
	var ok: bool = _db.call(READ_ONLY_QUERY, sql, bindings)
	if not ok:
		var msg: String = _db.error_message if _db.error_message else "SQL query failed"
		if _last_sql_error.is_empty(): _last_sql_error = msg
		# A read inside a transaction is part of its change: failing, it fails it.
		if _txn_depth > 0 and _txn_error.is_empty(): _txn_error = msg
		push_error("DocketDB: %s — %s" % [msg, sql.left(120)])
		return []
	return _db.query_result if _db.query_result else []


# Rows answered by any statement, writes included (_write_rows).
func _exec_rows(sql: String, bindings: Array = []) -> Array:
	var ok: bool
	if bindings.is_empty():
		ok = _db.query(sql)
	else:
		ok = _db.query_with_bindings(sql, bindings)
	if not ok:
		var msg: String = _db.error_message if _db.error_message else "SQL query failed"
		if _last_sql_error.is_empty(): _last_sql_error = msg
		push_error("DocketDB: %s — %s" % [msg, sql.left(120)])
		return []
	return _db.query_result if _db.query_result else []


func _rollback() -> void:
	_exec("ROLLBACK;")


# -- Meta helpers -------------------------------------------------------------

func get_meta_value(meta_key: String, default: String = "") -> String:
	var rows := _exec_select("SELECT value FROM docket_meta WHERE key=?;", [meta_key])
	return str(rows[0].value) if rows.size() > 0 else default


func set_meta_value(meta_key: String, val: String) -> void:
	var error := set_meta_value_checked(meta_key, val)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## Sets project metadata `meta_key` to `val` within a step of `op` (or an
## operation of its own): "" or why not.
func set_meta_value_checked(meta_key: String, val: String, op: RefCounted = null) -> String:
	return _writing_text(op, _set_meta_value.bind(meta_key, val))


func _set_meta_value(step: RefCounted, meta_key: String, val: String) -> String:
	return _write_checked(step, "INSERT OR REPLACE INTO docket_meta (key, value) VALUES (?, ?);", [meta_key, val])


func get_all_meta() -> Dictionary:
	## Every docket_meta key/value. Exists so serialization can persist whatever
	## is actually stored rather than a hardcoded list — that list silently
	## dropped project lifecycle fields, and nearly stranded every vault when the
	## KDF iteration count was added.
	var out := {}
	for row in _exec_select("SELECT key, value FROM docket_meta;"):
		var k := str(row.get("key", ""))
		if not k.is_empty():
			out[k] = str(row.get("value", ""))
	return out


func get_project_name() -> String:
	return get_meta_value("project", "")


func set_project_name(name: String) -> void:
	set_meta_value("project", name)


func set_project_name_checked(name: String, op: RefCounted = null) -> String:
	return set_meta_value_checked("project", name, op)


func get_project_meta() -> Dictionary:
	## Return all project lifecycle metadata as a dict.
	var d := {}
	var stage := get_meta_value("project_stage", "")
	if not stage.is_empty():
		d["stage"] = stage
	var hyp := get_meta_value("project_hypothesis", "")
	if not hyp.is_empty():
		d["hypothesis"] = hyp
	var sc := get_meta_value("project_success_criteria", "")
	if not sc.is_empty():
		d["success_criteria"] = sc
	var pt := get_meta_value("project_promoted_to", "")
	if not pt.is_empty():
		d["promoted_to"] = pt
	return d


const _PROJECT_META_KEYS := {"stage": "project_stage", "hypothesis": "project_hypothesis",
	"success_criteria": "project_success_criteria", "promoted_to": "project_promoted_to"}


func set_project_meta(meta: Dictionary) -> void:
	var error := set_project_meta_checked(meta)
	if not error.is_empty(): push_error("DocketDB: %s" % error)


## Sets the project lifecycle metadata `meta` has (stage, hypothesis,
## success_criteria, promoted_to), all or none, within a step of `op` (or an
## operation of its own): "" or why not.
func set_project_meta_checked(meta: Dictionary, op: RefCounted = null) -> String:
	return _writing_text(op, _set_project_meta.bind(meta))


func _set_project_meta(step: RefCounted, meta: Dictionary) -> String:
	var txn := _begin_transaction(step)
	if txn.has("error"): return txn.error
	var error := ""
	for key: String in _PROJECT_META_KEYS:
		if meta.has(key) and error.is_empty():
			error = set_meta_value_checked(_PROJECT_META_KEYS[key], str(meta[key]), step)
	return _complete_transaction(step, txn.ticket, error)
