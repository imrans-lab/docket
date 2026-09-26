class_name CoordState
extends RefCounted
## The account's coordination state: one row in coord.db, in the
## coordination directory beside the lock file (CoordGuard). It says whether a
## vault password is set up (state), which stored credential is the valid one
## (epoch and generation: the record in account CoordRecord.account(epoch,
## generation)), the next administration tag, and the administration left
## unfinished, if any (intent). A second table lists retired accounts whose
## removal from the credential store is not yet known to be complete.
##
## An administration is a chain of intent transitions, each committed before
## the step it allows: begin_setup reserves a tag, and so a fresh account,
## before anything is written there; acknowledge records that the one write
## to it completed; publish makes it the generation and ends the intent in one
## transaction; abandon ends the intent by retiring the account instead. Each
## transition names the intent's operation id, so a caller from before a
## crash, or another administration's, is refused. A retired or abandoned
## account is never published, and a tag is never reserved twice.
##
## Every call opens its own connection, and only while holding the lock:
## reads under SHARED, changes under EXCLUSIVE.
##
## A missing coord.db is created as unconfigured, without asking the
## credential store anything; so is one with no tables at all, which is what
## a first write cut short leaves (or a file emptied from outside, which
## thereby loses its state as a deleted one would). One that cannot be read
## as exactly one row of this schema is reported as corrupt and left alone:
## repairing it needs every Docket process stopped.
##
## Every result is {ok: true, ...} or {error, kind}. The marker is what makes
## a result a success: work cut short by a script error returns an empty or
## null result, which is treated as a failure and rolled back.

const FILE := "coord.db"
const SCHEMA_VERSION := 2
const UNCONFIGURED := "unconfigured"
const READY := "ready"
const FORGOTTEN := "forgotten"
const _STATES := [UNCONFIGURED, READY, FORGOTTEN]
# An intent's phases: its account's one write may have been dispatched, or it
# is known to have completed.
const DISPATCHING := "dispatching"
const WRITTEN := "written"
# How abandon() retires an account, from what is known about its one write.
const UNWRITTEN := "unwritten"
const UNCERTAIN := "uncertain"
const FOUND := "found"
# Retired accounts' status: to remove, where a removal proves it is gone; to
# remove, where a late write may still recreate it; removed once, but that
# write may still land (fenced); or found already holding an entry before
# Docket wrote there, left for a person to look at (kept).
const DELETE := "delete"
const DELETE_UNSETTLED := "delete_unsettled"
const FENCED := "fenced"
const KEPT := "kept"
const _RETIRED := [DELETE, DELETE_UNSETTLED, FENCED, KEPT]
# The largest tag CoordRecord.parse_tag reads; next_tag never passes it.
const _TAG_LIMIT := 999_999_999_999_999_999
# PRAGMA synchronous reads back FULL as 2.
const _SYNCHRONOUS_FULL := 2

var _guard := CoordGuard.new()
var _file := ""


## The state in coord.db in the coordination directory, or in `file` when
## given (tests keep theirs apart from the account's that way; the lock is
## always the account's).
func _init(file := "") -> void:
	_file = file


## Why setup cannot begin from `state` (from read() or ensure()), or {}: an
## administration is unfinished (kind "pending") or a password is set up.
static func setup_refusal(state: Dictionary) -> Dictionary:
	if not (state.intent as Dictionary).is_empty():
		return {"error": "another vault administration is unfinished", "kind": "pending"}
	if state.state == READY:
		return {"error": "a vault password is already set up", "kind": "refused"}
	return {}


static func is_epoch(text: String) -> bool:
	return RegEx.create_from_string("^[0-9a-f]{32}\\z").search(text) != null


## The state, creating it if it does not exist: {ok, state, epoch, generation,
## next_tag, intent} or {error, kind}. The intent is {} or {op, type, tag,
## phase}. Within `parent` (an operation from CoordGuard) when given, else in
## an operation of its own; either way it takes EXCLUSIVE, so it is refused
## within a SHARED operation.
func ensure(parent: RefCounted = null) -> Dictionary:
	return _locked(CoordGuard.EXCLUSIVE, parent, _ensure)


## The state as it is: the same as ensure(), or kind "missing" when coord.db
## does not exist yet.
func read(parent: RefCounted = null) -> Dictionary:
	return _locked(CoordGuard.SHARED, parent, _read)


## Starts setting up a vault password, for administration `parent` (an
## EXCLUSIVE operation) when none is set up or unfinished: {ok, op, epoch,
## tag, account} or {error, kind}. The intent is committed, in phase dispatching,
## before this returns, so a crash from here on leaves it for recovery.
func begin_setup(parent: RefCounted) -> Dictionary:
	return _administer(parent, _begin_setup)


