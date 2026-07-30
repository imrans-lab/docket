extends Node

var A := AssertHelpers
var _registry: ToolRegistry
var _schema: Dictionary
var _db: DocketDB
var _test_dir := "user://test_integration"
var _test_file: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_test_file = _test_dir + "/integration.dct"

	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	_schema = JSON.parse_string(f.get_as_text())

	# Remove old db file if exists
	if FileAccess.file_exists(_test_file):
		DirAccess.remove_absolute(_test_file)
	for suffix: String in ["-wal", "-shm"]:
		var p: String = _test_file + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

	_db = DocketDB.create_new(_test_file)
	_registry = ToolRegistry.new()
	_registry.init(_schema, _db)


func teardown() -> void:
	if _db:
		_db.close()
	var dir := DirAccess.open(_test_dir)
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			dir.remove(fname)
			fname = dir.get_next()
		DirAccess.remove_absolute(_test_dir)


func test_full_bug_lifecycle() -> Variant:
	# create → triage → active → resolve(fixed) → verify → close
	var cr = _registry.call_tool("docket_create", {"type": "bug", "title": "Login crash", "priority": 1})
	var id: String = cr.id

	_registry.call_tool("docket_transition", {"id": id, "to": "triaged", "note": "Confirmed repro"})
	_registry.call_tool("docket_transition", {"id": id, "to": "active", "note": "Working on fix"})
	_registry.call_tool("docket_transition", {"id": id, "to": "resolved", "resolution": "fixed", "note": "Patched in abc123"})
	_registry.call_tool("docket_transition", {"id": id, "to": "verified", "note": "Tested in staging"})
	_registry.call_tool("docket_transition", {"id": id, "to": "closed", "note": "Shipped"})

	var item: Dictionary = _db.get_item(id)
	var r = A.eq(item.status, "closed", "final status")
	if r is String: return r
	# creation + 5 transitions = 6 events minimum
	return A.gte(item.events.size(), 6, "at least 6 events")


func test_cross_type_linking() -> Variant:
	# Bug + RCA + Insight, linked, queryable by tag
	var bug = _registry.call_tool("docket_create", {"type": "bug", "title": "Memory leak", "tags": ["backend"]})
	var rca = _registry.call_tool("docket_create", {"type": "rca", "title": "Leak investigation", "tags": ["backend"]})
	var insight = _registry.call_tool("docket_create", {"type": "insight", "title": "Pool exhaustion",
		"tags": ["backend"], "assumed": "Pool auto-grows", "corrected": "Pool is fixed-size"})

	_registry.call_tool("docket_link", {"from": bug.id, "to": rca.id, "relation": "caused_by"})
	_registry.call_tool("docket_link", {"from": rca.id, "to": insight.id, "relation": "surfaced"})

	# Query by tag
	var ctx = _registry.call_tool("docket_context", {"tags": ["backend"]})
	var r = A.eq(ctx.items.size(), 3, "three backend items")
	if r is String: return r

	# Verify links
	var bug_item: Dictionary = _db.get_item(bug.id)
	return A.eq(bug_item.links.size(), 1, "bug has one link")


func test_question_promote_to_insight() -> Variant:
	# Question → escalate → answer → create insight
	var q = _registry.call_tool("docket_create", {"type": "question", "title": "Which cache strategy?", "tags": ["arch"]})
	_registry.call_tool("docket_transition", {"id": q.id, "to": "escalated", "note": "Need senior input"})
	_registry.call_tool("docket_transition", {"id": q.id, "to": "answered", "note": "Use write-through"})

	# Promote to insight
	var ins = _registry.call_tool("docket_create", {"type": "insight", "title": "Write-through caching",
		"tags": ["arch"], "assumed": "Write-behind is faster", "corrected": "Write-through is safer for our consistency needs"})
	_registry.call_tool("docket_link", {"from": ins.id, "to": q.id, "relation": "surfaced"})

	var q_item := _db.get_item(q.id)
	var r = A.eq(q_item.status, "answered")
	if r is String: return r
	var ins_item := _db.get_item(ins.id)
	return A.eq(ins_item.links.size(), 1, "insight linked to question")
