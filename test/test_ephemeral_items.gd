extends Node
## Ephemeral items in a file-backed project (ItemStorage): creating one, linking
## a durable item to it and commenting on it write nothing; keeping it through
## docket_promote with to_project omitted writes it, with the same id and a
## "promoted" event; dropping one that a durable item links to writes nothing
## and leaves no link behind.
##
## Oracle: files only, plus one public read of the cache. The canonical's
## sha256 after a forced full settle (flush_checked rewrites the canonical from
## the cache) against its sha256 before any ephemeral work; the sidecar file's
## existence and line count; JSONLParser.parse_file over the settled canonical
## for the kept item, its events, comment and incoming link; and the durable
## item's links (get_links) after the drop, before and after a cache rebuild.

var A := AssertHelpers
const DIR := "user://test_ephemeral_items"
const FIXTURE := "res://test/fixtures/dynamic_types_record_order_v2.jsonl"


func setup() -> void: DirAccess.make_dir_recursive_absolute(DIR)
func teardown() -> void:
	var dir := DirAccess.open(DIR)
	if dir != null:
		for name in dir.get_files(): dir.remove(name)
	DirAccess.remove_absolute(DIR)


func _sidecar_lines(path: String) -> int:
	var sidecar := path + ".log"
	if not FileAccess.file_exists(sidecar): return 0
	return FileAccess.get_file_as_string(sidecar).split("\n", false).size()


func _records_of(parsed: Dictionary, bucket: String, key: String, id: String) -> Array:
	return parsed[bucket].filter(func(record: Dictionary) -> bool: return str(record.get(key, "")) == id)


func test_ephemeral_items_are_never_written_until_kept() -> Variant:
	var path := DIR + "/ephemeral.dct"
	var out := FileAccess.open(path, FileAccess.WRITE); out.store_string(FileAccess.get_file_as_string(FIXTURE)); out.close()
	var db := DocketDBJsonl.open_jsonl(path)
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	# Baseline: the serializer's own form of the fixture.
	var r = A.eq(db.flush_checked(), "", "baseline settle")
	if r is String: db.close(); return r
	var baseline_sha := FileAccess.get_sha256(path)

	# An explicit ephemeral item and a wr:attempt item (ephemeral by default);
	# a durable item links to the first, which then gets a comment.
	var registry := TypeRegistry.for_db(db, db.get_project_name())
	var explicit := registry.create_item({"type": "widget", "title": "ephemeral-probe", "storage": "ephemeral"}, "tester")
	var attempt := registry.create_item({"type": "widget", "title": "attempt-probe", "tags": ["wr:attempt"]}, "tester")
	r = A.is_true(not explicit.has("error") and not attempt.has("error"), "both creates succeed (%s / %s)" % [explicit.get("error", ""), attempt.get("error", "")])
	if r is String: db.close(); return r
	var eph_id := str(explicit.id)
	var attempt_id := str(attempt.id)
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var linked := DocketLink.new().execute({"from": "ORD-0001", "to": eph_id, "relation": "follow_up"}, schema, db, {})
	var linked_attempt := DocketLink.new().execute({"from": "ORD-0001", "to": attempt_id, "relation": "blocks"}, schema, db, {})
	var commented := str(db.add_comment(eph_id, "tester", "ephemeral-comment-probe").get("error", ""))
	r = A.is_true(not linked.has("error") and not linked_attempt.has("error") and commented.is_empty(), "links and comment succeed (%s / %s / %s)" % [linked.get("error", ""), linked_attempt.get("error", ""), commented])
	if r is String: db.close(); return r

	# Nothing journaled, and a full rewrite from the cache reproduces the baseline.
	r = A.is_true(not FileAccess.file_exists(path + ".log") and FileAccess.get_sha256(path) == baseline_sha, "ephemeral work leaves no sidecar and the canonical untouched")
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "forced settle")
	if r is String: db.close(); return r
	r = A.is_true(FileAccess.get_sha256(path) == baseline_sha and not FileAccess.file_exists(path + ".log"), "a full settle writes the same bytes: no item, link, comment, event or counter change")
	if r is String: db.close(); return r

	# The cache is rebuilt from the files; the ephemeral rows are carried over,
	# which the keep below can only succeed on if they were.
	r = A.is_true(db.reload(), "cache rebuild")
	if r is String: db.close(); return r

	# Keep through the MCP verb: journaled at once, written on settle with the same id.
	var project := db.get_project_name()
	var kept := DocketPromote.new().execute({"items": [eph_id], "source_project": project, "promoted_by": "tester"}, schema, db, {project: db})
	r = A.eq(kept, {"project": project, "kept": [eph_id]}, "docket_promote with no to_project keeps the item")
	if r is String: db.close(); return r
	r = A.is_true(_sidecar_lines(path) == 1 and FileAccess.get_sha256(path) == baseline_sha, "keep journals one record and leaves the canonical until the settle")
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle after keep")
	if r is String: db.close(); return r
	var parsed := JSONLParser.parse_file(path)
	r = A.eq(str(parsed.get("error", "")), "", "settled canonical parses")
	if r is String: db.close(); return r
	var items := _records_of(parsed, "items", "id", eph_id)
	var event_types: Array = _records_of(parsed, "events", "item_id", eph_id).map(func(event: Dictionary) -> String: return str(event.event_type))
	var comments := _records_of(parsed, "comments", "item_id", eph_id)
	var links := _records_of(parsed, "links", "to_id", eph_id)
	r = A.is_true(items.size() == 1 and str(items[0].title) == "ephemeral-probe", "the kept item is in the canonical under its id")
	if r is String: db.close(); return r
	r = A.is_true(event_types.has("created") and event_types.has("linked") and event_types.has("promoted"), "its history is written with a promoted event: %s" % str(event_types))
	if r is String: db.close(); return r
	r = A.is_true(comments.size() == 1 and str(comments[0].text) == "ephemeral-comment-probe", "its comment is written")
	if r is String: db.close(); return r
	r = A.is_true(links.size() == 1 and str(links[0].from_id) == "ORD-0001" and str(links[0].relation) == "follow_up", "the durable item's link to it is written")
	if r is String: db.close(); return r
	r = A.is_true(_records_of(parsed, "items", "id", attempt_id).is_empty() and not FileAccess.get_file_as_string(path).contains(attempt_id), "the wr:attempt item is still unwritten")
	if r is String: db.close(); return r

	# Drop: the remaining ephemeral item, which ORD-0001 links to, goes without
	# touching the files, and its incoming link goes with it.
	var kept_sha := FileAccess.get_sha256(path)
	r = A.eq(ItemStorage.drop(db, attempt_id), "", "drop succeeds")
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle after drop")
	if r is String: db.close(); return r
	r = A.is_true(FileAccess.get_sha256(path) == kept_sha and not FileAccess.file_exists(path + ".log"), "dropping a linked ephemeral item changes no bytes")
	if r is String: db.close(); return r
	var link_targets := func() -> Array: return db.get_links("ORD-0001").map(func(link: Dictionary) -> String: return str(link.to))
	r = A.is_true(not link_targets.call().has(attempt_id), "the cache holds no link to the dropped item: %s" % str(link_targets.call()))
	if r is String: db.close(); return r
	r = A.is_true(db.reload(), "cache rebuild after drop")
	if r is String: db.close(); return r
	var after_reload: Array = link_targets.call()
	db.close()
	return A.is_true(not after_reload.has(attempt_id) and after_reload.has(eph_id), "after a rebuild the dropped item's link is still gone and the kept one's remains: %s" % str(after_reload))


