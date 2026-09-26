extends RefCounted
class_name ProjectEvents
## Project-scoped work event ids, layered on the item event stream.
##
## Every item mutation already writes one item_events row (ItemRevision relies
## on that). When the row records a work-relevant change it is also stamped with
##   eid     a project-scoped integer from the docket_meta counter COUNTER_KEY
##   fields  the tracked fields the mutation changed (JSON array text)
## Both are written on the event's .dct line, so an id survives restart and
## cache rebuilds. The counter only moves forward and is never below the
## largest stored eid, so ids are strictly increasing and never reused within a
## project, even after the item they belong to is deleted. The row's item_id,
## event_type (the event kind), actor and timestamp complete the event.
##
## Which rows are stamped:
##   created, moved, promoted          always; fields = tracked fields the item arrives with
##   comment_added, comment_reply      always; fields = []
##   claimed, claim_released,
##   claim_reassigned                  always; fields = ["claim"]
##   transition, status_repaired       always; fields = changed tracked fields, incl. status
##   any other row                     only when its mutation changed a tracked field
## Tracked fields: TRACKED_FIELDS, plus "tags" when a tag in an
## ItemClaim.PROTECTED_TAG_PREFIXES namespace was added or removed. An update
## touching several tracked fields is one row listing all of them.
##
## Changed fields are captured by DocketDB.update_item_fields_checked
## (note_work_fields) and consumed by the next event row of the same item in
## that mutation; a rollback discards them with the rows.
##
## Retention: the newest `event_retention` stamped rows keep their eid (docket
## meta key RETENTION_KEY, default DEFAULT_RETENTION). Older rows lose the eid
## and stay in the item's history, so item revisions do not change.

const COUNTER_KEY := "event_counter"
const RETENTION_KEY := "event_retention"
const DEFAULT_RETENTION := 10000

## ItemClaim.PROTECTED_FIELDS plus directed_to.
const TRACKED_FIELDS := ["status", "resolution", "assigned_to", "directed_to", "parent", "blocked_by", "title", "description"]
const ARRIVALS := ["created", "moved", "promoted"]
const COMMENTS := ["comment_added", "comment_reply"]
const CLAIMS := ["claimed", "claim_released", "claim_reassigned"]
const TRANSITIONS := ["transition", "status_repaired"]


## Tracked fields that applying the storage patch `changes` to item `id` would
## change. Setting a field to its current value is not a change.
static func tracked_changes(db: DocketDB, id: String, changes: Dictionary) -> Array[String]:
	var changed: Array[String] = []
	var rows: Array = db._exec_select("SELECT * FROM items WHERE id=?;", [id])
	if rows.is_empty(): return changed
	var row: Dictionary = rows[0]
	var envelope: Variant = JSON.parse_string(str(row.get("fields_json", "{}")))
	var stored_fields: Dictionary = envelope if envelope is Dictionary else {}
	var field_changes: Dictionary = changes.get("fields", {}) if changes.get("fields", {}) is Dictionary else {}
	var unset_fields: Array = changes.get("unset_fields", []) if changes.get("unset_fields", []) is Array else []
	for key in TRACKED_FIELDS:
		var differs: bool = false
		if changes.has(key): differs = _text(changes[key]) != _text(row.get(key))
		if field_changes.has(key): differs = differs or _text(field_changes[key]) != _text(stored_fields.get(key))
		if unset_fields.has(key): differs = differs or not _text(stored_fields.get(key)).is_empty()
		if differs: changed.append(key)
	if changes.has("tags"):
		var after: Variant = changes["tags"]
		if ItemClaim._protected_tags(_tags(db, id)) != ItemClaim._protected_tags(after): changed.append("tags")
	return changed


