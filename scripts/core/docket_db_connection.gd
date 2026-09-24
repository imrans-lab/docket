extends RefCounted
class_name DocketDBConnection
## A Docket project's SQLite connection, used from the thread that opened it:
## the SQL helpers its writes go through, within an explicit coordination
## operation, the transactions they run in, and the item changes reported
## once those are durable. DocketDB builds the project storage on it.


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
# owns is refused and executes nothing. A failed or refused write inside a
# transaction is that transaction's failure, unless it came from another
# operation; outside one it is kept in _last_sql_error.

## `work` called with the step it must pass to every write (first argument,
## before any bound ones), within a step of `parent` or, when that is null, a
## SHARED operation of its own. Returns what `work` returns, or null after a
## refusal (the reason in _last_sql_error). `work` must not await.
func _writing(parent: RefCounted, work: Callable) -> Variant:
	var opened := CoordLease.shared(parent)
	if opened.has("error"):
		_last_sql_error = opened.error
		return null
	var result: Variant = work.call(opened.operation)
	opened.operation.close()
	return result


## _writing for work that returns "" or an error.
func _writing_text(parent: RefCounted, work: Callable) -> String:
	var result: Variant = _writing(parent, work)
	return result if result is String else _last_sql_error


static func _live(operation: RefCounted) -> bool:
	return operation != null and operation.is_open()


# "" when `step` may write now, or why not.
func _write_refusal(step: RefCounted, sql: String) -> String:
	var refusal := _thread_refusal()
	if not refusal.is_empty(): return refusal
	if not _live(step):
		refusal = "a write to %s was attempted outside a coordination operation" % _path
	elif _txn_depth > 0 and not _txn_owner.same_operation(step):
		refusal = "a write to %s was attempted into another operation's change" % _path
	if refusal.is_empty(): return ""
	push_error("DocketDB: %s — %s" % [refusal, sql.left(120)])
	return refusal


# Records the failure of a write by `step`, made on the owning thread: in
# the open transaction, unless `step` is a live step of another operation
# (whose failure is its own), or else in _last_sql_error.
func _note_write_failure(step: RefCounted, error: String) -> void:
	if _txn_depth > 0:
		if (not _live(step) or _txn_owner.same_operation(step)) and _txn_error.is_empty():
			_txn_error = error
	elif _last_sql_error.is_empty():
		_last_sql_error = error


func _write(step: RefCounted, sql: String, bindings: Array = []) -> void:
	_write_checked(step, sql, bindings)


func _write_checked(step: RefCounted, sql: String, bindings: Array = []) -> String:
	var refusal := _thread_refusal()
	if not refusal.is_empty(): return refusal
	var error := _write_refusal(step, sql)
	if error.is_empty(): error = _exec_checked(sql, bindings)
	if not error.is_empty(): _note_write_failure(step, error)
	return error


## A write that answers rows (such as a checkpoint PRAGMA): its rows, or []
## with the reason in _last_sql_error. Not for use inside a transaction.
func _write_rows(step: RefCounted, sql: String, bindings: Array = []) -> Array:
	if not _thread_refusal().is_empty(): return []
	var refusal := _write_refusal(step, sql)
	if refusal.is_empty(): return _exec_select(sql, bindings)
	_note_write_failure(step, refusal)
	return []


# -- Transactions ------------------------------------------------------------
#
# A transaction belongs to the operation that began it, and holds a step of
# that operation of its own until it is settled. Each scope admitted into it
# gets a single-use ticket, which only a step of the owning operation can
# complete; only the outermost completion commits (or rolls back after any
# failure, which is sticky). Changes are reported once it is settled.

var _txn_owner: RefCounted = null
var _txn_depth := 0
var _txn_error := ""
var _txn_tickets: Dictionary = {}
var _txn_next_ticket := 1


## {ticket} or {error}: admits a scope of `step` into the open transaction,
## or begins one (BEGIN IMMEDIATE) owned by `step`'s operation. Refused,
## changing nothing, while a change begun some other way is in progress.
func _begin_transaction(step: RefCounted) -> Dictionary:
	var refusal := _write_refusal(step, "BEGIN")
	if not refusal.is_empty(): return {"error": refusal}
	if _txn_depth == 0:
		if _change_in_progress(): return {"error": "%s already has a change in progress" % _path}
		var hold: Dictionary = step.nested(CoordGuard.SHARED)
		if hold.has("error"): return {"error": str(hold.error)}
		_pending_changes = []
		var error := _exec_checked("BEGIN IMMEDIATE TRANSACTION;")
		if not error.is_empty():
			hold.operation.close()
			return {"error": error}
		_txn_owner = hold.operation
		_txn_error = ""
	elif not _txn_error.is_empty():
		return {"error": _txn_error}
	_txn_depth += 1
	var ticket := _txn_next_ticket
	_txn_next_ticket += 1
	_txn_tickets[ticket] = true
	return {"ticket": ticket}


## Completes the scope admitted with `ticket`, recording `error` if it
## failed: "" or the transaction's error. `step` is a live step of the
## operation that owns the transaction. A ticket completes once; an unknown
## ticket, or a step of another operation or thread, changes nothing.
func _complete_transaction(step: RefCounted, ticket: int, error: String = "") -> String:
	var refusal := _thread_refusal()
	if not refusal.is_empty(): return refusal
	if not _txn_tickets.has(ticket):
		return "that change was not admitted or has already completed"
	if not _live(step) or not _txn_owner.same_operation(step):
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
	if outcome.is_empty():
		_pending_changes = changes
		_report_changes()
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


## _thread_refusal for the older helpers (_exec, _exec_select), whose callers
## learn of a failure only from _last_sql_error, so the refusal is kept there.
func _on_owner_thread() -> bool:
	var refusal := _thread_refusal()
	if refusal.is_empty(): return true
	if _last_sql_error.is_empty(): _last_sql_error = refusal
	return false


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


func _exec_select(sql: String, bindings: Array = []) -> Array:
	if not _on_owner_thread(): return []
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


func _begin() -> void:
	_exec("BEGIN TRANSACTION;")


func _commit() -> void:
	_exec("COMMIT;")


func _rollback() -> void:
	_exec("ROLLBACK;")
