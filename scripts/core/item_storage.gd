extends RefCounted
class_name ItemStorage
## Per-item storage mode inside a file-backed (JSONL) project.
##
## A durable item is journaled to the sidecar and settled into the canonical. An
## ephemeral item is a row of the project's SQLite cache with
## items.storage = 'ephemeral'. It takes part in queries, links, comments,
## claims and transitions like any other item, and none of it is ever written:
##   - the sidecar's dirty triggers and JSONLSidecar.build_record skip its
##     sections, and every JSONLSerializer query leaves out its rows and any
##     link that touches it;
##   - its events get no project event id (ProjectEvents): the counter is part
##     of the canonical's meta line;
##   - the cache is its only copy, so JSONLCache.rebuild_cache carries it from
##     the old cache file into the new one (capture / restore below), and
##     retires the old file as it reads it so no commit lands there after the
##     read. The cache fingerprint
##     covers canonical and sidecar bytes only, so these rows never make a
##     cache stale.
## The cache is shared by every process that opens the project on this
## machine, so an ephemeral item is visible to all of them and outlives a crash
## until the cache file is deleted.
##
## keep() makes a batch of items durable in place, in one canonical mutation:
## same ids, a "promoted" event each (stamped as the item's arrival), and every
## section journaled as one record. drop() deletes one, with the "linked" events
## that name it, and removes it from other ephemeral items' parent and
## blocked_by. Both check storage inside their mutation, under the cache's
## write lock (write_locked): storage only ever goes ephemeral -> durable
## (keep) or ephemeral -> gone (drop), so a check that finds an item durable
## stays true, and only a check that finds it ephemeral must hold the lock
## until the write it allows.
##
## References: an id qualified with the item's own project name ("project:id")
## names the same item as the bare id (local_id; EPHEMERAL_REFS_SQL in SQL), and
## is stored as written. Links: a link with an ephemeral end is ephemeral itself.
## A same-project link is written once both ends are durable, since the
## serializer sees the target's storage. A link across projects is refused
## while either end is ephemeral (link_refusal): a project's serializer cannot
## see another project's storage. So is a parent or blocked_by across projects
## with an ephemeral end (foreign_reference_refusal in TypeRegistry). A durable
## item's parent and blocked_by may not name an ephemeral item of its own
## project either (reference_refusal in DocketDB), and a vault entry is never
## owned by an ephemeral item (owner_refusal): the canonical would name an item
## it does not hold. keep() refuses while an item
## names an ephemeral item outside the batch, of its own or another loaded
## project, in parent, blocked_by or a link.
##
## An ephemeral item cannot be moved or copied to another project
## (DocketDB.export_item_full_checked refuses it); it is kept first.

const DURABLE := "durable"
const EPHEMERAL := "ephemeral"
const MODES := [DURABLE, EPHEMERAL]
## Items born ephemeral unless the caller asks for durable.
const EPHEMERAL_TAGS := ["wr:attempt"]
const EPHEMERAL_TYPES := ["steering"]
## Item columns that name another item.
const REFERENCE_FIELDS := ["parent", "blocked_by"]
## The ids and own-project-qualified ids of ephemeral items, as a SQL row set:
## "<column> NOT IN EPHEMERAL_REFS_SQL" is true unless the column names one.
const EPHEMERAL_REFS_SQL := "(SELECT id FROM items WHERE storage='ephemeral' UNION ALL SELECT m.value || ':' || e.id FROM items e JOIN docket_meta m ON m.key='project' WHERE e.storage='ephemeral' AND m.value IS NOT NULL AND m.value<>'')"
const UPDATE_REFUSAL := "storage cannot be changed by an update; keep an ephemeral item with docket_promote (to_project omitted)"


static func supports_ephemeral(db: DocketDB) -> bool:
	## Only a file-backed project has something to leave ephemeral items out of.
	return db is DocketDBJsonl and (db as DocketDBJsonl)._uses_sidecar()


