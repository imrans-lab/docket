extends Node
## Behavioral storage checks for JSONL 2.0 registries and lossless envelopes.

var A := AssertHelpers
const DIR := "user://test_dynamic_type_storage"

func setup() -> void: DirAccess.make_dir_recursive_absolute(DIR)
func teardown() -> void: _remove_tree(DIR)

func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null: return
	for name in dir.get_files(): dir.remove(name)
	for name in dir.get_directories(): _remove_tree(path + "/" + name)
	DirAccess.remove_absolute(path)

func _copy_fixture(name: String, target: String) -> String:
	var source := FileAccess.open("res://test/fixtures/%s" % name, FileAccess.READ)
	var text := source.get_as_text(); source.close()
	var output := FileAccess.open(target, FileAccess.WRITE); output.store_string(text); output.close()
	return text

func _read_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	var text := file.get_as_text(); file.close()
	return text

func test_sqlite_extension_supports_required_json_functions() -> Variant:
	var db := DocketDB.create_new(DIR + "/json-probe.cache")
	var rows := db._exec_select("SELECT json_valid(?) AS valid, json_extract(?, '$.n') AS value;", ['{"n":7}', '{"n":7}'])
	var r = A.eq(rows.size(), 1, "JSON probe returns a row")
	if r is String: db.close(); return r
	r = A.is_true(int(rows[0].valid) == 1 and int(rows[0].value) == 7, "shipped SQLite supports json_valid/json_extract")
	db.close(); return r

func test_bootstrap_revision_identity_is_content_addressed() -> Variant:
	var schema := TypeRegistryBootstrap.load_shipped_schema()
	var first := TypeRegistryBootstrap.records(schema)
	var second := TypeRegistryBootstrap.records(schema)
	var r = A.eq(first.type_def_versions[0].id, second.type_def_versions[0].id, "same definition has stable revision identity")
	if r is String: return r
	var changed := schema.duplicate(true); changed.types.bug.description = "changed"
	var third := TypeRegistryBootstrap.records(changed)
	return A.is_true(first.type_def_versions[0].id != third.type_def_versions[0].id, "changed complete definition gets a new revision identity")

func test_bootstrap_preserves_declared_terminal_semantics_and_protected_behavior() -> Variant:
	var records := TypeRegistryBootstrap.records(TypeRegistryBootstrap.load_shipped_schema())
	var by_slug := {}
	for revision in records.type_def_versions: by_slug[revision.definition.slug] = revision.definition
	var r = A.eq(by_slug.discussion.lifecycle.terminal_states, [], "resolved remains nonterminal")
	if r is String: return r
	r = A.eq(by_slug.skill.lifecycle.states[2].state_category, "waiting", "archived remains nonterminal waiting")
	if r is String: return r
	r = A.eq(by_slug.encrypted_note.lifecycle.terminal_states, ["sealed"], "declared terminal retained despite outgoing edge")
	if r is String: return r
	return A.is_false(by_slug.secret.protected_behavior.regular_creation_allowed, "special secret creation restriction is snapshotted")

func test_parser_resolves_registry_after_item_and_preserves_all_json_values() -> Variant:
	var path := DIR + "/order.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var parsed := JSONLParser.parse_file(path)
	var item: Dictionary = parsed.items[0]
	var r = A.eq(parsed.registry_diagnostics, [], "record order does not affect resolution")
	if r is String: return r
	r = A.eq(item.fields, {"count":0.0,"enabled":false,"empty":"","nil":null,"array":[],"object":{},"unicode":"雪","literal":"\\n\\t","actual":"line\nnext\tcell"}, "field envelope preserves every JSON value")
	if r is String: return r
	return A.eq(item.extras.future_payload.nested, [1.0, true, null], "unknown top-level payload moves into extras")

func test_ambiguous_flat_and_nested_item_is_rejected() -> Variant:
	var line := '{"_type":"item","id":"X","type":"bug","status":"new","title":"flat","created_at":"x","updated_at":"x","fields":{"title":"nested"}}'
	return A.eq(JSONLParser.parse_line(line), {}, "one key cannot have flat and nested authorities")

func test_cache_roundtrip_and_title_edit_preserve_envelopes() -> Variant:
	var path := DIR + "/roundtrip.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var before: Dictionary = db.get_item("ORD-0001")
	var error := db.update_item_fields_checked("ORD-0001", {"title":"Changed only"})
	var after: Dictionary = db.get_item("ORD-0001")
	var r = A.eq(error, "", "checked title update succeeds")
	if r is String: db.close(); return r
	r = A.eq(after.fields, before.fields, "unrelated edit preserves custom values")
	if r is String: db.close(); return r
	r = A.eq(after.extras, before.extras, "unrelated edit preserves future payload")
	db.close(); return r

func test_field_updates_merge_exact_values_and_unset_is_explicit() -> Variant:
	var path := DIR + "/field-update.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var error := db.update_item_fields_checked("ORD-0001", {"fields":{"count":null,"added":false,"empty_container":[]}})
	var item := db.get_item("ORD-0001")
	var r = A.eq(error, "", "field merge succeeds")
	if r is String: db.close(); return r
	r = A.is_true(item.fields.has("count") and item.fields.count == null and item.fields.added == false and item.fields.empty_container == [], "null false and empty container remain explicit")
	if r is String: db.close(); return r
	r = A.eq(item.fields.unicode, "雪", "unmentioned custom field survives merge")
	if r is String: db.close(); return r
	error = db.update_item_fields_checked("ORD-0001", {"unset_fields":["count"]})
	item = db.get_item("ORD-0001")
	r = A.is_true(error.is_empty() and not item.fields.has("count") and item.fields.has("empty"), "unset removes only named key")
	db.close(); return r

