extends RefCounted
class_name JSONLSidecar
## Write-ahead sidecar for a JSONL canonical: <canonical>.log beside the .dct.
##
## A mutation on a durable project appends ONE line here instead of rewriting
## the canonical. The line carries canonical-format records for exactly the
## item sections the mutation touched, so replay is "replace these sections":
##
##   {"_type":"wal","base":"<canonical sha256>","replace":[[id,section],...],"records":[...]}
##
## Sections are "item" (item line incl. tags), "events", "comments", "links"
## (outgoing, by from_id), "attachments", and ["", "meta"]. An "item" section
## replaced with no item record means the item was deleted, which also drops
## every other section of that id. Registry, secret and saved-query changes are
## never journaled: the caller settles the canonical for those instead.
## Ephemeral items (ItemStorage) and links touching them are never journaled.
##
## Settling writes the canonical from the cache, then removes the sidecar.
## Before the canonical is replaced a {"_type":"settle","target":<sha>} line is
## appended; if the process dies between the rename and the removal, replay sees
## the canonical already has that hash and skips every record before the marker.
##
## Replay tolerates unparseable lines: an append is acknowledged only after it
## was written and flushed, so a torn line is one that no caller was told had
## succeeded. Any other defect (unknown record kind, invalid canonical record,
## orphan after replay) refuses the load, as the canonical parser does.

const SUFFIX := ".log"
const _ITEM_SECTIONS := ["item", "events", "comments", "links", "attachments"]
## Tables whose changes are not journaled; touching one forces a full settle.
const _SETTLE_TABLES := ["type_defs", "type_def_versions", "saved_queries", "docket_secrets", "docket_secret_versions"]


static func path_for(canonical_path: String) -> String:
	return canonical_path + SUFFIX


static func has_content(path: String) -> bool:
	## True when the sidecar is non-empty, or exists but cannot be opened: an
	## unreadable sidecar may hold acknowledged records, so it is never "empty".
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	return f == null or f.get_length() > 0


static func source_fingerprint(canonical_path: String) -> String:
	## Content identity of what a cache is built from: the canonical's sha256,
	## plus the sidecar's when it holds anything. With no sidecar this is the
	## bare canonical hash, so caches built before the sidecar stay valid.
	if not FileAccess.file_exists(canonical_path):
		return ""
	return fingerprint_with(JSONLFreshness.hash_file(canonical_path), canonical_path)


static func fingerprint_with(canonical_sha: String, canonical_path: String) -> String:
	## source_fingerprint for a caller that already verified the canonical's hash
	## (under the write lock), so the large file is not hashed a second time.
	## "" when the sidecar exists but cannot be read: its identity is unknown,
	## and every caller treats "" as a changed source.
	var sidecar := path_for(canonical_path)
	if not has_content(sidecar):
		return canonical_sha
	var sidecar_sha := JSONLFreshness.hash_file(sidecar)
	return "" if sidecar_sha.is_empty() else "%s:%s" % [canonical_sha, sidecar_sha]


static func fingerprint_of(canonical_sha: String, sidecar_bytes: PackedByteArray) -> String:
	## source_fingerprint of bytes the caller already read, so the identity it
	## stores describes exactly what it parsed and replayed.
	if sidecar_bytes.is_empty():
		return canonical_sha
	return "%s:%s" % [canonical_sha, sha256_bytes(sidecar_bytes)]


static func canonical_part(fingerprint: String) -> String:
	return fingerprint.get_slice(":", 0)


static func sha256_bytes(bytes: PackedByteArray) -> String:
	## Same lowercase hex as FileAccess.get_sha256 of a file holding these bytes.
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty(): context.update(bytes)
	return context.finish().hex_encode()