## Two ephemeral items that name each other in blocked_by: keeping one alone is
## refused; keeping both in one docket_promote succeeds.
## Oracle: the settled canonical (JSONLParser.parse_file) holds both items with
## blocked_by naming the other.
func test_mutually_referencing_ephemeral_items_keep_together() -> Variant:
	var path := DIR + "/mutual.dct"
	var out := FileAccess.open(path, FileAccess.WRITE); out.store_string(FileAccess.get_file_as_string(FIXTURE)); out.close()
	var db := DocketDBJsonl.open_jsonl(path)
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var registry := TypeRegistry.for_db(db, db.get_project_name())
	var first := registry.create_item({"type": "widget", "title": "mutual-first", "storage": "ephemeral"}, "tester")
	var second := registry.create_item({"type": "widget", "title": "mutual-second", "storage": "ephemeral"}, "tester")
	var r = A.is_true(not first.has("error") and not second.has("error"), "both creates succeed (%s / %s)" % [first.get("error", ""), second.get("error", "")])
	if r is String: db.close(); return r
	var first_id := str(first.id)
	var second_id := str(second.id)
	r = A.is_true(db.update_item_fields_checked(first_id, {"blocked_by": second_id}).is_empty() and db.update_item_fields_checked(second_id, {"blocked_by": first_id}).is_empty(), "each ephemeral item names the other")
	if r is String: db.close(); return r

	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var project := db.get_project_name()
	var alone := DocketPromote.new().execute({"items": [first_id], "source_project": project, "promoted_by": "tester"}, schema, db, {project: db})
	r = A.is_true(alone.has("error") and ItemStorage.is_ephemeral(db, first_id), "keeping one alone is refused: %s" % str(alone))
	if r is String: db.close(); return r
	var together := DocketPromote.new().execute({"items": [first_id, second_id], "source_project": project, "promoted_by": "tester"}, schema, db, {project: db})
	r = A.eq(together, {"project": project, "kept": [first_id, second_id]}, "keeping both together succeeds")
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle after keep")
	db.close()
	if r is String: return r
	var parsed := JSONLParser.parse_file(path)
	var blocked_by := {}
	for id in [first_id, second_id]:
		for record: Dictionary in _records_of(parsed, "items", "id", id): blocked_by[id] = str(record.get("blocked_by", ""))
	return A.eq(blocked_by, {first_id: second_id, second_id: first_id}, "both items are written, each blocked_by the other")