## Records that the one write to `op`'s account completed.
func acknowledge(parent: RefCounted, op: String) -> Dictionary:
	return _administer(parent, _transition.bind(op, DISPATCHING, _acknowledge))


## Makes `op`'s written account the generation, ready, and ends the intent.
func publish(parent: RefCounted, op: String) -> Dictionary:
	return _administer(parent, _transition.bind(op, WRITTEN, _publish))


## Ends `op`'s intent by retiring its account: UNWRITTEN when its write is
## known not to have been carried out, UNCERTAIN when it may have been (or
## may still be), FOUND when the account already held an entry before Docket
## wrote there. Once the intent is WRITTEN, the write is known to have
## completed, whatever `outcome` says.
func abandon(parent: RefCounted, op: String, outcome: String) -> Dictionary:
	if not outcome in [UNWRITTEN, UNCERTAIN, FOUND]:
		return {"error": "unknown outcome '%s'" % outcome, "kind": "refused"}
	return _administer(parent, _transition.bind(op, "", _abandon.bind(outcome)))


## The retired accounts: {ok, retired: [{account, status}]} or {error, kind}.
func retired(parent: RefCounted = null) -> Dictionary:
	return _locked(CoordGuard.SHARED, parent, _retired)


## Records that retired `account` was removed from the credential store (or
## was not there): one with status DELETE is then gone and is dropped; one
## with DELETE_UNSETTLED becomes FENCED.
func settle_removal(parent: RefCounted, account: String) -> Dictionary:
	return _administer(parent, _settle_removal.bind(account))


static func _completed(returned: Variant) -> Dictionary:
	if returned is Dictionary and ((returned as Dictionary).has("error") or (returned as Dictionary).get("ok") == true):
		return returned
	return {"error": "coordination state work stopped unexpectedly", "kind": "io"}


func _locked(mode: int, parent: RefCounted, work: Callable) -> Dictionary:
	var begun := _guard.open_within(parent, mode)
	if begun.has("error"):
		return begun
	# Checked only after close(): the hold is given back whatever `work` did.
	var returned: Variant = work.call()
	var end_error := str(begun.operation.close())
	var result := _completed(returned)
	if not end_error.is_empty() and not result.has("error"):
		return {"error": end_error, "kind": "io"}
	return result


func _administer(parent: RefCounted, change: Callable) -> Dictionary:
	if parent == null:
		return {"error": "vault administration runs only within its own operation", "kind": "refused"}
	return _locked(CoordGuard.EXCLUSIVE, parent, _change.bind(change))


func _path() -> String:
	if not _file.is_empty():
		return _file
	var directory := _guard.directory()
	return "" if directory.is_empty() else directory.path_join(FILE)


# {db, path} for coord.db as it is, or {error, kind}: kind "missing" when it
# does not exist.
func _open_existing() -> Dictionary:
	var path := _path()
	if path.is_empty():
		return {"error": "the coordination directory cannot be found", "kind": "io"}
	if not FileAccess.file_exists(path):
		return {"error": "Docket's coordination state has not been set up yet", "kind": "missing"}
	var opened := _open(path)
	if opened.has("error"):
		return opened
	opened["path"] = path
	return opened


# A connection with durable commits, read back to be sure: a rollback journal
# synced in full, and a wait for other processes' readers or recovery.
func _open(path: String) -> Dictionary:
	var db := SQLite.new()
	db.path = path
	db.verbosity_level = SQLite.QUIET
	if not db.open_db():
		return {"error": "cannot open %s" % path, "kind": "io"}
	# Each step runs only if the one before it worked, so the error message
	# is the first failure's.
	var durable := db.query("PRAGMA busy_timeout=8000;") \
		and _single(_select(db, "PRAGMA journal_mode=DELETE;"), "journal_mode", "delete") \
		and db.query("PRAGMA synchronous=FULL;") \
		and _single(_select(db, "PRAGMA synchronous;"), "synchronous", _SYNCHRONOUS_FULL)
	if not durable:
		var error := "cannot make %s durable: %s" % [path, db.error_message]
		db.close_db()
		return {"error": error, "kind": "io"}
	return {"db": db}


static func _single(rows: Variant, column: String, expected: Variant) -> bool:
	return rows is Array and (rows as Array).size() == 1 and (rows as Array)[0] is Dictionary \
		and (rows as Array)[0].get(column) == expected