static func read_bytes(path: String) -> Dictionary:
	## {"bytes": the file's bytes, "error": ""}. A missing file reads as empty;
	## an existing one that cannot be read is an error, never empty, so no
	## caller replays, compacts, rewrites or removes a sidecar it did not see.
	if not FileAccess.file_exists(path): return {"bytes": PackedByteArray(), "error": ""}
	var bytes := FileAccess.get_file_as_bytes(path)
	var open_error := FileAccess.get_open_error()
	if open_error != OK:
		return {"bytes": PackedByteArray(), "error": "cannot read sidecar %s (error %d); refusing to open or settle until it is readable" % [path, open_error]}
	return {"bytes": bytes, "error": ""}


# -- Dirty tracking (per SQLite connection) -----------------------------------

static func install_dirty_tracking(db: DocketDB) -> String:
	## TEMP triggers record which item sections each statement touched. They live
	## on this connection only and never reach the cache file; the temp table is
	## transactional, so a rolled-back mutation leaves no dirty rows.
	##
	## Rows of ephemeral items (ItemStorage) are never recorded: the items
	## triggers test the row's own storage, the dependent-table triggers test
	## the owning item's, and a link is recorded only when neither end is
	## ephemeral; a link target qualified with the project's own name counts as
	## the bare id (ItemStorage.EPHEMERAL_REFS_SQL). ItemStorage.drop deletes
	## dependent rows and links before the item row, so they are still
	## recognised. Keeping an item (storage ephemeral -> durable) records all of
	## its sections and the links sections of the durable items that link to it.
	var sql: PackedStringArray = ["CREATE TEMP TABLE IF NOT EXISTS sidecar_dirty (item_id TEXT NOT NULL, section TEXT NOT NULL, PRIMARY KEY(item_id, section)) WITHOUT ROWID;"]
	sql.append(_trigger("items", "INSERT", "WHEN NEW.storage<>'ephemeral'", _record("(NEW.id,'item')")))
	sql.append(_trigger("items", "DELETE", "WHEN OLD.storage<>'ephemeral'", _record("(OLD.id,'item')")))
	sql.append(_trigger("items", "UPDATE", "WHEN NEW.storage<>'ephemeral'", _record("(OLD.id,'item'),(NEW.id,'item')")))
	# Keep (storage ephemeral -> durable). The UPDATE trigger above marks only
	# the item's 'item' section (its row and tags); its other sections were never
	# journaled, so keep_sections marks them. A link is journaled in its source's
	# 'links' section (by from_id), and a durable item's link to this one was
	# left out of that section while this end was ephemeral, so durable_linkers
	# marks the 'links' section of every durable item linking here to re-emit it.
	var keep_sections := _record("(NEW.id,'events'),(NEW.id,'comments'),(NEW.id,'links'),(NEW.id,'attachments')")
	var durable_linkers := "INSERT OR IGNORE INTO sidecar_dirty(item_id,section) SELECT l.from_id,'links' FROM item_links l JOIN items f ON f.id=l.from_id WHERE (l.to_id=NEW.id OR l.to_id=(SELECT value FROM docket_meta WHERE key='project') || ':' || NEW.id) AND f.storage<>'ephemeral';"
	sql.append("CREATE TEMP TRIGGER IF NOT EXISTS sidecar_items_keep AFTER UPDATE OF storage ON main.items FOR EACH ROW WHEN OLD.storage='ephemeral' AND NEW.storage<>'ephemeral' BEGIN %s %s END;" % [keep_sections, durable_linkers])
	var owned := {"item_tags": "item", "item_events": "events", "comments": "comments", "attachments": "attachments"}
	for table: String in owned:
		var section: String = owned[table]
		sql.append(_trigger(table, "INSERT", "", _record_if("NEW.item_id", section, _durable("NEW.item_id"))))
		sql.append(_trigger(table, "DELETE", "", _record_if("OLD.item_id", section, _durable("OLD.item_id"))))
		sql.append(_trigger(table, "UPDATE", "", _record_if("OLD.item_id", section, _durable("OLD.item_id")) + " " + _record_if("NEW.item_id", section, _durable("NEW.item_id"))))
	sql.append(_trigger("item_links", "INSERT", "", _record_if("NEW.from_id", "links", _durable_link("NEW"))))
	sql.append(_trigger("item_links", "DELETE", "", _record_if("OLD.from_id", "links", _durable_link("OLD"))))
	sql.append(_trigger("item_links", "UPDATE", "", _record_if("OLD.from_id", "links", _durable_link("OLD")) + " " + _record_if("NEW.from_id", "links", _durable_link("NEW"))))
	var quoted: PackedStringArray = []
	for key: String in JSONLSerializer._EPHEMERAL_META_KEYS: quoted.append("'%s'" % key)
	var ephemeral := ",".join(quoted)
	sql.append(_trigger("docket_meta", "INSERT", "WHEN NEW.key NOT IN (%s)" % ephemeral, _record("('','meta')")))
	sql.append(_trigger("docket_meta", "DELETE", "WHEN OLD.key NOT IN (%s)" % ephemeral, _record("('','meta')")))
	sql.append(_trigger("docket_meta", "UPDATE", "WHEN NEW.key NOT IN (%s) OR OLD.key NOT IN (%s)" % [ephemeral, ephemeral], _record("('','meta')")))
	for table: String in _SETTLE_TABLES:
		for op in ["INSERT", "DELETE", "UPDATE"]:
			sql.append(_trigger(table, op, "", _record("('','full')")))
	for statement in sql:
		var error := db._exec_checked(statement)
		if not error.is_empty(): return "sidecar dirty tracking unavailable: %s" % error
	return ""


