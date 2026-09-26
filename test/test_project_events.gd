extends Node
## Project event log (ProjectEvents) through the MCP tool layer on a JSONL project.
##
## Oracle: the canonical .dct file on disk. Its `event` lines carrying an `eid`
## are the project events; the test counts them against the mutations it made,
## reads their kind and `fields`, and checks the eid sequence. The item revision
## expectation uses the W1 rule on the same lines (every event except
## comment_*, linked, attached, detached). Neither the SQLite cache nor
## ProjectEvents is consulted for an expectation.

var A := AssertHelpers
const DIR := "user://test_project_events"

func setup() -> void: DirAccess.make_dir_recursive_absolute(DIR)
func teardown() -> void:
	var directory: DirAccess = DirAccess.open(DIR)
	if directory != null:
		for name in directory.get_files(): directory.remove(name)
	DirAccess.remove_absolute(DIR)

func _db(name: String) -> DocketDBJsonl:
	var path := DIR + "/" + name + ".dct"
	JSONLCache.delete_cache_family(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var db: DocketDBJsonl = DocketDBJsonl.create_new_jsonl(path)
	assert(db != null, "failed to create isolated JSONL fixture %s" % path)
	db.set_project_name_checked(name)
	return db

## Project events on disk, in eid order: [{eid, item_id, kind, actor, fields}].
func _events(path: String) -> Array:
	var events: Array = []
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var record: Variant = JSON.parse_string(line)
		if not record is Dictionary: continue
		var row: Dictionary = record
		if row.get("_type") != "event" or not row.has("eid"): continue
		events.append({"eid":int(row.eid), "item_id":str(row.item_id), "kind":str(row.event_type), "actor":str(row.get("actor", "")), "fields":row.get("fields", [])})
	events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.eid) < int(b.eid))
	return events

## Item revision from the file's event lines (W1 rule).
func _revision(path: String, id: String) -> int:
	var count: int = 0
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var record: Variant = JSON.parse_string(line)
		if not record is Dictionary or (record as Dictionary).get("_type") != "event" or (record as Dictionary).get("item_id") != id: continue
		var kind: String = str((record as Dictionary).get("event_type", ""))
		if not kind.begins_with("comment_") and not ["linked", "attached", "detached"].has(kind): count += 1
	return count

## "" when eids strictly increase; otherwise the offending sequence.
func _ordered(events: Array) -> String:
	for index in range(1, events.size()):
		if int(events[index].eid) <= int(events[index - 1].eid): return "eids not strictly increasing: %s" % [events.map(func(e: Dictionary) -> int: return int(e.eid))]
	return ""

