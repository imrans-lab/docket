extends RefCounted
class_name DocketSubscriptions
## Per-subscriber change feeds over the project event log (ProjectEvents).
##
## A subscriber is a stored record in STORE (a JSON file in the app's user data,
## outside every .dct, so it survives restart and is never committed with a
## project):
##   {id, name, filters, start, delivered, created_at}
##   filters    {projects, kinds, identity, role}; empty = no restriction
##   start      {project: eid} the head of each project when the record was made
##   delivered  {project: eid} the largest eid ever returned to this subscriber
##
## A cursor is an opaque base64 of compact JSON {"s": subscriber id,
## "p": {project: eid}}: the last eid consumed in each project. Cursor "" means
## `start`. A project without a position (added to the server later) enters at
## its current head. eids are per project, so a page merges the projects'
## streams by (timestamp, project name); each project's events stay in eid order.
##
## Visibility. Without identity or role the subscriber sees every event in its
## projects. With either, it sees only events on its chain, the C1 T3 scope
## rule evaluated from the current records at read time: items whose
## assigned_to or directed_to equals the identity or the role exactly, plus
## their parents up to and including the first `wr:objective` item (at most
## ANCESTOR_DEPTH levels, never into a project outside the subscription).
## Events of deleted items leave the log with their rows.
##
## Duplicates. An event whose eid is at or below `delivered` for its project has
## been returned before (for instance after a cursor rewind) and carries
## possible_duplicate=true. Returning an event is not an acknowledgement.
##
## Expiry. A position below ProjectEvents.retention_floor has lost events to
## retention; a position above the project head belongs to a log that was
## rewound (a reverted or replaced file). Either returns expired=true, no
## events, and a next_cursor whose expired positions are the floor (retention)
## or the head (ahead_of_log). A rewound project's `delivered` is lowered to its
## head so the new events there are not flagged as duplicates.

const STORE := "user://docket_subscriptions.json"
const DEFAULT_LIMIT := 50
const MAX_LIMIT := 200
const SCAN_BATCH := 500
const ANCESTOR_DEPTH := 8
const OBJECTIVE_TAG := "wr:objective"
const FILTER_KEYS := ["projects", "kinds", "identity", "role"]
const EXPIRED_RETENTION := "retention"
const EXPIRED_AHEAD := "ahead_of_log"

## Where the records live; tests point it at a scratch file.
static var store_path: String = STORE


## Creates a subscriber. Returns {subscriber, name, filters, cursor, heads} or {error}.
static func subscribe(name: String, raw_filters: Variant, project_dbs: Dictionary) -> Dictionary:
	if name.strip_edges().is_empty(): return {"error":"name is required"}
	var filters: Dictionary = _normalize_filters(raw_filters, project_dbs)
	if filters.has("error"): return filters
	var start: Dictionary = {}
	var projects: Dictionary = _projects(filters, project_dbs)
	for project in projects: start[project] = ProjectEvents.head(projects[project])
	var id: String = "sub-" + Crypto.new().generate_random_bytes(8).hex_encode()
	var records: Dictionary = _load()
	records[id] = {"id":id, "name":name, "filters":filters, "start":start, "delivered":{}, "created_at":Time.get_datetime_string_from_system()}
	var error: String = _save(records)
	if not error.is_empty(): return {"error":error}
	return {"subscriber":id, "name":name, "filters":filters, "cursor":encode_cursor(id, start), "heads":start}


## Removes a subscriber. Returns {removed, subscriber} or {error}.
static func unsubscribe(id: String) -> Dictionary:
	var records: Dictionary = _load()
	if not records.has(id): return {"error":"Unknown subscriber: %s" % id}
	records.erase(id)
	var error: String = _save(records)
	if not error.is_empty(): return {"error":error}
	return {"removed":true, "subscriber":id}