static func _trigger(table: String, op: String, when: String, body: String) -> String:
	return "CREATE TEMP TRIGGER IF NOT EXISTS sidecar_%s_%s AFTER %s ON main.%s FOR EACH ROW %s BEGIN %s END;" % [table, op.to_lower(), op, table, when, body]


static func _record(values: String) -> String:
	return "INSERT OR IGNORE INTO sidecar_dirty(item_id,section) VALUES %s;" % values


static func _record_if(id_expr: String, section: String, condition: String) -> String:
	return "INSERT OR IGNORE INTO sidecar_dirty(item_id,section) SELECT %s,'%s' WHERE %s;" % [id_expr, section, condition]


static func _durable(id_expr: String) -> String:
	## True unless id_expr names an ephemeral item (ItemStorage).
	return "NOT EXISTS (SELECT 1 FROM items e WHERE e.id=%s AND e.storage='ephemeral')" % id_expr


static func _durable_link(row: String) -> String:
	return "%s AND %s.to_id NOT IN %s" % [_durable(row + ".from_id"), row, ItemStorage.EPHEMERAL_REFS_SQL]


static func clear_dirty(db: DocketDB) -> String:
	# Bookkeeping no results row reads (DocketDB.results_generation).
	db._begin_uncounted()
	var error := db._exec_checked("DELETE FROM temp.sidecar_dirty;")
	db._end_uncounted()
	return error


static func build_record(db: DocketDB, base: String) -> Dictionary:
	## The sidecar line for everything the dirty table names. Returns
	## {"full": true} when a non-journaled table changed, {"line": ""} when
	## nothing durable changed, or {"error": ...}.
	db._last_sql_error = ""
	# The triggers already skip ephemeral items; this also covers an entry
	# recorded before its item was marked ephemeral in the same transaction.
	var skip_error := db._exec_checked("DELETE FROM temp.sidecar_dirty WHERE item_id IN (SELECT id FROM main.items WHERE storage='ephemeral');")
	if not skip_error.is_empty(): return {"error": "cannot read sidecar dirty set: %s" % skip_error}
	var rows := db._exec_select("SELECT item_id,section FROM temp.sidecar_dirty ORDER BY item_id,section;")
	if not db._last_sql_error.is_empty(): return {"error": "cannot read sidecar dirty set: %s" % db._last_sql_error}
	var replace: Array = []
	var lines: PackedStringArray = []
	for row in rows:
		var id := str(row.item_id)
		var section := str(row.section)
		var text := ""
		match section:
			"full": return {"full": true}
			"meta": text = JSONLSerializer.serialize_meta(db)
			"item":
				var found := db._exec_select("SELECT * FROM items WHERE id=?;", [id])
				if not found.is_empty():
					text = JSONLSerializer._serialize_item_row(db, found[0])
					if text.is_empty(): return {"error": "item %s has malformed fields; refusing sidecar append" % id}
			"events": text = JSONLSerializer.serialize_events(db, id)
			"comments": text = JSONLSerializer.serialize_comments(db, id)
			"links": text = JSONLSerializer.serialize_links(db, id)
			"attachments": text = JSONLSerializer.serialize_attachments(db, id)
			_: return {"error": "unknown sidecar section '%s'" % section}
		replace.append([id, section])
		if not text.is_empty(): lines.append_array(text.split("\n", false))
	if not db._last_sql_error.is_empty(): return {"error": "cache read failed while journaling: %s" % db._last_sql_error}
	if replace.is_empty(): return {"line": ""}
	# Serialized records are complete JSON objects, so they embed verbatim.
	return {"line": '{"_type":"wal","base":%s,"replace":%s,"records":[%s]}' % [JSON.stringify(base), JSON.stringify(replace), ",".join(lines)]}