func test_each_work_mutation_is_one_ordered_project_event_that_survives_reload_on_file_and_memory_projects() -> Variant:
	var db: DocketDBJsonl = _db("Events")
	var path: String = db.get_jsonl_path()
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var tools: ToolRegistry = ToolRegistry.new(); tools.init(schema, db, {"Events":db})
	var created: Dictionary = tools.call_tool("docket_create", {"project":"Events", "type":"work_item", "title":"Task"})
	if created.has("error"): db.close(); return "fixture create failed: %s" % created.error
	var id: String = created.id

	# One call per mutation kind, each expected to add exactly one event of `kind`
	# listing `fields`; the unprotected change is expected to add none.
	var steps: Array = [
		{"what":"assign", "tool":["docket_update", {"id":id, "assigned_to":"local:alice"}], "kind":"typed_update", "fields":["assigned_to"]},
		{"what":"direct", "tool":["docket_update", {"id":id, "directed_to":"local:bob"}], "kind":"typed_update", "fields":["directed_to"]},
		{"what":"two fields", "tool":["docket_update", {"id":id, "title":"Task renamed", "assigned_to":"local:carol"}], "kind":"typed_update", "fields":["title", "assigned_to"]},
		{"what":"protected tag", "tool":["docket_update", {"id":id, "tags":["wr:task"]}], "kind":"typed_update", "fields":["tags"]},
		{"what":"unprotected change", "tool":["docket_update", {"id":id, "priority":2, "tags":["wr:task", "review:requested"]}], "kind":"", "fields":[]},
		{"what":"comment", "tool":["docket_comment", {"action":"add", "item_id":id, "text":"evidence", "author":"local:alice"}], "kind":"comment_added", "fields":[]},
		{"what":"transition", "tool":["docket_transition", {"id":id, "to":"open"}], "kind":"transition", "fields":["status"]},
		{"what":"claim", "tool":["docket_claim", {"id":id, "holder":"local:carol"}], "kind":"claimed", "fields":["claim"]},
	]
	var before: Array = _events(path)
	var r = A.is_true(before.size() == 1 and before[0].kind == "created" and before[0].item_id == id, "creation is one event: %s" % [before])
	if r is String: db.close(); return r
	for step in steps:
		var args: Dictionary = (step.tool[1] as Dictionary).duplicate(); args["project"] = "Events"
		var revision_before: int = _revision(path, id)
		var result: Dictionary = tools.call_tool(str(step.tool[0]), args)
		var after: Array = _events(path)
		var added: int = after.size() - before.size()
		if str(step.kind).is_empty():
			r = A.is_true(not result.has("error") and added == 0, "%s adds no event: added=%d result=%s" % [step.what, added, result])
		else:
			var newest: Dictionary = after.back()
			var fields: Array = newest.fields; fields.sort()
			var expected: Array = step.fields.duplicate(); expected.sort()
			r = A.is_true(not result.has("error") and added == 1 and newest.kind == step.kind and newest.item_id == id and fields == expected, "%s is one %s event listing %s: added=%d newest=%s result=%s" % [step.what, step.kind, expected, added, newest, result])
		if r is String: db.close(); return r
		if step.what == "comment":
			r = A.is_true(_revision(path, id) == revision_before, "a comment leaves the item revision at %d (now %d)" % [revision_before, _revision(path, id)])
			if r is String: db.close(); return r
		before = after
	var order_error: String = _ordered(before)
	if not order_error.is_empty(): db.close(); return order_error
	var mutations: int = 1 + steps.filter(func(s: Dictionary) -> bool: return not str(s.kind).is_empty()).size()
	r = A.is_true(before.size() == mutations, "file holds one event per work mutation: %d events for %d mutations" % [before.size(), mutations])
	if r is String: db.close(); return r

	# Save + reload from the file alone: the same ids come back, and the next
	# event continues the sequence rather than restarting or reusing an id.
	var ids_before: Array = before.map(func(e: Dictionary) -> int: return int(e.eid))
	db.close()
	JSONLCache.delete_cache_family(path)
	var reopened: DocketDBJsonl = DocketDBJsonl.open_jsonl(path)
	if reopened == null: return "reopen failed: %s" % DocketDBJsonl.last_open_error
	tools = ToolRegistry.new(); tools.init(schema, reopened, {"Events":reopened})
	var later: Dictionary = tools.call_tool("docket_comment", {"project":"Events", "action":"add", "item_id":id, "text":"after reload", "author":"local:bob"})
	var reloaded: Array = _events(path)
	var ids_after: Array = reloaded.map(func(e: Dictionary) -> int: return int(e.eid))
	r = A.is_true(not later.has("error") and ids_after.size() == ids_before.size() + 1 and ids_after.slice(0, ids_before.size()) == ids_before and int(ids_after.back()) > int(ids_before.back()) and _ordered(reloaded).is_empty(), "ids stable across reload and continue after it: before=%s after=%s" % [ids_before, ids_after])
	reopened.close()
	if r is String: return r
	return _memory_project_case()

