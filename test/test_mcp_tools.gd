extends Node

var A := AssertHelpers
var _registry: ToolRegistry
var _schema: Dictionary
var _db: DocketDB
var _test_dir := "user://test_mcp_tools"
var _test_file: String
var _db2: DocketDB
var _test_file2: String


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	_test_file = _test_dir + "/test_tools.dct"
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	_schema = JSON.parse_string(f.get_as_text())
	_reset_data()


func _reset_data() -> void:
	# Remove old db file if exists
	if FileAccess.file_exists(_test_file):
		DirAccess.remove_absolute(_test_file)
	# Also remove WAL/SHM files
	for suffix: String in ["-wal", "-shm"]:
		var p: String = _test_file + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	_db = DocketDB.create_new(_test_file)
	_registry = ToolRegistry.new()
	_registry.init(_schema, _db)


func before_each() -> void:
	_reset_data()


func _setup_multi_project() -> void:
	# Set primary DB project name to "alpha"
	_db.set_project_name("alpha")
	# Create second DB as "beta"
	_test_file2 = _test_dir + "/test_tools2.dct"
	if FileAccess.file_exists(_test_file2):
		DirAccess.remove_absolute(_test_file2)
	for suffix: String in ["-wal", "-shm"]:
		var p: String = _test_file2 + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	_db2 = DocketDB.create_new(_test_file2)
	_db2.set_project_name("beta")
	# Re-init registry with multi-project context
	_registry = ToolRegistry.new()
	_registry.init(_schema, _db, {"alpha": _db, "beta": _db2})


func teardown() -> void:
	if _db:
		_db.close()
	if _db2:
		_db2.close()
	var dir := DirAccess.open(_test_dir)
	if dir:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			dir.remove(fname)
			fname = dir.get_next()
		DirAccess.remove_absolute(_test_dir)


func test_create_bug() -> Variant:
	var result = _registry.call_tool("docket_create", {"type": "bug", "title": "Test bug"})
	var r = A.has_key(result, "id")
	if r is String: return r
	var id: String = result.id
	r = A.eq(id.length(), 32, "uuid7 id is 32 chars")
	if r is String: return r
	r = A.is_true(id.is_valid_hex_number(false), "uuid7 id is valid hex")
	if r is String: return r
	return A.is_true(_db.has_item(id), "item in db")


func test_create_invalid_type() -> Variant:
	var result = _registry.call_tool("docket_create", {"type": "nope", "title": "Bad"})
	return A.has_key(result, "error")


func test_get_existing() -> Variant:
	var created = _registry.call_tool("docket_create", {"type": "bug", "title": "Get test"})
	var id: String = created.id
	var result = _registry.call_tool("docket_get", {"id": id})
	var r = A.eq(result.title, "Get test")
	if r is String: return r
	return A.eq(result.type, "bug")


func test_get_missing() -> Variant:
	var result = _registry.call_tool("docket_get", {"id": "DKT-9999"})
	return A.has_key(result, "error")


func test_update_fields() -> Variant:
	var created = _registry.call_tool("docket_create", {"type": "bug", "title": "Update test"})
	var id: String = created.id
	var result = _registry.call_tool("docket_update", {"id": id, "priority": 1})
	var r = A.eq(result.get("error", ""), "")
	if r is String: return r
	var item := _db.get_item(id)
	return A.eq(item.priority, 1)


func test_create_policy_item() -> Variant:
	var result = _registry.call_tool("docket_create", {
		"type": "policy",
		"title": "Approval gate",
		"steps": "1. Detect write operations\n2. Pause for approval",
		"preconditions": "Mutation requested",
		"outcome": "Explicit approval before change",
	})
	var r = A.has_key(result, "id")
	if r is String: return r
	var item := _db.get_item(result.id)
	r = A.eq(item.type, "policy", "type stored")
	if r is String: return r
	return A.is_true(item.steps.contains("Detect write"), "steps stored")


func test_create_skill_with_structured_fields() -> Variant:
	var result = _registry.call_tool("docket_create", {
		"type": "skill",
		"title": "Schema sync",
		"tool_deps": ["docket_query", "docket_get"],
		"optimization": {"tool_budget": 2, "summary_mode": "deterministic"},
	})
	var r = A.has_key(result, "id")
	if r is String: return r
	var item := _db.get_item(result.id)
	r = A.eq(item.tool_deps.size(), 2, "tool_deps stored")
	if r is String: return r
	return A.eq(int(item.optimization.get("tool_budget", 0)), 2, "optimization stored")


func test_update_prompt_target() -> Variant:
	var created = _registry.call_tool("docket_create", {"type": "prompt", "title": "Target me"})
	var id: String = created.id
	var result = _registry.call_tool("docket_update", {"id": id, "target": "all"})
	var r = A.eq(result.get("error", ""), "")
	if r is String: return r
	var item := _db.get_item(id)
	return A.eq(item.get("target", ""), "all", "target stored")


