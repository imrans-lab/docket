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

func _read(tools: ToolRegistry, id: String, cursor: String, limit: int = 2, field: String = "article") -> Dictionary:
	return tools.call_tool("docket_read_since", {"project":PROJECT, "id":id, "field":field, "cursor":cursor, "limit":limit})

## Ledger entries of one field, as decoded from the file.
func _disk_entries(disk: Dictionary, field: String) -> Array:
	return (disk.entries as Array).filter(func(entry: Variant) -> bool: return entry is Dictionary and entry.get("f") == field)

func test_read_since_pages_without_gap_or_overlap_resets_explicitly_and_pages_a_large_article() -> Variant:
	var db: DocketDBJsonl = _fresh_db()
	var tools: ToolRegistry = _tools(db)
	var created: Dictionary = tools.call_tool("docket_create", {"project":PROJECT, "type":"kb", "title":"Paged", "article":"Base."})
	if created.has("error"): db.close(); return "fixture create failed: %s" % created.error
	var id: String = created.id

	# An empty field is an empty page with a usable cursor, not a reset; the next append is read from it.
	var empty: Dictionary = _read(tools, id, "", 2, "description")
	var r = A.is_true(not empty.has("error") and empty.get("reset") == false and (empty.get("entries", [1]) as Array).is_empty() and not str(empty.get("next_cursor", "")).is_empty(), "empty field reads as an empty page: %s" % empty)
	if r is String: db.close(); return r
	_append(tools, id, "D one", "req-d1", {"field":"description"})
	var after_empty: Dictionary = _read(tools, id, str(empty.next_cursor), 2, "description")
	var described: Array = _disk_entries(_on_disk(id), "description")
	r = A.is_true(after_empty.get("reset") == false and after_empty.get("entries", []).size() == 1 and after_empty.entries[0].get("text") == "D one" and after_empty.entries[0].get("entry_id") == described[0].e, "append after an empty-field cursor is returned: %s" % after_empty)
	if r is String: db.close(); return r

	# Five entries read as the base, then pages of 2, 2 and 1 with no gap or overlap, then an empty page.
	for i in 5: _append(tools, id, "Entry %d" % i, "req-p%d" % i)
	var disk: Dictionary = _on_disk(id)
	var logged: Array = _disk_entries(disk, "article")
	var base: Dictionary = _read(tools, id, "", 1)
	r = A.is_true(base.get("entries", []).size() == 1 and base.entries[0].get("entry_id") == null and base.entries[0].get("text") == "Base." and int(base.entries[0].get("offset", -1)) == 0, "cursor \"\" starts with the base: %s" % base)
	if r is String: db.close(); return r
	var cursor: String = str(base.next_cursor)
	var seen: Array = []
	for expected_size in [2, 2, 1]:
		var page: Dictionary = _read(tools, id, cursor, 2)
		r = A.is_true(page.get("reset") == false and page.get("entries", []).size() == expected_size, "page of %d: %s" % [expected_size, page])
		if r is String: db.close(); return r
		seen.append_array(page.entries)
		cursor = str(page.next_cursor)
	for i in 5:
		var entry: Dictionary = logged[i]
		var piece: Dictionary = seen[i]
		r = A.is_true(piece.get("entry_id") == entry.e and int(piece.get("offset", -1)) == int(entry.o) and piece.get("text") == str(disk.article).substr(int(entry.o), int(entry.n)) and piece.get("continued") == false, "entry %d read once, in order: %s vs %s" % [i, piece, entry])
		if r is String: db.close(); return r
	var drained: Dictionary = _read(tools, id, cursor, 2)
	r = A.is_true(not drained.has("error") and drained.get("reset") == false and drained.get("entries", [1]).is_empty() and drained.get("next_cursor") == cursor, "final cursor yields an empty page: %s" % drained)
	if r is String: db.close(); return r

	# A whole-field replace resets the old cursor, naming the replacing revision; cursor "" recovers in one call.
	tools.call_tool("docket_update", {"project":PROJECT, "id":id, "article":"Rewritten."})
	disk = _on_disk(id)
	var stale: Dictionary = _read(tools, id, cursor, 2)
	var recovered: Dictionary = _read(tools, id, "", 2)
	r = A.is_true(stale.get("reset") == true and stale.get("reset_reason") == "rewritten" and int(stale.get("revision", -1)) == int(disk.revision) and stale.get("entries", [1]).is_empty() and recovered.get("reset") == false and recovered.get("entries", []).size() == 1 and recovered.entries[0].get("text") == disk.article, "rewrite resets, \"\" recovers: %s %s" % [stale, recovered])
	if r is String: db.close(); return r

	# Text added after a cursor by a replace rather than an append is an unlogged tail.
	tools.call_tool("docket_update", {"project":PROJECT, "id":id, "article":"Rewritten. And more."})
	var tail: Dictionary = _read(tools, id, str(recovered.next_cursor), 2)
	var other_field: Dictionary = _read(tools, id, str(after_empty.next_cursor), 2)
	var garbage: Dictionary = _read(tools, id, Marshalls.utf8_to_base64("not a cursor"), 2)
	r = A.is_true(tail.get("reset_reason") == "unlogged_tail" and other_field.get("reset_reason") == "malformed" and garbage.get("reset_reason") == "malformed", "unlogged tail and malformed cursors reset: %s %s %s" % [tail, other_field, garbage])
	if r is String: db.close(); return r
	tools.call_tool("docket_delete", {"project":PROJECT, "id":id})
	var gone: Dictionary = _read(tools, id, "", 2)
	r = A.is_true(gone.get("reset") == true and gone.get("reset_reason") == "item_not_found", "deleted item resets: %s" % gone)
	if r is String: db.close(); return r

	# A >1 MB article, including an entry larger than one page, pages under a 64 KiB reply.
	var big: Dictionary = tools.call_tool("docket_create", {"project":PROJECT, "type":"kb", "title":"Big", "article":"Head."})
	if big.has("error"): db.close(); return "fixture create failed: %s" % big.error
	for i in 20: _append(tools, big.id, ("chunk %d " % i) + "abcdefghij".repeat(5200), "req-big%d" % i)
	_append(tools, big.id, "é".repeat(60000), "req-wide")
	var article: String = str(_on_disk(big.id).article)
	r = A.is_true(article.to_utf8_buffer().size() > 1048576, "fixture exceeds 1 MB: %d" % article.to_utf8_buffer().size())
	if r is String: db.close(); return r
	var covered: int = 0
	var next: String = ""
	var pages: int = 0
	while pages < 200:
		var page: Dictionary = _read(tools, big.id, next, 200)
		var reply_bytes: int = JSON.stringify(page).to_utf8_buffer().size()
		r = A.is_true(page.get("reset") == false and reply_bytes < 65536, "page %d under the cap: %d bytes, reset=%s" % [pages, reply_bytes, page.get("reset")])
		if r is String: db.close(); return r
		if (page.entries as Array).is_empty(): break
		for piece in page.entries:
			var offset: int = int(piece.offset)
			var gap_ok: bool = offset == covered or (offset == covered + 2 and article.substr(covered, 2) == "\n\n")
			r = A.is_true(gap_ok and piece.text == article.substr(offset, int(piece.length)), "piece at %d continues from %d and matches the file" % [offset, covered])
			if r is String: db.close(); return r
			covered = offset + int(piece.length)
		next = str(page.next_cursor)
		pages += 1
	r = A.is_true(covered == article.length() and pages > 16, "paging covered the whole article: %d of %d in %d pages" % [covered, article.length(), pages])
	db.close(); return r
