extends Node
## Functional lifecycle tests: exercises full create → query → update → transition → delete
## flows through the MCP tool layer for knowledge types and work items, including
## cross-project move.

var A := AssertHelpers
var schema: Dictionary
var db: DocketDB
var db2: DocketDB
var registry: ToolRegistry

var _test_dir := "user://test_func_life"
var _db_path: String
var _db2_path: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_db_path = _test_dir + "/proj_a_%d.dct" % Time.get_ticks_msec()
	_db2_path = _test_dir + "/proj_b_%d.dct" % Time.get_ticks_msec()

	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	schema = JSON.parse_string(f.get_as_text())

	db = DocketDB.create_new(_db_path)
	db.set_project_name("proj-a")

	db2 = DocketDB.create_new(_db2_path)
	db2.set_project_name("proj-b")

	var project_dbs := {"proj-a": db, "proj-b": db2}
	registry = ToolRegistry.new()
	registry.init(schema, db, project_dbs)
	registry.add_project_fn = Callable()
	registry.remove_project_fn = Callable()


func teardown() -> void:
	if db:
		db.close()
	if db2:
		db2.close()
	var dir := DirAccess.open(_test_dir)
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			dir.remove(fname)
			fname = dir.get_next()
		DirAccess.remove_absolute(_test_dir)


# -- Test 1: Skill full lifecycle -----------------------------------------------

func test_skill_full_lifecycle() -> Variant:
	# 1. Create
	var created = registry.call_tool("docket_create", {
		"type": "skill",
		"title": "List files",
		"steps": "1. Run: ls -la [path]\n2. Parse output for file details",
		"preconditions": "Unix shell",
		"outcome": "Directory listing printed to stdout",
	})
	var r = A.has_key(created, "id")
	if r is String: return r
	r = A.eq(created.get("error", ""), "", "no error on create")
	if r is String: return r
	var id: String = created.id

	# 2. Query — verify item appears with correct title
	var qresult = registry.call_tool("docket_query", {"filter": {"type": "skill"}})
	r = A.eq(qresult.get("error", ""), "", "no error on query")
	if r is String: return r
	r = A.eq(qresult.items.size(), 1, "one skill in query results")
	if r is String: return r
	r = A.eq(qresult.items[0].title, "List files", "title matches")
	if r is String: return r

	# 3. Update steps field
	var uresult = registry.call_tool("docket_update", {"id": id, "steps": "1. Run: ls -lah [path]\n2. Parse output"})
	r = A.eq(uresult.get("error", ""), "", "no error on update")
	if r is String: return r

	# 4. Get — verify updated steps, other fields preserved
	var item = registry.call_tool("docket_get", {"id": id})
	r = A.eq(item.get("error", ""), "", "no error on get")
	if r is String: return r
	r = A.is_true(str(item.get("steps", "")).contains("ls -lah"), "steps updated")
	if r is String: return r
	r = A.eq(item.preconditions, "Unix shell", "preconditions preserved")
	if r is String: return r
	r = A.eq(item.title, "List files", "title preserved")
	if r is String: return r

	# 5. Quality score
	var qscore = registry.call_tool("docket_quality", {"id": id, "score": 4, "reason": "reliable"})
	r = A.eq(qscore.get("error", ""), "", "no error on quality")
	if r is String: return r
	r = A.eq(qscore.quality, 4, "quality score returned")
	if r is String: return r
	var after_q = registry.call_tool("docket_get", {"id": id, "include": []})
	r = A.eq(after_q.quality, 4, "quality persisted")
	if r is String: return r

	# 6. Transition draft → active
	var tresult = registry.call_tool("docket_transition", {"id": id, "to": "active"})
	r = A.eq(tresult.get("error", ""), "", "no error on transition")
	if r is String: return r
	r = A.eq(tresult.status, "active", "status is active")
	if r is String: return r

	# 7. Delete
	var dresult = registry.call_tool("docket_delete", {"id": id})
	r = A.eq(dresult.get("error", ""), "", "no error on delete")
	if r is String: return r
	r = A.eq(dresult.deleted, true, "deleted flag set")
	if r is String: return r

	# 8. Confirm gone from query
	var after_del = registry.call_tool("docket_query", {"filter": {"type": "skill"}})
	return A.eq(after_del.items.size(), 0, "no skills after delete")


# -- Test 2: Prompt full lifecycle ----------------------------------------------