func _open_fixture(name: String) -> DocketDBJsonl:
	var path := DIR + "/" + name
	var out := FileAccess.open(path, FileAccess.WRITE); out.store_string(FileAccess.get_file_as_string(FIXTURE)); out.close()
	return DocketDBJsonl.open_jsonl(path)


## A batch keep is validated as a whole before anything is kept: [A, B] where B
## is blocked_by an ephemeral C outside the batch is refused.
## Oracle: the settled canonical's bytes and JSONLParser.parse_file hold none
## of the three.
func test_batch_keep_with_an_outside_ephemeral_reference_keeps_nothing() -> Variant:
	var db := _open_fixture("batch.dct")
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var path := DIR + "/batch.dct"
	var registry := TypeRegistry.for_db(db, db.get_project_name())
	var ids: Array = []
	for title in ["batch-a", "batch-b", "batch-c"]:
		var created := registry.create_item({"type": "widget", "title": title, "storage": "ephemeral"}, "tester")
		if created.has("error"): db.close(); return "create %s: %s" % [title, created.error]
		ids.append(str(created.id))
	var r = A.is_true(db.update_item_fields_checked(ids[0], {"blocked_by": ids[1]}).is_empty() and db.update_item_fields_checked(ids[1], {"blocked_by": ids[2]}).is_empty(), "A names B and B names C")
	if r is String: db.close(); return r
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var project := db.get_project_name()
	var kept := DocketPromote.new().execute({"items": [ids[0], ids[1]], "source_project": project, "promoted_by": "tester"}, schema, db, {project: db})
	r = A.is_true(kept.has("error") and str(kept.error).contains(ids[1]) and str(kept.error).contains(ids[2]), "the batch is refused naming B and C: %s" % str(kept))
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle after the refusal")
	db.close()
	if r is String: return r
	var text := FileAccess.get_file_as_string(path)
	var parsed := JSONLParser.parse_file(path)
	r = A.eq(str(parsed.get("error", "")), "", "settled canonical parses")
	if r is String: return r
	for id: String in ids:
		if text.contains(id) or not _records_of(parsed, "items", "id", id).is_empty(): return "item %s reached the canonical" % id
	return true


## Keeping two ephemeral items in one docket_promote is one canonical mutation.
## Oracle: the sidecar file gains exactly one line; after a settle
## JSONLParser.parse_file holds each item once.
func test_batch_keep_is_one_journal_record() -> Variant:
	var db := _open_fixture("one_record.dct")
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var path := DIR + "/one_record.dct"
	var registry := TypeRegistry.for_db(db, db.get_project_name())
	var ids: Array = []
	for title in ["record-a", "record-b"]:
		var created := registry.create_item({"type": "widget", "title": title, "storage": "ephemeral"}, "tester")
		if created.has("error"): db.close(); return "create %s: %s" % [title, created.error]
		ids.append(str(created.id))
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var project := db.get_project_name()
	var before := _sidecar_lines(path)
	var kept := DocketPromote.new().execute({"items": ids, "source_project": project, "promoted_by": "tester"}, schema, db, {project: db})
	var r = A.eq(kept, {"project": project, "kept": ids}, "the batch is kept")
	if r is String: db.close(); return r
	r = A.eq(_sidecar_lines(path) - before, 1, "the batch adds one sidecar line")
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle after keep")
	db.close()
	if r is String: return r
	var parsed := JSONLParser.parse_file(path)
	r = A.eq(str(parsed.get("error", "")), "", "settled canonical parses")
	if r is String: return r
	for id: String in ids:
		if _records_of(parsed, "items", "id", id).size() != 1: return "item %s is not in the canonical once" % id
	return true