func test_update_rejection() -> Variant:
	var created = _registry.call_tool("docket_create", {"type": "chore", "title": "Chore"})
	var id: String = created.id
	var result = _registry.call_tool("docket_update", {"id": id, "resolution": "fixed"})
	return A.has_key(result, "error")


func test_transition_valid() -> Variant:
	var created = _registry.call_tool("docket_create", {"type": "chore", "title": "Trans test"})
	var id: String = created.id
	var result = _registry.call_tool("docket_transition", {"id": id, "to": "in_progress"})
	var r = A.eq(result.get("error", ""), "")
	if r is String: return r
	var item := _db.get_item(id)
	return A.eq(item.status, "in_progress")


func test_transition_invalid() -> Variant:
	var created = _registry.call_tool("docket_create", {"type": "chore", "title": "Trans test"})
	var id: String = created.id
	var result = _registry.call_tool("docket_transition", {"id": id, "to": "done"})
	return A.has_key(result, "error")


func test_query_all() -> Variant:
	_registry.call_tool("docket_create", {"type": "bug", "title": "Bug 1"})
	_registry.call_tool("docket_create", {"type": "chore", "title": "Chore 1"})
	var result = _registry.call_tool("docket_query", {})
	return A.eq(result.items.size(), 2, "both items returned")


func test_query_filtered() -> Variant:
	_registry.call_tool("docket_create", {"type": "bug", "title": "Bug 1"})
	_registry.call_tool("docket_create", {"type": "chore", "title": "Chore 1"})
	var result = _registry.call_tool("docket_query", {"filter": {"type": "bug"}})
	return A.eq(result.items.size(), 1, "only bugs")


func test_link_valid() -> Variant:
	var c1 = _registry.call_tool("docket_create", {"type": "bug", "title": "Bug"})
	var c2 = _registry.call_tool("docket_create", {"type": "rca", "title": "RCA"})
	var id1: String = c1.id
	var id2: String = c2.id
	var result = _registry.call_tool("docket_link", {"from": id1, "to": id2, "relation": "caused_by"})
	var r = A.eq(result.get("error", ""), "")
	if r is String: return r
	var item := _db.get_item(id1)
	return A.gt(item.links.size(), 0, "link added")


func test_link_invalid_relation() -> Variant:
	var c1 = _registry.call_tool("docket_create", {"type": "bug", "title": "Bug"})
	var c2 = _registry.call_tool("docket_create", {"type": "rca", "title": "RCA"})
	var result = _registry.call_tool("docket_link", {"from": c1.id, "to": c2.id, "relation": "invalid_rel"})
	return A.has_key(result, "error")


func test_context() -> Variant:
	_registry.call_tool("docket_create", {"type": "bug", "title": "API bug", "tags": ["api"]})
	_registry.call_tool("docket_create", {"type": "insight", "title": "API insight", "tags": ["api"], "assumed": "A", "corrected": "B"})
	var result = _registry.call_tool("docket_context", {"tags": ["api"]})
	return A.gt(result.items.size(), 0, "context returns items")


func test_saved_query_save_and_load() -> Variant:
	_registry.call_tool("docket_saved_query", {
		"action": "save", "name": "p1-bugs",
		"filter": {"type": "bug", "priority": 1}, "sort": [{"field": "created_at", "dir": "desc"}]
	})
	var result = _registry.call_tool("docket_saved_query", {"action": "load", "name": "p1-bugs"})
	var r = A.has_key(result, "filter")
	if r is String: return r
	return A.eq(result.filter.type, "bug")


func test_saved_query_list() -> Variant:
	_registry.call_tool("docket_saved_query", {
		"action": "save", "name": "my-query",
		"filter": {"status": "active"}
	})
	var result = _registry.call_tool("docket_saved_query", {"action": "list"})
	return A.contains(result.queries, "my-query")


# -- Work Item + Blocked Transition -------------------------------------------

func test_create_work_item() -> Variant:
	var result = _registry.call_tool("docket_create", {"type": "work_item", "title": "My task"})
	var r = A.has_key(result, "id")
	if r is String: return r
	var item := _db.get_item(result.id)
	r = A.eq(item.type, "work_item")
	if r is String: return r
	return A.eq(item.status, "backlog", "initial state is backlog")