## Stamps event row `row_id` (just written for `item_id`) when it is
## work-relevant. Revision-bearing rows (ItemRevision.counts) consume the fields
## noted for the item; links, attachments and comment resolutions are never
## stamped and leave them in place. Returns "" or an SQL error; the caller's
## transaction rolls the stamp back with the row.
static func stamp(db: DocketDB, row_id: int, item_id: String, event_type: String) -> String:
	var fields: Array[String] = []
	if not COMMENTS.has(event_type):
		if not ItemRevision.counts(event_type): return ""
		fields = db.take_work_fields(item_id)
		if ARRIVALS.has(event_type): fields = _present_fields(db, item_id)
		elif CLAIMS.has(event_type): fields.assign(["claim"])
		elif TRANSITIONS.has(event_type):
			if not fields.has("status"): fields.push_front("status")
		elif fields.is_empty(): return ""
	var eid: int = _next_eid(db)
	var error: String = db._exec_checked("UPDATE item_events SET eid=?, fields=? WHERE id=?;", [eid, JSON.stringify(fields), row_id])
	if error.is_empty(): error = db._exec_checked("INSERT OR REPLACE INTO docket_meta (key, value) VALUES (?, ?);", [COUNTER_KEY, str(eid)])
	if error.is_empty(): error = db._exec_checked("UPDATE item_events SET eid=NULL WHERE eid IS NOT NULL AND eid<=?;", [eid - retention(db)])
	return error


## Stamps the item_events row most recently inserted on this connection.
static func stamp_last(db: DocketDB, item_id: String, event_type: String) -> String:
	var rows: Array = db._exec_select("SELECT last_insert_rowid() AS id;")
	if rows.is_empty(): return db._last_sql_error if not db._last_sql_error.is_empty() else "could not read the new event row"
	return stamp(db, int(rows[0].id), item_id, event_type)


## How many of the newest stamped events keep their id.
static func retention(db: DocketDB) -> int:
	var raw: String = db.get_meta_value(RETENTION_KEY, "")
	return int(raw) if raw.is_valid_int() and int(raw) > 0 else DEFAULT_RETENTION


## Sets the retention count as one canonical mutation. Returns "" or an error.
static func set_retention(db: DocketDB, count: int) -> String:
	if count <= 0: return "event_retention must be a positive integer"
	if db is DocketDBJsonl:
		var json_db: DocketDBJsonl = db as DocketDBJsonl
		var error: String = json_db._begin_canonical_mutation()
		if not error.is_empty(): return error
		error = json_db._exec_checked("INSERT OR REPLACE INTO docket_meta (key, value) VALUES (?, ?);", [RETENTION_KEY, str(count)])
		return json_db._complete_canonical_mutation(error)
	return db._exec_checked("INSERT OR REPLACE INTO docket_meta (key, value) VALUES (?, ?);", [RETENTION_KEY, str(count)])


## One past the larger of the stored counter and the largest stored eid, so a
## hand-edited or merged file cannot make an id repeat.
static func _next_eid(db: DocketDB) -> int:
	var raw: String = db.get_meta_value(COUNTER_KEY, "0")
	var counter: int = int(raw) if raw.is_valid_int() else 0
	var rows: Array = db._exec_select("SELECT MAX(eid) AS top FROM item_events;")
	if not rows.is_empty() and rows[0].get("top") != null: counter = maxi(counter, int(rows[0].top))
	return counter + 1


## Tracked fields a newly arrived item carries with a value.
static func _present_fields(db: DocketDB, id: String) -> Array[String]:
	var present: Array[String] = []
	var item: Dictionary = db.get_item(id)
	if item.is_empty(): return present
	var custom: Dictionary = item.get("fields", {}) if item.get("fields", {}) is Dictionary else {}
	for key in TRACKED_FIELDS:
		if not _text(item.get(key)).is_empty() or not _text(custom.get(key)).is_empty(): present.append(key)
	if not ItemClaim._protected_tags(_tags(db, id)).is_empty(): present.append("tags")
	return present


static func _tags(db: DocketDB, id: String) -> Array:
	var tags: Array = []
	for row in db._exec_select("SELECT tag FROM item_tags WHERE item_id=?;", [id]): tags.append(str(row.tag))
	return tags


static func _text(value: Variant) -> String:
	return "" if value == null else str(value)