## Ephemeral A links to ephemeral B; B is dropped, then A is kept.
## Oracle: the settled canonical's bytes hold no byte of B's id, and
## JSONLParser.parse_file holds A with no link.
func test_dropped_link_target_leaves_no_history() -> Variant:
	var db := _open_fixture("dropped_target.dct")
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var path := DIR + "/dropped_target.dct"
	var registry := TypeRegistry.for_db(db, db.get_project_name())
	var source := registry.create_item({"type": "widget", "title": "drop-source", "storage": "ephemeral"}, "tester")
	var target := registry.create_item({"type": "widget", "title": "drop-target", "storage": "ephemeral"}, "tester")
	var r = A.is_true(not source.has("error") and not target.has("error"), "both creates succeed")
	if r is String: db.close(); return r
	var a_id := str(source.id)
	var b_id := str(target.id)
	var project := db.get_project_name()
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var linked := DocketLink.new().execute({"from": a_id, "to": b_id, "relation": "follow_up"}, schema, db, {project: db})
	r = A.is_true(not linked.has("error"), "the link succeeds: %s" % str(linked))
	if r is String: db.close(); return r
	r = A.eq(ItemStorage.drop(db, b_id), "", "dropping the target succeeds")
	if r is String: db.close(); return r
	var kept := DocketPromote.new().execute({"items": [a_id], "source_project": project, "promoted_by": "tester"}, schema, db, {project: db})
	r = A.eq(kept, {"project": project, "kept": [a_id]}, "keeping the source succeeds")
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle after keep")
	db.close()
	if r is String: return r
	r = A.is_true(not FileAccess.get_file_as_string(path).contains(b_id), "nothing written names the dropped target")
	if r is String: return r
	var parsed := JSONLParser.parse_file(path)
	return A.is_true(_records_of(parsed, "items", "id", a_id).size() == 1 and _records_of(parsed, "links", "from_id", a_id).is_empty(), "the source is written with no link")


## Ephemeral A has parent B (ephemeral) and blocked_by "B,C" (C durable); B is
## dropped, then A is kept.
## Oracle: the settled canonical's bytes hold no byte of B's id, and
## JSONLParser.parse_file holds A with no parent and blocked_by C only.
func test_dropped_reference_target_is_cleared_from_ephemeral_items() -> Variant:
	var db := _open_fixture("dropped_reference.dct")
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var path := DIR + "/dropped_reference.dct"
	var registry := TypeRegistry.for_db(db, db.get_project_name())
	var holder := registry.create_item({"type": "widget", "title": "reference-holder", "storage": "ephemeral"}, "tester")
	var target := registry.create_item({"type": "widget", "title": "reference-target", "storage": "ephemeral"}, "tester")
	var durable := registry.create_item({"type": "widget", "title": "reference-durable", "storage": "durable"}, "tester")
	var r = A.is_true(not holder.has("error") and not target.has("error") and not durable.has("error"), "creates succeed")
	if r is String: db.close(); return r
	var a_id := str(holder.id)
	var b_id := str(target.id)
	var c_id := str(durable.id)
	r = A.eq(db.update_item_fields_checked(a_id, {"parent": b_id, "blocked_by": "%s,%s" % [b_id, c_id]}), "", "A names B and C")
	if r is String: db.close(); return r
	r = A.eq(ItemStorage.drop(db, b_id), "", "dropping B succeeds")
	if r is String: db.close(); return r
	var project := db.get_project_name()
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var kept := DocketPromote.new().execute({"items": [a_id], "source_project": project, "promoted_by": "tester"}, schema, db, {project: db})
	r = A.eq(kept, {"project": project, "kept": [a_id]}, "keeping A succeeds")
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle after keep")
	db.close()
	if r is String: return r
	r = A.is_true(not FileAccess.get_file_as_string(path).contains(b_id), "nothing written names the dropped item")
	if r is String: return r
	var records := _records_of(JSONLParser.parse_file(path), "items", "id", a_id)
	r = A.eq(records.size(), 1, "A is written once")
	if r is String: return r
	var parent: Variant = records[0].get("parent")
	r = A.is_true(parent == null or str(parent).is_empty(), "A has no parent: %s" % str(parent))
	if r is String: return r
	return A.eq(str(records[0].get("blocked_by", "")), c_id, "A is blocked_by C only")


## A durable item holds a "linked" event naming "other:<E>", an item of another
## project with the same id as local ephemeral E; E is dropped.
## Oracle: the settled canonical's bytes are unchanged by the drop, and
## JSONLParser.parse_file still holds the durable item's event.
func test_drop_keeps_events_naming_another_projects_item() -> Variant:
	var db := _open_fixture("foreign_event.dct")
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var path := DIR + "/foreign_event.dct"
	var registry := TypeRegistry.for_db(db, db.get_project_name())
	var created := registry.create_item({"type": "widget", "title": "foreign-namesake", "storage": "ephemeral"}, "tester")
	if created.has("error"): db.close(); return "create: %s" % created.error
	var e_id := str(created.id)
	var r = A.is_true(db.get_project_name() != "other", "the fixture project is not named 'other'")
	if r is String: db.close(); return r
	var note := "Linked ORD-0001 → other:%s (follow_up)" % e_id
	r = A.eq(db.add_event_checked("ORD-0001", "linked", "tester", note), "", "the durable item records the foreign link")
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle before the drop")
	if r is String: db.close(); return r
	var before_sha := FileAccess.get_sha256(path)
	r = A.eq(ItemStorage.drop(db, e_id), "", "dropping E succeeds")
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle after the drop")
	db.close()
	if r is String: return r
	r = A.is_true(FileAccess.get_sha256(path) == before_sha and not FileAccess.file_exists(path + ".log"), "the drop changes no bytes")
	if r is String: return r
	var notes: Array = _records_of(JSONLParser.parse_file(path), "events", "item_id", "ORD-0001").map(func(event: Dictionary) -> String: return str(event.get("note", "")))
	return A.is_true(notes.has(note), "the durable item's event survives: %s" % str(notes))