func test_full_export_import_preserves_pins_and_envelopes() -> Variant:
	var path := DIR + "/export.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var source := JSONLCache.rebuild_cache(path, path + ".v2.cache")
	var exported := source.export_item_full("ORD-0001")
	var target := DocketDB.create_new(DIR + "/target.cache")
	target.import_item_full("COPY-1", exported)
	var copied := target.get_item("COPY-1")
	var r = A.eq(copied.fields, exported.item.fields, "custom fields survive full transfer")
	if r is String: source.close(); target.close(); return r
	r = A.eq(copied.type_revision, exported.item.type_revision, "revision pin survives full transfer")
	if r is String: source.close(); target.close(); return r
	r = A.eq(copied.extras, exported.item.extras, "unknown payload survives full transfer")
	source.close(); target.close(); return r

func test_recursive_serialization_is_deterministic() -> Variant:
	var left := {"z":{"b":2,"a":1},"a":[{"y":2,"x":1}]}
	var right := {"a":[{"x":1,"y":2}],"z":{"a":1,"b":2}}
	return A.eq(JSONLSerializer._json_value(left), JSONLSerializer._json_value(right), "recursive object key order is canonical")

func test_unsupported_version_refuses_warm_cache_without_mutation() -> Variant:
	var path := DIR + "/future.dct"
	var file := FileAccess.open(path, FileAccess.WRITE); file.store_string('{"_type":"meta","version":"99.0.0","counter":0,"id_prefix":"X"}\n'); file.close()
	var cache_path := path + ".cache"
	var cache := FileAccess.open(cache_path, FileAccess.WRITE); cache.store_string("sentinel"); cache.close()
	var opened := DocketDBJsonl.open_jsonl(path)
	var reread := FileAccess.open(cache_path, FileAccess.READ); var content := reread.get_as_text(); reread.close()
	var r = A.eq(opened, null, "unsupported source is refused before warm cache")
	if r is String: return r
	return A.eq(content, "sentinel", "refusal does not mutate existing cache")

func test_upgrade_requires_explicit_exclusive_confirmation_and_roundtrips() -> Variant:
	var path := DIR + "/upgrade.dct"
	var original := _copy_fixture("dynamic_types_legacy_v1.jsonl", path)
	var preview := JSONLTypeUpgrade.preview(path)
	var denied := JSONLTypeUpgrade.apply(path, preview)
	var r = A.is_false(denied.ok, "shared-file upgrade requires explicit writer shutdown confirmation")
	if r is String: return r
	var applied := JSONLTypeUpgrade.apply(path, preview, {}, true)
	if not applied.ok: return "upgrade failed: %s" % applied.error
	var upgraded := _read_file(path)
	r = A.is_true(upgraded.contains('"type_def"') and upgraded.contains('"type_revision"'), "upgrade adds definitions and item pins")
	if r is String: return r
	r = A.is_true(upgraded.contains('"_type":"event"') and upgraded.contains('"_type":"comment"') and upgraded.contains('"_type":"saved_query"'), "unrelated records survive upgrade")
	if r is String: return r
	r = A.is_true(upgraded.contains('{"_type":"attachment","id":1,"item_id":"LEG-0001","filename":"tiny.bin","data":"AAEC/w=="') and upgraded.contains('"future_vault_flag":{"kept":true}'), "binary attachment and unknown vault payload remain verbatim")
	if r is String: return r
	var rolled := JSONLTypeUpgrade.rollback(path, applied.upgraded_hash)
	if not rolled.ok: return "rollback failed: %s" % rolled.error
	var restored := _read_file(path)
	return A.eq(restored, original, "rollback restores exact 1.0 source")

func test_upgrade_preview_detects_source_change_and_unresolved_items() -> Variant:
	var path := DIR + "/stale.dct"
	var original := _copy_fixture("dynamic_types_legacy_v1.jsonl", path)
	var preview := JSONLTypeUpgrade.preview(path)
	var file := FileAccess.open(path, FileAccess.WRITE); file.store_string(original.replace("Legacy discussion", "Edited title")); file.close()
	var stale := JSONLTypeUpgrade.apply(path, preview, {}, true)
	var r = A.is_false(stale.ok, "any canonical edit invalidates preview")
	if r is String: return r
	file = FileAccess.open(path, FileAccess.WRITE); file.store_string(original.replace('"type":"discussion"', '"type":"foreign"')); file.close()
	var unresolved := JSONLTypeUpgrade.preview(path)
	return A.is_true(not unresolved.ok and unresolved.unresolved.size() == 1, "unknown legacy type blocks upgrade with item diagnostic")

func test_new_file_seeds_v2_registry_and_uses_v2_cache() -> Variant:
	var path := DIR + "/new.dct"
	var db := DocketDBJsonl.create_new_jsonl(path)
	var parsed := JSONLParser.parse_file(path)
	var r = A.eq(parsed.meta.version, "2.0.0", "new file uses v2")
	if r is String: db.close(); return r
	r = A.eq(parsed.type_defs.size(), TypeRegistryBootstrap.load_shipped_schema().types.size(), "new file snapshots all starters")
	if r is String: db.close(); return r
	r = A.is_true(FileAccess.file_exists(path + ".v2.cache") and not FileAccess.file_exists(path + ".cache"), "new format has isolated cache name")
	db.close(); return r