func test_prompt_full_lifecycle() -> Variant:
	# 1. Create
	var created = registry.call_tool("docket_create", {
		"type": "prompt",
		"title": "Supervisor system prompt",
		"prompt_text": "You are a supervisor agent. Decompose tasks and track via Docket.",
		"parameters": "{{project_name}}, {{worker_count}}",
	})
	var r = A.has_key(created, "id")
	if r is String: return r
	r = A.eq(created.get("error", ""), "", "no error on create")
	if r is String: return r
	var id: String = created.id
	r = A.eq(created.status, "draft", "initial status is draft")
	if r is String: return r

	# 2. Query back and verify fields
	var qresult = registry.call_tool("docket_query", {"filter": {"type": "prompt"}})
	r = A.eq(qresult.items.size(), 1, "one prompt returned")
	if r is String: return r
	r = A.eq(qresult.items[0].title, "Supervisor system prompt", "title matches")
	if r is String: return r

	# 3. Update prompt_text
	var uresult = registry.call_tool("docket_update", {
		"id": id,
		"prompt_text": "You are a supervisor agent. Decompose tasks, assign workers, track via Docket.",
	})
	r = A.eq(uresult.get("error", ""), "", "no error on update")
	if r is String: return r

	# 4. Verify updated text and preserved parameters
	var item = registry.call_tool("docket_get", {"id": id, "include": []})
	r = A.eq(item.get("error", ""), "", "no error on get")
	if r is String: return r
	r = A.is_true(item.prompt_text.contains("assign workers"), "prompt_text updated")
	if r is String: return r
	r = A.eq(item.parameters, "{{project_name}}, {{worker_count}}", "parameters preserved")
	if r is String: return r

	# 5. Score quality
	var qscore = registry.call_tool("docket_quality", {"id": id, "score": 3, "reason": "works well"})
	r = A.eq(qscore.get("error", ""), "", "no error on quality")
	if r is String: return r
	r = A.eq(qscore.quality, 3, "quality score returned")
	if r is String: return r

	# 6. Transition: draft → active → archived → active (reactivate)
	var t1 = registry.call_tool("docket_transition", {"id": id, "to": "active"})
	r = A.eq(t1.get("error", ""), "", "draft->active ok")
	if r is String: return r
	r = A.eq(t1.status, "active")
	if r is String: return r

	var t2 = registry.call_tool("docket_transition", {"id": id, "to": "archived"})
	r = A.eq(t2.get("error", ""), "", "active->archived ok")
	if r is String: return r
	r = A.eq(t2.status, "archived")
	if r is String: return r

	var t3 = registry.call_tool("docket_transition", {"id": id, "to": "active"})
	r = A.eq(t3.get("error", ""), "", "archived->active (reactivate) ok")
	if r is String: return r
	r = A.eq(t3.status, "active", "reactivated to active")
	if r is String: return r

	# 7. Verify final state persisted
	var final_item = registry.call_tool("docket_get", {"id": id, "include": []})
	r = A.eq(final_item.status, "active", "final status is active")
	if r is String: return r
	r = A.eq(final_item.quality, 3, "quality still set after transitions")
	if r is String: return r

	return true


# -- Test 3: KB full lifecycle --------------------------------------------------

func test_kb_full_lifecycle() -> Variant:
	# 1. Create KB with article, summary, key
	var created = registry.call_tool("docket_create", {
		"type": "kb",
		"title": "Minerva trigger system",
		"key": "triggers",
		"article": "Triggers are event subscriptions that wake sleeping chats on docket state changes.",
		"summary": "Event subscriptions that wake sleeping chats",
	})
	var r = A.has_key(created, "id")
	if r is String: return r
	r = A.eq(created.get("error", ""), "", "no error on create")
	if r is String: return r
	var id: String = created.id
	r = A.eq(created.status, "draft", "initial status is draft")
	if r is String: return r

	# 2. Query back and verify key fields present
	var qresult = registry.call_tool("docket_query", {"filter": {"type": "kb"}})
	r = A.eq(qresult.items.size(), 1, "one kb returned")
	if r is String: return r
	r = A.eq(qresult.items[0].title, "Minerva trigger system", "title matches")
	if r is String: return r

	# 3. Get full item, verify all creation fields
	var item = registry.call_tool("docket_get", {"id": id, "include": []})
	r = A.eq(item.get("error", ""), "", "no error on get")
	if r is String: return r
	r = A.eq(item.key, "triggers", "key stored")
	if r is String: return r
	r = A.eq(item.summary, "Event subscriptions that wake sleeping chats", "summary stored")
	if r is String: return r
	r = A.is_true(item.article.begins_with("Triggers are event subscriptions"), "article stored")
	if r is String: return r

	# 4. Update article
	var uresult = registry.call_tool("docket_update", {
		"id": id,
		"article": "Triggers are event subscriptions that wake sleeping chats. They fire when a docket item matching a filter changes state.",
	})
	r = A.eq(uresult.get("error", ""), "", "no error on update")
	if r is String: return r

	var after_update = registry.call_tool("docket_get", {"id": id, "include": []})
	r = A.is_true(after_update.article.contains("filter changes state"), "article updated")
	if r is String: return r
	r = A.eq(after_update.key, "triggers", "key preserved after update")
	if r is String: return r

	# 5. Score quality
	var qscore = registry.call_tool("docket_quality", {"id": id, "score": 5, "reason": "authoritative"})
	r = A.eq(qscore.get("error", ""), "", "no error on quality")
	if r is String: return r
	r = A.eq(qscore.quality, 5, "quality=5 returned")
	if r is String: return r

	# 6. Transition draft → active
	var tresult = registry.call_tool("docket_transition", {"id": id, "to": "active"})
	r = A.eq(tresult.get("error", ""), "", "no error on transition")
	if r is String: return r
	r = A.eq(tresult.status, "active", "status is active")
	if r is String: return r

	# 7. Verify final state
	var final_item = registry.call_tool("docket_get", {"id": id, "include": []})
	r = A.eq(final_item.status, "active", "final status active")
	if r is String: return r
	r = A.eq(final_item.quality, 5, "quality preserved")
	if r is String: return r
	r = A.eq(final_item.key, "triggers", "key preserved")
	if r is String: return r

	return true