## Project P and a second loaded project Q, which holds a durable item D and an
## ephemeral item E. An ephemeral item of P given parent or blocked_by "Q:D",
## "Q:E" or an unloaded project's item is refused on create and on update; a
## durable item of P naming "Q:E" is refused too. The ephemeral item is then
## kept and P settled.
## Oracle: the refusal messages; P's settled canonical's bytes hold neither
## D's nor E's id, and JSONLParser.parse_file holds the kept item once with no
## parent or blocked_by.
func test_cross_project_references_need_both_ends_durable() -> Variant:
	var db := _open_fixture("cross_p.dct")
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var path := DIR + "/cross_p.dct"
	var q_path := DIR + "/cross_q.dct"
	var out := FileAccess.open(q_path, FileAccess.WRITE); out.store_string(FileAccess.get_file_as_string(FIXTURE).replace("\"project\":\"order-fixture\"", "\"project\":\"cross-q\"")); out.close()
	var q_db := DocketDBJsonl.open_jsonl(q_path)
	if q_db == null: db.close(); return "second fixture did not open: %s" % DocketDBJsonl.last_open_error
	var project := db.get_project_name()
	var r = A.is_true(q_db.get_project_name() == "cross-q" and project != "cross-q", "two projects with distinct names (%s / %s)" % [project, q_db.get_project_name()])
	if r is String: db.close(); q_db.close(); return r
	var project_dbs := {project: db, "cross-q": q_db}
	var registry := TypeRegistry.for_db(db, project)
	registry.project_dbs = project_dbs
	var q_registry := TypeRegistry.for_db(q_db, "cross-q")
	q_registry.project_dbs = project_dbs
	var q_durable := q_registry.create_item({"type": "widget", "title": "q-durable", "storage": "durable"}, "tester")
	var q_ephemeral := q_registry.create_item({"type": "widget", "title": "q-ephemeral", "storage": "ephemeral"}, "tester")
	var holder := registry.create_item({"type": "widget", "title": "cross-holder", "storage": "ephemeral"}, "tester")
	r = A.is_true(not q_durable.has("error") and not q_ephemeral.has("error") and not holder.has("error"), "creates succeed")
	if r is String: db.close(); q_db.close(); return r
	var d_id := str(q_durable.id)
	var e_id := str(q_ephemeral.id)
	var a_id := str(holder.id)
	r = A.eq(db.flush_checked(), "", "settle before the refusals")
	if r is String: db.close(); q_db.close(); return r
	var settled_sha := FileAccess.get_sha256(path)

	for reference: String in ["cross-q:" + d_id, "cross-q:" + e_id, "unloaded-project:" + d_id]:
		for key: String in ItemStorage.REFERENCE_FIELDS:
			var created := registry.create_item({"type": "widget", "title": "cross-probe", "storage": "ephemeral", key: reference}, "tester")
			var updated := registry.update_item(a_id, {key: reference}, "tester")
			r = A.is_true(str(created.get("error", "")).contains("both ends durable") and updated.contains("both ends durable"), "ephemeral %s = %s is refused on create and update: %s / %s" % [key, reference, created, updated])
			if r is String: db.close(); q_db.close(); return r
	var durable_probe := registry.create_item({"type": "widget", "title": "durable-probe", "storage": "durable", "parent": "cross-q:" + e_id}, "tester")
	r = A.is_true(str(durable_probe.get("error", "")).contains("both ends durable"), "a durable item naming Q's ephemeral item is refused: %s" % str(durable_probe))
	if r is String: db.close(); q_db.close(); return r
	r = A.is_true(FileAccess.get_sha256(path) == settled_sha and not FileAccess.file_exists(path + ".log"), "the refusals write nothing")
	if r is String: db.close(); q_db.close(); return r

	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var kept := DocketPromote.new().execute({"items": [a_id], "source_project": project, "promoted_by": "tester"}, schema, db, project_dbs)
	r = A.eq(kept, {"project": project, "kept": [a_id]}, "keeping the holder succeeds")
	if r is String: db.close(); q_db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle after keep")
	db.close(); q_db.close()
	if r is String: return r
	var text := FileAccess.get_file_as_string(path)
	r = A.is_true(not text.contains(d_id) and not text.contains(e_id), "nothing written in P names Q's items")
	if r is String: return r
	var records := _records_of(JSONLParser.parse_file(path), "items", "id", a_id)
	r = A.eq(records.size(), 1, "the holder is written once")
	if r is String: return r
	var parent: Variant = records[0].get("parent")
	var blocked_by: Variant = records[0].get("blocked_by")
	return A.is_true((parent == null or str(parent).is_empty()) and (blocked_by == null or str(blocked_by).is_empty()), "the holder has no parent or blocked_by: %s / %s" % [parent, blocked_by])