## One page of the subscriber's visible events after `cursor`:
## {events, next_cursor, more, expired, expired_projects, unavailable_projects}
## or {error}. A page holds at most `limit` events and ContentLedger.PAGE_BYTES
## of encoded events; `more` is true while events may remain.
static func changes_since(id: String, cursor: String, limit: int, project_dbs: Dictionary) -> Dictionary:
	var records: Dictionary = _load()
	if not records.has(id): return {"error":"Unknown subscriber: %s" % id}
	var record: Dictionary = records[id]
	var filters: Dictionary = record.get("filters", {})
	var positions: Dictionary = record.get("start", {}).duplicate()
	if not cursor.is_empty():
		var decoded: Dictionary = decode_cursor(cursor)
		if decoded.is_empty() or str(decoded.s) != id: return {"error":"cursor is malformed or belongs to another subscriber; pass \"\" to read from the subscription start"}
		positions = decoded.p
	var delivered: Dictionary = record.get("delivered", {}).duplicate()
	var projects: Dictionary = _projects(filters, project_dbs)
	var unavailable: Array[String] = []
	for listed in filters.get("projects", []):
		if not projects.has(str(listed)): unavailable.append(str(listed))

	var expired: Array[Dictionary] = []
	for project in projects:
		var db: DocketDB = projects[project]
		var head: int = ProjectEvents.head(db)
		if not positions.has(project): positions[project] = head
		var position: int = int(positions[project])
		var floor_eid: int = ProjectEvents.retention_floor(db)
		if position > head:
			expired.append({"project":project, "cursor_eid":position, "recovery_eid":head, "reason":EXPIRED_AHEAD})
			positions[project] = head
			if int(delivered.get(project, 0)) > head: delivered[project] = head
		elif position < floor_eid:
			expired.append({"project":project, "cursor_eid":position, "recovery_eid":floor_eid, "reason":EXPIRED_RETENTION})
			positions[project] = floor_eid
	if not expired.is_empty():
		record["delivered"] = delivered
		var save_error: String = _save(records)
		if not save_error.is_empty(): return {"error":save_error}
		return {"events":[], "next_cursor":encode_cursor(id, positions), "more":true, "expired":true, "expired_projects":expired, "unavailable_projects":unavailable}

	var scoped: bool = not str(filters.get("identity", "")).is_empty() or not str(filters.get("role", "")).is_empty()
	var chain: Dictionary = _chain(_principals(filters), projects) if scoped else {}
	var kinds: Array = filters.get("kinds", [])
	var streams: Dictionary = {}
	for project in projects:
		streams[project] = _collect(project, projects[project], int(positions[project]), limit, kinds, chain if scoped else null)

	var page: Array[Dictionary] = []
	var budget: int = ContentLedger.PAGE_BYTES
	var full: bool = false
	while page.size() < limit and not full:
		var pick: String = ""
		for project in streams:
			var stream: Dictionary = streams[project]
			if int(stream.taken) >= (stream.events as Array).size(): continue
			if pick.is_empty() or _earlier(stream, str(project), streams[pick], pick): pick = str(project)
		if pick.is_empty(): break
		var chosen: Dictionary = streams[pick]
		var event: Dictionary = (chosen.events as Array)[int(chosen.taken)].duplicate()
		event["possible_duplicate"] = int(event.eid) <= int(delivered.get(pick, 0))
		var size: int = JSON.stringify(event).to_utf8_buffer().size()
		if not page.is_empty() and size > budget:
			full = true
			continue
		budget -= size
		page.append(event)
		chosen.taken = int(chosen.taken) + 1
		chosen.last = int(event.eid)

	var more: bool = false
	var raised: bool = false
	for project in streams:
		var stream: Dictionary = streams[project]
		var all_taken: bool = int(stream.taken) == (stream.events as Array).size()
		positions[project] = int(stream.scanned_to) if all_taken else int(stream.last)
		if not all_taken or not bool(stream.exhausted): more = true
		if int(stream.taken) > 0 and int(stream.last) > int(delivered.get(project, 0)):
			delivered[project] = int(stream.last)
			raised = true
	if raised:
		record["delivered"] = delivered
		var error: String = _save(records)
		if not error.is_empty(): return {"error":error}
	return {"events":page, "next_cursor":encode_cursor(id, positions), "more":more, "expired":false, "expired_projects":[], "unavailable_projects":unavailable}