func test_lock_failure_has_bounded_zero_timeout() -> Variant:
	var lock := FileLock.acquire(DIR + "/missing/parent/file.dct", 0)
	return A.eq(lock, null, "failed lock creation honors deadline")

func test_unresolved_registry_opens_read_only_and_close_preserves_source() -> Variant:
	var path := DIR + "/unresolved.dct"
	var text := _copy_fixture("dynamic_types_record_order_v2.jsonl", path).replace('"id":"ORD-0001","type":"widget","type_id":"type:widget"', '"id":"ORD-0001","type":"widget","type_id":"missing"')
	var file := FileAccess.open(path, FileAccess.WRITE); file.store_string(text); file.close()
	var db := DocketDBJsonl.open_jsonl(path)
	var r = A.eq(db.get_storage_diagnostics().size(), 1, "missing definition is visible")
	if r is String: db.close(); return r
	r = A.is_true(not db.update_item_fields_checked("ORD-0001", {"title":"unsafe"}).is_empty(), "destructive write is blocked")
	db.close()
	var preserved := _read_file(path)
	return A.eq(preserved, text, "close cannot flush cache over unresolved source")

func test_same_size_external_edit_is_reloaded_before_unrelated_write() -> Variant:
	var path := DIR + "/same-size.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var file := FileAccess.open(path, FileAccess.READ)
	var external := file.get_as_text().replace("Before definition", "External revision"); file.close()
	file = FileAccess.open(path, FileAccess.WRITE); file.store_string(external); file.close()
	var error := db.update_item_fields_checked("ORD-0001", {"fields":{"new_value":1}})
	var item := db.get_item("ORD-0001")
	var r = A.eq(error, "", "unrelated checked write reloads rapid canonical edit")
	if r is String: db.close(); return r
	r = A.eq(item.title, "External revision", "same-length external title is preserved")
	db.close(); return r

func test_missing_or_unreadable_canonical_blocks_before_cache_mutation_and_close() -> Variant:
	var path := DIR + "/missing-source.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	DirAccess.remove_absolute(path)
	var error := db.update_item_fields_checked("ORD-0001", {"title":"must not enter cache"})
	var r = A.is_true(not error.is_empty(), "missing source blocks checked write")
	if r is String: db.close(); return r
	r = A.eq(db.get_item("ORD-0001").title, "Before definition", "blocked write leaves cache unchanged")
	db.close()
	if r is String: return r
	return A.is_false(FileAccess.file_exists(path), "close does not recreate missing canonical source")

func test_failed_reload_and_close_preserve_conflicted_canonical_source() -> Variant:
	var path := DIR + "/conflict.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var conflict := "<<<<<<< ours\ninvalid\n=======\ninvalid\n>>>>>>> theirs\n"
	var file := FileAccess.open(path, FileAccess.WRITE); file.store_string(conflict); file.close()
	var error := db.update_item_fields_checked("ORD-0001", {"title":"unsafe"})
	var r = A.is_true(not error.is_empty(), "failed canonical reload blocks mutation")
	db.close()
	if r is String: return r
	file = FileAccess.open(path, FileAccess.READ); var preserved := file.get_as_text(); file.close()
	return A.eq(preserved, conflict, "close cannot overwrite unresolved canonical source")

func test_injected_lock_and_atomic_write_failures_restore_canonical_cache() -> Variant:
	var path := DIR + "/write-failure.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	db._lock_timeout_ms = 0
	var lock_file := FileAccess.open(path + ".lock", FileAccess.WRITE)
	lock_file.store_string(JSON.stringify({"pid":OS.get_process_id(),"timestamp":Time.get_unix_time_from_system()})); lock_file.close()
	var error := db.update_item_fields_checked("ORD-0001", {"title":"lock leak"})
	DirAccess.remove_absolute(path + ".lock")
	var r = A.is_true(not error.is_empty() and db.get_item("ORD-0001").title == "Before definition", "lock failure is reported and cache reconstructed")
	if r is String: db.close(); return r
	db._atomic_write_hook = func(_path, _text): return "injected temp write failure"
	error = db.update_item_fields_checked("ORD-0001", {"title":"temp leak"})
	r = A.is_true(error.contains("injected") and db.get_item("ORD-0001").title == "Before definition", "atomic failure is reported and cache reconstructed")
	db._atomic_write_hook = Callable()
	db.close(); return r

func test_malformed_cached_envelope_cannot_be_flushed_over_canonical_source() -> Variant:
	var path := DIR + "/malformed-envelope.dct"
	var original := _copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	db._exec("UPDATE items SET fields_json='not-json' WHERE id='ORD-0001';")
	var error := db.update_item_fields_checked("ORD-0001", {"title":"unsafe"})
	var r = A.is_true(not error.is_empty(), "malformed cache payload blocks canonical flush")
	if r is String: db.close(); return r
	r = A.eq(_read_file(path), original, "canonical source remains unchanged")
	if r is String: db.close(); return r
	r = A.eq(db.get_item("ORD-0001").fields.count, 0.0, "cache is reconstructed from canonical JSON number")
	db.close(); return r