static func resolve(db: DocketDB, requested: String, type_slug: String, tags: Array) -> Dictionary:
	## {"storage": mode} for a new item, or {"error": ...}. An empty request
	## takes the default: ephemeral for EPHEMERAL_TAGS / EPHEMERAL_TYPES in a
	## project that supports it, durable otherwise.
	if not requested.is_empty():
		if requested not in MODES: return {"error": "storage must be 'durable' or 'ephemeral'"}
		if requested == EPHEMERAL and not supports_ephemeral(db): return {"error": "ephemeral storage needs a file-backed project"}
		return {"storage": requested}
	if supports_ephemeral(db):
		if type_slug in EPHEMERAL_TYPES: return {"storage": EPHEMERAL}
		for tag in tags:
			if str(tag) in EPHEMERAL_TAGS: return {"storage": EPHEMERAL}
	return {"storage": DURABLE}


static func is_ephemeral(db: DocketDB, id: String) -> bool:
	return not db._exec_select("SELECT 1 FROM items WHERE id=? AND storage='ephemeral' LIMIT 1;", [id]).is_empty()


static func list_ephemeral(db: DocketDB) -> Array:
	## [{id, type, title}] of the project's ephemeral items, oldest first.
	return db._exec_select("SELECT id, type, title FROM items WHERE storage='ephemeral' ORDER BY created_at ASC, id ASC;")


static func outstanding(project_dbs: Dictionary) -> Dictionary:
	## Project name -> list_ephemeral(), for projects that hold any.
	var result := {}
	for project_name in project_dbs:
		var db: DocketDB = project_dbs[project_name]
		if db == null or not db.is_open() or not supports_ephemeral(db): continue
		var items := list_ephemeral(db)
		if not items.is_empty(): result[project_name] = items
	return result


static func keep(db: DocketDB, ids: Array, actor: String, project_dbs: Dictionary = {}) -> String:
	## Ephemeral -> durable, same ids, all in one write_locked mutation: the
	## checks see the rows the UPDATEs change, the batch is one journal record,
	## and a refusal or failure anywhere rolls every member back.
	## project_dbs is the loaded project map for batch_refusal; another
	## project's rows (foreign_ephemeral) are read from its own cache, outside
	## this lock.
	if not supports_ephemeral(db): return "project has no ephemeral items"
	return write_locked(db, func() -> String:
		for id in ids:
			if not is_ephemeral(db, str(id)): return "item %s is not ephemeral" % id
		var refusal := batch_refusal(db, ids, project_dbs)
		if not refusal.is_empty(): return refusal
		for id in ids:
			var error := db._exec_checked("UPDATE items SET storage='durable' WHERE id=? AND storage='ephemeral';", [str(id)])
			if error.is_empty(): error = (db as DocketDBJsonl).add_event_checked(str(id), "promoted", actor, "Kept in place: ephemeral → durable")
			if not error.is_empty(): return error
		return "")


static func write_locked(db: DocketDB, body: Callable) -> String:
	## Runs body (-> String) inside one canonical mutation opened with BEGIN
	## IMMEDIATE: SQLite's write lock on the cache, which every process on the
	## machine shares, is held from before body's first read until COMMIT, so
	## no other process commits between body's checks and its writes. body
	## returns "" to commit, else a refusal or error, and everything it wrote is
	## rolled back (_refuse_canonical_mutation). Nested in another mutation, the
	## outer BEGIN decides. A DocketDB that is not file-backed just runs body.
	if not db is DocketDBJsonl: return str(body.call())
	var jsonl_db := db as DocketDBJsonl
	var error := jsonl_db._begin_canonical_mutation(true)
	if not error.is_empty(): return error
	error = str(body.call())
	return jsonl_db._complete_canonical_mutation() if error.is_empty() else jsonl_db._refuse_canonical_mutation(error)


static func keep_refusal(db: DocketDB, id: String, batch: Array = [], project_dbs: Dictionary = {}) -> String:
	## "" unless keeping id alone with batch would leave it durable while its
	## parent, blocked_by or one of its links names an ephemeral item: one of db
	## that is not in batch, or one of another project loaded in project_dbs.
	## Its "linked" events name its link targets, so an outgoing link counts
	## even though the serializer would defer the link itself.
	var rows := db._exec_select("SELECT parent, blocked_by FROM items WHERE id=?;", [id])
	var references: Dictionary = rows[0] if not rows.is_empty() else {}
	var error := reference_refusal(db, references, batch)
	if error.is_empty(): error = foreign_reference_refusal(db, references, project_dbs)
	if error.is_empty():
		for link: Dictionary in db._exec_select("SELECT to_id FROM item_links WHERE from_id=? ORDER BY id;", [id]):
			var target := local_id(db, str(link.to_id))
			if target.is_empty(): target = foreign_ephemeral(db, str(link.to_id), project_dbs)
			elif target in batch or not is_ephemeral(db, target): target = ""
			if not target.is_empty():
				error = "item %s is ephemeral; a durable item cannot link to it. Keep it first or in the same batch" % target
				break
	return "" if error.is_empty() else "cannot keep %s: %s" % [id, error]