## The same stamping on a memory project, read from its serialized text.
func _memory_project_case() -> Variant:
	var db: DocketDBMemory = DocketDBMemory.create("MemEvents")
	if db == null: return "memory project create failed: %s" % DocketDBJsonl.last_open_error
	var registry: TypeRegistry = TypeRegistry.for_db(db, "MemEvents")
	var created: Dictionary = registry.create_item({"type":"work_item", "title":"Mem task"}, "local:alice")
	if created.has("error"): db.close(); return "create failed: %s" % created.error
	var update_error: String = registry.update_item(created.id, {"assigned_to":"local:alice", "directed_to":"local:bob"}, "local:alice")
	var comment: Dictionary = db.add_comment(created.id, "local:bob", "noted")
	var scratch: String = DIR + "/MemEvents.dct"
	var file := FileAccess.open(scratch, FileAccess.WRITE); file.store_string(db.serialize_as(SessionProject.MODE_MEMORY)); file.close()
	var events: Array = _events(scratch)
	var kinds: Array = events.map(func(e: Dictionary) -> String: return str(e.kind))
	var two: Array = events[1].fields if events.size() > 1 else []; two.sort()
	db.close()
	return A.is_true(update_error.is_empty() and not comment.has("error") and kinds == ["created", "typed_update", "comment_added"] and two == ["assigned_to", "directed_to"] and _ordered(events).is_empty(), "memory project: create, two-field update and comment are three ordered events: %s" % [events])


# --- Change feed (DocketSubscriptions) ---------------------------------------
# Oracle: the eids on the .dct's event lines (_events). A replay is correct when
# its eid list equals the file's eids after the subscriber's last read position,
# restricted to the subscriber's items for a scoped subscriber.

## The file's eids after `after`, optionally only on `items`.
func _file_eids(path: String, after: int, items: Array = []) -> Array:
	var eids: Array = []
	for event in _events(path):
		if int(event.eid) > after and (items.is_empty() or items.has(event.item_id)): eids.append(int(event.eid))
	return eids

func _file_head(path: String) -> int:
	var events: Array = _events(path)
	return 0 if events.is_empty() else int(events.back().eid)

## Reads pages until more=false: {eids, duplicates, pages, cursor} or {error}.
func _drain(tools: ToolRegistry, subscriber: String, cursor: String, limit: int) -> Dictionary:
	var eids: Array = []
	var duplicates: int = 0
	for pages in range(1, 100):
		var page: Dictionary = tools.call_tool("docket_changes_since", {"subscriber":subscriber, "cursor":cursor, "limit":limit})
		if page.has("error") or bool(page.get("expired", false)) or (page.events as Array).size() > limit: return {"error":"bad page: %s" % page}
		for event in page.events:
			eids.append(int(event.eid))
			if bool(event.possible_duplicate): duplicates += 1
		cursor = page.next_cursor
		if not bool(page.more): return {"eids":eids, "duplicates":duplicates, "pages":pages, "cursor":cursor}
	return {"error":"feed did not finish within 99 pages"}

func test_a_reconnecting_subscriber_replays_exactly_the_missed_visible_events_and_an_expired_cursor_says_so() -> Variant:
	var saved_store: String = DocketSubscriptions.store_path
	DocketSubscriptions.store_path = DIR + "/subscriptions.json"
	var result: Variant = _feed_case()
	DocketSubscriptions.store_path = saved_store
	return result

