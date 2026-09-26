extends Node
## Claims on protected fields through the MCP tool layer on a JSONL project.
##
## Oracle: the canonical .dct file on disk, read line by line in this test. Its
## `item` line gives the stored fields; its `event` lines give the claim
## history (claimed / claim_released / claim_reassigned, with actor and note)
## and the revision, counted with the W1 KB rule. The SQLite cache, ItemClaim
## and ItemRevision are never consulted for an expectation.

var A := AssertHelpers
const DIR := "user://test_item_claim"
const CLAIM_EVENTS := ["claimed", "claim_released", "claim_reassigned"]

func setup() -> void: DirAccess.make_dir_recursive_absolute(DIR)
func teardown() -> void:
	var directory: DirAccess = DirAccess.open(DIR)
	if directory != null:
		for name in directory.get_files(): directory.remove(name)
	DirAccess.remove_absolute(DIR)

func _path() -> String: return DIR + "/Claims.dct"

func _fresh_db() -> DocketDBJsonl:
	JSONLCache.delete_cache_family(_path())
	if FileAccess.file_exists(_path()): DirAccess.remove_absolute(ProjectSettings.globalize_path(_path()))
	var db: DocketDBJsonl = DocketDBJsonl.create_new_jsonl(_path())
	assert(db != null, "failed to create isolated JSONL fixture")
	db.set_project_name_checked("Claims")
	return db

func _tools(db: DocketDBJsonl) -> ToolRegistry:
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var tools: ToolRegistry = ToolRegistry.new(); tools.init(schema, db, {"Claims":db})
	return tools

## {"item": Dictionary, "claims": Array of event rows, "revision": int} from the file.
func _on_disk(id: String) -> Dictionary:
	var result: Dictionary = {"item":{}, "claims":[], "revision":0}
	for line in FileAccess.get_file_as_string(_path()).split("\n", false):
		var record: Variant = JSON.parse_string(line)
		if not record is Dictionary: continue
		var row: Dictionary = record
		if row.get("_type") == "item" and row.get("id") == id: result.item = row
		elif row.get("_type") == "event" and row.get("item_id") == id:
			var kind: String = str(row.get("event_type", ""))
			if CLAIM_EVENTS.has(kind): result.claims.append(row)
			if not kind.begins_with("comment_") and not ["linked", "attached", "detached"].has(kind): result.revision += 1
	return result