func _ensure() -> Dictionary:
	var path := _path()
	if path.is_empty():
		return {"error": "the coordination directory cannot be found", "kind": "io"}
	var opened := _open(path)
	if opened.has("error"):
		return opened
	var db: SQLite = opened.db
	if _has_no_tables(db):
		var epoch := Crypto.new().generate_random_bytes(16).hex_encode()
		var created := db.query("BEGIN IMMEDIATE;") \
			and db.query("CREATE TABLE coord_state (id INTEGER PRIMARY KEY CHECK (id = 1), schema_version INTEGER NOT NULL, epoch TEXT NOT NULL, next_tag TEXT NOT NULL, generation TEXT NOT NULL, state TEXT NOT NULL, intent TEXT);") \
			and db.query("CREATE TABLE retired (account TEXT PRIMARY KEY, status TEXT NOT NULL);") \
			and db.query_with_bindings("INSERT INTO coord_state VALUES (1, ?, ?, '1', '0', ?, NULL);", [SCHEMA_VERSION, epoch, UNCONFIGURED]) \
			and db.query("COMMIT;")
		if not created:
			var error := "cannot create %s: %s" % [path, db.error_message]
			db.query("ROLLBACK;")
			db.close_db()
			return {"error": error, "kind": "io"}
	var row := _row(db, path)
	db.close_db()
	return row


func _read() -> Dictionary:
	var opened := _open_existing()
	if opened.has("error"):
		return opened
	var db: SQLite = opened.db
	var path: String = opened.path
	var row := {"error": "Docket's coordination state has not been set up yet", "kind": "missing"} \
		if _has_no_tables(db) else _row(db, path)
	db.close_db()
	return row


func _begin_setup(row: Dictionary, db: SQLite) -> Dictionary:
	var refusal := setup_refusal(row)
	if not refusal.is_empty():
		return refusal
	var tag: int = row.next_tag
	if tag >= _TAG_LIMIT:
		return {"error": "every administration tag has been used", "kind": "exhausted"}
	var op := Crypto.new().generate_random_bytes(16).hex_encode()
	var intent := JSON.stringify({"v": "1", "op": op, "type": "setup", "tag": str(tag), "phase": DISPATCHING})
	var updated := _update(db, "UPDATE coord_state SET next_tag = ?, intent = ? WHERE id = 1;", [str(tag + 1), intent])
	return updated if updated.has("error") else {"ok": true, "op": op, "epoch": row.epoch, "tag": tag, "account": CoordRecord.account(row.epoch, tag)}


# Runs `change` (row, db) when `op` is the unfinished intent's and, unless
# `phase` is empty, the intent is in that phase.
func _transition(row: Dictionary, db: SQLite, op: String, phase: String, change: Callable) -> Dictionary:
	var intent: Dictionary = row.intent
	if intent.is_empty() or intent.op != op:
		return {"error": "that vault administration is not the unfinished one", "kind": "refused"}
	if not phase.is_empty() and intent.phase != phase:
		return {"error": "that vault administration is not at that step", "kind": "refused"}
	return change.call(row, db)


func _acknowledge(row: Dictionary, db: SQLite) -> Dictionary:
	var intent: Dictionary = row.intent
	var written := JSON.stringify({"v": "1", "op": intent.op, "type": intent.type, "tag": str(intent.tag), "phase": WRITTEN})
	return _update(db, "UPDATE coord_state SET intent = ? WHERE id = 1;", [written])


func _publish(row: Dictionary, db: SQLite) -> Dictionary:
	return _update(db, "UPDATE coord_state SET generation = ?, state = ?, intent = NULL WHERE id = 1;", [str(row.intent.tag), READY])


func _abandon(row: Dictionary, db: SQLite, outcome: String) -> Dictionary:
	var intent: Dictionary = row.intent
	var status := DELETE
	if intent.phase == DISPATCHING and outcome == UNCERTAIN:
		status = DELETE_UNSETTLED
	elif intent.phase == DISPATCHING and outcome == FOUND:
		status = KEPT
	if not db.query_with_bindings("INSERT INTO retired VALUES (?, ?);", [CoordRecord.account(row.epoch, intent.tag), status]):
		return {"error": "cannot retire the account: %s" % db.error_message, "kind": "io"}
	return _update(db, "UPDATE coord_state SET intent = NULL WHERE id = 1;", [])


func _retired() -> Dictionary:
	var opened := _open_existing()
	if opened.get("kind") == "missing":
		return {"ok": true, "retired": []}
	if opened.has("error"):
		return opened
	var db: SQLite = opened.db
	var path: String = opened.path
	var rows: Variant = _select(db, "SELECT account, status FROM retired ORDER BY account;")
	db.close_db()
	var corrupt := {"error": "%s is not readable as Docket's coordination state; stop every Docket process before repairing it" % path, "kind": "corrupt"}
	if not rows is Array:
		return corrupt
	for entry: Variant in rows:
		if not entry is Dictionary or not entry.account is String or not entry.status in _RETIRED \
				or CoordRecord.parse_account(entry.account).is_empty():
			return corrupt
	return {"ok": true, "retired": rows}