func _feed_case() -> Variant:
	var db: DocketDBJsonl = _db("Feed")
	var path: String = db.get_jsonl_path()
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var tools: ToolRegistry = ToolRegistry.new(); tools.init(schema, db, {"Feed":db})
	var objective: Dictionary = tools.call_tool("docket_create", {"project":"Feed", "type":"work_item", "title":"Objective", "tags":["wr:objective"]})
	var task: Dictionary = tools.call_tool("docket_create", {"project":"Feed", "type":"work_item", "title":"Alice task", "assigned_to":"local:alice", "parent":str(objective.get("id", ""))})
	var other: Dictionary = tools.call_tool("docket_create", {"project":"Feed", "type":"work_item", "title":"Bob task", "assigned_to":"local:bob"})
	if objective.has("error") or task.has("error") or other.has("error"): db.close(); return "fixture create failed: %s %s %s" % [objective, task, other]
	var alice_items: Array = [objective.id, task.id]
	var all_sub: Dictionary = tools.call_tool("docket_subscribe", {"name":"everything"})
	var alice_sub: Dictionary = tools.call_tool("docket_subscribe", {"name":"alice", "filters":{"identity":"local:alice"}})
	if all_sub.has("error") or alice_sub.has("error"): db.close(); return "subscribe failed: %s %s" % [all_sub, alice_sub]

	# N=1: one change after subscribing is the whole feed, for both subscribers.
	var head: int = _file_head(path)
	tools.call_tool("docket_comment", {"project":"Feed", "action":"add", "item_id":task.id, "text":"one", "author":"local:alice"})
	var one: Dictionary = _drain(tools, all_sub.subscriber, all_sub.cursor, 10)
	var alice_one: Dictionary = _drain(tools, alice_sub.subscriber, alice_sub.cursor, 10)
	var r = A.is_true(not one.has("error") and one.eids == _file_eids(path, head) and one.eids.size() == 1 and not alice_one.has("error") and alice_one.eids == one.eids, "N=1 replays the one change: file=%s all=%s alice=%s" % [_file_eids(path, head), one, alice_one])
	if r is String: db.close(); return r

	# N>limit while disconnected, across a restart: every missed change comes
	# back once, paged, with no duplicate flags; alice's feed has no Bob events.
	head = _file_head(path)
	var calls: Array = [
		["docket_comment", {"action":"add", "item_id":other.id, "text":"bob one", "author":"local:bob"}],
		["docket_update", {"id":objective.id, "title":"Objective renamed"}],
		["docket_comment", {"action":"add", "item_id":task.id, "text":"two", "author":"local:alice"}],
		["docket_update", {"id":other.id, "title":"Bob task renamed"}],
		["docket_update", {"id":task.id, "directed_to":"local:carol"}],
		["docket_comment", {"action":"add", "item_id":objective.id, "text":"three", "author":"local:alice"}],
		["docket_comment", {"action":"add", "item_id":other.id, "text":"bob two", "author":"local:bob"}],
	]
	for call in calls:
		var args: Dictionary = (call[1] as Dictionary).duplicate(); args["project"] = "Feed"
		var done: Dictionary = tools.call_tool(str(call[0]), args)
		if done.has("error"): db.close(); return "%s failed: %s" % [call[0], done.error]
	db.close()
	JSONLCache.delete_cache_family(path)
	db = DocketDBJsonl.open_jsonl(path)
	if db == null: return "reopen failed: %s" % DocketDBJsonl.last_open_error
	tools = ToolRegistry.new(); tools.init(schema, db, {"Feed":db})
	var missed: Array = _file_eids(path, head)
	var alice_missed: Array = _file_eids(path, head, alice_items)
	var many: Dictionary = _drain(tools, all_sub.subscriber, one.cursor, 3)
	var alice_many: Dictionary = _drain(tools, alice_sub.subscriber, alice_one.cursor, 3)
	r = A.is_true(missed.size() == calls.size() and not many.has("error") and many.eids == missed and int(many.pages) >= 3 and int(many.duplicates) == 0, "N=%d > limit 3 replays every missed change once, paged: file=%s feed=%s" % [calls.size(), missed, many])
	if r is String: db.close(); return r
	r = A.is_true(alice_missed.size() < missed.size() and not alice_many.has("error") and alice_many.eids == alice_missed, "scoped feed holds only alice's chain (objective + task), not Bob's item: file=%s alice=%s" % [alice_missed, alice_many])
	if r is String: db.close(); return r

	# Rewind: re-reading from the older cursor returns the same events, flagged.
	var again: Dictionary = _drain(tools, all_sub.subscriber, one.cursor, 3)
	r = A.is_true(not again.has("error") and again.eids == missed and int(again.duplicates) == missed.size(), "a rewound cursor replays %s flagged possible_duplicate: %s" % [missed, again])
	if r is String: db.close(); return r

	# Expired: with retention 3, four more changes drop the events after the
	# cursor; the reply says expired, and its recovery cursor reads what is left.
	var retention: Dictionary = tools.call_tool("docket_project_meta", {"project":"Feed", "action":"set", "event_retention":3})
	if retention.has("error"): db.close(); return "set retention failed: %s" % retention.error
	for text in ["r1", "r2", "r3", "r4"]:
		tools.call_tool("docket_comment", {"project":"Feed", "action":"add", "item_id":task.id, "text":text, "author":"local:alice"})
	var stale: Dictionary = tools.call_tool("docket_changes_since", {"subscriber":all_sub.subscriber, "cursor":one.cursor, "limit":10})
	var expired_rows: Array = stale.get("expired_projects", [])
	r = A.is_true(bool(stale.get("expired", false)) and (stale.get("events", [1]) as Array).is_empty() and expired_rows.size() == 1 and str(expired_rows[0].reason) == DocketSubscriptions.EXPIRED_RETENTION, "a cursor past retention is expired, not an empty page: %s" % stale)
	if r is String: db.close(); return r
	var recovered: Dictionary = _drain(tools, all_sub.subscriber, str(stale.next_cursor), 10)
	r = A.is_true(not recovered.has("error") and recovered.eids == _file_eids(path, 0) and recovered.eids.size() == 3, "the recovery cursor reads every retained event: file=%s feed=%s" % [_file_eids(path, 0), recovered])
	if r is String: db.close(); return r

	var gone: Dictionary = tools.call_tool("docket_unsubscribe", {"subscriber":all_sub.subscriber})
	var after_gone: Dictionary = tools.call_tool("docket_changes_since", {"subscriber":all_sub.subscriber, "cursor":""})
	db.close()
	r = A.is_true(not gone.has("error") and after_gone.has("error"), "an unsubscribed id is refused: %s / %s" % [gone, after_gone])
	if r is String: return r
	return _memory_feed_case(schema)

