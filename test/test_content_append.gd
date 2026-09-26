extends Node
## docket_append through the MCP tool layer on a JSONL project.
##
## Oracle: the canonical .dct file on disk, read line by line in this test. Its
## `item` line gives the stored article (top level or inside its `fields`
## envelope); its `content_appended` event lines give the ledger entries (note
## JSON: e, f, o, n, h, q, r); the revision is its event lines counted with the
## W1 KB rule. The SQLite cache, ContentLedger and ItemRevision are never
## consulted for an expectation.

var A := AssertHelpers
const DIR := "user://test_content_append"
const PROJECT := "Appends"

func setup() -> void: DirAccess.make_dir_recursive_absolute(DIR)
func teardown() -> void:
	var directory: DirAccess = DirAccess.open(DIR)
	if directory != null:
		for name in directory.get_files(): directory.remove(name)
	DirAccess.remove_absolute(DIR)

func _path() -> String: return DIR + "/" + PROJECT + ".dct"

func _fresh_db() -> DocketDBJsonl:
	JSONLCache.delete_cache_family(_path())
	if FileAccess.file_exists(_path()): DirAccess.remove_absolute(ProjectSettings.globalize_path(_path()))
	var db: DocketDBJsonl = DocketDBJsonl.create_new_jsonl(_path())
	assert(db != null, "failed to create isolated JSONL fixture")
	db.set_project_name_checked(PROJECT)
	return db

func _tools(db: DocketDBJsonl) -> ToolRegistry:
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var tools: ToolRegistry = ToolRegistry.new(); tools.init(schema, db, {PROJECT:db})
	return tools

## {"article": String, "entries": Array of decoded notes, "revision": int} from the file.
func _on_disk(id: String) -> Dictionary:
	var result: Dictionary = {"article":"", "entries":[], "revision":0}
	for line in FileAccess.get_file_as_string(_path()).split("\n", false):
		var record: Variant = JSON.parse_string(line)
		if not record is Dictionary: continue
		var row: Dictionary = record
		if row.get("_type") == "item" and row.get("id") == id:
			var envelope: Variant = row.get("fields", {})
			var value: Variant = row.get("article", (envelope as Dictionary).get("article", "") if envelope is Dictionary else "")
			result.article = "" if value == null else str(value)
		elif row.get("_type") == "event" and row.get("item_id") == id:
			var kind: String = str(row.get("event_type", ""))
			if kind == "content_appended": result.entries.append(JSON.parse_string(str(row.get("note", ""))))
			if not kind.begins_with("comment_") and not ["linked", "attached", "detached"].has(kind): result.revision += 1
	return result

func _append(tools: ToolRegistry, id: String, text: String, request_id: String, extra: Dictionary = {}) -> Dictionary:
	var args: Dictionary = {"project":PROJECT, "id":id, "field":"article", "text":text, "request_id":request_id}
	args.merge(extra)
	return tools.call_tool("docket_append", args)