func test_claim_gates_protected_fields_reassign_overrides_with_audit_and_survives_restart() -> Variant:
	var db: DocketDBJsonl = _fresh_db()
	var tools: ToolRegistry = _tools(db)
	var created: Dictionary = tools.call_tool("docket_create", {"project":"Claims", "type":"work_item", "title":"Task", "tags":["wr:task"]})
	if created.has("error"): db.close(); return "fixture create failed: %s" % created.error
	var id: String = created.id

	# A claims; the file records exactly one claimed event with actor A.
	var claimed: Dictionary = tools.call_tool("docket_claim", {"project":"Claims", "id":id, "holder":"agent-A"})
	var disk: Dictionary = _on_disk(id)
	var r = A.is_true(not claimed.has("error") and disk.claims.size() == 1 and disk.claims[0].get("event_type") == "claimed" and disk.claims[0].get("actor") == "agent-A", "A's claim is on disk: %s %s" % [claimed, disk.claims])
	if r is String: db.close(); return r

	# B's protected writes are refused naming A (field, protected tag namespace, transition); B's unprotected writes land.
	var b_title: Dictionary = tools.call_tool("docket_update", {"project":"Claims", "id":id, "holder":"agent-B", "title":"B was here"})
	var b_tag: Dictionary = tools.call_tool("docket_update", {"project":"Claims", "id":id, "holder":"agent-B", "tags":[]})
	var b_move: Dictionary = tools.call_tool("docket_transition", {"project":"Claims", "id":id, "holder":"agent-B", "to":"open"})
	var b_open: Dictionary = tools.call_tool("docket_update", {"project":"Claims", "id":id, "holder":"agent-B", "priority":1, "tags":["wr:task", "test:passed"]})
	disk = _on_disk(id)
	r = A.is_true(str(b_title.get("error", "")) == "not the holder: agent-A" and str(b_tag.get("error", "")) == "not the holder: agent-A" and str(b_move.get("error", "")) == "not the holder: agent-A" and not b_open.has("error") and disk.item.get("title") == "Task" and disk.item.get("status") == "backlog" and int(disk.item.get("priority", 0)) == 1 and (disk.item.get("tags", []) as Array).has("test:passed"), "B refused on protected, allowed on unprotected: %s %s %s %s item=%s" % [b_title, b_tag, b_move, b_open, disk.item])
	if r is String: db.close(); return r

	# A reads: no claim event is written and the revision does not move.
	var before_read: Dictionary = _on_disk(id)
	var a_read: Dictionary = tools.call_tool("docket_get", {"project":"Claims", "id":id})
	disk = _on_disk(id)
	r = A.is_true(a_read.get("claim_holder") == "agent-A" and disk.claims.size() == before_read.claims.size() and int(disk.revision) == int(before_read.revision), "docket_get neither creates nor refreshes a claim: before=%s after=%s" % [before_read.claims, disk.claims])
	if r is String: db.close(); return r

	# The owner overrides: refused without override=true, then reassigned to B with a reason.
	var no_flag: Dictionary = tools.call_tool("docket_reassign", {"project":"Claims", "id":id, "actor":"human:owner", "to":"agent-B", "reason":"A stalled"})
	var reassigned: Dictionary = tools.call_tool("docket_reassign", {"project":"Claims", "id":id, "actor":"human:owner", "to":"agent-B", "reason":"A stalled", "override":true})
	disk = _on_disk(id)
	var last: Dictionary = disk.claims[disk.claims.size() - 1]
	var audit: Variant = JSON.parse_string(str(last.get("note", "")))
	r = A.is_true(str(no_flag.get("error", "")).begins_with("not the holder: agent-A") and not reassigned.has("error") and last.get("event_type") == "claim_reassigned" and last.get("actor") == "human:owner" and audit is Dictionary and audit.get("reason") == "A stalled" and audit.get("from") == "agent-A" and audit.get("to") == "agent-B" and audit.get("override") == true, "override recorded with actor and reason: %s %s last=%s" % [no_flag, reassigned, last])
	if r is String: db.close(); return r

	# A's next protected write is refused naming B; B's succeeds.
	var a_after: Dictionary = tools.call_tool("docket_update", {"project":"Claims", "id":id, "holder":"agent-A", "title":"A again"})
	var b_after: Dictionary = tools.call_tool("docket_update", {"project":"Claims", "id":id, "holder":"agent-B", "title":"B owns it"})
	disk = _on_disk(id)
	r = A.is_true(str(a_after.get("error", "")) == "not the holder: agent-B" and not b_after.has("error") and disk.item.get("title") == "B owns it", "prior holder invalidated: %s %s" % [a_after, b_after])
	if r is String: db.close(); return r

	# Restart: drop the cache, reopen from the file with a new tool layer. The claim still holds.
	db.close()
	JSONLCache.delete_cache_family(_path())
	db = DocketDBJsonl.open_jsonl(_path())
	if db == null: return "reopen failed: %s" % DocketDBJsonl.last_open_error
	tools = _tools(db)
	var a_restart: Dictionary = tools.call_tool("docket_transition", {"project":"Claims", "id":id, "holder":"agent-A", "to":"open"})
	var b_restart: Dictionary = tools.call_tool("docket_transition", {"project":"Claims", "id":id, "holder":"agent-B", "to":"open"})
	disk = _on_disk(id)
	r = A.is_true(str(a_restart.get("error", "")) == "not the holder: agent-B" and not b_restart.has("error") and disk.item.get("status") == "open", "claim survives restart: %s %s" % [a_restart, b_restart])
	db.close(); return r
