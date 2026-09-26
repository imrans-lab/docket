extends RefCounted
class_name DocketReceipts
## Explicit consumption receipts for change-feed subscribers (DocketSubscriptions).
##
## A subscriber consumes an event only by acknowledging it with ack(). The
## acknowledgement is stored in the subscriber's record as
##   acked  {project: [eid, ...]}  ascending
## Nothing else writes `acked`: reading a page (changes_since raises
## `delivered`) is not consumption, and comment accept/reject and item
## transitions neither read nor change it. An ack changes no project file.
##
## Pending events are the delivered-but-unacknowledged ones: events the
## subscriber can see now (DocketSubscriptions.visibility) whose eid is after
## the project's `start` and at or below its `delivered`, and not in `acked`.
## Visibility is evaluated at read time, so an event on an item that has left
## a scoped subscriber's chain leaves its pending list. Events that lost their
## eid to retention leave the log and the pending list; their acks are dropped
## at the next ack. When a project's log is rewound (changes_since reports
## ahead_of_log), acks above the new head are dropped by forget_after, since
## those eids will be issued again.

const DEFAULT_LIMIT := 50
const MAX_LIMIT := 200


## Marks `raw_events` consumed by subscriber `id`. Each entry is
## {project, eid}, "project:eid", or a bare eid when the subscription covers
## one project. All or nothing: any refused entry returns {error, rejected} and
## records nothing. Acking an acknowledged event again changes nothing.
## Returns {subscriber, acked, already_acked, pending_count} or {error}.
static func ack(id: String, raw_events: Variant, project_dbs: Dictionary) -> Dictionary:
	if not raw_events is Array or (raw_events as Array).is_empty(): return {"error":"event_ids must be a non-empty array"}
	var records: Dictionary = DocketSubscriptions.load_records()
	if not records.has(id): return {"error":"Unknown subscriber: %s" % id}
	var record: Dictionary = records[id]
	var view: Dictionary = DocketSubscriptions.visibility(record.get("filters", {}), project_dbs)
	var projects: Dictionary = view.projects
	var acked: Dictionary = acked_sets(record)
	var added: Array[Dictionary] = []
	var already: Array[Dictionary] = []
	var rejected: Array[Dictionary] = []
	for raw in raw_events:
		var event: Dictionary = _parse(raw, projects)
		if event.has("error"):
			rejected.append({"event":raw, "reason":event.error})
			continue
		var project: String = event.project
		var eid: int = event.eid
		var eids: Array = acked.get(project, [])
		if eids.has(eid):
			already.append(event)
			continue
		var reason: String = _refusal(record, view, project, eid)
		if not reason.is_empty():
			rejected.append({"event":raw, "reason":reason})
			continue
		eids.append(eid)
		acked[project] = eids
		added.append(event)
	if not rejected.is_empty(): return {"error":"no events were acknowledged: %d event id(s) were refused" % rejected.size(), "rejected":rejected}
	if not added.is_empty():
		for project in acked:
			var floor_eid: int = ProjectEvents.retention_floor(projects[project]) if projects.has(project) else 0
			var kept: Array = (acked[project] as Array).filter(func(eid: int) -> bool: return eid > floor_eid)
			kept.sort()
			acked[project] = kept
		record["acked"] = acked
		var error: String = DocketSubscriptions.save_records(records)
		if not error.is_empty(): return {"error":error}
	return {"subscriber":id, "acked":added, "already_acked":already, "pending_count":int(_scan(record, view, 0, false).pending_count)}


## A subscriber's receipt state: {subscriber, name, filters, pending,
## pending_count, acked_count, acked_events (with include_acked), positions,
## cursor} or {error}. pending and acked_events hold at most `limit` events
## {project, eid, item_id, kind, actor, timestamp}; positions has one row per
## project {project, start, delivered, head, retention_floor, acked}; cursor is
## a changes_since cursor just after everything delivered.
static func status(id: String, include_acked: bool, limit: int, project_dbs: Dictionary) -> Dictionary:
	var records: Dictionary = DocketSubscriptions.load_records()
	if not records.has(id): return {"error":"Unknown subscriber: %s" % id}
	var record: Dictionary = records[id]
	var view: Dictionary = DocketSubscriptions.visibility(record.get("filters", {}), project_dbs)
	var scan: Dictionary = _scan(record, view, limit, include_acked)
	var acked_count: int = 0
	var acked: Dictionary = acked_sets(record)
	for project in acked: acked_count += (acked[project] as Array).size()
	var start: Dictionary = record.get("start", {})
	var delivered: Dictionary = record.get("delivered", {})
	var positions: Array[Dictionary] = []
	var cursor_positions: Dictionary = {}
	for project in view.projects:
		var db: DocketDB = view.projects[project]
		if start.has(project): cursor_positions[project] = maxi(int(start[project]), int(delivered.get(project, 0)))
		positions.append({"project":project, "start":int(start.get(project, -1)), "delivered":int(delivered.get(project, 0)), "head":ProjectEvents.head(db), "retention_floor":ProjectEvents.retention_floor(db), "acked":(acked.get(project, []) as Array).size()})
	var out: Dictionary = {"subscriber":id, "name":str(record.get("name", "")), "filters":record.get("filters", {}), "pending":scan.pending, "pending_count":scan.pending_count, "acked_count":acked_count, "positions":positions, "cursor":DocketSubscriptions.encode_cursor(id, cursor_positions)}
	if include_acked: out["acked_events"] = scan.acked
	return out