func test_rollback_refuses_to_erase_post_upgrade_edit() -> Variant:
	var path := DIR + "/rollback-stale.dct"
	_copy_fixture("dynamic_types_legacy_v1.jsonl", path)
	var preview := JSONLTypeUpgrade.preview(path)
	var applied := JSONLTypeUpgrade.apply(path, preview, {}, true)
	if not applied.ok: return "upgrade failed: %s" % applied.error
	var file := FileAccess.open(path, FileAccess.READ)
	var changed := file.get_as_text().replace("Legacy discussion", "Later discussion!"); file.close()
	file = FileAccess.open(path, FileAccess.WRITE); file.store_string(changed); file.close()
	var rollback := JSONLTypeUpgrade.rollback(path, applied.upgraded_hash)
	return A.is_true(not rollback.ok and FileAccess.file_exists(path + ".pre-v2.bak"), "rollback preserves recovery snapshot after later edits")

func test_duplicate_registry_identity_and_slug_are_rejected() -> Variant:
	var path := DIR + "/duplicate.dct"
	var original := _copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var duplicate := '{"_type":"type_def","id":"type:other","slug":"widget","lifecycle":"active","current_revision":"type:widget@abc","provenance":{}}\n'
	var file := FileAccess.open(path, FileAccess.WRITE); file.store_string(original + duplicate); file.close()
	var parsed := JSONLParser.parse_file(path)
	return A.is_true(str(parsed.error).contains("duplicate") and str(parsed.error).contains("slug"), "ambiguous project-local slug refuses whole file")

func test_checked_registry_compound_write_rolls_back_cache_after_canonical_failure() -> Variant:
	var path := DIR + "/compound.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var parsed := JSONLParser.parse_file(path)
	var old_definition: Dictionary = parsed.type_defs[0]
	var old_revision: Dictionary = parsed.type_def_versions[0]
	var new_revision := old_revision.duplicate(true)
	new_revision.parent_revision = old_revision.id
	new_revision.definition.label = "Changed Widget"
	new_revision.reason = "test checked compound write"
	new_revision.id = "%s@%s" % [new_revision.type_id, TypeRegistryBootstrap._definition_hash(new_revision.definition)]
	var new_definition := old_definition.duplicate(true)
	new_definition.current_revision = new_revision.id
	db._atomic_write_hook = func(_path, _text): return "injected canonical failure"
	var error := db.apply_registry_change(new_definition, new_revision, [{"item_id":"ORD-0001","type_id":new_definition.id,"type_revision":new_revision.id}], [{"item_id":"ORD-0001","event_type":"type_revision_changed","timestamp":"2026-09-12T00:00:00Z"}], old_revision.id)
	var revision_rows := db._exec_select("SELECT id FROM type_def_versions WHERE id=?;", [new_revision.id])
	var r = A.is_true(error.contains("injected") and revision_rows.is_empty(), "failed canonical replacement reconstructs cache without staged revision")
	if r is String: db._atomic_write_hook = Callable(); db.close(); return r
	r = A.eq(db.get_item("ORD-0001").type_revision, old_revision.id, "failed compound write restores item pin")
	db._atomic_write_hook = Callable(); db.close(); return r

func test_checked_registry_compound_write_persists_one_coherent_snapshot_without_ddl() -> Variant:
	var path := DIR + "/compound-success.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var before_columns := db._exec_select("PRAGMA table_info(items);").size()
	var parsed := JSONLParser.parse_file(path)
	var definition: Dictionary = parsed.type_defs[0].duplicate(true)
	var revision: Dictionary = parsed.type_def_versions[0].duplicate(true)
	var previous := str(revision.id)
	revision.parent_revision = previous
	revision.definition.fields.append({"key":"reviewer","type":"string","required":false,"nullable":true})
	revision.reason = "coherent write fixture"
	revision.id = "%s@%s" % [revision.type_id, TypeRegistryBootstrap._definition_hash(revision.definition)]
	definition.current_revision = revision.id
	var error := db.apply_registry_change(definition, revision, [{"item_id":"ORD-0001","type_id":definition.id,"type_revision":revision.id}], [{"item_id":"ORD-0001","event_type":"type_revision_changed","timestamp":"2026-09-12T00:00:00Z"}], previous)
	var after_columns := db._exec_select("PRAGMA table_info(items);").size()
	var written := JSONLParser.parse_file(path)
	var r = A.eq(error, "", "compound registry write succeeds")
	if r is String: db.close(); return r
	r = A.eq(after_columns, before_columns, "adding a field performs no item-table DDL")
	if r is String: db.close(); return r
	r = A.eq(written.type_defs[0].current_revision, revision.id, "current pointer and immutable revision persist together")
	if r is String: db.close(); return r
	r = A.eq(written.items[0].type_revision, revision.id, "item pin persists with registry snapshot")
	if r is String: db.close(); return r
	var found_event := false
	for event in written.events:
		if event.event_type == "type_revision_changed": found_event = true
	r = A.is_true(found_event, "audit event persists in same canonical replacement")
	db.close(); return r

func test_upgrade_reports_old_cache_invalidation_failure_and_keeps_recovery_snapshot() -> Variant:
	var path := DIR + "/cache-delete-failure.dct"
	_copy_fixture("dynamic_types_legacy_v1.jsonl", path)
	var old_cache := FileAccess.open(path + ".cache", FileAccess.WRITE); old_cache.store_string("old-reader-cache"); old_cache.close()
	var preview := JSONLTypeUpgrade.preview(path)
	JSONLCache.cache_delete_hook = func(_path): return ERR_CANT_CREATE
	var applied := JSONLTypeUpgrade.apply(path, preview, {}, true)
	JSONLCache.cache_delete_hook = Callable()
	var r = A.is_false(applied.ok, "upgrade cannot report compatibility-safe success when old cache remains")
	if r is String: return r
	r = A.is_true(FileAccess.file_exists(path + ".cache"), "failed invalidation leaves evidence for repair")
	if r is String: return r
	return A.is_true(FileAccess.file_exists(path + ".pre-v2.bak"), "rollback snapshot is retained")