func test_blocked_transition_auto_link() -> Variant:
	# Create blocker and blockee
	var c1 = _registry.call_tool("docket_create", {"type": "work_item", "title": "Blocker"})
	var c2 = _registry.call_tool("docket_create", {"type": "work_item", "title": "Blocked task"})
	var blocker_id: String = c1.id
	var blocked_id: String = c2.id

	# Move blocked task to in_progress first (backlog -> open -> in_progress)
	_registry.call_tool("docket_transition", {"id": blocked_id, "to": "open"})
	_registry.call_tool("docket_transition", {"id": blocked_id, "to": "in_progress"})

	# Now block it
	var result = _registry.call_tool("docket_transition", {
		"id": blocked_id, "to": "blocked", "blocked_by": blocker_id
	})
	var r = A.eq(result.get("error", ""), "", "transition succeeded")
	if r is String: return r
	r = A.eq(result.status, "blocked")
	if r is String: return r

	# Check that blocked_by was stored
	var item := _db.get_item(blocked_id)
	r = A.eq(item.blocked_by, blocker_id, "blocked_by stored")
	if r is String: return r

	# Check that a blocks link was auto-created from blocker -> blocked
	var links := _db.get_links(blocker_id)
	r = A.eq(links.size(), 1, "one link from blocker")
	if r is String: return r
	r = A.eq(links[0].to, blocked_id, "link points to blocked item")
	if r is String: return r
	return A.eq(links[0].relation, "blocks", "link relation is blocks")


func test_blocked_transition_cross_project_ref() -> Variant:
	# Cross-project ref — blocker doesn't exist locally, link should NOT be created
	var c1 = _registry.call_tool("docket_create", {"type": "work_item", "title": "Blocked task"})
	var id: String = c1.id
	_registry.call_tool("docket_transition", {"id": id, "to": "open"})
	_registry.call_tool("docket_transition", {"id": id, "to": "in_progress"})

	var result = _registry.call_tool("docket_transition", {
		"id": id, "to": "blocked", "blocked_by": "otherproject:DKT-0015"
	})
	var r = A.eq(result.get("error", ""), "", "cross-project block succeeded")
	if r is String: return r

	var item := _db.get_item(id)
	r = A.eq(item.blocked_by, "otherproject:DKT-0015", "qualified ID stored")
	if r is String: return r

	# No links should exist since the blocker is in another project
	var links := _db.get_links(id)
	return A.eq(links.size(), 0, "no local link for cross-project blocker")


# -- Short ID resolution ------------------------------------------------------

func test_short_id_resolution() -> Variant:
	var created = _registry.call_tool("docket_create", {"type": "bug", "title": "Short ID test"})
	var full_id: String = created.id
	# Get by 8-char prefix
	var short_prefix := full_id.substr(0, 8)
	var result = _registry.call_tool("docket_get", {"id": short_prefix})
	var r = A.eq(result.get("error", ""), "", "short prefix resolved")
	if r is String: return r
	return A.eq(result.title, "Short ID test", "title matches via short ID")


# -- Lean / Detail response tests --------------------------------------------

func test_query_lean_default() -> Variant:
	# Unfiltered query returns lean {id, title} rows — no description key
	_registry.call_tool("docket_create", {"type": "bug", "title": "Lean bug", "description": "some desc"})
	var result = _registry.call_tool("docket_query", {})
	var r = A.eq(result.items.size(), 1, "one item")
	if r is String: return r
	var item: Dictionary = result.items[0]
	r = A.has_key(item, "id")
	if r is String: return r
	r = A.has_key(item, "title")
	if r is String: return r
	return A.is_true(not item.has("description"), "lean row has no description")


func test_query_filtered_auto_hydrates() -> Variant:
	# Filtered query auto-hydrates — has created_at
	_registry.call_tool("docket_create", {"type": "bug", "title": "Hydrate bug"})
	var result = _registry.call_tool("docket_query", {"filter": {"type": "bug"}})
	var r = A.eq(result.items.size(), 1, "one item")
	if r is String: return r
	var item: Dictionary = result.items[0]
	return A.has_key(item, "created_at")


func test_query_filtered_many_stays_lean() -> Variant:
	# Filtered query with >5 results stays lean (no auto-hydrate)
	for i in range(6):
		_registry.call_tool("docket_create", {"type": "bug", "title": "Bug %d" % i})
	var result = _registry.call_tool("docket_query", {"filter": {"type": "bug"}})
	var r = A.eq(result.items.size(), 6, "six items")
	if r is String: return r
	var item: Dictionary = result.items[0]
	r = A.has_key(item, "title")
	if r is String: return r
	return A.is_true(not item.has("created_at"), "stays lean when >5 results")


func test_query_explicit_full() -> Variant:
	# detail: "full" overrides lean default — has created_at even without filter
	_registry.call_tool("docket_create", {"type": "bug", "title": "Full bug"})
	var result = _registry.call_tool("docket_query", {"detail": "full"})
	var r = A.eq(result.items.size(), 1, "one item")
	if r is String: return r
	var item: Dictionary = result.items[0]
	return A.has_key(item, "created_at")


func test_query_explicit_lean() -> Variant:
	# detail: "lean" overrides auto-hydrate on filtered query
	_registry.call_tool("docket_create", {"type": "bug", "title": "Lean override"})
	var result = _registry.call_tool("docket_query", {"filter": {"type": "bug"}, "detail": "lean"})
	var r = A.eq(result.items.size(), 1, "one item")
	if r is String: return r
	var item: Dictionary = result.items[0]
	r = A.has_key(item, "title")
	if r is String: return r
	return A.is_true(not item.has("created_at"), "lean row has no created_at")


