extends RefCounted
class_name JSONLTypeUpgrade
## Explicit 1.0 -> 2.0 upgrade with a byte-for-byte rollback snapshot. Preview
## performs every semantic check used by apply and never mutates source/cache.

static var cache_delete_failure_hook: Callable = Callable()

static func preview(path: String, schema: Dictionary = {}) -> Dictionary:
	var result := {"ok": false, "error": "", "from_version": "", "to_version": "2.0.0", "definitions": 0, "items": 0, "bindings": [], "unresolved": [], "source_hash": "", "backup_path": path + ".pre-v2.bak", "cache_path": path + ".v2.cache"}
	if JSONLMigration.detect_format(path) != "jsonl": result.error = "custom types require explicit SQLite-to-JSONL promotion first"; return result
	var parsed := JSONLParser.parse_file(path)
	if not str(parsed.get("error", "")).is_empty(): result.error = parsed.error; return result
	result.from_version = str(parsed.meta.version)
	result.source_hash = FileAccess.get_sha256(path)
	if result.from_version != "1.0.0": result.error = "upgrade requires a 1.0.0 JSONL source"; return result
	var effective := schema if not schema.is_empty() else TypeRegistryBootstrap.load_shipped_schema()
	if effective.is_empty(): result.error = "shipped schema is unavailable"; return result
	var bootstrap := TypeRegistryBootstrap.records(effective)
	result.definitions = bootstrap.type_defs.size()
	var by_slug := {}
	for definition in bootstrap.type_defs: by_slug[definition.slug] = definition
	var revisions := {}
	for revision in bootstrap.type_def_versions: revisions[revision.id] = revision
	for item_value in parsed.items:
		var item: Dictionary = item_value
		var slug := str(item.type)
		if not by_slug.has(slug): result.unresolved.append({"item_id": item.id, "type": slug, "reason": "unknown type slug"}); continue
		var definition: Dictionary = by_slug[slug]
		var revision: Dictionary = revisions[definition.current_revision]
		var states: Array = []
		for state in revision.definition.lifecycle.states: states.append(state.key)
		if not states.has(item.status): result.unresolved.append({"item_id": item.id, "type": slug, "status": item.status, "reason": "unknown status"}); continue
		result.bindings.append({"item_id": item.id, "type_id": definition.id, "type_revision": definition.current_revision})
	result.items = parsed.items.size()
	result.ok = result.unresolved.is_empty()
	if not result.ok: result.error = "unresolved item definitions must be repaired before upgrade"
	return result

static func apply(path: String, expected_preview: Dictionary, schema: Dictionary = {}, exclusive_writer_confirmed: bool = false) -> Dictionary:
	if not exclusive_writer_confirmed: return {"ok": false, "error": "confirm exclusive upgrade workflow with incompatible writers stopped"}
	var checked := preview(path, schema)
	if not checked.ok: return checked
	for key in ["from_version", "to_version", "items", "definitions", "bindings", "source_hash"]:
		if checked.get(key) != expected_preview.get(key): return {"ok": false, "error": "canonical source changed since upgrade preview"}
	var lock := FileLock.acquire(path)
	if lock == null: return {"ok": false, "error": "could not acquire advisory lock"}
	if FileAccess.get_sha256(path) != checked.source_hash: lock.release(); return {"ok": false, "error": "canonical source changed while acquiring upgrade lock"}
	var source := FileAccess.open(path, FileAccess.READ)
	if source == null: lock.release(); return {"ok": false, "error": "cannot read canonical source"}
	var original := source.get_as_text(); source.close()
	var backup_path := str(checked.backup_path)
	if FileAccess.file_exists(backup_path): lock.release(); return {"ok": false, "error": "upgrade backup already exists: %s" % backup_path}
	var backup := FileAccess.open(backup_path, FileAccess.WRITE)
	if backup == null: lock.release(); return {"ok": false, "error": "cannot create rollback snapshot"}
	backup.store_string(original); backup.flush()
	var backup_error := backup.get_error()
	backup.close()
	if backup_error != OK: lock.release(); return {"ok": false, "error": "rollback snapshot write failed", "backup_path": backup_path}
	var bootstrap := TypeRegistryBootstrap.records(schema if not schema.is_empty() else TypeRegistryBootstrap.load_shipped_schema())
	var binding_by_id := {}
	for binding in checked.bindings: binding_by_id[binding.item_id] = binding
	var text := _upgrade_raw_records(original, bootstrap, binding_by_id)
	var write_error := DocketDBJsonl._atomic_write(path, text)
	lock.release()
	if not write_error.is_empty(): return {"ok": false, "error": write_error, "backup_path": backup_path}
	var upgraded_hash := FileAccess.get_sha256(path)
	var cache_error := str(cache_delete_failure_hook.call()) if cache_delete_failure_hook.is_valid() else JSONLCache.delete_cache_family(path)
	if not cache_error.is_empty(): return {"ok": false, "error": cache_error, "backup_path": backup_path, "upgraded_hash": upgraded_hash}
	return {"ok": true, "backup_path": backup_path, "cache_path": checked.cache_path, "items": checked.items, "definitions": checked.definitions, "upgraded_hash": upgraded_hash}

static func rollback(path: String, expected_upgraded_hash: String) -> Dictionary:
	var backup_path := path + ".pre-v2.bak"
	if not FileAccess.file_exists(backup_path): return {"ok": false, "error": "rollback snapshot is missing"}
	if expected_upgraded_hash.is_empty() or FileAccess.get_sha256(path) != expected_upgraded_hash: return {"ok": false, "error": "upgraded source changed; refusing destructive rollback"}
	var lock := FileLock.acquire(path)
	if lock == null: return {"ok": false, "error": "could not acquire advisory lock"}
	if FileAccess.get_sha256(path) != expected_upgraded_hash: lock.release(); return {"ok": false, "error": "upgraded source changed while acquiring rollback lock"}
	var backup := FileAccess.open(backup_path, FileAccess.READ)
	if backup == null: lock.release(); return {"ok": false, "error": "rollback snapshot is unreadable"}
	var content := backup.get_as_text(); backup.close()
	var error := DocketDBJsonl._atomic_write(path, content)
	lock.release()
	if not error.is_empty(): return {"ok": false, "error": error}
	var cache_error := JSONLCache.delete_cache_family(path)
	if not cache_error.is_empty(): return {"ok": false, "error": cache_error, "backup_path": backup_path}
	DirAccess.remove_absolute(backup_path)
	return {"ok": true}

static func _upgrade_raw_records(original: String, bootstrap: Dictionary, bindings: Dictionary) -> String:
	var lines: PackedStringArray = []
	for raw_value in original.split("\n"):
		var raw := str(raw_value)
		if raw.strip_edges().is_empty(): continue
		var record = JSON.parse_string(raw)
		if record is Dictionary and record.get("_type") == "meta":
			record.version = "2.0.0"
			lines.append(JSONLSerializer._to_ordered_json(record))
			for definition in bootstrap.type_defs: lines.append(JSONLSerializer._to_ordered_json(definition))
			for revision in bootstrap.type_def_versions: lines.append(JSONLSerializer._to_ordered_json(revision))
		elif record is Dictionary and record.get("_type") == "item":
			var binding: Dictionary = bindings[record.id]
			record.type_id = binding.type_id
			record.type_revision = binding.type_revision
			lines.append(JSONLSerializer._to_ordered_json(record))
		else:
			# Binary-bearing and future-compatible known records remain byte-for-byte
			# identical; upgrade changes only meta, registry, and item binding records.
			lines.append(raw)
	return "\n".join(lines) + "\n"