static func batch_refusal(db: DocketDB, ids: Array, project_dbs: Dictionary = {}) -> String:
	## keep_refusal for every id against the whole batch, checked before any is
	## kept; the first refusal refuses the batch.
	for id in ids:
		var refusal := keep_refusal(db, str(id), ids, project_dbs)
		if not refusal.is_empty(): return refusal
	return ""


static func drop(db: DocketDB, id: String) -> String:
	## Deletes id with its links (DocketDB.delete_item), every "linked" event
	## that names it on another item, and every other ephemeral item's parent or
	## blocked_by entry that names it, in one write_locked mutation that first
	## checks id is ephemeral: an item another process keeps is either kept
	## before the check (refused here) or after the delete (not found there).
	## A "linked" event has no target column: DocketLink writes both ends into
	## its note, so the note's two endpoints are parsed and compared through
	## local_id; "other:<id>" names another project's item and is left alone.
	## Such an event sits on an ephemeral item (DocketLink puts it on an
	## ephemeral end), so the delete is journaled only if it ever is not.
	## Only ephemeral items' references are cleared: a durable item's are
	## refused at write time (reference_refusal), and ephemeral rows are never
	## journaled.
	var refusal := "item %s is not ephemeral; only ephemeral items can be dropped" % id
	if not supports_ephemeral(db): return refusal
	return write_locked(db, func() -> String:
		if not is_ephemeral(db, id): return refusal
		for event: Dictionary in db._exec_select("SELECT id, note FROM item_events WHERE event_type='linked' AND instr(note, ?)>0;", [id]):
			if not _link_note_names(db, str(event.note), id): continue
			var error := db._exec_checked("DELETE FROM item_events WHERE id=?;", [event.id])
			if not error.is_empty(): return error
		var error := _clear_references(db, id)
		return error if not error.is_empty() else (db as DocketDBJsonl).delete_item_checked(id))


static func _link_note_names(db: DocketDB, note: String, id: String) -> bool:
	## True when a "linked" note ("Linked <from> → <to> (<relation>)") has id as
	## either endpoint in db (local_id).
	if not note.begins_with("Linked "): return false
	var ends := note.trim_prefix("Linked ").split(" → ", true, 1)
	if ends.size() != 2: return false
	var to := ends[1]
	var cut := to.rfind(" (")
	if cut >= 0: to = to.substr(0, cut)
	return local_id(db, ends[0]) == id or local_id(db, to) == id


static func _clear_references(db: DocketDB, id: String) -> String:
	## Removes id from every other ephemeral item's parent (set to '') and
	## blocked_by (that entry only; NULL when none is left).
	var rows := db._exec_select("SELECT id, parent, blocked_by FROM items WHERE storage='ephemeral' AND id<>? AND (instr(parent, ?)>0 OR instr(blocked_by, ?)>0);", [id, id, id])
	if not db._last_sql_error.is_empty(): return db._last_sql_error
	for row: Dictionary in rows:
		var parent: Variant = row.parent
		if parent != null and local_id(db, str(parent)) == id: parent = ""
		var blocked_by: Variant = row.blocked_by
		if blocked_by != null:
			var kept: PackedStringArray = []
			var parts := str(blocked_by).split(",", false)
			for part in parts:
				if local_id(db, part) != id: kept.append(part)
			if kept.size() != parts.size(): blocked_by = null if kept.is_empty() else ",".join(kept).strip_edges()
		if parent == row.parent and blocked_by == row.blocked_by: continue
		var error := db._exec_checked("UPDATE items SET parent=?, blocked_by=? WHERE id=?;", [parent, blocked_by, row.id])
		if not error.is_empty(): return error
	return ""