# -- File operations ----------------------------------------------------------

static func append(path: String, line: String) -> String:
	## Append one record line. A torn tail from an earlier crash is fenced off
	## with a newline so it stays a separate, skippable line.
	var fence := ""
	if FileAccess.file_exists(path):
		var reader := FileAccess.open(path, FileAccess.READ)
		if reader == null: return "cannot read sidecar %s (error %d)" % [path, FileAccess.get_open_error()]
		if reader.get_length() > 0:
			reader.seek(reader.get_length() - 1)
			if reader.get_8() != 10: fence = "\n"
		reader.close()
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if f == null: return "cannot open sidecar %s (error %d)" % [path, FileAccess.get_open_error()]
	f.seek_end()
	f.store_string(fence + line + "\n")
	f.flush()
	var error := f.get_error()
	f.close()
	return "" if error == OK else "sidecar append failed (error %d)" % error


static func length_of(path: String) -> int:
	## Byte length; -1 when the file does not exist or cannot be opened.
	var f := FileAccess.open(path, FileAccess.READ) if FileAccess.file_exists(path) else null
	return -1 if f == null else f.get_length()


static func truncate(path: String, length: int) -> String:
	## Undo an append: cut the file back to length bytes (length_of before the
	## append); -1 removes the file the append created.
	if length < 0: return remove(path)
	if not FileAccess.file_exists(path): return ""
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null: return "cannot reopen sidecar %s to undo a failed append (error %d)" % [path, FileAccess.get_open_error()]
	var error := f.resize(length)
	f.close()
	return "" if error == OK else "cannot cut sidecar %s back after a failed append (error %d)" % [path, error]


static func settle_marker(target_sha: String) -> String:
	return '{"_type":"settle","target":%s}' % JSON.stringify(target_sha)


static func remove(path: String) -> String:
	if not FileAccess.file_exists(path): return ""
	var error := DirAccess.remove_absolute(path)
	return "" if error == OK else "cannot remove settled sidecar %s (error %d)" % [path, error]


# -- Replay -------------------------------------------------------------------