func test_cache_rebuild_sql_failure_rolls_back_and_never_marks_partial_cache_fresh() -> Variant:
	var path := DIR + "/cache-sql-failure.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var cache_path := path + ".v2.cache"
	JSONLCache.rebuild_failure_hook = func(): return "injected cache insert failure"
	var db := JSONLCache.rebuild_cache(path, cache_path)
	JSONLCache.rebuild_failure_hook = Callable()
	var r = A.eq(db, null, "cache rebuild propagates compound SQL failure")
	if r is String:
		if db != null: db.close()
		return r
	return A.is_false(FileAccess.file_exists(cache_path), "partial cache is removed rather than marked fresh")

func test_new_file_seed_failure_does_not_publish_partial_canonical_state() -> Variant:
	var path := DIR + "/seed-sql-failure.dct"
	TypeRegistryBootstrap.seed_failure_hook = func(): return "injected registry seed failure"
	var db := DocketDBJsonl.create_new_jsonl(path)
	TypeRegistryBootstrap.seed_failure_hook = Callable()
	var r = A.eq(db, null, "new-file creation propagates an incomplete registry seed")
	if r is String:
		if db != null: db.close()
		return r
	if FileAccess.file_exists(path): return A.is_false(true, "failed seed must not publish a canonical file")
	var cache_path := path + ".v2.cache"
	if not FileAccess.file_exists(cache_path): return true
	var cache := DocketDB.new()
	if not cache.open(cache_path): return A.is_true(false, "leftover cache should remain inspectable")
	var definitions: Array = cache._exec_select("SELECT id FROM type_defs;")
	var version := cache.get_meta_value("jsonl_version", "")
	cache.close()
	r = A.eq(definitions.size(), 0, "failed seed transaction rolls back registry rows")
	if r is String: return r
	return A.eq(version, "", "failed seed transaction does not mark cache as format 2")

func test_registry_rejects_forged_digest_and_missing_active_pointer() -> Variant:
	var path := DIR + "/registry-forged.dct"
	var original := _copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var forged := original.replace("Fixture", "Changed without revision identity")
	var file := FileAccess.open(path, FileAccess.WRITE); file.store_string(forged); file.close()
	var parsed := JSONLParser.parse_file(path)
	var r = A.contains(parsed.error, "canonical definition digest", "definition content is bound to immutable revision id")
	if r is String: return r
	file = FileAccess.open(path, FileAccess.WRITE); file.store_string(original.replace("current_revision\":\"type:widget@", "current_revision\":\"type:widget@missing-")); file.close()
	parsed = JSONLParser.parse_file(path)
	return A.contains(parsed.error, "missing current revision", "active pointer must resolve")

func test_orphaned_related_record_refuses_cache_rebuild() -> Variant:
	var path := DIR + "/orphan.dct"
	var original := _copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var orphan := '{"_type":"event","item_id":"MISSING","seq":1,"event_type":"created","timestamp":"2026-09-12T00:00:00Z"}\n'
	var file := FileAccess.open(path, FileAccess.WRITE); file.store_string(original + orphan); file.close()
	var parsed := JSONLParser.parse_file(path)
	var r = A.contains(parsed.error, "orphaned event", "canonical related records are never silently dropped")
	if r is String: return r
	return A.eq(JSONLCache.rebuild_cache(path, path + ".v2.cache"), null, "invalid canonical source cannot produce a cache")

func test_related_insert_failure_rolls_back_cache_and_canonical() -> Variant:
	var path := DIR + "/related-insert-failure.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var original := _read_file(path)
	var db := DocketDBJsonl.open_jsonl(path)
	db._exec("CREATE TRIGGER reject_tag BEFORE INSERT ON item_tags BEGIN SELECT RAISE(ABORT, 'tag rejected'); END;")
	var error := db.insert_item("ORD-0002", {"type":"widget","status":"queued","title":"Rejected","created_at":"x","updated_at":"x","tags":["blocked"]})
	var r = A.is_true(not error.is_empty(), "related-row SQL failure reaches caller")
	if r is String: db.close(); return r
	r = A.is_false(db.has_item("ORD-0002"), "main row is rolled back with related row")
	if r is String: db.close(); return r
	db.close()
	return A.eq(_read_file(path), original, "failed insert leaves canonical bytes unchanged")

func test_tag_update_rejects_malformed_or_ambiguous_envelopes_before_mutation() -> Variant:
	var path := DIR + "/envelope-update-refusal.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var original := _read_file(path)
	db._exec("UPDATE items SET fields_json='not-json' WHERE id='ORD-0001';")
	var error := db.update_item_fields_checked("ORD-0001", {"title":"unsafe"})
	var r = A.contains(error, "malformed", "malformed stored envelope blocks updates")
	if r is String: db.close(); return r
	db.reload()
	error = db.update_item_fields_checked("ORD-0001", {"fields_json":"{}"})
	r = A.contains(error, "internal envelope", "internal encoded columns are never accepted")
	if r is String: db.close(); return r
	error = db.update_item_fields_checked("ORD-0001", {"fields":{"count":2},"unset_fields":["count"]})
	r = A.contains(error, "ambiguous set/unset", "same key cannot be set and unset")
	db.close()
	if r is String: return r
	return A.eq(_read_file(path), original, "rejected envelope changes preserve canonical bytes")

