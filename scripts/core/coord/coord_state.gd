class_name CoordState
extends RefCounted
## The account's coordination state: one row in coord.db, in the
## coordination directory beside the lock file (CoordGuard). It says whether a
## vault password is set up (state), which stored credential is the valid one
## (epoch and generation, see CoordRecord), the next administration tag, and
## any password rotation left unfinished.
##
## Every call opens its own connection, and only while holding the lock:
## reads under SHARED, changes under EXCLUSIVE. Tags are reserved and
## committed before the administration they belong to does anything else, so
## a tag is never used twice, even after a crash.
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
const SCHEMA_VERSION := 1
const UNCONFIGURED := "unconfigured"
const READY := "ready"
const FORGOTTEN := "forgotten"
const _STATES := [UNCONFIGURED, READY, FORGOTTEN]
# The largest tag CoordRecord.parse_tag reads; next_tag never passes it.
const _TAG_LIMIT := 999_999_999_999_999_999
# PRAGMA synchronous reads back FULL as 2.
const _SYNCHRONOUS_FULL := 2

var _guard := CoordGuard.new()


static func is_epoch(text: String) -> bool:
	return RegEx.create_from_string("^[0-9a-f]{32}\\z").search(text) != null


## The state, creating it if it does not exist: {ok, state, epoch, generation,
## next_tag, rotation_intent} or {error, kind}. Takes EXCLUSIVE, so it must not
## be called from within a SHARED operation.
func ensure(within: int = 0) -> Dictionary:
	return _locked(CoordGuard.EXCLUSIVE, within, _ensure)


## The state as it is: the same as ensure(), or kind "missing" when coord.db
## does not exist yet.
func read(within: int = 0) -> Dictionary:
	return _locked(CoordGuard.SHARED, within, _read)


## Reserves the next administration tag, for administration `within` (an
## EXCLUSIVE operation): {ok, tag} or {error, kind}. The tag is committed as
## used before this returns.
func reserve_tag(within: int) -> Dictionary:
	if within == 0:
		return {"error": "a tag is reserved only by a running administration", "kind": "refused"}
	return _locked(CoordGuard.EXCLUSIVE, within, _reserve_tag)


## Makes reserved `tag` the committed generation, in `state`, for
## administration `within`: the new state {ok, ...} or {error, kind}. Any tag
## reserved after the committed generation is accepted, so the caller must
## pass the one its own administration reserved.
func commit_generation(within: int, tag: int, state: String) -> Dictionary:
	if within == 0:
		return {"error": "a generation is committed only by a running administration", "kind": "refused"}
	if not state in _STATES:
		return {"error": "unknown coordination state '%s'" % state, "kind": "refused"}
	return _locked(CoordGuard.EXCLUSIVE, within, _commit_generation.bind(tag, state))


static func _completed(returned: Variant) -> Dictionary:
	if returned is Dictionary and ((returned as Dictionary).has("error") or (returned as Dictionary).get("ok") == true):
		return returned
	return {"error": "coordination state work stopped unexpectedly", "kind": "io"}


func _locked(mode: int, within: int, work: Callable) -> Dictionary:
	var begun := _guard.begin(mode, within)
	if begun.has("error"):
		return begun
	# Checked only after end(): the lock is given back whatever `work` did.
	var returned: Variant = work.call()
	var end_error := _guard.end(int(begun.op))
	var result := _completed(returned)
	if not end_error.is_empty() and not result.has("error"):
		return {"error": end_error, "kind": "io"}
	return result


func _path() -> String:
	var directory := _guard.directory()
	return "" if directory.is_empty() else directory.path_join(FILE)


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
			and db.query("CREATE TABLE coord_state (id INTEGER PRIMARY KEY CHECK (id = 1), schema_version INTEGER NOT NULL, epoch TEXT NOT NULL, next_tag TEXT NOT NULL, generation TEXT NOT NULL, state TEXT NOT NULL, rotation_intent TEXT);") \
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
	var path := _path()
	if path.is_empty():
		return {"error": "the coordination directory cannot be found", "kind": "io"}
	if not FileAccess.file_exists(path):
		return {"error": "Docket's coordination state has not been set up yet", "kind": "missing"}
	var opened := _open(path)
	if opened.has("error"):
		return opened
	var db: SQLite = opened.db
	var row := {"error": "Docket's coordination state has not been set up yet", "kind": "missing"} \
		if _has_no_tables(db) else _row(db, path)
	db.close_db()
	return row


func _reserve_tag() -> Dictionary:
	return _change(func(row: Dictionary, db: SQLite) -> Dictionary:
		var tag: int = row.next_tag
		if tag >= _TAG_LIMIT:
			return {"error": "every administration tag has been used", "kind": "exhausted"}
		var updated := _update(db, "UPDATE coord_state SET next_tag = ? WHERE id = 1;", [str(tag + 1)])
		return updated if updated.has("error") else {"ok": true, "tag": tag})


func _commit_generation(tag: int, state: String) -> Dictionary:
	return _change(func(row: Dictionary, db: SQLite) -> Dictionary:
		if tag <= row.generation or tag >= row.next_tag:
			return {"error": "tag %d was not reserved after the committed generation" % tag, "kind": "refused"}
		return _update(db, "UPDATE coord_state SET generation = ?, state = ? WHERE id = 1;", [str(tag), state]))


# Runs `sql` and checks it changed the one state row: {ok} or {error, kind}.
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
	var path := _path()
	if path.is_empty():
		return {"error": "the coordination directory cannot be found", "kind": "io"}
	if not FileAccess.file_exists(path):
		return {"error": "Docket's coordination state has not been set up yet", "kind": "missing"}
	var opened := _open(path)
	if opened.has("error"):
		return opened
	var db: SQLite = opened.db
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


func _has_no_tables(db: SQLite) -> bool:
	var tables: Variant = _select(db, "SELECT name FROM sqlite_master;")
	return tables is Array and (tables as Array).is_empty()


# The one state row, checked, or kind "corrupt" (kind "io" when SQLite was
# only too busy to answer).
func _row(db: SQLite, path: String) -> Dictionary:
	var rows: Variant = _select(db, "SELECT id, schema_version, epoch, next_tag, generation, state, rotation_intent FROM coord_state;")
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
			or not (row.rotation_intent == null or row.rotation_intent is String):
		return corrupt
	return {"ok": true, "state": row.state, "epoch": row.epoch, "generation": generation, "next_tag": next_tag,
		"rotation_intent": "" if row.rotation_intent == null else row.rotation_intent}