func test_get_without_events() -> Variant:
	# include: [] omits both events and links
	var created = _registry.call_tool("docket_create", {"type": "bug", "title": "No events"})
	var result = _registry.call_tool("docket_get", {"id": created.id, "include": []})
	var r = A.eq(result.get("error", ""), "", "no error")
	if r is String: return r
	r = A.is_true(not result.has("events"), "no events key")
	if r is String: return r
	return A.is_true(not result.has("links"), "no links key")


func test_create_returns_lean() -> Variant:
	# Create returns only {id, type, status, title}
	var result = _registry.call_tool("docket_create", {"type": "bug", "title": "Lean create", "description": "desc"})
	var r = A.has_key(result, "id")
	if r is String: return r
	r = A.has_key(result, "type")
	if r is String: return r
	r = A.has_key(result, "status")
	if r is String: return r
	r = A.has_key(result, "title")
	if r is String: return r
	return A.is_true(not result.has("description"), "no description in create response")


func test_strip_empty_removes_nulls() -> Variant:
	# Unit test for _strip_empty
	var input := {
		"id": "abc123", "type": "bug", "status": "open", "title": "Test",
		"created_at": "2025-01-01", "updated_at": "2025-01-01",
		"description": "", "priority": 0, "tags": [], "resolution": "",
		"environment": "prod",
	}
	var stripped := DocketDB._strip_empty(input)
	var r = A.has_key(stripped, "id")
	if r is String: return r
	r = A.has_key(stripped, "type")
	if r is String: return r
	r = A.has_key(stripped, "created_at")
	if r is String: return r
	# Empty/zero values removed
	r = A.is_true(not stripped.has("description"), "empty string removed")
	if r is String: return r
	r = A.is_true(not stripped.has("priority"), "zero int removed")
	if r is String: return r
	r = A.is_true(not stripped.has("tags"), "empty array removed")
	if r is String: return r
	# Non-empty values kept
	return A.eq(stripped.get("environment", ""), "prod", "non-empty field kept")


# -- Mirror tool tests ---------------------------------------------------------

func test_mirror_push_mode() -> Variant:
	_setup_multi_project()
	# Create a question in alpha
	var c1 = _registry.call_tool("docket_create", {"type": "question", "title": "Q1", "project": "alpha"})
	var target_id: String = c1.id

	# Push explicit field values to the question
	var result = _registry.call_tool("docket_mirror", {
		"source_id": target_id, "source_project": "alpha",
		"target_id": target_id, "target_project": "alpha",
		"fields": {"answer": "42", "findings": "tested"},
	})
	var r = A.eq(result.get("error", ""), "", "no error")
	if r is String: return r
	r = A.has_key(result, "pushed_fields")
	if r is String: return r

	# Verify fields were written
	var item := _db.get_item(target_id)
	r = A.eq(str(item.get("answer", "")), "42", "answer field set")
	if r is String: return r
	return A.eq(str(item.get("findings", "")), "tested", "findings field set")


func test_mirror_pull_mode() -> Variant:
	_setup_multi_project()
	# Create and answer a question in alpha
	var c1 = _registry.call_tool("docket_create", {"type": "question", "title": "Source Q", "project": "alpha"})
	var source_id: String = c1.id
	_registry.call_tool("docket_update", {"id": source_id, "answer": "pulled answer", "findings": "pulled findings"})

	# Create a question in beta
	var c2 = _registry.call_tool("docket_create", {"type": "question", "title": "Target Q", "project": "beta"})
	var target_id: String = c2.id

	# Pull answer and findings from alpha to beta
	var result = _registry.call_tool("docket_mirror", {
		"source_id": source_id, "source_project": "alpha",
		"target_id": target_id, "target_project": "beta",
		"fields": ["answer", "findings"],
	})
	var r = A.eq(result.get("error", ""), "", "no error")
	if r is String: return r

	# Verify values were copied
	var item := _db2.get_item(target_id)
	r = A.eq(str(item.get("answer", "")), "pulled answer", "answer pulled")
	if r is String: return r
	return A.eq(str(item.get("findings", "")), "pulled findings", "findings pulled")


func test_mirror_with_transition() -> Variant:
	_setup_multi_project()
	# Create a question in alpha (initial state: asked)
	var c1 = _registry.call_tool("docket_create", {"type": "question", "title": "Trans Q", "project": "alpha"})
	var target_id: String = c1.id

	# Push with transition (asked -> answered is valid)
	var result = _registry.call_tool("docket_mirror", {
		"source_id": target_id, "source_project": "alpha",
		"target_id": target_id, "target_project": "alpha",
		"fields": {"answer": "transitioned"},
		"transition_to": "answered",
	})
	var r = A.eq(result.get("error", ""), "", "no error")
	if r is String: return r
	r = A.eq(result.get("transitioned_to", ""), "answered", "transition reported")
	if r is String: return r

	# Verify status changed
	var item := _db.get_item(target_id)
	return A.eq(item.status, "answered", "status is answered")