## Ephemeral A links to ephemeral B twice, once as "<project>:B" and once bare.
## Keeping A alone is refused; keeping B alone writes B with no link and no
## event naming A; keeping A then writes both links.
## Oracle: the settled canonical's bytes and JSONLParser.parse_file.
func test_links_between_ephemeral_items_are_written_once_both_are_kept() -> Variant:
	var db := _open_fixture("linked.dct")
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var path := DIR + "/linked.dct"
	var registry := TypeRegistry.for_db(db, db.get_project_name())
	var source := registry.create_item({"type": "widget", "title": "link-source", "storage": "ephemeral"}, "tester")
	var target := registry.create_item({"type": "widget", "title": "link-target", "storage": "ephemeral"}, "tester")
	var r = A.is_true(not source.has("error") and not target.has("error"), "both creates succeed")
	if r is String: db.close(); return r
	var a_id := str(source.id)
	var b_id := str(target.id)
	var project := db.get_project_name()
	var project_dbs := {project: db}
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schema.json"))
	var qualified := DocketLink.new().execute({"from": a_id, "to": "%s:%s" % [project, b_id], "relation": "follow_up"}, schema, db, project_dbs)
	var bare := DocketLink.new().execute({"from": a_id, "to": b_id, "relation": "blocks"}, schema, db, project_dbs)
	r = A.is_true(not qualified.has("error") and not bare.has("error"), "both links succeed (%s / %s)" % [qualified.get("error", ""), bare.get("error", "")])
	if r is String: db.close(); return r
	var promote := func(ids: Array) -> Dictionary: return DocketPromote.new().execute({"items": ids, "source_project": project, "promoted_by": "tester"}, schema, db, project_dbs)

	var alone: Dictionary = promote.call([a_id])
	r = A.is_true(alone.has("error") and ItemStorage.is_ephemeral(db, a_id), "keeping the source alone is refused: %s" % str(alone))
	if r is String: db.close(); return r
	r = A.eq(promote.call([b_id]), {"project": project, "kept": [b_id]}, "keeping the target alone succeeds")
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle after keeping the target")
	if r is String: db.close(); return r
	var parsed := JSONLParser.parse_file(path)
	r = A.is_true(_records_of(parsed, "items", "id", b_id).size() == 1 and _records_of(parsed, "links", "from_id", a_id).is_empty(), "the target is written and no link is")
	if r is String: db.close(); return r
	r = A.is_true(not FileAccess.get_file_as_string(path).contains(a_id), "nothing written names the ephemeral source")
	if r is String: db.close(); return r

	r = A.eq(promote.call([a_id]), {"project": project, "kept": [a_id]}, "keeping the source afterwards succeeds")
	if r is String: db.close(); return r
	r = A.eq(db.flush_checked(), "", "settle after keeping the source")
	db.close()
	if r is String: return r
	var links: Array = _records_of(JSONLParser.parse_file(path), "links", "from_id", a_id).map(func(link: Dictionary) -> String: return "%s %s" % [link.to_id, link.relation])
	links.sort()
	var expected := ["%s blocks" % b_id, "%s:%s follow_up" % [project, b_id]]
	expected.sort()
	return A.eq(links, expected, "both links are written once both ends are durable")