func test_append_interleaves_losslessly_dedups_retries_and_honours_if_revision() -> Variant:
	var db: DocketDBJsonl = _fresh_db()
	var tools: ToolRegistry = _tools(db)
	var created: Dictionary = tools.call_tool("docket_create", {"project":PROJECT, "type":"kb", "title":"Log", "article":"Base."})
	if created.has("error"): db.close(); return "fixture create failed: %s" % created.error
	var id: String = created.id

	# Two appenders interleave; every entry lands once, in arrival order, each span hashing to its entry.
	var sent: Array[String] = ["A one", "B one", "A two", "B two"]
	var ids: Array[String] = ["req-a1", "req-b1", "req-a2", "req-b2"]
	var replies: Array = []
	for i in sent.size(): replies.append(_append(tools, id, sent[i], ids[i]))
	var disk: Dictionary = _on_disk(id)
	var expected_body: String = "Base.\n\nA one\n\nB one\n\nA two\n\nB two"
	var r = A.is_true(disk.article == expected_body and disk.entries.size() == 4, "all four entries on disk in order: %s entries=%s replies=%s" % [JSON.stringify(disk.article), disk.entries, replies])
	if r is String: db.close(); return r
	var seen: Dictionary = {}
	for i in 4:
		var entry: Dictionary = disk.entries[i]
		var span: String = str(disk.article).substr(int(entry.o), int(entry.n))
		var reply: Dictionary = replies[i]
		r = A.is_true(span == sent[i] and entry.q == ids[i] and entry.h == sent[i].sha256_text().substr(0, 16) and reply.get("entry_id") == entry.e and int(reply.get("revision", -1)) == int(entry.r) and not seen.has(entry.e), "entry %d matches its text and reply: %s reply=%s" % [i, entry, reply])
		if r is String: db.close(); return r
		seen[entry.e] = true
	var got: Dictionary = tools.call_tool("docket_get", {"project":PROJECT, "id":id})
	var got_fields: Variant = got.get("fields", {})
	var got_article: Variant = got.get("article", (got_fields as Dictionary).get("article", "") if got_fields is Dictionary else "")
	r = A.is_true(int(disk.entries[3].r) == int(disk.revision) and got_article == expected_body, "last entry's revision is the file's revision and docket_get returns the composed body: %s" % got)
	if r is String: db.close(); return r

	# Same request_id and text again: the original entry, deduplicated, nothing written.
	var revision: int = int(disk.revision)
	var retry: Dictionary = _append(tools, id, "B two", "req-b2")
	disk = _on_disk(id)
	r = A.is_true(retry.get("entry_id") == replies[3].get("entry_id") and retry.get("deduplicated") == true and int(retry.get("revision", -1)) == int(replies[3].revision) and disk.entries.size() == 4 and disk.article == expected_body and int(disk.revision) == revision, "retry returns the original entry and writes nothing: %s" % retry)
	if r is String: db.close(); return r

	# Same request_id, different text: refused, nothing written.
	var reused: Dictionary = _append(tools, id, "B two, edited", "req-b2")
	disk = _on_disk(id)
	r = A.is_true(str(reused.get("error", "")) == "request_id already used for different content" and disk.entries.size() == 4 and disk.article == expected_body and int(disk.revision) == revision, "reused request_id with other text refused: %s" % reused)
	if r is String: db.close(); return r

	# A new request_id with a stale if_revision: refused, item unchanged.
	var stale: Dictionary = _append(tools, id, "late", "req-c1", {"if_revision":revision - 1})
	disk = _on_disk(id)
	r = A.is_true(str(stale.get("error", "")) == "stale revision: expected %d, current %d" % [revision - 1, revision] and int(stale.get("revision", -1)) == revision and disk.entries.size() == 4 and disk.article == expected_body and int(disk.revision) == revision, "stale new append refused: %s" % stale)
	if r is String: db.close(); return r

	# The same request_id with the current revision lands; retrying it with the now-stale revision returns the original.
	var fresh: Dictionary = _append(tools, id, "late", "req-c1", {"if_revision":revision})
	var stale_retry: Dictionary = _append(tools, id, "late", "req-c1", {"if_revision":revision})
	disk = _on_disk(id)
	r = A.is_true(not fresh.has("error") and int(fresh.get("revision", -1)) == revision + 1 and stale_retry.get("entry_id") == fresh.get("entry_id") and stale_retry.get("deduplicated") == true and disk.entries.size() == 5 and disk.article == expected_body + "\n\nlate" and int(disk.revision) == revision + 1, "completed append retried with a stale if_revision returns the original, no write: %s %s" % [fresh, stale_retry])
	if r is String: db.close(); return r

	# Dedup is kept in the file: after a whole-field replace and a restart from the file alone,
	# a retry of a removed entry is reported superseded and its text is not re-added.
	tools.call_tool("docket_update", {"project":PROJECT, "id":id, "article":"Rewritten."})
	db.close()
	JSONLCache.delete_cache_family(_path())
	db = DocketDBJsonl.open_jsonl(_path())
	if db == null: return "reopen failed: %s" % DocketDBJsonl.last_open_error
	tools = _tools(db)
	var before: Dictionary = _on_disk(id)
	var after_restart: Dictionary = _append(tools, id, "A one", "req-a1")
	disk = _on_disk(id)
	r = A.is_true(after_restart.get("entry_id") == replies[0].get("entry_id") and after_restart.get("deduplicated") == true and after_restart.get("superseded") == true and disk.article == "Rewritten." and disk.entries.size() == before.entries.size() and int(disk.revision) == int(before.revision), "dedup survives restart and never re-adds removed text: %s" % after_restart)
	db.close(); return r
