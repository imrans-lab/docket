extends RefCounted
class_name ItemRevision
## Per-item integer revision used by `if_revision` on docket_update and
## docket_transition.
##
## The revision is computed, never stored: it is the number of the item's
## item_events rows whose event_type is not comment_*, linked, attached or
## detached. Those evidence events are excluded so a comment, link or
## attachment never makes a holder's if_revision stale. Every field-writing
## path emits exactly one qualifying event per item it changes, so the count
## rises by one per mutation and a rolled-back mutation takes its event with it.
##
## Items whose history lacks events (legacy files, older writers, hand edits)
## simply start at whatever count they have, possibly 0; if_revision only needs
## the count to change when this Docket writes the item.

## Sentinel for "no if_revision supplied". Revisions are never negative.
const ABSENT := -1
const EXCLUDED_EVENTS := ["linked", "attached", "detached"]
const EXCLUDED_PREFIX := "comment_"


## Current revision of `id`, or 0 for an item with no qualifying events.
static func current(db: DocketDB, id: String) -> int:
	var rows: Array = db._exec_select("SELECT event_type FROM item_events WHERE item_id=?;", [id])
	var count: int = 0
	for row in rows:
		if counts(str(row.get("event_type", ""))): count += 1
	return count


## Whether an event of this type is a revision-bearing mutation.
static func counts(event_type: String) -> bool:
	return not event_type.begins_with(EXCLUDED_PREFIX) and not EXCLUDED_EVENTS.has(event_type)


## Parses a tool argument. Returns {"value": int} (ABSENT when not supplied)
## or {"error": String}. JSON numbers arrive as floats, so an integral float
## is accepted.
static func parse_arg(args: Dictionary) -> Dictionary:
	if not args.has("if_revision") or args.if_revision == null: return {"value":ABSENT}
	var raw: Variant = args.if_revision
	if raw is int and int(raw) >= 0: return {"value":int(raw)}
	if raw is float and float(raw) >= 0.0 and float(raw) == floorf(float(raw)): return {"value":int(raw)}
	return {"error":"if_revision must be a non-negative integer"}


## "" when `expected` is ABSENT or equals the current revision; otherwise the
## stale-revision refusal naming both numbers.
static func check(db: DocketDB, id: String, expected: int) -> String:
	if expected == ABSENT: return ""
	var now: int = current(db, id)
	if now == expected: return ""
	return "stale revision: expected %d, current %d" % [expected, now]