## The grid's Storage column and filter (QueryGrid via StorageBadge): the query
## path the grid runs, filtered on storage, returns exactly the ephemeral item;
## an unfiltered run gives each row the word its creation implies; sorting on
## the column orders rows by that word.
## Oracle: the storage and project each item was created with.
func test_grid_storage_filter_and_words() -> Variant:
	var path := DIR + "/badge.dct"
	var out := FileAccess.open(path, FileAccess.WRITE); out.store_string(FileAccess.get_file_as_string(FIXTURE)); out.close()
	var db := DocketDBJsonl.open_jsonl(path)
	if db == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var mem: DocketDBMemory = DocketDBMemory.create("badge-mem")
	if mem == null: db.close(); return "memory project create failed"
	var state := AppState.new()
	state.schema = TypeRegistryBootstrap.load_shipped_schema()
	state._project_dbs = {"badge-file": db, "badge-mem": mem}
	state._type_registries = {"badge-file": TypeRegistry.for_db(db, "badge-file"), "badge-mem": TypeRegistry.for_db(mem, "badge-mem")}
	var durable: Dictionary = state._type_registries["badge-file"].create_item({"type": "widget", "title": "durable-probe", "storage": "durable"}, "tester")
	var ephemeral: Dictionary = state._type_registries["badge-file"].create_item({"type": "widget", "title": "ephemeral-probe", "storage": "ephemeral"}, "tester")
	var in_memory: Dictionary = state._type_registries["badge-mem"].create_item({"type": "work_item", "title": "memory-probe"}, "tester")
	var r = A.is_true(not durable.has("error") and not ephemeral.has("error") and not in_memory.has("error"), "creates succeed (%s / %s / %s)" % [durable.get("error", ""), ephemeral.get("error", ""), in_memory.get("error", "")])
	if r is String: db.close(); mem.close(); return r

	var filter := QueryTypeScope.compile_catalog_conditions([{"field": StorageBadge.FIELD, "op": "eq", "value": ItemStorage.EPHEMERAL}], [], true)
	var filtered: Array = state.execute_cross_project_query({"filter": filter}).map(func(row: Dictionary) -> String: return str(row.id))
	r = A.is_true(state.last_cross_project_query_error.is_empty() and filtered == [str(ephemeral.id)], "storage = ephemeral narrows to the ephemeral item: %s %s" % [filtered, state.last_cross_project_query_error])
	if r is String: db.close(); mem.close(); return r

	var expected := {str(durable.id): StorageBadge.FILE, str(ephemeral.id): StorageBadge.EPHEMERAL, str(in_memory.id): StorageBadge.MEMORY}
	var modes := StorageBadge.project_modes(state.get_project_dbs())
	var word_of := func(row: Dictionary) -> String: return StorageBadge.word(str(modes.get(str(row.get("project", "")), "")), str(row.get("storage", "")))
	var rows: Array = state.execute_cross_project_query({"filter": {}}).filter(func(row: Dictionary) -> bool: return expected.has(str(row.id)))
	var words := {}
	for row in rows: words[str(row.id)] = word_of.call(row)
	r = A.eq(words, expected, "each row's word matches how it was created")
	if r is String: db.close(); mem.close(); return r
	StorageBadge.sort_rows(rows, word_of, false)
	var order: Array = rows.map(func(row: Dictionary) -> String: return words[str(row.id)])
	db.close(); mem.close()
	return A.eq(order, [StorageBadge.EPHEMERAL, StorageBadge.FILE, StorageBadge.MEMORY], "sorting on the column orders by the shown word")


## Two connections share one cache file. A durable item's title is edited in
## the canonical on disk, A rebuilds the cache (reload) while B holds it open,
## and B then creates an ephemeral item.
## Oracle: the rebuild succeeds; B's first read after it, a plain SELECT with
## no B mutation before it (so no staleness check can reload B), returns the
## edited title, which only a rebuild of the file B holds can put there; A's
## connection holds both A's ephemeral item from before the rebuild and B's
## from after it, and so does B's.
func test_ephemeral_item_created_after_another_connections_rebuild_is_kept() -> Variant:
	var path := DIR + "/two_connections.dct"
	var a := _open_fixture("two_connections.dct")
	if a == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var b := DocketDBJsonl.open_jsonl(path)
	if b == null: a.close(); return "second connection did not open: %s" % DocketDBJsonl.last_open_error
	var before := TypeRegistry.for_db(a, a.get_project_name()).create_item({"type": "widget", "title": "before-rebuild", "storage": "ephemeral"}, "tester")
	var text := FileAccess.get_file_as_string(path)
	var out := FileAccess.open(path, FileAccess.WRITE); out.store_string(text.replace("Before definition", "Edited on disk")); out.close()
	var reloaded := a.reload()
	var seen_by_b: Array = b._exec_select("SELECT title FROM items WHERE id='ORD-0001';").map(func(row: Dictionary) -> String: return str(row.title))
	var after := TypeRegistry.for_db(b, b.get_project_name()).create_item({"type": "widget", "title": "after-rebuild", "storage": "ephemeral"}, "tester")
	var r = A.is_true(text.contains("Before definition") and not before.has("error") and reloaded and not after.has("error"), "edit, create, rebuild, create succeed (%s / %s)" % [before.get("error", ""), after.get("error", "")])
	if not (r is String):
		r = A.eq(seen_by_b, ["Edited on disk"], "the other connection reads the rebuilt rows")
	if not (r is String):
		r = A.is_true(ItemStorage.is_ephemeral(a, str(before.id)) and ItemStorage.is_ephemeral(a, str(after.id)), "the rebuilt file holds both ephemeral items")
	if not (r is String):
		r = A.is_true(ItemStorage.is_ephemeral(b, str(before.id)) and ItemStorage.is_ephemeral(b, str(after.id)), "the other connection sees both too")
	b.close()
	a.close()
	return r