static func replay_into(parsed: Dictionary, canonical_path: String, canonical_sha: String, sidecar_bytes: PackedByteArray) -> String:
	## Apply sidecar_bytes' records to the parse of the canonical whose bytes
	## hash to canonical_sha, in place. The caller read both files once and
	## fingerprints the same bytes. Returns "" on success (including an empty
	## sidecar) or the reason the load must be refused.
	var path := path_for(canonical_path)
	if sidecar_bytes.is_empty(): return ""
	# UTF-8 decoding stops at a NUL, which would silently drop every later record.
	if sidecar_bytes.has(0): return "sidecar %s contains a NUL byte; refusing to open it — replay would discard every record after it. Repair or restore the sidecar" % path
	var lines := sidecar_bytes.get_string_from_utf8().split("\n")
	# Everything after the last newline is an append that never completed.
	var torn := lines[lines.size() - 1]
	lines.resize(lines.size() - 1)
	if not torn.strip_edges().is_empty(): push_warning("JSONLSidecar: ignoring incomplete final line in %s" % path)
	var records: Array = []
	for raw: String in lines:
		var line := raw.strip_edges()
		if line.is_empty(): continue
		var record = JSON.parse_string(line)
		if not record is Dictionary:
			push_warning("JSONLSidecar: ignoring unacknowledged torn line in %s" % path)
			continue
		match str(record.get("_type", "")):
			"wal": records.append(record)
			"settle":
				# The canonical already holds everything journaled before this point.
				if str(record.get("target", "")) == canonical_sha: records.clear()
			_: return "sidecar %s has an unknown record kind '%s'; repair or remove it before opening" % [path, str(record.get("_type", ""))]
	if records.is_empty(): return ""

	# Latest replacement wins per (id, section); keys are "id\tsection".
	var replaced := {}
	var meta_record: Dictionary = {}
	for record: Dictionary in records:
		if str(record.get("base", "")) != canonical_sha:
			push_warning("JSONLSidecar: %s holds records written against another version of %s; replay overrides only the sections it names — review git diff after the next settle" % [path, canonical_path])
		if not record.get("replace") is Array or not record.get("records") is Array:
			return "sidecar %s has a malformed record; repair or remove it before opening" % path
		for pair in record["replace"]:
			if not pair is Array or pair.size() != 2: return "sidecar %s has a malformed replace entry" % path
			replaced["%s\t%s" % [pair[0], pair[1]]] = []
		for value in record["records"]:
			if not value is Dictionary: return "sidecar %s has a non-object record" % path
			var parsed_record := JSONLParser.parse_record(value)
			if parsed_record.is_empty(): return "sidecar %s holds an invalid %s record; repair or remove it before opening" % [path, str(value.get("_type", "?"))]
			var kind := str(parsed_record._type)
			if kind == "meta":
				if not replaced.has("\tmeta"): return "sidecar %s has a meta record outside its replace set" % path
				meta_record = parsed_record
				continue
			var key := "%s\t%s" % [_owner_id(parsed_record), _section_of(kind)]
			if not replaced.has(key): return "sidecar %s has a %s record outside its replace set" % [path, kind]
			replaced[key].append(parsed_record)
		# A deleted item takes its dependent sections with it at this point in the
		# sequence; a later record that re-creates the id replaces them again.
		for pair in record["replace"]:
			if str(pair[1]) == "item" and replaced["%s\titem" % pair[0]].is_empty():
				for section in _ITEM_SECTIONS: replaced["%s\t%s" % [pair[0], section]] = []

	var buckets := {"item": "items", "events": "events", "comments": "comments", "links": "links", "attachments": "attachments"}
	for section: String in buckets:
		var bucket: String = buckets[section]
		var kept: Array = []
		for existing: Dictionary in parsed[bucket]:
			if not replaced.has("%s\t%s" % [_owner_id(existing), section]): kept.append(existing)
		for key: String in replaced:
			if key.get_slice("\t", 1) == section: kept.append_array(replaced[key])
		parsed[bucket] = kept
	if not meta_record.is_empty():
		# The format version belongs to the canonical, never to a journal record.
		meta_record["version"] = parsed.meta.get("version", meta_record.get("version", ""))
		parsed["meta"] = meta_record
	var dependency_error := JSONLParser._validate_record_dependencies(parsed)
	if not dependency_error.is_empty(): return "sidecar %s replay left %s; repair or remove it before opening" % [path, dependency_error]
	parsed["registry_diagnostics"] = JSONLParser._item_registry_diagnostics(parsed)
	return ""


static func _section_of(kind: String) -> String:
	match kind:
		"item": return "item"
		"event": return "events"
		"comment": return "comments"
		"link": return "links"
		"attachment": return "attachments"
	return ""


static func _owner_id(record: Dictionary) -> String:
	match str(record.get("_type", "")):
		"item": return str(record.get("id", ""))
		"link": return str(record.get("from_id", ""))
	return str(record.get("item_id", ""))