## The feed on a memory project; oracle is its serialized text.
func _memory_feed_case(schema: Dictionary) -> Variant:
	var db: DocketDBMemory = DocketDBMemory.create("MemFeed")
	if db == null: return "memory project create failed: %s" % DocketDBJsonl.last_open_error
	var tools: ToolRegistry = ToolRegistry.new(); tools.init(schema, db, {"MemFeed":db})
	var sub: Dictionary = tools.call_tool("docket_subscribe", {"name":"mem", "filters":{"projects":["MemFeed"]}})
	var created: Dictionary = tools.call_tool("docket_create", {"project":"MemFeed", "type":"work_item", "title":"Mem task"})
	var feed: Dictionary = _drain(tools, str(sub.get("subscriber", "")), str(sub.get("cursor", "")), 10)
	var scratch: String = DIR + "/MemFeed.dct"
	var file := FileAccess.open(scratch, FileAccess.WRITE); file.store_string(db.serialize_as(SessionProject.MODE_MEMORY)); file.close()
	db.close()
	return A.is_true(not sub.has("error") and not created.has("error") and not feed.has("error") and feed.eids == _file_eids(scratch, 0) and feed.eids.size() == 1, "memory project feed: file=%s feed=%s" % [_file_eids(scratch, 0), feed])


# --- Receipts (DocketReceipts) -----------------------------------------------
# Oracle: the subscriber record in the store file (its start, delivered and
# acked, read as JSON) and the .dct's comment and event lines. Pending is
# expected to be the file's eids after `start` up to `delivered`, minus `acked`.

## The stored record of subscriber `id`, read straight from the store file.
func _stored(id: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DocketSubscriptions.store_path))
	if not parsed is Dictionary: return {}
	return ((parsed as Dictionary).get("subscribers", {}) as Dictionary).get(id, {})

## The status a comment has on the .dct ("open" when the line has none).
func _comment_status(path: String, comment_id: int) -> String:
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var record: Variant = JSON.parse_string(line)
		if record is Dictionary and (record as Dictionary).get("_type") == "comment" and int((record as Dictionary).get("id", 0)) == comment_id:
			return str((record as Dictionary).get("status", "open"))
	return "(missing)"

## Pending eids for `project` expected from the stored record and the file.
func _expected_pending(path: String, record: Dictionary, project: String) -> Array:
	var start: int = int((record.get("start", {}) as Dictionary).get(project, 0))
	var delivered: int = int((record.get("delivered", {}) as Dictionary).get(project, 0))
	var acked: Array = ((record.get("acked", {}) as Dictionary).get(project, []) as Array).map(func(v: Variant) -> int: return int(v))
	return _file_eids(path, start).filter(func(eid: int) -> bool: return eid <= delivered and not acked.has(eid))