# -- Test 4: Work item move across projects ------------------------------------

func test_work_item_move_across_projects() -> Variant:
	# 1. Create first work_item in proj-a
	var c1 = registry.call_tool("docket_create", {
		"type": "work_item",
		"title": "Implement trigger subsystem",
		"description": "Build the event subscription mechanism",
		"tags": ["triggers", "backend"],
		"project": "proj-a",
	})
	var r = A.has_key(c1, "id")
	if r is String: return r
	r = A.eq(c1.get("error", ""), "", "no error creating first item")
	if r is String: return r
	var first_id: String = c1.id

	# 2. Create second work_item in proj-a and link to first (follow_up)
	var c2 = registry.call_tool("docket_create", {
		"type": "work_item",
		"title": "Write trigger subsystem tests",
		"project": "proj-a",
	})
	r = A.has_key(c2, "id")
	if r is String: return r
	var second_id: String = c2.id

	var lresult = registry.call_tool("docket_link", {
		"from": second_id,
		"to": first_id,
		"relation": "follow_up",
	})
	r = A.eq(lresult.get("error", ""), "", "link created ok")
	if r is String: return r

	# Advance first item to in_progress so it has a richer event log
	registry.call_tool("docket_transition", {"id": first_id, "to": "open"})
	registry.call_tool("docket_transition", {"id": first_id, "to": "in_progress"})

	# Confirm both items in proj-a before move
	var before_move = registry.call_tool("docket_query", {"filter": {"type": "work_item"}, "project": "proj-a"})
	r = A.eq(before_move.items.size(), 2, "two items in proj-a before move")
	if r is String: return r

	# 3. Move first item to proj-b
	var mresult = registry.call_tool("docket_move", {
		"id": first_id,
		"target_project": "proj-b",
	})
	r = A.eq(mresult.get("error", ""), "", "no error on move")
	if r is String: return r
	r = A.eq(mresult.new_project, "proj-b", "new_project is proj-b")
	if r is String: return r
	r = A.eq(mresult.old_project, "proj-a", "old_project is proj-a")
	if r is String: return r
	var new_id: String = mresult.new_id

	# 4. Query proj-b for work_items — first item must appear there
	var qb = registry.call_tool("docket_query", {"filter": {"type": "work_item"}, "project": "proj-b"})
	r = A.eq(qb.get("error", ""), "", "no error querying proj-b")
	if r is String: return r
	r = A.eq(qb.items.size(), 1, "one work_item in proj-b after move")
	if r is String: return r
	r = A.eq(qb.items[0].title, "Implement trigger subsystem", "correct item moved")
	if r is String: return r

	# 5. Get full item from proj-b — verify fields preserved
	var moved = registry.call_tool("docket_get", {"id": new_id, "project": "proj-b", "include": []})
	r = A.eq(moved.get("error", ""), "", "no error on get from proj-b")
	if r is String: return r
	r = A.eq(moved.title, "Implement trigger subsystem", "title preserved")
	if r is String: return r
	r = A.eq(moved.type, "work_item", "type preserved")
	if r is String: return r
	r = A.eq(moved.status, "in_progress", "status preserved after move")
	if r is String: return r

	# 6. Verify item is gone from proj-a
	var qa = registry.call_tool("docket_query", {"filter": {"type": "work_item"}, "project": "proj-a"})
	r = A.eq(qa.items.size(), 1, "only one item remains in proj-a")
	if r is String: return r
	r = A.eq(qa.items[0].title, "Write trigger subsystem tests", "remaining item is the second one")
	if r is String: return r

	# Also confirm direct get of moved id fails against proj-a
	var gone = registry.call_tool("docket_get", {"id": new_id, "project": "proj-a"})
	return A.has_key(gone, "error", "item not found in proj-a after move")