func test_mirror_cross_project() -> Variant:
	_setup_multi_project()
	# Create and populate a question in alpha
	var c1 = _registry.call_tool("docket_create", {"type": "question", "title": "Alpha Q", "project": "alpha"})
	var source_id: String = c1.id
	_registry.call_tool("docket_update", {"id": source_id, "answer": "cross-project answer"})

	# Create a question in beta
	var c2 = _registry.call_tool("docket_create", {"type": "question", "title": "Beta Q", "project": "beta"})
	var target_id: String = c2.id

	# Pull from alpha to beta
	var result = _registry.call_tool("docket_mirror", {
		"source_id": source_id, "source_project": "alpha",
		"target_id": target_id, "target_project": "beta",
		"fields": ["answer"],
	})
	var r = A.eq(result.get("error", ""), "", "no error")
	if r is String: return r

	# Verify field value matches source
	var source_item := _db.get_item(source_id)
	var target_item := _db2.get_item(target_id)
	return A.eq(str(target_item.get("answer", "")), str(source_item.get("answer", "")), "field values match")


func test_mirror_missing_target() -> Variant:
	_setup_multi_project()
	# Create a source item
	var c1 = _registry.call_tool("docket_create", {"type": "question", "title": "Src", "project": "alpha"})
	# Mirror to non-existent target
	var result = _registry.call_tool("docket_mirror", {
		"source_id": c1.id, "source_project": "alpha",
		"target_id": "00000000000000000000000000000000", "target_project": "beta",
		"fields": {"answer": "test"},
	})
	return A.has_key(result, "error")


func test_mirror_audit_comment() -> Variant:
	_setup_multi_project()
	# Create items
	var c1 = _registry.call_tool("docket_create", {"type": "question", "title": "Audit Src", "project": "alpha"})
	var c2 = _registry.call_tool("docket_create", {"type": "question", "title": "Audit Tgt", "project": "beta"})
	var source_id: String = c1.id
	var target_id: String = c2.id

	# Mirror with a note
	_registry.call_tool("docket_mirror", {
		"source_id": source_id, "source_project": "alpha",
		"target_id": target_id, "target_project": "beta",
		"fields": {"answer": "audited"},
		"note": "Vision passthrough confirmed",
	})

	# Verify audit comment exists
	var comments := _db2.list_comments(target_id)
	var r = A.gt(comments.size(), 0, "has comments")
	if r is String: return r
	var found := false
	for c: Dictionary in comments:
		if str(c.get("text", "")).contains("Mirrored from"):
			found = true
			break
	return A.is_true(found, "audit comment contains 'Mirrored from'")


# -- Delete tool tests ---------------------------------------------------------

func test_delete_item() -> Variant:
	var c1 = _registry.call_tool("docket_create", {"type": "bug", "title": "Delete me"})
	var id: String = c1.id
	var result = _registry.call_tool("docket_delete", {"id": id})
	var r = A.eq(result.get("deleted", false), true, "deleted flag")
	if r is String: return r
	r = A.eq(result.get("title", ""), "Delete me", "title returned")
	if r is String: return r
	return A.is_true(not _db.has_item(id), "item removed from db")


func test_delete_terminal_state() -> Variant:
	# Create a chore and move it to terminal state (done)
	var c1 = _registry.call_tool("docket_create", {"type": "chore", "title": "Finished chore"})
	var id: String = c1.id
	_registry.call_tool("docket_transition", {"id": id, "to": "in_progress"})
	_registry.call_tool("docket_transition", {"id": id, "to": "done"})
	# Verify it's in terminal state
	var item := _db.get_item(id)
	var r = A.eq(item.status, "done", "item is in terminal state")
	if r is String: return r
	# Delete should work even in terminal state
	var result = _registry.call_tool("docket_delete", {"id": id})
	r = A.eq(result.get("deleted", false), true, "deleted from terminal state")
	if r is String: return r
	return A.is_true(not _db.has_item(id), "terminal item removed from db")


func test_delete_cascades() -> Variant:
	# Create item with comments and links
	var c1 = _registry.call_tool("docket_create", {"type": "bug", "title": "Cascade bug"})
	var c2 = _registry.call_tool("docket_create", {"type": "rca", "title": "Related RCA"})
	var id: String = c1.id
	_registry.call_tool("docket_comment", {"action": "add", "item_id": id, "text": "test comment"})
	_registry.call_tool("docket_link", {"from": id, "to": c2.id, "relation": "caused_by"})
	# Delete the bug
	_registry.call_tool("docket_delete", {"id": id})
	# Verify cascading cleanup
	var r = A.is_true(not _db.has_item(id), "item gone")
	if r is String: return r
	r = A.eq(_db.list_comments(id).size(), 0, "comments gone")
	if r is String: return r
	return A.eq(_db.get_events(id).size(), 0, "events gone")