func test_new_type_compound_persists_definition_revision_binding_and_event() -> Variant:
	var path := DIR + "/new-type-compound.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var parsed := JSONLParser.parse_file(path)
	var revision: Dictionary = parsed.type_def_versions[0].duplicate(true)
	revision.type_id = "type:gadget"
	revision.definition.slug = "gadget"
	revision.definition.label = "Gadget"
	revision.id = "%s@%s" % [revision.type_id, TypeRegistryBootstrap._definition_hash(revision.definition)]
	var definition := {"id":"type:gadget","slug":"gadget","lifecycle":"active","current_revision":revision.id,"provenance":{"kind":"custom","protected":false}}
	var error := db.apply_registry_change(definition, revision, [{"item_id":"ORD-0001","type_id":definition.id,"type_revision":revision.id}], [{"item_id":"ORD-0001","event_type":"type_revision_changed","timestamp":"2026-09-12T00:00:00Z"}], "")
	var r = A.eq(error, "", "new type stages parent before FK-bound revision")
	if r is String: db.close(); return r
	db.close()
	db = DocketDBJsonl.open_jsonl(path)
	var item := db.get_item("ORD-0001")
	r = A.eq(item.type_id, definition.id, "binding survives canonical reopen")
	if r is String: db.close(); return r
	var events := db.get_events("ORD-0001")
	var found := false
	for event in events:
		if event.event_type == "type_revision_changed": found = true
	db.close()
	return A.is_true(found, "compound audit event survives canonical reopen")

func test_import_and_delete_failures_roll_back_complete_operations() -> Variant:
	var path := DIR + "/import-delete-failure.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	db.update_item_fields_checked("ORD-0001", {"tags":["must-survive"]})
	db.add_event_checked("ORD-0001", "prepared", "tester")
	# Vault entries the item owns: under its own handle (with an archived
	# version) and under another one.
	db.set_secret("ORD-0001", PackedByteArray([1]), PackedByteArray([2]), PackedByteArray([3]), false, "ORD-0001")
	db.rotate_secret("ORD-0001", PackedByteArray([4]), PackedByteArray([5]), PackedByteArray([6]), "tester")
	db.set_secret("owned-elsewhere", PackedByteArray([7]), PackedByteArray([8]), PackedByteArray([9]), false, "ORD-0001")
	var vault_intact := func(check: DocketDB) -> bool:
		return not check.get_secret_raw("ORD-0001").is_empty() and not check.get_secret_raw("owned-elsewhere").is_empty() \
			and check.get_secret_versions("ORD-0001").size() == 1
	var original := _read_file(path)
	var expected_events := db.get_events("ORD-0001")
	var exported := db.export_item_full("ORD-0001")
	db._exec("CREATE TRIGGER reject_import_event BEFORE INSERT ON item_events BEGIN SELECT RAISE(ABORT, 'event rejected'); END;")
	var error := db.import_item_full_checked("ORD-0002", exported)
	var r = A.is_true(not error.is_empty() and not db.has_item("ORD-0002"), "failed related import rolls back its main row")
	if r is String: db.close(); return r
	db._exec("DROP TRIGGER IF EXISTS reject_import_event;")
	db._exec("CREATE TRIGGER reject_delete_event BEFORE DELETE ON item_events BEGIN SELECT RAISE(ABORT, 'delete rejected'); END;")
	error = db.delete_item_checked("ORD-0001")
	r = A.is_true(not error.is_empty(), "failed cascading delete reaches caller")
	if r is String: db.close(); return r
	r = A.is_true(db.has_item("ORD-0001"), "failed cascading delete restores the complete item")
	if r is String: db.close(); return r
	r = A.eq(db.get_item("ORD-0001").tags, ["must-survive"], "earlier tag deletion rolls back")
	if r is String: db.close(); return r
	r = A.eq(db.get_events("ORD-0001"), expected_events, "rejected event deletion preserves events")
	if r is String: db.close(); return r
	db.close()
	r = A.eq(_read_file(path), original, "failed import and delete preserve canonical bytes")
	if r is String: return r
	db = DocketDBJsonl.open_jsonl(path)
	r = A.is_true(db != null and db.has_item("ORD-0001") and not db.has_item("ORD-0002") and db.get_item("ORD-0001").tags == ["must-survive"] and db.get_events("ORD-0001") == expected_events and vault_intact.call(db), "canonical reopen observes the complete pre-failure item")
	if r is String:
		if db != null: db.close()
		return r
	error = db.delete_item_checked("ORD-0001")
	db.close()
	db = DocketDBJsonl.open_jsonl(path)
	r = A.is_true(error.is_empty() and not db.has_item("ORD-0001") and db.get_secret_raw("ORD-0001").is_empty() and db.get_secret_raw("owned-elsewhere").is_empty() and db.get_secret_versions("ORD-0001").is_empty(), "a successful deletion removes the item with its vault entries and archive: %s" % error)
	db.close()
	return r

func test_event_failure_returns_error_and_restores_item_timestamp() -> Variant:
	var path := DIR + "/event-failure.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var before := db.get_item("ORD-0001")
	db._exec("CREATE TRIGGER reject_event BEFORE INSERT ON item_events BEGIN SELECT RAISE(ABORT, 'event rejected'); END;")
	var error := db.add_event_checked("ORD-0001", "changed", "tester")
	var after := db.get_item("ORD-0001")
	var r = A.is_true(not error.is_empty(), "event insertion failure is observable")
	if r is String: db.close(); return r
	r = A.eq(after.updated_at, before.updated_at, "event and timestamp update share one rollback boundary")
	db.close()
	return r