func _pending_eids(status: Dictionary) -> Array:
	return (status.get("pending", []) as Array).map(func(e: Dictionary) -> int: return int(e.eid))

func test_only_an_ack_consumes_an_event_idempotently_and_apart_from_comment_status_across_a_restart() -> Variant:
	var saved_store: String = DocketSubscriptions.store_path
	DocketSubscriptions.store_path = DIR + "/receipts.json"
	var result: Variant = _receipt_case()
	DocketSubscriptions.store_path = saved_store
	return result

func _receipt_case() -> Variant:
	var db: DocketDBJsonl = _db("Acks")
	var path: String = db.get_jsonl_path()
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var tools: ToolRegistry = ToolRegistry.new(); tools.init(schema, db, {"Acks":db})
	var item: Dictionary = tools.call_tool("docket_create", {"project":"Acks", "type":"work_item", "title":"Acked task"})
	var sub: Dictionary = tools.call_tool("docket_subscribe", {"name":"acker"})
	if item.has("error") or sub.has("error"): db.close(); return "fixture failed: %s %s" % [item, sub]
	var id: String = sub.subscriber
	var comment: Dictionary = tools.call_tool("docket_comment", {"project":"Acks", "action":"add", "item_id":item.id, "text":"please look", "author":"local:alice"})
	tools.call_tool("docket_update", {"project":"Acks", "id":item.id, "title":"Acked task renamed"})
	var fed: Dictionary = _drain(tools, id, sub.cursor, 10)
	if comment.has("error") or fed.has("error"): db.close(); return "feed failed: %s %s" % [comment, fed]
	var comment_eid: int = int(fed.eids[0])
	var update_eid: int = int(fed.eids[1])

	# Delivered but unacked: both events pending, nothing acked, comment open.
	var status: Dictionary = tools.call_tool("docket_subscription_status", {"subscriber":id})
	var record: Dictionary = _stored(id)
	var r = A.is_true(fed.eids.size() == 2 and (record.get("acked", {}) as Dictionary).is_empty() and _pending_eids(status) == _expected_pending(path, record, "Acks") and _pending_eids(status) == fed.eids, "delivered events stay pending until acked: record=%s status=%s" % [record, status])
	if r is String: db.close(); return r

	# Ack removes the event from pending and records it; the comment stays open.
	var acked: Dictionary = tools.call_tool("docket_ack", {"subscriber":id, "event_ids":[{"project":"Acks", "eid":comment_eid}]})
	status = tools.call_tool("docket_subscription_status", {"subscriber":id})
	record = _stored(id)
	r = A.is_true(not acked.has("error") and (acked.acked as Array).size() == 1 and _pending_eids(status) == [update_eid] and _expected_pending(path, record, "Acks") == [update_eid] and _comment_status(path, int(comment.id)) == "open", "ack consumes only the acked event and leaves the comment open: ack=%s record=%s comment=%s" % [acked, record, _comment_status(path, int(comment.id))])
	if r is String: db.close(); return r

	# Idempotent: acking again (another spelling) changes nothing in the store.
	var before: String = FileAccess.get_file_as_string(DocketSubscriptions.store_path)
	var again: Dictionary = tools.call_tool("docket_ack", {"subscriber":id, "event_ids":["Acks:%d" % comment_eid]})
	r = A.is_true(not again.has("error") and (again.acked as Array).is_empty() and (again.already_acked as Array).size() == 1 and FileAccess.get_file_as_string(DocketSubscriptions.store_path) == before, "a second ack is a no-op: %s" % again)
	if r is String: db.close(); return r

	# Accepting the comment changes its status on the .dct and not the acks.
	var accepted: Dictionary = tools.call_tool("docket_comment", {"project":"Acks", "action":"accept", "comment_id":int(comment.id), "addressed_by":"local:bob"})
	r = A.is_true(not accepted.has("error") and _comment_status(path, int(comment.id)) == "accepted" and FileAccess.get_file_as_string(DocketSubscriptions.store_path) == before, "comment accept leaves the receipt record unchanged: %s" % accepted)
	if r is String: db.close(); return r

	# An event that was never delivered cannot be acked, and a refused batch
	# records nothing, including its valid entries.
	var second: Dictionary = tools.call_tool("docket_comment", {"project":"Acks", "action":"add", "item_id":item.id, "text":"second", "author":"local:alice"})
	var undelivered: int = _file_head(path)
	var refused: Dictionary = tools.call_tool("docket_ack", {"subscriber":id, "event_ids":[update_eid, undelivered]})
	r = A.is_true(refused.has("error") and (refused.get("rejected", []) as Array).size() == 1 and FileAccess.get_file_as_string(DocketSubscriptions.store_path) == before, "an undelivered event is refused and nothing is recorded: %s" % refused)
	if r is String: db.close(); return r

	# The second comment is delivered but its receipt never arrives (a failed
	# delivery downstream): it stays pending and the comment stays open.
	var fed_again: Dictionary = _drain(tools, id, fed.cursor, 10)
	var event_view: Dictionary = tools.call_tool("docket_subscription_status", {"event":{"project":"Acks", "eid":undelivered}})
	r = A.is_true(not fed_again.has("error") and fed_again.eids == [undelivered] and _comment_status(path, int(second.id)) == "open" and (event_view.get("pending_for", []) as Array).size() == 1 and (event_view.get("acked_by", [1]) as Array).is_empty(), "delivery alone consumes nothing: feed=%s event=%s" % [fed_again, event_view])
	if r is String: db.close(); return r

	# Restart: the pending set comes back from the stored record.
	db.close()
	JSONLCache.delete_cache_family(path)
	db = DocketDBJsonl.open_jsonl(path)
	if db == null: return "reopen failed: %s" % DocketDBJsonl.last_open_error
	tools = ToolRegistry.new(); tools.init(schema, db, {"Acks":db})
	status = tools.call_tool("docket_subscription_status", {"subscriber":id, "include_acked":true})
	record = _stored(id)
	db.close()
	r = A.is_true(_pending_eids(status) == [update_eid, undelivered] and _expected_pending(path, record, "Acks") == _pending_eids(status) and int(status.get("acked_count", 0)) == 1 and (status.get("acked_events", []) as Array).size() == 1, "delivered-but-unacked events are still pending after a restart: record=%s status=%s" % [record, status])
	if r is String: return r
	return _memory_receipt_case(schema)