static func encode_cursor(id: String, positions: Dictionary) -> String:
	return Marshalls.utf8_to_base64(JSON.stringify({"s":id, "p":positions}))


## {s, p} with integer positions, or {} when the cursor cannot be decoded.
static func decode_cursor(cursor: String) -> Dictionary:
	var raw_bytes: PackedByteArray = Marshalls.base64_to_raw(cursor)
	if raw_bytes.is_empty(): return {}
	var parsed: Variant = JSON.parse_string(raw_bytes.get_string_from_utf8())
	if not parsed is Dictionary: return {}
	var raw: Dictionary = parsed
	if not raw.get("s") is String or not raw.get("p") is Dictionary: return {}
	var positions: Dictionary = {}
	for project in raw.p:
		var value: Variant = raw.p[project]
		if not (value is int or value is float) or float(value) != floorf(float(value)) or int(value) < 0: return {}
		positions[str(project)] = int(value)
	return {"s":str(raw.s), "p":positions}


## The project's visible events after `position`, in eid order, stopping once
## `limit` are found: {events, taken, last, scanned_to, exhausted}. `chain` is
## null for an unscoped subscriber.
static func _collect(project: String, db: DocketDB, position: int, limit: int, kinds: Array, chain: Variant) -> Dictionary:
	var stream: Dictionary = {"events":[], "taken":0, "last":position, "scanned_to":position, "exhausted":false}
	var events: Array = stream.events
	while true:
		var rows: Array = db._exec_select("SELECT eid, item_id, event_type, actor, timestamp, fields FROM item_events WHERE eid>? ORDER BY eid LIMIT ?;", [int(stream.scanned_to), SCAN_BATCH])
		for row in rows:
			stream.scanned_to = int(row.eid)
			var kind: String = str(row.event_type)
			var item_id: String = str(row.item_id)
			if not kinds.is_empty() and not kinds.has(kind): continue
			if chain != null and not (chain as Dictionary).has(_key(project, item_id)): continue
			var fields: Variant = JSON.parse_string(_text(row.get("fields")))
			events.append({"project":project, "eid":int(row.eid), "item_id":item_id, "kind":kind, "actor":_text(row.get("actor")), "timestamp":_text(row.get("timestamp")), "fields":fields if fields is Array else []})
			if events.size() >= limit: return stream
		if rows.size() < SCAN_BATCH:
			stream.exhausted = true
			return stream
	return stream


## Whether stream `a`'s next event precedes stream `b`'s: timestamp, then project name.
static func _earlier(a: Dictionary, a_name: String, b: Dictionary, b_name: String) -> bool:
	var a_time: String = str((a.events as Array)[int(a.taken)].timestamp)
	var b_time: String = str((b.events as Array)[int(b.taken)].timestamp)
	return a_time < b_time or (a_time == b_time and a_name < b_name)