func test_comment_resolution_event_failure_rolls_back_open_comment() -> Variant:
	var path := DIR + "/comment-resolution-failure.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var created := db.add_comment("ORD-0001", "reviewer", "keep this open")
	var comment_id := int(created.id)
	var canonical_before := _read_file(path)
	var events_before := db.get_events("ORD-0001")
	db._exec("CREATE TRIGGER reject_resolution_event BEFORE INSERT ON item_events BEGIN SELECT RAISE(ABORT, 'resolution audit rejected'); END;")
	var resolved := db.resolve_comment(comment_id, "accepted", "reviewer")
	var r = A.is_true(resolved.has("error"), "resolution audit failure reaches caller")
	if r is String: db.close(); return r
	var comment := db.get_comment(comment_id)
	r = A.is_true(not comment.is_empty() and comment.get("status") == "open" and comment.get("resolved_at", "") == "" and comment.get("resolved_by", "") == "", "comment resolution fields roll back with rejected audit event")
	if r is String: db.close(); return r
	r = A.eq(db.get_events("ORD-0001"), events_before, "failed resolution adds no event")
	if r is String: db.close(); return r
	db.close()
	r = A.eq(_read_file(path), canonical_before, "failed resolution preserves canonical bytes")
	if r is String: return r
	db = DocketDBJsonl.open_jsonl(path)
	comment = db.get_comment(comment_id)
	r = A.is_true(not comment.is_empty() and comment.get("status") == "open" and db.get_events("ORD-0001") == events_before, "reopen observes the original open comment and events")
	db.close()
	return r

func test_attachment_import_failure_rolls_back_main_and_related_rows() -> Variant:
	var path := DIR + "/attachment-import-failure.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var exported := db.export_item_full("ORD-0001")
	exported.events = []
	exported.attachments = [{"filename":"blocked.bin","data":PackedByteArray([1]),"created_at":"x"}]
	db._exec("CREATE TRIGGER reject_import_attachment BEFORE INSERT ON attachments BEGIN SELECT RAISE(ABORT, 'attachment rejected'); END;")
	var error := db.import_item_full_checked("ORD-0002", exported)
	var r = A.is_true(not error.is_empty(), "attachment SQL failure reaches import caller")
	if r is String: db.close(); return r
	r = A.is_false(db.has_item("ORD-0002"), "attachment failure rolls back imported item and moved event")
	db.close()
	return r

func test_unset_envelopes_require_arrays_of_string_keys() -> Variant:
	var path := DIR + "/invalid-unset.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var before := _read_file(path)
	var error := db.update_item_fields_checked("ORD-0001", {"unset_fields":"count"})
	var r = A.contains(error, "must be an array", "string unset payload is rejected")
	if r is String: db.close(); return r
	error = db.update_item_fields_checked("ORD-0001", {"unset_extras":[7]})
	r = A.contains(error, "must be strings", "unset keys require strings")
	db.close()
	if r is String: return r
	return A.eq(_read_file(path), before, "invalid unset payloads perform no canonical mutation")

func test_project_meta_multiwrite_failure_rolls_back_earlier_key() -> Variant:
	var path := DIR + "/project-meta-failure.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	db._exec("CREATE TRIGGER reject_project_hypothesis BEFORE INSERT ON docket_meta WHEN NEW.key='project_hypothesis' BEGIN SELECT RAISE(ABORT, 'meta rejected'); END;")
	var error := db.set_project_meta_checked({"stage":"experiment","hypothesis":"blocked"})
	var r = A.is_true(not error.is_empty(), "middle project metadata failure reaches caller")
	if r is String: db.close(); return r
	r = A.eq(db.get_meta_value("project_stage", ""), "", "earlier metadata key rolls back")
	db.close()
	return r

func test_rewrite_middle_failure_rolls_back_all_reference_columns() -> Variant:
	var path := DIR + "/rewrite-failure.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	db.update_item_fields_checked("ORD-0001", {"parent":"old:item","blocked_by":"old:item"})
	db._exec("CREATE TRIGGER reject_blocked_rewrite BEFORE UPDATE OF blocked_by ON items BEGIN SELECT RAISE(ABORT, 'rewrite rejected'); END;")
	var result := db.rewrite_refs_checked("old:item", "new:item", "old", "new:item")
	var item := db.get_item("ORD-0001")
	var r = A.is_true(not str(result.error).is_empty(), "middle rewrite failure reaches checked caller")
	if r is String: db.close(); return r
	r = A.is_true(not item.is_empty() and item.get("parent", "") == "old:item" and item.get("blocked_by", "") == "old:item", "all reference updates roll back together")
	db.close()
	return r

func test_vault_initialization_failure_rolls_back_all_metadata() -> Variant:
	var path := DIR + "/vault-init-failure.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	db._exec("CREATE TRIGGER reject_vault_verify BEFORE INSERT ON docket_meta WHEN NEW.key='vault_verify' BEGIN SELECT RAISE(ABORT, 'vault rejected'); END;")
	var error := db.init_vault_checked(PackedByteArray([1,2,3]), PackedByteArray([4,5,6]), 10)
	var r = A.is_true(not error.is_empty(), "vault multiwrite failure reaches checked caller")
	if r is String: db.close(); return r
	r = A.eq(db.get_meta_value("vault_salt", ""), "", "earlier vault metadata rolls back")
	db.close()
	return r