func test_delete_missing_item() -> Variant:
	var result = _registry.call_tool("docket_delete", {"id": "00000000000000000000000000000000"})
	return A.has_key(result, "error")


# -- Transition log tests ------------------------------------------------------

func test_transition_log_success() -> Variant:
	var c1 = _registry.call_tool("docket_create", {"type": "chore", "title": "Log test"})
	var id: String = c1.id
	_registry.call_tool("docket_transition", {"id": id, "to": "in_progress"})
	# Check the report has no failures for this transition
	var result = _registry.call_tool("docket_transition_report", {})
	var r = A.has_key(result, "failures")
	if r is String: return r
	# Success was logged but shouldn't appear in failure report
	for entry: Dictionary in result.failures:
		if entry.from_state == "open" and entry.attempted_to == "in_progress" and entry.item_type == "chore":
			return "successful transition should not appear in failure report"
	return true


func test_transition_log_failure() -> Variant:
	var c1 = _registry.call_tool("docket_create", {"type": "chore", "title": "Fail log test"})
	var id: String = c1.id
	# Try an invalid transition
	_registry.call_tool("docket_transition", {"id": id, "to": "done"})
	# Check the report captures the failure
	var result = _registry.call_tool("docket_transition_report", {})
	var r = A.has_key(result, "failures")
	if r is String: return r
	var found := false
	for entry: Dictionary in result.failures:
		if entry.item_type == "chore" and entry.from_state == "open" and entry.attempted_to == "done":
			found = true
			break
	return A.is_true(found, "failed transition logged in report")


# -- MCP error log tests -------------------------------------------------------

func test_error_log_captures_tool_error() -> Variant:
	# Trigger an error: update a non-existent item
	_registry.call_tool("docket_update", {"id": "00000000000000000000000000000000", "title": "nope"})
	# Check the error report
	var result = _registry.call_tool("docket_error_report", {})
	var r = A.has_key(result, "errors")
	if r is String: return r
	var found := false
	for entry: Dictionary in result.errors:
		if entry.tool_name == "docket_update":
			found = true
			break
	return A.is_true(found, "update error logged in report")


func test_error_log_no_false_positives() -> Variant:
	# Successful calls should NOT appear in the error report
	_registry.call_tool("docket_create", {"type": "bug", "title": "Good bug"})
	var result = _registry.call_tool("docket_error_report", {})
	for entry: Dictionary in result.errors:
		if entry.tool_name == "docket_create" and entry.error_message.contains("Good bug"):
			return "successful create should not appear in error report"
	return true


# -- Bug fix: query with project in filter (019cbf1f) -------------------------

func test_query_strips_project_from_filter() -> Variant:
	# Project param inside filter dict should not cause 0 results
	_setup_multi_project()
	_registry.call_tool("docket_create", {"type": "bug", "title": "Alpha bug", "project": "alpha"})
	_registry.call_tool("docket_create", {"type": "dcr", "title": "Alpha dcr", "project": "alpha"})

	# Query with project inside filter (the pattern that triggers the bug)
	var result = _registry.call_tool("docket_query", {
		"filter": {"type": "bug", "project": "alpha"},
		"project": "alpha",
	})
	var r = A.is_true(result.count > 0, "query with project in filter returns results")
	if r is String: return r
	return A.eq(result.count, 1, "only bugs returned, not dcr")


# -- Bug fix: tags on create (019cb9ee) ----------------------------------------

func test_create_with_tags_persists() -> Variant:
	# Creating with tags should persist the item
	var result = _registry.call_tool("docket_create", {
		"type": "bug", "title": "Tagged bug", "tags": ["api", "urgent"]
	})
	var r = A.has_key(result, "id", "create returned id")
	if r is String: return r
	var id: String = result.id

	# Verify item was actually persisted
	var item = _registry.call_tool("docket_get", {"id": id})
	r = A.eq(item.get("error", ""), "", "item found after create")
	if r is String: return r
	r = A.eq(item.title, "Tagged bug", "title matches")
	if r is String: return r
	return A.is_true(item.tags.has("api") and item.tags.has("urgent"), "tags persisted")


func test_create_with_string_tags_coerced() -> Variant:
	# String tags should be coerced to single-element Array
	var result = _registry.call_tool("docket_create", {
		"type": "bug", "title": "String tag bug", "tags": "solo-tag"
	})
	var r = A.has_key(result, "id", "create returned id")
	if r is String: return r
	var item = _registry.call_tool("docket_get", {"id": result.id})
	return A.is_true(item.tags.has("solo-tag"), "string tag coerced to array")


# -- Bug fix: cross-project linking (019cb9c0) ---------------------------------