## A rebuild whose transaction fails after it has deleted the durable rows and
## inserted the changed canonical's (JSONLCache.rebuild_failure_hook), while
## another connection holds the cache open.
## Oracle: read through a fresh connection to the cache file, the item rows
## (id, title, storage) and the stored jsonl_hash equal those read the same way
## before the rebuild: the edited title is absent and the ephemeral item is
## still there.
func test_failed_rebuild_leaves_the_previous_rows_and_fingerprint() -> Variant:
	var path := DIR + "/failed_rebuild.dct"
	var a := _open_fixture("failed_rebuild.dct")
	if a == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var ephemeral := TypeRegistry.for_db(a, a.get_project_name()).create_item({"type": "widget", "title": "survives-failed-rebuild", "storage": "ephemeral"}, "tester")
	if ephemeral.has("error"): a.close(); return "ephemeral create failed: %s" % ephemeral.error
	var cache_path := JSONLCache.cache_path_for(path)
	var read_cache := func() -> Dictionary:
		var probe := DocketDB.new()
		if not probe.open(cache_path, false): return {}
		var state := {"rows": probe._exec_select("SELECT id, title, storage FROM items ORDER BY id;"), "hash": probe.get_meta_value("jsonl_hash", "")}
		probe.close()
		return state
	var before: Dictionary = read_cache.call()
	var text := FileAccess.get_file_as_string(path)
	var out := FileAccess.open(path, FileAccess.WRITE); out.store_string(text.replace("Before definition", "Edited outside")); out.close()
	JSONLCache.rebuild_failure_hook = func() -> String: return "injected failure after the inserts"
	var rebuilt := JSONLCache.rebuild_cache(path, cache_path)
	JSONLCache.rebuild_failure_hook = Callable()
	var after: Dictionary = read_cache.call()
	a.close()
	var r = A.is_true(rebuilt == null and JSONLCache.last_error.contains("injected"), "the rebuild fails (%s)" % JSONLCache.last_error)
	if r is String:
		if rebuilt != null: rebuilt.close()
		return r
	var titles: Array = before.get("rows", []).map(func(row: Dictionary) -> String: return str(row.title))
	r = A.is_true(text.contains("Before definition") and titles.has("Before definition") and titles.has("survives-failed-rebuild") and not str(before.get("hash", "")).is_empty(), "the pre-rebuild cache holds the old title, the ephemeral item and a fingerprint: %s" % str(before))
	if r is String: return r
	return A.eq(after, before, "rows and fingerprint are unchanged by the failed rebuild")


## A peer connection commits a durable item after each of the rebuild's source
## reads and before it takes the write lock (JSONLCache.before_write_lock_hook),
## so both attempts find the files changed.
## Oracle: rebuild_cache returns null and last_error names the second change;
## read through a fresh connection to the cache file, both peer items are
## there, and the stored fingerprint matches the files (is_cache_valid).
func test_rebuild_that_finds_the_source_moved_twice_keeps_the_peers_rows() -> Variant:
	var path := DIR + "/moved_twice.dct"
	var peer := _open_fixture("moved_twice.dct")
	if peer == null: return "fixture did not open: %s" % DocketDBJsonl.last_open_error
	var cache_path := JSONLCache.cache_path_for(path)
	var writes: Array[String] = []
	JSONLCache.before_write_lock_hook = func() -> void:
		var title := "peer-write-%d" % writes.size()
		var created := TypeRegistry.for_db(peer, peer.get_project_name()).create_item({"type": "widget", "title": title}, "tester")
		writes.append(title if not created.has("error") else "error: %s" % created.error)
	var rebuilt := JSONLCache.rebuild_cache(path, cache_path)
	JSONLCache.before_write_lock_hook = Callable()
	var reason := JSONLCache.last_error
	if rebuilt != null: rebuilt.close()
	# Read before the peer closes: its close may settle the sidecar.
	var probe := DocketDB.new()
	var titles: Array = []
	if probe.open(cache_path, false):
		titles = probe._exec_select("SELECT title FROM items WHERE storage<>'ephemeral';").map(func(row: Dictionary) -> String: return str(row.title))
		probe.close()
	var fresh := JSONLCache.is_cache_valid(path, cache_path)
	peer.close()
	var r = A.eq(writes, ["peer-write-0", "peer-write-1"], "the peer commits once before each attempt's lock")
	if r is String: return r
	r = A.is_true(rebuilt == null and reason.contains("twice"), "the rebuild fails on the second change (%s)" % reason)
	if r is String: return r
	r = A.is_true(titles.has("peer-write-0") and titles.has("peer-write-1"), "both peer items are in the cache: %s" % str(titles))
	if r is String: return r
	return A.is_true(fresh, "the cache's fingerprint is the one the peer committed")