## {project\titem_id: true} for every item on the principals' chain.
static func _chain(principals: Array, projects: Dictionary) -> Dictionary:
	var chain: Dictionary = {}
	if principals.is_empty(): return chain
	var by_lower: Dictionary = {}
	for project in projects: by_lower[str(project).to_lower()] = str(project)
	var marks: String = ",".join(PackedStringArray(principals.map(func(_p: String) -> String: return "?")))
	var sql: String = "SELECT id FROM items WHERE assigned_to IN (%s) OR directed_to IN (%s);" % [marks, marks]
	for start_project in projects:
		for row in (projects[start_project] as DocketDB)._exec_select(sql, principals + principals):
			var project: String = str(start_project)
			var id: String = str(row.id)
			for depth in range(ANCESTOR_DEPTH + 1):
				var key: String = _key(project, id)
				if depth > 0 and chain.has(key): break
				chain[key] = true
				var db: DocketDB = projects[project]
				if not db._exec_select("SELECT 1 FROM item_tags WHERE item_id=? AND tag=? LIMIT 1;", [id, OBJECTIVE_TAG]).is_empty(): break
				var parents: Array = db._exec_select("SELECT parent FROM items WHERE id=?;", [id])
				var parent: String = _text(parents[0].get("parent")) if not parents.is_empty() else ""
				if parent.is_empty(): break
				var colon: int = parent.find(":")
				if colon >= 0:
					project = str(by_lower.get(parent.substr(0, colon).to_lower(), ""))
					parent = parent.substr(colon + 1)
				if project.is_empty(): break
				id = parent
	return chain


static func _principals(filters: Dictionary) -> Array:
	var principals: Array = []
	for key in ["identity", "role"]:
		var value: String = str(filters.get(key, ""))
		if not value.is_empty(): principals.append(value)
	return principals


## The server's projects: `project_dbs`, or the lone primary when none are registered.
static func loaded(db: DocketDB, project_dbs: Dictionary) -> Dictionary:
	if not project_dbs.is_empty() or db == null: return project_dbs
	return {db.get_project_name(): db}


## The loaded projects the filters cover: {name: DocketDB}.
static func _projects(filters: Dictionary, project_dbs: Dictionary) -> Dictionary:
	var listed: Array = filters.get("projects", [])
	var out: Dictionary = {}
	for project in project_dbs:
		if listed.is_empty() or listed.has(str(project)): out[str(project)] = project_dbs[project]
	return out


## Validated filters with project names in their loaded spelling, or {error}.
static func _normalize_filters(raw: Variant, project_dbs: Dictionary) -> Dictionary:
	if raw == null: raw = {}
	if not raw is Dictionary: return {"error":"filters must be an object"}
	var given: Dictionary = raw
	for key in given:
		if not FILTER_KEYS.has(str(key)): return {"error":"Unknown filter '%s'; filters are %s" % [key, FILTER_KEYS]}
	var filters: Dictionary = {"projects":[], "kinds":[], "identity":"", "role":""}
	for key in ["projects", "kinds"]:
		var values: Variant = given.get(key, [])
		if not values is Array: return {"error":"filters.%s must be an array of strings" % key}
		for value in values:
			if not value is String or (value as String).is_empty(): return {"error":"filters.%s must be an array of strings" % key}
			var entry: String = value
			if key == "projects":
				entry = ""
				for project in project_dbs:
					if str(project).to_lower() == (value as String).to_lower(): entry = str(project)
				if entry.is_empty(): return {"error":"Unknown project '%s'" % value}
			if not (filters[key] as Array).has(entry): (filters[key] as Array).append(entry)
	for key in ["identity", "role"]:
		var value: Variant = given.get(key, "")
		if not value is String: return {"error":"filters.%s must be a string" % key}
		filters[key] = (value as String).strip_edges()
	return filters


static func _key(project: String, id: String) -> String:
	return project.to_lower() + "\t" + id


static func _load() -> Dictionary:
	if not FileAccess.file_exists(store_path): return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(store_path))
	if not parsed is Dictionary or not (parsed as Dictionary).get("subscribers") is Dictionary: return {}
	return (parsed as Dictionary).subscribers


static func _save(records: Dictionary) -> String:
	var file: FileAccess = FileAccess.open(store_path, FileAccess.WRITE)
	if file == null: return "could not write subscriptions to %s: %s" % [store_path, error_string(FileAccess.get_open_error())]
	file.store_string(JSON.stringify({"version":1, "subscribers":records}, "\t"))
	file.close()
	return ""


static func _text(value: Variant) -> String:
	return "" if value == null else str(value)
