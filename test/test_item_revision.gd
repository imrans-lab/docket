extends Node
## Item revision and if_revision through the MCP tool layer on JSONL projects.
##
## Oracle: the canonical .dct file on disk, read line by line in this test.
## Its `item` line gives the stored title/status/parent, and its `event` lines,
## counted with the contract's rule (every event except comment_*, linked,
## attached, detached; W1 KB docket:01a0dc3549bc), give the expected revision.
## Neither the SQLite cache nor ItemRevision is consulted for the expectation.

var A := AssertHelpers
const DIR := "user://test_item_revision"

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

## Reads one item from the canonical file: {"item": Dictionary, "revision": int}.
func _on_disk(db: DocketDBJsonl, id: String) -> Dictionary:
	var result: Dictionary = {"item":{}, "revision":0}
	for line in FileAccess.get_file_as_string(db.get_jsonl_path()).split("\n", false):
		var record: Variant = JSON.parse_string(line)
		if not record is Dictionary: continue
		var row: Dictionary = record
		if row.get("_type") == "item" and row.get("id") == id: result.item = row
		elif row.get("_type") == "event" and row.get("item_id") == id:
			var kind: String = str(row.get("event_type", ""))
			if not kind.begins_with("comment_") and not ["linked", "attached", "detached"].has(kind): result.revision += 1
	return result

func _close(dbs: Array) -> void:
	for db in dbs: (db as DocketDBJsonl).close()

func test_if_revision_refuses_stale_writers_ignores_comments_and_counts_reference_rewrites() -> Variant:
	var source: DocketDBJsonl = _db("RevSource"); var target: DocketDBJsonl = _db("RevTarget")
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var tools: ToolRegistry = ToolRegistry.new(); tools.init(schema, source, {"RevSource":source, "RevTarget":target})
	var parent: Dictionary = tools.call_tool("docket_create", {"project":"RevSource", "type":"work_item", "title":"Parent"})
	var child: Dictionary = tools.call_tool("docket_create", {"project":"RevSource", "type":"work_item", "title":"Child", "parent":"RevSource:%s" % parent.get("id", "")})
	if parent.has("error") or child.has("error"): _close([source, target]); return "fixture create failed: %s %s" % [parent.get("error", ""), child.get("error", "")]
	var id: String = child.id

	# Two readers see the same revision, and it matches the file's event count.
	var reader_a: Dictionary = tools.call_tool("docket_get", {"project":"RevSource", "id":id})
	var reader_b: Dictionary = tools.call_tool("docket_get", {"project":"RevSource", "id":id})
	var read_revision: int = int(reader_a.get("revision", -1))
	var r = A.is_true(read_revision == int(reader_b.get("revision", -2)) and read_revision == int(_on_disk(source, id).revision), "both readers see the on-disk revision %d" % _on_disk(source, id).revision)
	if r is String: _close([source, target]); return r

	# The first writer wins; the second, holding the same read, is refused and writes nothing.
	var first: Dictionary = tools.call_tool("docket_update", {"project":"RevSource", "id":id, "title":"First writer", "if_revision":read_revision})
	var second: Dictionary = tools.call_tool("docket_update", {"project":"RevSource", "id":id, "title":"Second writer", "if_revision":read_revision})
	var disk: Dictionary = _on_disk(source, id)
	r = A.is_true(not first.has("error") and int(first.get("revision", -1)) == read_revision + 1 and str(second.get("error", "")) == "stale revision: expected %d, current %d" % [read_revision, read_revision + 1] and disk.item.get("title") == "First writer" and int(disk.revision) == read_revision + 1, "second writer refused, file holds only the first write: first=%s second=%s disk=%s" % [first, second, disk])
	if r is String: _close([source, target]); return r

	# A stale transition does not move the state.
	var stale_move: Dictionary = tools.call_tool("docket_transition", {"project":"RevSource", "id":id, "to":"open", "if_revision":read_revision})
	disk = _on_disk(source, id)
	r = A.is_true(str(stale_move.get("error", "")).begins_with("stale revision:") and disk.item.get("status") == "backlog" and int(disk.revision) == read_revision + 1, "stale transition refused and status unchanged: %s" % stale_move)
	if r is String: _close([source, target]); return r

	# A comment is evidence, not a mutation: the revision holds and a writer using it still succeeds.
	tools.call_tool("docket_comment", {"project":"RevSource", "action":"add", "item_id":id, "text":"evidence", "author":"tester"})
	var after_comment: Dictionary = tools.call_tool("docket_get", {"project":"RevSource", "id":id})
	var moved_state: Dictionary = tools.call_tool("docket_transition", {"project":"RevSource", "id":id, "to":"open", "if_revision":read_revision + 1})
	r = A.is_true(int(after_comment.get("revision", -1)) == read_revision + 1 and not moved_state.has("error") and _on_disk(source, id).item.get("status") == "open", "comment leaves the revision at %d and a fresh transition applies: %s" % [read_revision + 1, moved_state])
	if r is String: _close([source, target]); return r

	# Moving the parent rewrites the child's parent reference; that rewrite bumps the child's revision.
	var before_rewrite: int = int(_on_disk(source, id).revision)
	var moved: Dictionary = tools.call_tool("docket_move", {"id":parent.id, "source_project":"RevSource", "target_project":"RevTarget"})
	disk = _on_disk(source, id)
	var fetched: Dictionary = tools.call_tool("docket_get", {"project":"RevSource", "id":id})
	r = A.is_true(not moved.has("error") and disk.item.get("parent") == "RevTarget:%s" % moved.get("new_id", "") and int(disk.revision) == before_rewrite + 1 and int(fetched.get("revision", -1)) == before_rewrite + 1, "reference rewrite bumps the child from %d: move=%s disk=%s" % [before_rewrite, moved, disk])
	_close([source, target]); return r