func test_link_cross_project() -> Variant:
	_setup_multi_project()
	var c1 = _registry.call_tool("docket_create", {"type": "bug", "title": "Alpha item", "project": "alpha"})
	var c2 = _registry.call_tool("docket_create", {"type": "dcr", "title": "Beta item", "project": "beta"})
	var alpha_id: String = c1.id
	var beta_id: String = c2.id

	# Link from alpha to beta using qualified ID
	var result = _registry.call_tool("docket_link", {
		"from": alpha_id, "to": "beta:%s" % beta_id,
		"relation": "caused_by", "project": "alpha"
	})
	var r = A.eq(result.get("error", ""), "", "cross-project link succeeded")
	if r is String: return r
	r = A.eq(result.to, "beta:%s" % beta_id, "qualified ID in response")
	if r is String: return r

	# Verify link stored in alpha DB
	var links := _db.get_links(alpha_id)
	r = A.eq(links.size(), 1, "one link stored")
	if r is String: return r
	return A.eq(links[0].to, "beta:%s" % beta_id, "qualified ID persisted")


func test_link_cross_project_missing_item() -> Variant:
	_setup_multi_project()
	var c1 = _registry.call_tool("docket_create", {"type": "bug", "title": "Alpha item", "project": "alpha"})
	# Try linking to a nonexistent item in beta
	var result = _registry.call_tool("docket_link", {
		"from": c1.id, "to": "beta:NONEXISTENT",
		"relation": "follow_up", "project": "alpha"
	})
	return A.contains(str(result.get("error", "")), "not found", "error for missing cross-project item")


# -- Project management tool tests ----------------------------------------

func _setup_project_management() -> void:
	## Set up multi-project with add/remove callables for project tool testing.
	_setup_multi_project()
	_registry.add_project_fn = func(path: String) -> Dictionary:
		var new_db := DocketDB.create_new(path)
		if not new_db:
			return {"error": "Failed to open: %s" % path}
		var proj_name := path.get_file().get_basename()
		new_db.set_project_name(proj_name)
		_registry._project_dbs[proj_name] = new_db
		return {"name": proj_name, "path": path, "prefix": new_db.get_id_prefix()}
	_registry.remove_project_fn = func(proj_name: String) -> Dictionary:
		if not _registry._project_dbs.has(proj_name):
			return {"error": "Project not found: %s" % proj_name}
		var closing_db: DocketDB = _registry._project_dbs[proj_name]
		closing_db.close()
		_registry._project_dbs.erase(proj_name)
		return {"closed": proj_name, "remaining": _registry._project_dbs.keys()}


func test_project_list() -> Variant:
	_setup_multi_project()
	var result = _registry.call_tool("docket_project_list", {})
	var r = A.has_key(result, "projects")
	if r is String: return r
	r = A.eq(result.count, 2, "two projects listed")
	if r is String: return r
	# Verify project names
	var names: Array = []
	for p in result.projects:
		names.append(p.name)
	r = A.is_true(names.has("alpha"), "alpha in list")
	if r is String: return r
	return A.is_true(names.has("beta"), "beta in list")


func test_project_add() -> Variant:
	_setup_project_management()
	var new_path := _test_dir + "/test_gamma.dct"
	var result = _registry.call_tool("docket_project_add", {"path": new_path, "create": true})
	var r = A.has_key(result, "name")
	if r is String: return r
	r = A.eq(result.name, "test_gamma", "project name derived from filename")
	if r is String: return r
	# Verify it shows in project_list
	var list_result = _registry.call_tool("docket_project_list", {})
	return A.eq(list_result.count, 3, "three projects after add")


func test_project_add_already_loaded() -> Variant:
	_setup_project_management()
	# Try adding alpha's path again
	var result = _registry.call_tool("docket_project_add", {"path": _test_file})
	return A.has_key(result, "error")


func test_project_add_file_not_found() -> Variant:
	_setup_project_management()
	var result = _registry.call_tool("docket_project_add", {"path": "/nonexistent/path.dct"})
	return A.contains(str(result.get("error", "")), "not found", "error for missing file without create")


func test_project_remove() -> Variant:
	_setup_project_management()
	var result = _registry.call_tool("docket_project_remove", {"name": "beta"})
	var r = A.has_key(result, "closed")
	if r is String: return r
	r = A.eq(result.closed, "beta", "beta was removed")
	if r is String: return r
	var list_result = _registry.call_tool("docket_project_list", {})
	return A.eq(list_result.count, 1, "one project after remove")


func test_project_remove_last() -> Variant:
	_setup_multi_project()
	# Remove beta first so only alpha remains
	_registry._project_dbs.erase("beta")
	_db2.close()
	_registry.update_db(_schema, _db, {"alpha": _db})
	var result = _registry.call_tool("docket_project_remove", {"name": "alpha"})
	return A.has_key(result, "error")


func test_project_remove_not_found() -> Variant:
	_setup_project_management()
	var result = _registry.call_tool("docket_project_remove", {"name": "nonexistent"})
	return A.has_key(result, "error")


# -- GUI open tool tests ---------------------------------------------------

