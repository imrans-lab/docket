extends RefCounted
class_name ItemClaim
## Claim on an item's protected fields (W1 KB docket:01a0dc3549bc s4-6).
##
## The claim is not stored in a column: it is derived from the item's own
## claim events (claimed, claim_released, claim_reassigned), read in the order
## the canonical file keeps them (timestamp, then insertion). Those events live
## in the .dct, so a claim survives a server restart, and each one bumps the
## item revision through ItemRevision's ordinary event count.
##
## A holder is a declared string. Nothing authenticates it: per the trust model
## any caller may declare any holder, and the gate only keeps cooperating
## callers from overwriting each other. A claim is not tied to a connection or
## session; it lasts until its holder releases it or someone reassigns it.
##
## While an item is unclaimed every write behaves as before. While it is
## claimed, a write that changes a protected field is refused unless the
## caller's declared holder equals the current holder.

const CLAIMED := "claimed"
const RELEASED := "claim_released"
const REASSIGNED := "claim_reassigned"

## Exactly the W1 KB section 4 list. Anything else is unprotected.
const PROTECTED_FIELDS := ["status", "resolution", "assigned_to", "parent", "blocked_by", "title", "description"]
const PROTECTED_TAG_PREFIXES := ["wr:", "role:", "base:", "head:", "result:", "requires:", "outcome:", "deferred:"]


## Current holder of `id`, or "" when unclaimed. Reads events only; never writes.
static func holder(db: DocketDB, id: String) -> String:
	var rows: Array = db._exec_select("SELECT event_type, actor, note FROM item_events WHERE item_id=? AND event_type IN (?,?,?) ORDER BY timestamp ASC, id ASC;", [id, CLAIMED, RELEASED, REASSIGNED])
	var current: String = ""
	for row in rows:
		match str(row.get("event_type", "")):
			CLAIMED: current = str(row.get("actor", ""))
			RELEASED: current = ""
			REASSIGNED:
				# A hand-edited, unparseable note leaves the item unclaimed rather
				# than locked to a holder nobody can name.
				var parsed: Variant = JSON.parse_string(str(row.get("note", "")))
				current = str((parsed as Dictionary).get("to", "")) if parsed is Dictionary else ""
	return current


## Claims `id` for `declared`. Re-claiming a claim you hold writes nothing.
## Returns {"holder", "changed"} or {"error"}.
static func claim(db: DocketDB, id: String, declared: String) -> Dictionary:
	if declared.strip_edges().is_empty(): return {"error":"holder is required"}
	var current: String = holder(db, id)
	if current == declared: return {"holder":current, "changed":false}
	if not current.is_empty(): return {"error":refusal(current)}
	var error: String = _append(db, id, CLAIMED, declared, "claimed by %s" % declared)
	return {"error":error} if not error.is_empty() else {"holder":declared, "changed":true}


## Releases the claim `declared` holds. Releasing an unclaimed item writes nothing.
static func release(db: DocketDB, id: String, declared: String) -> Dictionary:
	var current: String = holder(db, id)
	if current.is_empty(): return {"holder":"", "changed":false}
	if current != declared: return {"error":refusal(current)}
	var error: String = _append(db, id, RELEASED, declared, "released by %s" % declared)
	return {"error":error} if not error.is_empty() else {"holder":"", "changed":true}


## Moves the claim to `to`. The current holder (or anyone, when unclaimed) may
## hand it over; anyone else must pass `override`. Either way the event records
## the actor, previous holder, new holder, reason and whether it overrode, and
## the previous holder's next protected write is refused.
static func reassign(db: DocketDB, id: String, actor: String, to: String, reason: String, override: bool) -> Dictionary:
	if actor.strip_edges().is_empty(): return {"error":"actor is required"}
	if to.strip_edges().is_empty(): return {"error":"to is required"}
	if reason.strip_edges().is_empty(): return {"error":"reason is required"}
	var current: String = holder(db, id)
	var overriding: bool = not current.is_empty() and current != actor
	if overriding and not override: return {"error":"%s; reassigning it requires override=true" % refusal(current)}
	var note: String = JSON.stringify({"from":current, "to":to, "reason":reason, "override":overriding})
	var error: String = _append(db, id, REASSIGNED, actor, note)
	return {"error":error} if not error.is_empty() else {"holder":to, "previous":current, "override":overriding}


## One claim event, as its own canonical mutation on a JSONL project.
static func _append(db: DocketDB, id: String, event_type: String, actor: String, note: String) -> String:
	if db is DocketDBJsonl: return (db as DocketDBJsonl).add_event_checked(id, event_type, actor, note)
	db._last_sql_error = ""
	db.add_event(id, event_type, actor, note)
	return db._last_sql_error


## The refusal every gate returns. It reports who holds the claim and nothing
## else: a claim never stops another process or undoes its side effects.
static func refusal(current: String) -> String:
	return "not the holder: %s" % current


## "" when the write may proceed. `touches_protected` is computed by the caller
## (protected_change for updates; always true for a transition).
static func check(db: DocketDB, id: String, declared: String, touches_protected: bool) -> String:
	if not touches_protected: return ""
	var current: String = holder(db, id)
	if current.is_empty() or current == declared: return ""
	return refusal(current)


## Whether applying `values` / `unset` to `item` changes a protected field or a
## tag in a protected namespace. Setting a field to its current value is not a
## change, so a form that resubmits unchanged fields is not refused.
static func protected_change(item: Dictionary, values: Dictionary, unset: Array) -> bool:
	for key in PROTECTED_FIELDS:
		if unset.has(key) and not _blank(item.get(key)): return true
		if values.has(key) and _text(values[key]) != _text(item.get(key)): return true
	if not values.has("tags") and not unset.has("tags"): return false
	var before: Array = _protected_tags(item.get("tags", []))
	var after: Array = [] if unset.has("tags") else _protected_tags(values.get("tags", []))
	return before != after


static func _protected_tags(tags: Variant) -> Array:
	var kept: Array = []
	if not tags is Array: return kept
	for tag in tags:
		for prefix in PROTECTED_TAG_PREFIXES:
			if str(tag).begins_with(prefix):
				kept.append(str(tag))
				break
	kept.sort()
	return kept


static func _blank(value: Variant) -> bool:
	return _text(value).is_empty()


static func _text(value: Variant) -> String:
	return "" if value == null else str(value)