## Who has acknowledged event `eid` of `project_name`, and who has it pending:
## {project, eid, acked_by, pending_for} (each [{subscriber, name}]) or {error}.
static func event_status(project_name: String, eid: int, project_dbs: Dictionary) -> Dictionary:
	var project: String = ""
	for loaded in project_dbs:
		if str(loaded).to_lower() == project_name.to_lower(): project = str(loaded)
	if project.is_empty(): return {"error":"Unknown project '%s'" % project_name}
	var acked_by: Array[Dictionary] = []
	var pending_for: Array[Dictionary] = []
	var records: Dictionary = DocketSubscriptions.load_records()
	for id in records:
		var record: Dictionary = records[id]
		var view: Dictionary = DocketSubscriptions.visibility(record.get("filters", {}), project_dbs)
		if not (view.projects as Dictionary).has(project): continue
		var entry: Dictionary = {"subscriber":str(id), "name":str(record.get("name", ""))}
		if (acked_sets(record).get(project, []) as Array).has(eid): acked_by.append(entry)
		elif _refusal(record, view, project, eid).is_empty(): pending_for.append(entry)
	return {"project":project, "eid":eid, "acked_by":acked_by, "pending_for":pending_for}


## Drops the acks of `project` above `head` from `record` (a rewound log).
static func forget_after(record: Dictionary, project: String, head: int) -> void:
	var acked: Dictionary = acked_sets(record)
	if not acked.has(project): return
	acked[project] = (acked[project] as Array).filter(func(eid: int) -> bool: return eid <= head)
	record["acked"] = acked


## The record's acks as {project: [int eid]} (JSON numbers come back as floats).
static func acked_sets(record: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var stored: Variant = record.get("acked", {})
	if not stored is Dictionary: return out
	for project in stored:
		var eids: Array = []
		if (stored as Dictionary)[project] is Array:
			for value in (stored as Dictionary)[project]: eids.append(int(value))
		out[str(project)] = eids
	return out


## Why `eid` of `project` cannot be acknowledged by this subscriber, or "".
static func _refusal(record: Dictionary, view: Dictionary, project: String, eid: int) -> String:
	var db: DocketDB = view.projects[project]
	var start: Dictionary = record.get("start", {})
	if not start.has(project) or eid <= int(start[project]) or eid > int((record.get("delivered", {}) as Dictionary).get(project, 0)): return "not delivered to this subscriber"
	if eid <= ProjectEvents.retention_floor(db): return "expired: the event has left the retained log"
	var found: Dictionary = DocketSubscriptions.collect(project, db, eid - 1, 1, view.kinds, view.chain, eid)
	if (found.events as Array).is_empty(): return "not an event this subscriber can see"
	return ""


## Delivered visible events split by ack state: {pending, pending_count, acked}
## with at most `limit` events in each list.
static func _scan(record: Dictionary, view: Dictionary, limit: int, include_acked: bool) -> Dictionary:
	var pending: Array[Dictionary] = []
	var acked_events: Array[Dictionary] = []
	var pending_count: int = 0
	var acked: Dictionary = acked_sets(record)
	var start: Dictionary = record.get("start", {})
	var delivered: Dictionary = record.get("delivered", {})
	for project in view.projects:
		if not start.has(project): continue
		var db: DocketDB = view.projects[project]
		var low: int = maxi(int(start[project]), ProjectEvents.retention_floor(db))
		var high: int = int(delivered.get(project, 0))
		if high <= low: continue
		var eids: Array = acked.get(project, [])
		var stream: Dictionary = DocketSubscriptions.collect(project, db, low, high - low, view.kinds, view.chain, high)
		for event in stream.events:
			var row: Dictionary = {"project":project, "eid":int(event.eid), "item_id":event.item_id, "kind":event.kind, "actor":event.actor, "timestamp":event.timestamp}
			if eids.has(int(event.eid)):
				if include_acked and acked_events.size() < limit: acked_events.append(row)
				continue
			pending_count += 1
			if pending.size() < limit: pending.append(row)
	return {"pending":pending, "pending_count":pending_count, "acked":acked_events}


## {project, eid} for one event_ids entry, or {error}.
static func _parse(raw: Variant, projects: Dictionary) -> Dictionary:
	var project_name: String = ""
	var eid_value: Variant = null
	if raw is Dictionary:
		project_name = str((raw as Dictionary).get("project", ""))
		eid_value = (raw as Dictionary).get("eid")
	elif raw is String:
		var colon: int = (raw as String).rfind(":")
		if colon <= 0: return {"error":"expected \"project:eid\""}
		project_name = (raw as String).substr(0, colon)
		var digits: String = (raw as String).substr(colon + 1)
		if not digits.is_valid_int(): return {"error":"expected \"project:eid\""}
		eid_value = int(digits)
	elif raw is int or raw is float:
		if projects.size() != 1: return {"error":"a bare eid needs a subscription covering exactly one project; pass {project, eid}"}
		project_name = str(projects.keys()[0])
		eid_value = raw
	else:
		return {"error":"expected {project, eid}, \"project:eid\", or an eid"}
	if not (eid_value is int or eid_value is float) or float(eid_value) != floorf(float(eid_value)) or int(eid_value) < 1: return {"error":"eid must be a positive integer"}
	for loaded in projects:
		if str(loaded).to_lower() == project_name.to_lower(): return {"project":str(loaded), "eid":int(eid_value)}
	return {"error":"project '%s' is not in this subscription or not loaded" % project_name}