func test_gui_open_item() -> Variant:
	_setup_multi_project()
	var c1 = _registry.call_tool("docket_create", {"type": "bug", "title": "Open me", "project": "alpha"})
	var capture := {"id": ""}
	_registry.gui_open_fn = func(request: Dictionary) -> Dictionary:
		capture.id = str(request.get("id", ""))
		return {"opened": "item", "id": capture.id}
	var result = _registry.call_tool("docket_gui_open", {"id": c1.id})
	var r = A.eq(result.get("opened", ""), "item", "opened an item")
	if r is String: return r
	return A.eq(capture.id, c1.id, "callback received correct id")


func test_gui_open_query() -> Variant:
	_setup_multi_project()
	var capture := {"filter": "", "label": ""}
	_registry.gui_open_fn = func(request: Dictionary) -> Dictionary:
		capture.filter = str(request.get("filter", ""))
		capture.label = str(request.get("label", ""))
		return {"opened": "query", "label": capture.label}
	var result = _registry.call_tool("docket_gui_open", {"filter": "{\"type\":\"bug\"}", "label": "All Bugs"})
	var r = A.eq(result.get("opened", ""), "query", "opened a query")
	if r is String: return r
	return A.eq(capture.label, "All Bugs", "callback received label")


func test_gui_open_headless_error() -> Variant:
	_setup_multi_project()
	# gui_open_fn not set — should error
	var result = _registry.call_tool("docket_gui_open", {"id": "nonexistent"})
	return A.has_key(result, "error")


func test_gui_open_missing_item() -> Variant:
	_setup_multi_project()
	_registry.gui_open_fn = func(_request: Dictionary) -> Dictionary:
		return {"opened": "item"}
	var result = _registry.call_tool("docket_gui_open", {"id": "nonexistent_item_id"})
	return A.has_key(result, "error")


func test_gui_open_no_args() -> Variant:
	_setup_multi_project()
	_registry.gui_open_fn = func(_request: Dictionary) -> Dictionary:
		return {}
	var result = _registry.call_tool("docket_gui_open", {})
	return A.has_key(result, "error")


# -- docket_get_state_machine tests --------------------------------------------

func test_get_state_machine_specific_type() -> Variant:
	var result = _registry.call_tool("docket_get_state_machine", {"type": "work_item"})
	var r = A.eq(result.get("error", ""), "", "no error")
	if r is String: return r
	r = A.eq(result.get("type", ""), "work_item", "type field matches")
	if r is String: return r
	r = A.has_key(result, "states")
	if r is String: return r
	r = A.has_key(result, "initial_state")
	if r is String: return r
	r = A.has_key(result, "transitions")
	if r is String: return r
	r = A.eq(result.get("initial_state", ""), "backlog", "initial_state is backlog")
	if r is String: return r
	var states: Array = result.get("states", [])
	r = A.is_true(states.has("backlog"), "states includes backlog")
	if r is String: return r
	r = A.is_true(states.has("done"), "states includes done")
	if r is String: return r
	var transitions: Dictionary = result.get("transitions", {})
	r = A.has_key(transitions, "backlog")
	if r is String: return r
	var backlog_transitions: Array = transitions.get("backlog", [])
	return A.is_true(backlog_transitions.has("open"), "backlog can transition to open")


func test_get_state_machine_invalid_type() -> Variant:
	var result = _registry.call_tool("docket_get_state_machine", {"type": "nonexistent_type"})
	return A.has_key(result, "error")


func test_get_state_machine_all_types() -> Variant:
	var result = _registry.call_tool("docket_get_state_machine", {})
	var r = A.has_key(result, "state_machines")
	if r is String: return r
	var machines: Array = result.get("state_machines", [])
	r = A.is_true(machines.size() > 0, "has at least one state machine")
	if r is String: return r
	# Check each entry has required fields
	for sm in machines:
		r = A.has_key(sm, "type")
		if r is String: return r
		r = A.has_key(sm, "states")
		if r is String: return r
		r = A.has_key(sm, "initial_state")
		if r is String: return r
		r = A.has_key(sm, "transitions")
		if r is String: return r
	# Verify known types are present
	var type_names: Array = []
	for sm in machines:
		type_names.append(sm.get("type", ""))
	r = A.is_true(type_names.has("bug"), "bug type included")
	if r is String: return r
	return A.is_true(type_names.has("work_item"), "work_item type included")


func test_get_state_machine_bug_transitions() -> Variant:
	var result = _registry.call_tool("docket_get_state_machine", {"type": "bug"})
	var r = A.eq(result.get("error", ""), "", "no error")
	if r is String: return r
	r = A.eq(result.get("initial_state", ""), "new", "bug initial state is new")
	if r is String: return r
	var transitions: Dictionary = result.get("transitions", {})
	var closed_transitions: Array = transitions.get("closed", [])
	return A.eq(closed_transitions.size(), 0, "closed is terminal (no outgoing transitions)")