func _settle_removal(_row: Dictionary, db: SQLite, account: String) -> Dictionary:
	var rows: Variant = _select_bound(db, "SELECT status FROM retired WHERE account = ?;", [account])
	if not rows is Array or (rows as Array).size() != 1:
		return {"error": "that account is not awaiting removal", "kind": "refused"}
	match (rows as Array)[0].get("status"):
		DELETE:
			return _update(db, "DELETE FROM retired WHERE account = ?;", [account])
		DELETE_UNSETTLED:
			return _update(db, "UPDATE retired SET status = ? WHERE account = ?;", [FENCED, account])
	return {"error": "that account is not awaiting removal", "kind": "refused"}


# Runs `sql` and checks it changed exactly one row: {ok} or {error, kind}.
func _update(db: SQLite, sql: String, bindings: Array) -> Dictionary:
	if not db.query_with_bindings(sql, bindings):
		return {"error": "cannot change the coordination state: %s" % db.error_message, "kind": "io"}
	var changed: Variant = _select(db, "SELECT changes() AS changed;")
	if not _single(changed, "changed", 1):
		return {"error": "the coordination state row was not changed", "kind": "corrupt"}
	return {"ok": true}


# Runs `change` (row, db) inside one transaction on the current row and
# commits only a completed result; returns it, or the row after it when it
# carries nothing but the marker.
func _change(change: Callable) -> Dictionary:
	var opened := _open_existing()
	if opened.has("error"):
		return opened
	var db: SQLite = opened.db
	var path: String = opened.path
	if not db.query("BEGIN IMMEDIATE;"):
		var error := "cannot change %s: %s" % [path, db.error_message]
		db.close_db()
		return {"error": error, "kind": "io"}
	var row := _row(db, path)
	var result := row if row.has("error") else _completed(change.call(row, db))
	if result.has("error") or not db.query("COMMIT;"):
		if not result.has("error"):
			result = {"error": "cannot commit %s: %s" % [path, db.error_message], "kind": "io"}
		db.query("ROLLBACK;")
		db.close_db()
		return result
	if result.keys() == ["ok"]:
		result = _row(db, path)
	db.close_db()
	return result


func _select(db: SQLite, sql: String) -> Variant:
	return db.query_result.duplicate() if db.query(sql) else null


func _select_bound(db: SQLite, sql: String, bindings: Array) -> Variant:
	return db.query_result.duplicate() if db.query_with_bindings(sql, bindings) else null


func _has_no_tables(db: SQLite) -> bool:
	var tables: Variant = _select(db, "SELECT name FROM sqlite_master;")
	return tables is Array and (tables as Array).is_empty()


# The one state row, checked, or kind "corrupt" (kind "io" when SQLite was
# only too busy to answer).
func _row(db: SQLite, path: String) -> Dictionary:
	var rows: Variant = _select(db, "SELECT id, schema_version, epoch, next_tag, generation, state, intent FROM coord_state;")
	if rows == null and ("busy" in db.error_message or "locked" in db.error_message):
		return {"error": "cannot read %s: %s" % [path, db.error_message], "kind": "io"}
	var corrupt := {"error": "%s is not readable as Docket's coordination state; stop every Docket process before repairing it" % path, "kind": "corrupt"}
	if not rows is Array or (rows as Array).size() != 1:
		return corrupt
	var row: Dictionary = rows[0]
	if not row.id is int or row.id != 1 or not row.schema_version is int or row.schema_version != SCHEMA_VERSION:
		return corrupt
	var next_tag := CoordRecord.parse_tag(str(row.next_tag)) if row.next_tag is String else -1
	var generation := CoordRecord.parse_tag(str(row.generation)) if row.generation is String else -1
	if not row.epoch is String or not is_epoch(row.epoch) or not row.state is String or not row.state in _STATES \
			or next_tag < 1 or generation < 0 or generation >= next_tag \
			or not (row.intent == null or row.intent is String):
		return corrupt
	var intent := {} if row.intent == null else _intent(str(row.intent), generation, next_tag)
	if intent.has("error"):
		return corrupt
	return {"ok": true, "state": row.state, "epoch": row.epoch, "generation": generation, "next_tag": next_tag, "intent": intent}


# {op, type, tag, phase} from its JSON, or {error} unless it is exactly an
# intent whose tag was reserved after the committed generation.
static func _intent(text: String, generation: int, next_tag: int) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {"error": "unreadable"}
	var intent: Dictionary = json.data
	var keys := intent.keys()
	keys.sort()
	if keys != ["op", "phase", "tag", "type", "v"] or intent.values().any(func(value: Variant) -> bool: return not value is String):
		return {"error": "unreadable"}
	var tag := CoordRecord.parse_tag(intent.tag)
	# An op id has an epoch's form.
	if intent.v != "1" or not is_epoch(intent.op) or intent.type != "setup" or not intent.phase in [DISPATCHING, WRITTEN] \
			or tag <= generation or tag >= next_tag:
		return {"error": "unreadable"}
	return {"op": intent.op, "type": intent.type, "tag": tag, "phase": intent.phase}
