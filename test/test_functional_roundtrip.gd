extends Node
## Functional roundtrip tests covering two scenarios:
## 1. Vault full cycle through MCP tools (create, get, list, update, delete).
## 2. JSONL roundtrip for all item types with all type-specific fields populated.

var A := AssertHelpers
var schema: Dictionary
var db: DocketDB
var registry: ToolRegistry

var _test_dir := "user://test_func_rt"


# -- Setup / teardown ---------------------------------------------------------

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	schema = JSON.parse_string(f.get_as_text())


func _make_db(suffix: String) -> DocketDB:
	var path := _test_dir + "/test_func_rt_%s.dct" % suffix
	_remove_db_files(path)
	var new_db := DocketDB.create_new(path)
	return new_db


func _remove_db_files(path: String) -> void:
	for suffix: String in ["", "-wal", "-shm"]:
		var p := path + suffix
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func before_each() -> void:
	if db:
		db.close()
		db = null
	registry = null


func teardown() -> void:
	if db:
		db.close()
		db = null
	UserPrefs.clear_vault_password()
	_cleanup_dir(_test_dir)
	DirAccess.remove_absolute(_test_dir)


func _cleanup_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		DirAccess.remove_absolute(dir_path + "/" + fname)
		fname = dir.get_next()


func _init_registry(target_db: DocketDB) -> void:
	registry = ToolRegistry.new()
	registry.init(schema, target_db, {"roundtrip-test": target_db})
	registry.add_project_fn = Callable()
	registry.remove_project_fn = Callable()


func _call_tool(tool_name: String, args: Dictionary) -> Dictionary:
	return registry.call_tool(tool_name, args)


# =========================================================================
# 1. VAULT FULL CYCLE
# =========================================================================

func test_vault_full_cycle() -> Variant:
	## Tests the complete lifecycle of a secret through MCP tools:
	## set → get → list → update → get updated → delete → get deleted (error)

	db = _make_db("vault")
	db.set_project_name("roundtrip-test")
	_init_registry(db)

	# Step 1: Set vault password
	UserPrefs.save_vault_password("test-password-123")

	# Step 2: Create secret
	var set_result := _call_tool("docket_secret_set", {
		"handle": "api-key",
		"value": "sk-abc123",
	})
	var r = A.has_key(set_result, "status")
	if r is String: return r
	r = A.eq(set_result.status, "created", "initial set status is 'created'")
	if r is String: return r

	# Step 3: Get secret — verify decrypted value
	var get_result := _call_tool("docket_secret_get", {"handle": "api-key"})
	r = A.has_key(get_result, "value")
	if r is String: return r
	r = A.eq(get_result.value, "sk-abc123", "decrypted value matches original")
	if r is String: return r

	# Step 4: List secrets — verify api-key is listed
	var list_result := _call_tool("docket_secret_list", {})
	r = A.has_key(list_result, "secrets")
	if r is String: return r
	r = A.eq(list_result.secrets.size(), 1, "one secret listed")
	if r is String: return r
	var listed_handle: String = list_result.secrets[0].get("handle", "")
	r = A.eq(listed_handle, "api-key", "api-key is the listed handle")
	if r is String: return r

	# Step 5: Update (rotate) — set a new value for the same handle
	var update_result := _call_tool("docket_secret_set", {
		"handle": "api-key",
		"value": "sk-newvalue",
	})
	r = A.has_key(update_result, "status")
	if r is String: return r
	r = A.eq(update_result.status, "updated", "second set status is 'updated'")
	if r is String: return r

	# Step 6: Get updated value
	var get_updated := _call_tool("docket_secret_get", {"handle": "api-key"})
	r = A.has_key(get_updated, "value")
	if r is String: return r
	r = A.eq(get_updated.value, "sk-newvalue", "updated value decrypts correctly")
	if r is String: return r

	# Step 7: Delete secret
	var delete_result := _call_tool("docket_secret_delete", {"handle": "api-key"})
	r = A.has_key(delete_result, "deleted")
	if r is String: return r
	r = A.is_true(delete_result.deleted, "delete reports success")
	if r is String: return r

	# Step 8: Get deleted secret — must be an error
	var get_deleted := _call_tool("docket_secret_get", {"handle": "api-key"})
	r = A.has_key(get_deleted, "error")
	if r is String: return r

	# Step 9: Clean up vault password
	UserPrefs.save_vault_password("")
	return true


# =========================================================================
# 2. JSONL ROUNDTRIP — ALL ITEM TYPES
# =========================================================================

