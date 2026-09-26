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