static func keep_all(db: DocketDB, actor: String, project_dbs: Dictionary = {}) -> PackedStringArray:
	var ids: Array = list_ephemeral(db).map(func(row: Dictionary) -> String: return str(row.id))
	if ids.is_empty(): return PackedStringArray()
	var error := keep(db, ids, actor, project_dbs)
	return PackedStringArray() if error.is_empty() else PackedStringArray([error])


static func drop_all(db: DocketDB) -> PackedStringArray:
	var errors: PackedStringArray = []
	for row in list_ephemeral(db):
		var error := drop(db, str(row.id))
		if not error.is_empty(): errors.append("%s: %s" % [row.id, error])
	return errors


static func local_id(db: DocketDB, reference: String) -> String:
	## The id reference names in db: bare, or qualified with db's project name.
	## "" when it is qualified with another project's name.
	var parsed := DocketDB.parse_qualified_ref(reference.strip_edges())
	if not str(parsed.project).is_empty() and str(parsed.project) != db.get_project_name(): return ""
	return str(parsed.id)


static func link_refusal(from_db: DocketDB, from_id: String, to_db: DocketDB, to_id: String) -> String:
	## For a link whose target is named "project:id". "" when allowed. A target
	## in the source's own project is treated as a bare id: the serializer
	## defers the link until both ends are durable. Across projects neither end
	## may be ephemeral: each project's serializer sees only its own storage.
	if to_db == from_db or to_db.get_project_name() == from_db.get_project_name(): return ""
	var ephemeral_id := from_id if is_ephemeral(from_db, from_id) else (to_id if is_ephemeral(to_db, to_id) else "")
	if ephemeral_id.is_empty(): return ""
	return "item %s is ephemeral; a link across projects needs both ends durable. Keep both first (docket_promote with to_project omitted)" % ephemeral_id


static func reference_refusal(db: DocketDB, values: Dictionary, ignored: Array = []) -> String:
	## For a durable item's REFERENCE_FIELDS in values: "" unless one names an
	## ephemeral item of db (local_id) that is not in ignored. A reference
	## qualified with another project's name is checked by
	## foreign_reference_refusal.
	if not supports_ephemeral(db): return ""
	for key: String in REFERENCE_FIELDS:
		var value: Variant = values.get(key)
		if value == null: continue
		for part in str(value).split(",", false):
			var id := local_id(db, part)
			if not id.is_empty() and id not in ignored and is_ephemeral(db, id): return _reference_message(id, key)
	return ""


static func foreign_reference_refusal(db: DocketDB, values: Dictionary, project_dbs: Dictionary, ephemeral_writer: String = "") -> String:
	## For an item of db: "" unless one of its REFERENCE_FIELDS in values names
	## another project's item while either end is ephemeral. ephemeral_writer
	## describes the item being written when it is ephemeral ("item <id>"), ""
	## when it is durable. An ephemeral writer is refused any reference
	## qualified with another project's name, loaded or not: dropping an item
	## clears references in its own project only (drop). A durable writer is
	## refused a target that is ephemeral in a loaded project (foreign_ephemeral).
	for key: String in REFERENCE_FIELDS:
		var value: Variant = values.get(key)
		if value == null: continue
		for part in str(value).split(",", false):
			var ephemeral_end := foreign_ephemeral(db, part, project_dbs)
			if not ephemeral_end.is_empty(): ephemeral_end = "item " + ephemeral_end
			elif not ephemeral_writer.is_empty() and _names_other_project(db, part): ephemeral_end = ephemeral_writer
			if not ephemeral_end.is_empty(): return "%s is ephemeral; a %s naming another project's item needs both ends durable. Keep it first (docket_promote with to_project omitted)" % [ephemeral_end, key]
	return ""


static func _names_other_project(db: DocketDB, reference: String) -> bool:
	var project := str(DocketDB.parse_qualified_ref(reference.strip_edges()).project)
	return not project.is_empty() and project != db.get_project_name()