## Acks on a memory project; oracle is the stored record.
func _memory_receipt_case(schema: Dictionary) -> Variant:
	var db: DocketDBMemory = DocketDBMemory.create("MemAcks")
	if db == null: return "memory project create failed: %s" % DocketDBJsonl.last_open_error
	var tools: ToolRegistry = ToolRegistry.new(); tools.init(schema, db, {"MemAcks":db})
	var sub: Dictionary = tools.call_tool("docket_subscribe", {"name":"mem-acker", "filters":{"projects":["MemAcks"]}})
	tools.call_tool("docket_create", {"project":"MemAcks", "type":"work_item", "title":"Mem task"})
	var id: String = str(sub.get("subscriber", ""))
	var feed: Dictionary = _drain(tools, id, str(sub.get("cursor", "")), 10)
	var acked: Dictionary = tools.call_tool("docket_ack", {"subscriber":id, "event_ids":feed.get("eids", [])})
	var status: Dictionary = tools.call_tool("docket_subscription_status", {"subscriber":id})
	var record: Dictionary = _stored(id)
	db.close()
	var stored_acks: Array = ((record.get("acked", {}) as Dictionary).get("MemAcks", []) as Array).map(func(v: Variant) -> int: return int(v))
	return A.is_true(not feed.has("error") and not acked.has("error") and stored_acks == feed.eids and _pending_eids(status) == [] and int(status.get("acked_count", 0)) == 1, "memory project acks: feed=%s ack=%s record=%s status=%s" % [feed, acked, record, status])