func test_jsonl_roundtrip_all_types() -> Variant:
	## Creates one item of every type with all type-specific fields, serializes
	## to JSONL, rebuilds the cache from that JSONL, and verifies all fields survive.

	db = _make_db("rt_all")
	db.set_project_name("roundtrip-test")

	var ts := "2026-04-03T12:00:00Z"

	# -- bug ------------------------------------------------------------------
	var bug_id := db.next_uuid7_id()
	var bug_item := DataModel.create_item(schema, "bug", {
		"title": "RT Bug",
		"description": "a critical bug",
		"severity": 1,
		"priority": 2,
		"environment": "production",
		"repro_steps": "1. do thing\n2. see error",
		"resolution": "",
	})
	bug_item.tags = ["backend", "critical"]
	db.insert_item(bug_id, bug_item)

	# -- dcr ------------------------------------------------------------------
	var dcr_id := db.next_uuid7_id()
	var dcr_item := DataModel.create_item(schema, "dcr", {
		"title": "RT DCR",
		"description": "a design change",
		"priority": 1,
	})
	dcr_item.tags = ["design"]
	db.insert_item(dcr_id, dcr_item)

	# -- rca ------------------------------------------------------------------
	var rca_id := db.next_uuid7_id()
	var rca_item := DataModel.create_item(schema, "rca", {
		"title": "RT RCA",
		"occurred_at": "2026-04-01T08:00:00Z",
		"detected_at": "2026-04-01T09:30:00Z",
		"why_chain": "why 1|why 2|why 3",
		"significant_events": "Server restart|Traffic spike",
		"contributing_factors": "Missing retry logic",
	})
	db.insert_item(rca_id, rca_item)

	# -- chore ----------------------------------------------------------------
	var chore_id := db.next_uuid7_id()
	var chore_item := DataModel.create_item(schema, "chore", {
		"title": "RT Chore",
		"description": "clean up temp files",
		"priority": 3,
	})
	db.insert_item(chore_id, chore_item)

	# -- hint -----------------------------------------------------------------
	var hint_id := db.next_uuid7_id()
	var hint_item := DataModel.create_item(schema, "hint", {
		"title": "RT Hint",
		"value": "use --headless flag for test runs",
		"component": "test-runner",
		"key": "run-tests",
		"topic": "testing",
		"subtopic": "cli",
		"confidence": "high",
		"target": "all",
	})
	db.insert_item(hint_id, hint_item)

	# -- insight --------------------------------------------------------------
	var insight_id := db.next_uuid7_id()
	var insight_item := DataModel.create_item(schema, "insight", {
		"title": "RT Insight",
		"assumed": "JSONL is slow to parse",
		"corrected": "JSONL cache makes it O(1)",
		"component": "storage",
		"key": "jsonl-cache",
		"surprise": "Cache rebuild is nearly instant",
		"surfaced_from": "perf profiling",
		"confidence": "high",
		"target": "gpt-5.4",
	})
	db.insert_item(insight_id, insight_item)

	# -- question -------------------------------------------------------------
	var question_id := db.next_uuid7_id()
	var question_item := DataModel.create_item(schema, "question", {
		"title": "RT Question",
		"findings": "researched three approaches",
		"answer": "use the JSONL serializer",
	})
	db.insert_item(question_id, question_item)

	# -- work_item ------------------------------------------------------------
	var work_id := db.next_uuid7_id()
	var work_item := DataModel.create_item(schema, "work_item", {
		"title": "RT Work Item",
		"description": "implement the feature",
		"priority": 2,
		"blocked_by": "external-dep",
	})
	work_item.tags = ["feature"]
	db.insert_item(work_id, work_item)

	# -- test -----------------------------------------------------------------
	var test_id := db.next_uuid7_id()
	var test_item := DataModel.create_item(schema, "test", {
		"title": "RT Test Case",
		"test_setup": "spin up test db",
		"test_steps": "1. insert item\n2. serialize\n3. reload",
		"expected_result": "all fields preserved",
		"component": "jsonl-serializer",
		"environment": "headless",
	})
	db.insert_item(test_id, test_item)

	# -- discussion -----------------------------------------------------------
	var disc_id := db.next_uuid7_id()
	var disc_item := DataModel.create_item(schema, "discussion", {
		"title": "RT Discussion",
		"description": "should we keep the cache layer?",
		"priority": 1,
	})
	disc_item.tags = ["architecture"]
	db.insert_item(disc_id, disc_item)

	# -- skill ----------------------------------------------------------------
	var skill_id := db.next_uuid7_id()
	var skill_item := DataModel.create_item(schema, "skill", {
		"title": "RT Skill",
		"steps": "1. godot --headless --path . -- test\n2. Check exit code for pass/fail",
		"preconditions": "Godot binary on PATH",
		"outcome": "All tests pass with exit code 0",
		"tool_deps": ["docket_query", "docket_get"],
		"optimization": {"context_window": 12000, "tool_budget": 3},
		"component": "test-runner",
	})
	db.insert_item(skill_id, skill_item)

	# -- prompt ---------------------------------------------------------------
	var prompt_id := db.next_uuid7_id()
	var prompt_item := DataModel.create_item(schema, "prompt", {
		"title": "RT Prompt",
		"prompt_text": "Summarize the following bug report: {{text}}",
		"parameters": "text",
		"key": "bug-summary",
		"component": "llm-tools",
		"target": "sonnet",
	})
	db.insert_item(prompt_id, prompt_item)

	# -- kb -------------------------------------------------------------------
	var kb_id := db.next_uuid7_id()
	var kb_item := DataModel.create_item(schema, "kb", {
		"title": "RT KB Article",
		"article": "# JSONL Format\n\nOne JSON object per line...",
		"summary": "Reference for the .dct JSONL format",
		"key": "jsonl-format",
		"component": "storage",
	})
	db.insert_item(kb_id, kb_item)

	# -- policy ---------------------------------------------------------------
	var policy_id := db.next_uuid7_id()
	var policy_item := DataModel.create_item(schema, "policy", {
		"title": "RT Policy",
		"description": "Escalate destructive tools",
		"component": "safety",
		"steps": "1. Detect write operations\n2. Require approval",
		"preconditions": "Tool mutates user state",
		"outcome": "Human approval before writes",
	})
	db.insert_item(policy_id, policy_item)

	# -------------------------------------------------------------------------
	# Serialize to JSONL, write to a temp file, rebuild cache, verify all fields
	# -------------------------------------------------------------------------

	var jsonl_text := JSONLSerializer.serialize_all(db)
	var r = A.is_true(jsonl_text.length() > 0, "serialized JSONL is non-empty")
	if r is String: return r

	var jsonl_path := _test_dir + "/rt_all_verify.dct"
	var f := FileAccess.open(jsonl_path, FileAccess.WRITE)
	r = A.not_null(f, "opened JSONL file for writing")
	if r is String: return r
	f.store_string(jsonl_text)
	f.close()

	var cache_path := jsonl_path + ".cache"
	var db2 := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	r = A.not_null(db2, "cache rebuilt from serialized JSONL")
	if r is String: return r

	# -- Verify bug -----------------------------------------------------------
	var bug2 := db2.get_item(bug_id)
	r = A.eq(bug2.get("type", ""), "bug", "bug: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(bug2.get("title", ""), "RT Bug", "bug: title preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(bug2.get("description", ""), "a critical bug", "bug: description preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(int(bug2.get("severity", 0)), 1, "bug: severity preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(int(bug2.get("priority", 0)), 2, "bug: priority preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(bug2.get("environment", ""), "production", "bug: environment preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(bug2.get("repro_steps", "").contains("do thing"), "bug: repro_steps preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(bug2.get("tags", []).has("backend"), "bug: tags preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify dcr -----------------------------------------------------------
	var dcr2 := db2.get_item(dcr_id)
	r = A.eq(dcr2.get("type", ""), "dcr", "dcr: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(dcr2.get("description", ""), "a design change", "dcr: description preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(int(dcr2.get("priority", 0)), 1, "dcr: priority preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify rca -----------------------------------------------------------
	var rca2 := db2.get_item(rca_id)
	r = A.eq(rca2.get("type", ""), "rca", "rca: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(rca2.get("occurred_at", ""), "2026-04-01T08:00:00Z", "rca: occurred_at preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(rca2.get("detected_at", ""), "2026-04-01T09:30:00Z", "rca: detected_at preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(rca2.get("why_chain", "").contains("why 1"), "rca: why_chain preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(rca2.get("significant_events", "").contains("Traffic spike"), "rca: significant_events preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(rca2.get("contributing_factors", "").contains("retry"), "rca: contributing_factors preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify chore ---------------------------------------------------------
	var chore2 := db2.get_item(chore_id)
	r = A.eq(chore2.get("type", ""), "chore", "chore: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(int(chore2.get("priority", 0)), 3, "chore: priority preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify hint ----------------------------------------------------------
	var hint2 := db2.get_item(hint_id)
	r = A.eq(hint2.get("type", ""), "hint", "hint: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(hint2.get("value", ""), "use --headless flag for test runs", "hint: value preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(hint2.get("component", ""), "test-runner", "hint: component preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(hint2.get("key", ""), "run-tests", "hint: key preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(hint2.get("topic", ""), "testing", "hint: topic preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(hint2.get("subtopic", ""), "cli", "hint: subtopic preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(hint2.get("confidence", ""), "high", "hint: confidence preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(hint2.get("target", ""), "all", "hint: target preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify insight -------------------------------------------------------
	var insight2 := db2.get_item(insight_id)
	r = A.eq(insight2.get("type", ""), "insight", "insight: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(insight2.get("assumed", ""), "JSONL is slow to parse", "insight: assumed preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(insight2.get("corrected", ""), "JSONL cache makes it O(1)", "insight: corrected preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(insight2.get("surprise", "").contains("instant"), "insight: surprise preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(insight2.get("surfaced_from", ""), "perf profiling", "insight: surfaced_from preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(insight2.get("confidence", ""), "high", "insight: confidence preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(insight2.get("component", ""), "storage", "insight: component preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(insight2.get("key", ""), "jsonl-cache", "insight: key preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(insight2.get("target", ""), "gpt-5.4", "insight: target preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify question -------------------------------------------------------
	var question2 := db2.get_item(question_id)
	r = A.eq(question2.get("type", ""), "question", "question: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(question2.get("findings", "").contains("three approaches"), "question: findings preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(question2.get("answer", "").contains("JSONL serializer"), "question: answer preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify work_item -----------------------------------------------------
	var work2 := db2.get_item(work_id)
	r = A.eq(work2.get("type", ""), "work_item", "work_item: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(work2.get("description", ""), "implement the feature", "work_item: description preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(int(work2.get("priority", 0)), 2, "work_item: priority preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(work2.get("blocked_by", ""), "external-dep", "work_item: blocked_by preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(work2.get("tags", []).has("feature"), "work_item: tags preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify test ----------------------------------------------------------
	var test2 := db2.get_item(test_id)
	r = A.eq(test2.get("type", ""), "test", "test: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(test2.get("test_setup", "").contains("test db"), "test: test_setup preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(test2.get("test_steps", "").contains("serialize"), "test: test_steps preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(test2.get("expected_result", "").contains("preserved"), "test: expected_result preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(test2.get("component", ""), "jsonl-serializer", "test: component preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(test2.get("environment", ""), "headless", "test: environment preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify discussion ----------------------------------------------------
	var disc2 := db2.get_item(disc_id)
	r = A.eq(disc2.get("type", ""), "discussion", "discussion: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(disc2.get("description", "").contains("cache layer"), "discussion: description preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(int(disc2.get("priority", 0)), 1, "discussion: priority preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(disc2.get("tags", []).has("architecture"), "discussion: tags preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify skill ---------------------------------------------------------
	var skill2 := db2.get_item(skill_id)
	r = A.eq(skill2.get("type", ""), "skill", "skill: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(skill2.get("steps", "").contains("godot --headless"), "skill: steps preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(skill2.get("outcome", "").contains("exit code"), "skill: outcome preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(skill2.get("preconditions", "").contains("Godot"), "skill: preconditions preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(skill2.get("preconditions", "").contains("PATH"), "skill: preconditions preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(skill2.get("component", ""), "test-runner", "skill: component preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(skill2.get("tool_deps", []).size(), 2, "skill: tool_deps preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(int(skill2.get("optimization", {}).get("tool_budget", 0)), 3, "skill: optimization preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify prompt --------------------------------------------------------
	var prompt2 := db2.get_item(prompt_id)
	r = A.eq(prompt2.get("type", ""), "prompt", "prompt: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(prompt2.get("prompt_text", "").contains("{{text}}"), "prompt: prompt_text preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(prompt2.get("parameters", ""), "text", "prompt: parameters preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(prompt2.get("component", ""), "llm-tools", "prompt: component preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(prompt2.get("key", ""), "bug-summary", "prompt: key preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(prompt2.get("target", ""), "sonnet", "prompt: target preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify kb ------------------------------------------------------------
	var kb2 := db2.get_item(kb_id)
	r = A.eq(kb2.get("type", ""), "kb", "kb: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(kb2.get("article", "").contains("JSONL Format"), "kb: article preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(kb2.get("summary", "").contains(".dct"), "kb: summary preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(kb2.get("key", ""), "jsonl-format", "kb: key preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(kb2.get("component", ""), "storage", "kb: component preserved")
	if r is String:
		db2.close()
		return r

	# -- Verify policy --------------------------------------------------------
	var policy2 := db2.get_item(policy_id)
	r = A.eq(policy2.get("type", ""), "policy", "policy: type preserved")
	if r is String:
		db2.close()
		return r
	r = A.eq(policy2.get("component", ""), "safety", "policy: component preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(policy2.get("steps", "").contains("Require approval"), "policy: steps preserved")
	if r is String:
		db2.close()
		return r
	r = A.is_true(policy2.get("outcome", "").contains("Human approval"), "policy: outcome preserved")
	if r is String:
		db2.close()
		return r

	db2.close()
	return true