static func foreign_ephemeral(db: DocketDB, reference: String, project_dbs: Dictionary) -> String:
	## reference ("project:id") when it names an ephemeral item of another
	## project loaded in project_dbs, else "". A project that is not loaded is
	## not checked.
	var parsed := DocketDB.parse_qualified_ref(reference.strip_edges())
	var project := str(parsed.project)
	if project.is_empty() or project == db.get_project_name() or not project_dbs.has(project): return ""
	var other: DocketDB = project_dbs[project]
	if other == null or not other.is_open() or not supports_ephemeral(other) or not is_ephemeral(other, str(parsed.id)): return ""
	return "%s:%s" % [project, parsed.id]


static func _reference_message(reference: String, key: String) -> String:
	return "item %s is ephemeral; a durable item's %s cannot name it. Keep it first (docket_promote with to_project omitted)" % [reference, key]


static func owner_refusal(db: DocketDB, owner_item_id: String) -> String:
	## "" unless owner_item_id is an ephemeral item: vault entries are written
	## with the canonical, which would then name an owner it does not hold.
	if owner_item_id.is_empty() or not is_ephemeral(db, owner_item_id): return ""
	return "item %s is ephemeral; a vault entry cannot belong to it. Keep it first (docket_promote with to_project omitted)" % owner_item_id


static func move_refusal(db: DocketDB, id: String) -> String:
	## "" unless id is ephemeral. A move or copy imports into the target as a
	## durable item, so an ephemeral one is refused rather than written there.
	if not is_ephemeral(db, id): return ""
	return "item %s is ephemeral and cannot be moved or copied to another project; keep it first (docket_promote with to_project omitted)" % id


# -- Carry across a cache rebuild -----------------------------------------------

static func capture(cache_path: String) -> Dictionary:
	## Reads the ephemeral rows of the cache file at cache_path before a rebuild
	## replaces it, and retires that file: {"rows": rows or {}, "db": the open
	## connection, "retired": the marker}, or {"error": ...} when the file's
	## write lock cannot be taken. BEGIN IMMEDIATE waits (busy_timeout) for any
	## connection's write transaction to commit and then holds the write lock
	## while the rows are read and cache_id is set to a retired marker
	## (JSONLCache.retired_marker) in the same transaction. So every commit to
	## this file either precedes the read, or starts after the retire and is
	## refused (DocketDBJsonl._cache_replaced). A file that cannot be opened or
	## read (corrupt, pre-storage schema) has nothing to carry: {"rows": {}}.
	## A file that cannot take the marker is replaced unretired; a connection's
	## commit to it would need the same write.
	if not FileAccess.file_exists(cache_path): return {"rows": {}}
	var old := DocketDB.new()
	if not old.open(cache_path): return {"rows": {}}
	old._last_sql_error = ""
	var lock_error := old._exec_checked("BEGIN IMMEDIATE TRANSACTION;")
	if not lock_error.is_empty():
		old.close()
		# Busy means a writer still holds the file; replacing it now could lose
		# that writer's rows. Any other failure is a file with nothing to carry.
		if lock_error.containsn("locked") or lock_error.containsn("busy"): return {"error": "cache %s is busy; not rebuilt: %s" % [cache_path, lock_error]}
		return {"rows": {}}
	var ids := "(SELECT id FROM items WHERE storage='ephemeral')"
	var captured := {
		"items": old._exec_select("SELECT * FROM items WHERE storage='ephemeral';"),
		"tags": old._exec_select("SELECT item_id, tag FROM item_tags WHERE item_id IN %s;" % ids),
		"events": old._exec_select("SELECT item_id, event_type, actor, timestamp, note FROM item_events WHERE item_id IN %s ORDER BY id;" % ids),
		"comments": old._exec_select("SELECT * FROM comments WHERE item_id IN %s ORDER BY id;" % ids),
		"attachments": old._exec_select("SELECT item_id, filename, mime_type, size_bytes, data, created_at, description FROM attachments WHERE item_id IN %s ORDER BY id;" % ids),
		"links": old._exec_select("SELECT from_id, to_id, relation FROM item_links WHERE from_id IN %s OR to_id IN %s ORDER BY id;" % [ids, EPHEMERAL_REFS_SQL]),
	}
	var read_error := old._last_sql_error
	var rows: Dictionary = captured if read_error.is_empty() and not captured.items.is_empty() else {}
	if not read_error.is_empty(): push_warning("ItemStorage: ephemeral items in %s not carried over: %s" % [cache_path, read_error])
	old._last_sql_error = ""
	var id_rows := old._exec_select("SELECT value FROM docket_meta WHERE key='cache_id';")
	var marker := JSONLCache.retired_marker(str(id_rows[0].value) if not id_rows.is_empty() else "")
	var retire_error := old._last_sql_error
	if retire_error.is_empty(): retire_error = old._exec_checked("INSERT OR REPLACE INTO docket_meta(key,value) VALUES('cache_id',?);", [marker])
	if retire_error.is_empty(): retire_error = old._exec_checked("COMMIT;")
	if retire_error.is_empty(): return {"rows": rows, "db": old, "retired": marker}
	old._rollback()
	push_warning("ItemStorage: cache %s not retired: %s" % [cache_path, retire_error])
	return {"rows": rows, "db": old}