func test_nested_project_metadata_completion_writes_canonical_once() -> Variant:
	var path := DIR + "/nested-one-flush.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var db := DocketDBJsonl.open_jsonl(path)
	var calls := {"count":0}
	db._atomic_write_hook = func(write_path: String, text: String):
		calls.count += 1
		return DocketDBJsonl._atomic_write(write_path, text)
	var error := db.set_project_meta_checked({"stage":"experiment","hypothesis":"one transaction","success_criteria":"one flush"})
	db._atomic_write_hook = Callable()
	var r = A.eq(error, "", "nested metadata mutation succeeds")
	if r is String: db.close(); return r
	r = A.eq(calls.count, 1, "nested virtual setters complete through one durable flush")
	db.close()
	return r

func test_midmutation_flush_close_and_reload_cannot_publish_uncommitted_cache() -> Variant:
	var path := DIR + "/midmutation-guards.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var original := _read_file(path)
	var db := DocketDBJsonl.open_jsonl(path)
	var reloaded := {}
	var error := db.run_change(null, func(step: RefCounted) -> String:
		var nested := db.run_change(step, func(_inner: RefCounted) -> String:
			return db._exec_checked("UPDATE items SET title='uncommitted' WHERE id='ORD-0001';"))
		db.flush()
		db.close()
		reloaded.still_open = db.is_open()
		reloaded.value = db.reload()
		return nested if not nested.is_empty() else "forced outer failure")
	var r = A.eq([error, reloaded.get("still_open"), reloaded.get("value")], ["forced outer failure", true, false], "reload and close are deferred while the change is open")
	if r is String: db.close(); return r
	r = A.eq(_read_file(path), original, "public flush never publishes uncommitted SQL")
	if r is String: db.close(); return r
	r = A.eq(db.get_item("ORD-0001").title, "Before definition", "failed outer mutation reconstructs cache")
	db.close()
	return r

func test_serializer_read_failure_preserves_canonical_and_rebuilds_complete_cache() -> Variant:
	var path := DIR + "/serializer-read-failure.dct"
	_copy_fixture("dynamic_types_legacy_v1.jsonl", path)
	var original := _read_file(path)
	var db := DocketDBJsonl.open_jsonl(path)
	db._exec_checked("DROP TABLE attachments;")
	var error := db._flush_jsonl()
	var r = A.contains(error, "cache read failed", "failed serializer SELECT reaches persistence caller")
	if r is String: db.close(); return r
	r = A.eq(_read_file(path), original, "serializer read failure performs no atomic replacement")
	if r is String: db.close(); return r
	db.close()
	db = DocketDBJsonl.open_jsonl(path)
	r = A.eq(db.list_attachments("LEG-0001").size(), 1, "reopen rebuild retains canonical attachment")
	db.close()
	return r

func test_checked_setters_return_sql_and_canonical_write_failures() -> Variant:
	var path := DIR + "/checked-setter-failures.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var original := _read_file(path)
	var db := DocketDBJsonl.open_jsonl(path)
	db._exec("CREATE TRIGGER reject_counter BEFORE UPDATE ON docket_meta WHEN NEW.key='counter' BEGIN SELECT RAISE(ABORT, 'counter rejected'); END;")
	var error := db.set_counter_checked(99)
	var r = A.is_true(not error.is_empty(), "checked metadata setter returns SQL failure")
	if r is String: db.close(); return r
	db._atomic_write_hook = func(_path, _text): return "injected setter write failure"
	error = db.update_item_fields_checked("ORD-0001", {"title": "must roll back"})
	db._atomic_write_hook = Callable()
	r = A.contains(error, "injected setter write failure", "checked item setter returns canonical failure")
	if r is String: db.close(); return r
	r = A.eq(_read_file(path), original, "checked setter failures preserve canonical bytes")
	db.close()
	return r

func test_next_id_checked_distinguishes_counter_and_canonical_failures() -> Variant:
	var path := DIR + "/next-id-checked-failures.dct"
	_copy_fixture("dynamic_types_record_order_v2.jsonl", path)
	var original := _read_file(path)
	var db := DocketDBJsonl.open_jsonl(path)
	var counter_before := db.get_counter()
	db._exec("CREATE TRIGGER reject_next_counter BEFORE UPDATE ON docket_meta WHEN NEW.key='counter' BEGIN SELECT RAISE(ABORT, 'next counter rejected'); END;")
	var result := db.next_id_checked()
	var r = A.is_true(str(result.id).is_empty() and not str(result.error).is_empty(), "checked ID allocation distinguishes SQL failure from an ID")
	if r is String: db.close(); return r
	r = A.eq(db.get_counter(), counter_before, "failed counter update rolls back")
	if r is String: db.close(); return r
	db._atomic_write_hook = func(_path, _text): return "injected next-id canonical failure"
	result = db.next_id_checked()
	db._atomic_write_hook = Callable()
	r = A.is_true(str(result.id).is_empty() and str(result.error).contains("canonical failure"), "checked ID allocation reports canonical replacement failure")
	if r is String: db.close(); return r
	r = A.eq(db.get_counter(), counter_before, "failed canonical replacement reconstructs original counter")
	if r is String: db.close(); return r
	r = A.eq(_read_file(path), original, "failed allocations preserve canonical bytes")
	db.close()
	return r