static func end_capture(capture: Dictionary) -> void:
	## Closes capture's connection. The rebuild calls it after unlinking the
	## file, or before retrying on a platform that cannot unlink an open file.
	var old: DocketDB = capture.get("db")
	if old == null or not old.is_open(): return
	old.close()


static func restore(db: DocketDB, captured: Dictionary) -> void:
	## Re-insert capture()'s rows into a cache being rebuilt, inside its open
	## transaction and after the canonical's rows. An id the canonical now holds
	## is durable and wins. A failure is rolled back to the savepoint and only
	## warned about: losing ephemeral rows must not fail the rebuild.
	if captured.is_empty() or not db._last_sql_error.is_empty(): return
	if not db._exec_checked("SAVEPOINT ephemeral_carry;").is_empty():
		db._last_sql_error = ""
		return
	var error := _restore_rows(db, captured)
	if error.is_empty():
		db._exec_checked("RELEASE ephemeral_carry;")
	else:
		push_warning("ItemStorage: ephemeral items not carried into the rebuilt cache: %s" % error)
		db._exec("ROLLBACK TO ephemeral_carry;")
		db._exec("RELEASE ephemeral_carry;")
	db._last_sql_error = ""


static func _restore_rows(db: DocketDB, captured: Dictionary) -> String:
	var kept := {}
	for row: Dictionary in captured.items:
		var id := str(row.id)
		if db.has_item(id): continue
		var error := _insert_row(db, "items", row)
		if not error.is_empty(): return error
		kept[id] = true
	for row: Dictionary in captured.tags:
		if not kept.has(str(row.item_id)): continue
		var error := db._exec_checked("INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?);", [row.item_id, row.tag])
		if not error.is_empty(): return error
	for row: Dictionary in captured.events:
		if not kept.has(str(row.item_id)): continue
		var error := _insert_row(db, "item_events", row)
		if not error.is_empty(): return error
	# Comment ids are renumbered, since the canonical may now hold the old ones;
	# replies follow their parent.
	var comment_ids := {}
	for row: Dictionary in captured.comments:
		if not kept.has(str(row.item_id)): continue
		var copy := row.duplicate()
		copy.erase("id")
		if comment_ids.has(int(copy.get("parent_id", 0))): copy["parent_id"] = comment_ids[int(copy.parent_id)]
		var error := _insert_row(db, "comments", copy)
		if not error.is_empty(): return error
		var rows := db._exec_select("SELECT last_insert_rowid() AS id;")
		if not rows.is_empty(): comment_ids[int(row.id)] = int(rows[0].id)
	for row: Dictionary in captured.attachments:
		if not kept.has(str(row.item_id)): continue
		var error := _insert_row(db, "attachments", row)
		if not error.is_empty(): return error
	for row: Dictionary in captured.links:
		var from_id := str(row.from_id)
		if not db.has_item(from_id) or not (kept.has(from_id) or kept.has(local_id(db, str(row.to_id)))): continue
		var error := _insert_row(db, "item_links", row)
		if not error.is_empty(): return error
	return db._last_sql_error


static func _insert_row(db: DocketDB, table: String, row: Dictionary) -> String:
	var cols := PackedStringArray()
	var marks := PackedStringArray()
	var bindings: Array = []
	for key in row:
		cols.append(str(key))
		marks.append("?")
		bindings.append(row[key])
	return db._exec_checked("INSERT INTO %s (%s) VALUES (%s);" % [table, ",".join(cols), ",".join(marks)], bindings)
