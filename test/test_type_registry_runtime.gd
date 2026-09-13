extends Node
## Project registry, typed candidate, lifecycle and evolution behavior.

var A := AssertHelpers
const DIR := "user://test_type_registry_runtime"

func setup() -> void: DirAccess.make_dir_recursive_absolute(DIR)
func teardown() -> void:
	var dir := DirAccess.open(DIR)
	if dir != null:
		for name in dir.get_files(): dir.remove(name)
	DirAccess.remove_absolute(DIR)

func _db(name: String) -> DocketDBJsonl:
	return DocketDBJsonl.create_new_jsonl(DIR + "/" + name + ".dct")

func _definition(slug: String = "widget", enforcement: String = "strict") -> Dictionary:
	return {"slug":slug,"label":slug.capitalize(),"description":"Tracks %s records" % slug,"use_when":"Use for %s work" % slug,
		"fields":[
			{"key":"title","type":"string","required":true,"nullable":false,"min_length":1},
			{"key":"count","type":"integer","required":false,"nullable":true,"default":0,"minimum":0},
			{"key":"ratio","type":"number","required":false,"nullable":true},
			{"key":"enabled","type":"boolean","required":false,"nullable":false,"default":false},
			{"key":"mode","type":"enum","values":["a","b"],"required":false,"nullable":true},
			{"key":"due","type":"date","required":false,"nullable":true},
			{"key":"at","type":"timestamp","required":false,"nullable":true},
			{"key":"owner","type":"item_ref","required":false,"nullable":true},
			{"key":"refs","type":"reference_list","required":false,"nullable":true},
			{"key":"body","type":"markdown","required":false,"nullable":true}],
		"lifecycle":{"initial_state":"queued","states":[{"key":"queued","state_category":"queued","state_outcome":""},{"key":"done","state_category":"terminal","state_outcome":"unspecified"},{"key":"held","state_category":"waiting","state_outcome":""}],"terminal_states":["done"],"transitions":{"queued":["done"],"done":[],"held":["queued"]},"guards":{"done":{"required_fields":["mode"]}},"enforcement":enforcement},
		"protected":false,"protected_behavior":{"regular_creation_allowed":true}}

func _define(registry: TypeRegistry, slug: String = "widget", enforcement: String = "strict") -> Dictionary:
	var result := registry.define_type(slug, _definition(slug, enforcement), "tester", "test definition", {"kind":"test","protected":false})
	if not result.has("error"): registry.activate_type(slug, result.type.current_revision, "tester", "activate for test")
	return result

func _rewrite_definition(path: String, slug: String, mutate: Callable) -> void:
	var file := FileAccess.open(path, FileAccess.READ); var records: Array = []
	for line in file.get_as_text().split("\n", false): records.append(JSON.parse_string(line))
	file.close()
	var type_id := ""; var old_revision := ""; var new_revision := ""
	for record in records:
		if record.get("_type") == "type_def" and record.get("slug") == slug: type_id = record.id; old_revision = record.current_revision
	for record in records:
		if record.get("_type") == "type_def_version" and record.get("id") == old_revision:
			mutate.call(record.definition)
			new_revision = "%s@%s" % [type_id, TypeRegistryBootstrap._definition_hash(record.definition)]
			record.id = new_revision
	for record in records:
		if record.get("_type") == "type_def" and record.get("slug") == slug: record.current_revision = new_revision
		if record.get("_type") == "item" and record.get("type_revision") == old_revision: record.type_revision = new_revision
	var output := FileAccess.open(path, FileAccess.WRITE)
	for record in records: output.store_line(JSON.stringify(record, "", true, true))
	output.close()

func _add_unsupported_guard(definition: Dictionary) -> void:
	definition.lifecycle.guards.done.actor = "admin"

func _spoof_protected_behavior(definition: Dictionary) -> void:
	definition.protected = true
	definition.protected_behavior = {"regular_creation_allowed":true,"blocking":{"enabled":true,"state":"queued"}}

func test_project_owned_same_slug_has_independent_revision_identity() -> Variant:
	var a := _db("alpha"); var b := _db("beta")
	var ra := TypeRegistry.new(a, "Alpha"); var rb := TypeRegistry.new(b, "Beta")
	var da := _definition(); var dbeta := _definition(); dbeta.description = "Beta-specific meaning"
	var one := ra.define_type("widget", da, "tester", "alpha meaning")
	var two := rb.define_type("widget", dbeta, "tester", "beta meaning")
	var r = A.is_true(not one.has("error") and not two.has("error") and one.type.project == "Alpha" and two.type.project == "Beta" and one.type.id != two.type.id, "same slug has distinct stable identity in each owning project")
	if r is String: a.close(); b.close(); return r
	r = A.neq(one.type.current_revision, two.type.current_revision, "different meanings have different immutable revisions")
	if r is String: a.close(); b.close(); return r
	var foreign := {"type":"widget","type_id":two.type.id,"type_revision":two.type.current_revision,"status":"queued"}
	r = A.is_true(ra.resolve_item(foreign).read_only and ra.resolve_item(foreign).error.contains("missing pinned revision"), "a project never resolves another project's same-slug revision")
	if r is String: a.close(); b.close(); return r
	var alpha_id: String = one.type.id; a.close(); var reopened := DocketDBJsonl.open_jsonl(DIR + "/alpha.dct"); var loaded := TypeRegistry.new(reopened, "Alpha")
	r = A.is_true(loaded.get_type("widget").id == alpha_id and loaded.get_revision(one.type.current_revision).definition.description == da.description, "project identity and complete pinned revision survive reopen")
	reopened.close(); b.close(); return r

func test_legacy_registry_supports_builtins_but_refuses_definition_writes() -> Variant:
	var path := DIR + "/legacy.dct"
	var source := FileAccess.open("res://test/fixtures/dynamic_types_legacy_v1.jsonl", FileAccess.READ)
	var output := FileAccess.open(path, FileAccess.WRITE); output.store_string(source.get_as_text()); source.close(); output.close()
	var db := DocketDBJsonl.open_jsonl(path); var registry := TypeRegistry.new(db, "Legacy")
	var r = A.is_true(not registry.get_type("discussion").has("error"), "legacy flat built-in resolves through compatibility registry")
	if r is String: db.close(); return r
	r = A.contains(registry.define_type("widget", _definition(), "tester", "blocked").error, "read-only", "legacy registry definitions require explicit upgrade")
	db.close(); return r

func test_definition_validation_and_idempotent_conflict_behavior() -> Variant:
	var db := _db("define"); var registry := TypeRegistry.new(db)
	var first := _define(registry); var same := _define(registry)
	var changed := _definition(); changed.description = "different"
	var conflict := registry.define_type("widget", changed, "tester", "conflict")
	var r = A.is_true(not first.has("error") and same.idempotent and conflict.has("error") and conflict.similar[0].slug == "widget" and registry.get_type("widget").use_when == "Use for widget work", "same content is idempotent, conflicts have deterministic matches, and presentation metadata resolves")
	if r is String: db.close(); return r
	var invalid := _definition("bad"); invalid.fields[1].type = "executable"
	r = A.contains(registry.validate_definition(invalid), "unsupported type", "unsupported descriptor kinds refuse complete definition")
	if r is String: db.close(); return r
	invalid = _definition("reserved"); invalid.fields[1].key = "type_revision"
	r = A.contains(registry.validate_definition(invalid), "reserved", "definitions cannot claim internal storage identity")
	if r is String: db.close(); return r
	invalid = _definition("duplicate"); invalid.lifecycle.states.append(invalid.lifecycle.states[0].duplicate(true))
	r = A.contains(registry.validate_definition(invalid), "unique", "duplicate lifecycle identities are refused")
	if r is String: db.close(); return r
	invalid = _definition("guard"); invalid.lifecycle.guards.done.actor = "admin"
	r = A.contains(registry.validate_definition(invalid), "guard property", "unsupported guard properties are refused instead of silently ignored")
	if r is String: db.close(); return r
	invalid = _definition("constraint"); invalid.fields[0].pattern = ".*"
	r = A.contains(registry.validate_definition(invalid), "descriptor property", "unimplemented field constraints are refused instead of advertised")
	if r is String: db.close(); return r
	invalid = _definition("values"); invalid.fields[0].values = ["ignored"]
	r = A.contains(registry.validate_definition(invalid), "enum type", "enum values cannot be accepted on a non-enum descriptor")
	db.close(); return r

func test_custom_definition_is_draft_until_explicit_audited_activation() -> Variant:
	var db := _db("activation"); var registry := TypeRegistry.new(db)
	var defined := registry.define_type("widget", _definition(), "author", "draft proposal", {"kind":"test"})
	var r = A.is_true(defined.type.lifecycle == "draft" and registry.create_item({"type":"widget","title":"blocked"}).has("error"), "draft definition cannot create items")
	if r is String: db.close(); return r
	var error := registry.activate_type("widget", defined.type.current_revision, "reviewer", "approved semantics")
	var active := registry.get_type("widget")
	r = A.is_true(error.is_empty() and active.lifecycle == "active" and active.provenance.lifecycle_history[0].reason == "approved semantics", "explicit activation records author and reason")
	if r is String: db.close(); return r
	error = registry.deprecate_type("widget", active.current_revision, "reviewer", "retired semantics")
	r = A.is_true(error.is_empty() and registry.create_item({"type":"widget","title":"blocked"}).has("error") and registry.get_type("widget").provenance.lifecycle_history[-1].reason == "retired semantics", "deprecated types reject creation and retain lifecycle provenance")
	db.close(); return r

func test_all_scalar_shapes_defaults_false_zero_null_and_unset() -> Variant:
	var db := _db("shapes"); var registry := TypeRegistry.new(db); _define(registry)
	var made := registry.create_item({"type":"widget","title":"One","ratio":1.5,"enabled":false,"mode":"a","due":"2026-09-12","at":"2026-09-12T00:00:00Z","owner":"X","refs":["A","B"],"body":"text"}, "tester")
	var r = A.is_true(not made.has("error") and made.item.fields.count == 0 and made.item.fields.enabled == false, "creation applies typed false and zero defaults")
	if r is String: db.close(); return r
	var error := registry.update_item(made.id, {"fields":{"count":null}}, "tester")
	r = A.is_true(error.is_empty() and db.get_item(made.id).fields.has("count") and db.get_item(made.id).fields.count == null, "nullable explicit null is retained distinctly from unset")
	if r is String: db.close(); return r
	error = registry.update_item(made.id, {"unset_fields":["ratio"]}, "tester")
	r = A.is_true(error.is_empty() and not db.get_item(made.id).fields.has("ratio"), "explicit unset removes the selected optional key")
	if r is String: db.close(); return r
	error = registry.update_item(made.id, {"unset_fields":["title"]}, "tester")
	r = A.contains(error, "required field", "required values cannot be unset")
	if r is String: db.close(); return r
	error = registry.update_item(made.id, {"fields":{"due":"2026-02-31"}}, "tester")
	r = A.contains(error, "ISO date", "calendar-invalid dates are rejected")
	if r is String: db.close(); return r
	error = registry.update_item(made.id, {"fields":{"at":"2026-09-12T25:00:00Z"}}, "tester")
	r = A.contains(error, "ISO timestamp", "timestamps validate time components")
	if r is String: db.close(); return r
	error = registry.update_item(made.id, {"fields":{"at":""}}, "tester")
	r = A.contains(error, "ISO timestamp", "custom nullable timestamps accept null but not an empty string")
	if r is String: db.close(); return r
	error = registry.update_item(made.id, {"fields":{"refs":["A", 2]}}, "tester")
	r = A.contains(error, "reference_list", "reference lists reject non-string entries")
	db.close(); return r

func test_patch_shapes_authority_and_immutable_fields_are_refused() -> Variant:
	var db := _db("patch-shapes"); var registry := TypeRegistry.new(db); var definition := _definition(); definition.fields[0].mutable = false
	var defined := registry.define_type("widget", definition, "tester", "immutable title"); registry.activate_type("widget", defined.type.current_revision, "tester", "activate")
	var made := registry.create_item({"type":"widget","title":"Fixed"}, "tester")
	var r = A.contains(registry.update_item(made.id, {"fields":{"title":"Nested"},"title":"Flat"}), "ambiguous", "flat and nested authority cannot conflict")
	if r is String: db.close(); return r
	r = A.contains(registry.update_item(made.id, {"fields":[],"title":"Bad"}), "object", "nested fields require an object")
	if r is String: db.close(); return r
	r = A.contains(registry.update_item(made.id, {"fields":{"type_revision":"forged"}}), "reserved", "nested identity writes are refused")
	if r is String: db.close(); return r
	r = A.contains(registry.update_item(made.id, {"type":"other"}), "retype", "typed updates cannot rebind item type identity")
	if r is String: db.close(); return r
	r = A.contains(registry.update_item(made.id, {"fields":{"count":2},"unset_fields":["count"]}), "set and unset", "one patch cannot set and unset the same field")
	if r is String: db.close(); return r
	r = A.contains(registry.update_item(made.id, {"title":"Changed"}), "immutable", "immutable descriptor fields reject edits")
	db.close(); return r

func test_invalid_candidate_never_partially_mutates_item_or_audit() -> Variant:
	var db := _db("candidate"); var registry := TypeRegistry.new(db); _define(registry)
	var made := registry.create_item({"type":"widget","title":"Stable"}, "tester")
	var before := db.get_events(made.id); var error := registry.update_item(made.id, {"fields":{"count":-1}}, "tester")
	var r = A.is_true(error.contains("minimum") and db.get_item(made.id).title == "Stable" and db.get_events(made.id) == before, "invalid clone produces neither patch nor audit")
	db.close(); return r

func test_typed_item_and_audit_rollback_together_on_durable_failure() -> Variant:
	var path := DIR + "/item-failure.dct"; var db := DocketDBJsonl.create_new_jsonl(path); var registry := TypeRegistry.new(db); _define(registry)
	var made := registry.create_item({"type":"widget","title":"Before"}, "tester"); var before_events := db.get_events(made.id)
	db._atomic_write_hook = func(_path, _text): return "injected typed write failure"
	var error := registry.update_item(made.id, {"title":"After"}, "tester")
	db._atomic_write_hook = Callable()
	var r = A.is_true(error.contains("injected") and db.get_item(made.id).title == "Before" and db.get_events(made.id) == before_events, "failed durable publish rolls back candidate and audit in the live cache")
	if r is String: db.close(); return r
	db.close(); var reopened := DocketDBJsonl.open_jsonl(path)
	r = A.is_true(reopened.get_item(made.id).title == "Before" and reopened.get_events(made.id) == before_events, "failed durable publish leaves canonical data unchanged after reopen")
	reopened.close(); return r

func test_unknown_stored_payload_survives_typed_edit_but_unknown_edit_is_rejected() -> Variant:
	var path := DIR + "/unknown-preserved.dct"
	var source := FileAccess.open("res://test/fixtures/dynamic_types_record_order_v2.jsonl", FileAccess.READ)
	var output := FileAccess.open(path, FileAccess.WRITE); output.store_string(source.get_as_text()); source.close(); output.close()
	var db := DocketDBJsonl.open_jsonl(path); var registry := TypeRegistry.new(db)
	var error := registry.update_item("ORD-0001", {"fields":{"count":2}}, "tester")
	var item := db.get_item("ORD-0001")
	var r = A.is_true(error.is_empty() and item.extras.future_payload.nested == [1.0,true,null], "typed edit preserves unknown future payload")
	if r is String: db.close(); return r
	var before_text := FileAccess.get_file_as_string(path); var before_events := db.get_events("ORD-0001")
	error = registry.update_item("ORD-0001", {"fields":{"future_unknown":"edit"}}, "tester")
	r = A.is_true(error.contains("unsupported") and db.get_item("ORD-0001").extras.future_payload.nested == [1.0,true,null] and db.get_events("ORD-0001") == before_events and FileAccess.get_file_as_string(path) == before_text, "unsupported future field edits preserve opaque data, audit, and canonical bytes")
	if r is String: db.close(); return r
	error = registry.update_item("ORD-0001", {"unset_fields":["future_unknown"]}, "tester")
	r = A.is_true(error.contains("unsupported") and FileAccess.get_file_as_string(path) == before_text, "unsupported future fields cannot be erased through unset")
	db.close(); return r

func test_present_opaque_field_cannot_be_unset_by_typed_operations() -> Variant:
	var path := DIR + "/opaque-unset.dct"; var db := DocketDBJsonl.create_new_jsonl(path); var registry := TypeRegistry.new(db); _define(registry)
	var made := registry.create_item({"type":"widget","title":"Opaque","mode":"a"}, "tester")
	var seed_error := db.update_item_fields_checked(made.id, {"fields":{"future_field":{"nested":[0,false,null,""]}}})
	if seed_error.is_empty(): seed_error = db._exec_checked("UPDATE items SET extras_json=? WHERE id=?;", [JSON.stringify({"future_envelope":{"unicode":"雪"}}, "", true, true), made.id])
	if seed_error.is_empty(): seed_error = db.flush_checked()
	var r = A.eq(seed_error, "", "opaque forward data is durably seeded before typed refusal checks")
	if r is String: db.close(); return r
	var before_item: Dictionary = db.get_item(made.id); var before_events := db.get_events(made.id); var before_text := FileAccess.get_file_as_string(path)
	var error := registry.update_item(made.id, {"unset_fields":["future_field"]}, "tester")
	r = _assert_opaque_refusal(db, path, made.id, error, before_item, before_events, before_text, "typed update")
	if r is String: db.close(); return r
	error = registry.transition_item(made.id, "done", "tester", "", {"mode":"a","unset_fields":["future_field"]})
	r = _assert_opaque_refusal(db, path, made.id, error, before_item, before_events, before_text, "valid transition")
	if r is String: db.close(); return r
	error = registry.repair_item_status(made.id, "queued", "reviewer", "validated repair", {"unset_fields":["future_field"]})
	r = _assert_opaque_refusal(db, path, made.id, error, before_item, before_events, before_text, "explicit repair")
	db.close(); return r

func _assert_opaque_refusal(db: DocketDBJsonl, path: String, id: String, error: String, before_item: Dictionary, before_events: Array, before_text: String, operation: String) -> Variant:
	var item: Dictionary = db.get_item(id)
	return A.is_true(error.contains("unsupported") and item.fields.future_field == before_item.fields.future_field and item.extras.future_envelope == before_item.extras.future_envelope and item.status == before_item.status and item.type_revision == before_item.type_revision and db.get_events(id) == before_events and FileAccess.get_file_as_string(path) == before_text, "%s refuses present opaque unset without changing payload, extras, lifecycle, pin, audit, or canonical bytes" % operation)

func test_numeric_constraints_survive_json_roundtrip_and_nonfinite_values_refuse() -> Variant:
	var path := DIR + "/numeric.dct"; var db := DocketDBJsonl.create_new_jsonl(path); var registry := TypeRegistry.new(db); var definition := _definition(); definition.fields[0].max_length = 20
	var defined := registry.define_type("widget", definition, "tester", "numeric constraints")
	var r = A.is_true(not defined.has("error"), "integral numeric length constraints define successfully")
	if r is String: db.close(); return r
	db.close(); db = DocketDBJsonl.open_jsonl(path); registry = TypeRegistry.new(db)
	r = A.is_true(registry.get_diagnostic().is_empty() and registry.get_type("widget").definition.fields[0].max_length == 20.0, "JSON float representation of integral length constraints reloads")
	if r is String: db.close(); return r
	var repeated := registry.define_type("widget", definition, "tester", "same numeric definition")
	r = A.is_true(repeated.get("idempotent", false), "integer-authored definition remains idempotent after JSON numeric roundtrip")
	if r is String: db.close(); return r
	var evolved: Dictionary = registry.get_type("widget").definition.duplicate(true); evolved.label = "Presented Widget"
	var numeric_preview := registry.preview_evolution("widget", evolved, registry.get_type("widget").current_revision)
	var numeric_error := registry.apply_evolution(numeric_preview, "tester", "presentation after numeric roundtrip")
	r = A.is_true(numeric_error.is_empty() and registry.get_type("widget").definition.fields[0].max_length == 20.0, "integral constraints remain evolvable after roundtrip")
	if r is String: db.close(); return r
	definition = _definition("nonfinite"); definition.fields[1].minimum = INF
	r = A.contains(registry.validate_definition(definition), "finite", "nonfinite numeric constraints are refused")
	if r is String: db.close(); return r
	registry.activate_type("widget", registry.get_type("widget").current_revision, "tester", "activate")
	var made := registry.create_item({"type":"widget","title":"Finite"}, "tester")
	var error := registry.update_item(made.id, {"ratio":NAN}, "tester")
	r = A.contains(error, "finite", "nonfinite numeric item values are refused")
	if r is String: db.close(); return r
	var with_object: Dictionary = registry.get_type("widget").definition.duplicate(true); with_object.fields.append({"key":"payload","type":"object","required":false,"nullable":true})
	var preview := registry.preview_evolution("widget", with_object, registry.get_type("widget").current_revision, [made.id])
	error = registry.apply_evolution(preview, "tester", "object payload")
	if error.is_empty(): error = registry.update_item(made.id, {"fields":{"payload":{"nested":[0,false,null,""]}}}, "tester")
	r = A.eq(error, "", "valid nested JSON payload update succeeds")
	if r is String: db.close(); return r
	r = A.eq(db.get_item(made.id).fields.payload.nested, [0.0,false,null,""], "nested JSON payload preserves zero, false, null, and empty strings")
	if r is String: db.close(); return r
	error = registry.update_item(made.id, {"fields":{"payload":{"nested":[INF]}}}, "tester")
	r = A.contains(error, "finite JSON", "nested JSON containers reject nonfinite payloads")
	db.close(); return r

func test_strict_guided_open_and_scalar_guard_rules() -> Variant:
	var db := _db("lifecycle"); var strict := TypeRegistry.new(db); _define(strict)
	var item := strict.create_item({"type":"widget","title":"Flow"}, "tester")
	var r = A.contains(strict.transition_item(item.id, "held", "tester", "because"), "strict", "strict rejects off-flow despite note")
	if r is String: db.close(); return r
	r = A.contains(strict.transition_item(item.id, "done", "tester", "", {"mode":""}), "requires field", "blank scalar cannot bypass transition guard")
	if r is String: db.close(); return r
	r = A.contains(strict.transition_item(item.id, "done", "tester", "because", {"mode":null}), "requires field", "nullable null cannot bypass a required transition guard")
	if r is String: db.close(); return r
	_define(strict, "guided_widget", "guided")
	var guided := strict.create_item({"type":"guided_widget","title":"Guided"}, "tester")
	r = A.contains(strict.transition_item(guided.id, "held", "tester"), "requires a note", "guided off-flow requires a note")
	if r is String: db.close(); return r
	r = A.eq(strict.transition_item(guided.id, "held", "tester", "triage"), "", "guided off-flow accepts explanatory note")
	if r is String: db.close(); return r
	_define(strict, "open_widget", "open")
	var open_item := strict.create_item({"type":"open_widget","title":"Open"}, "tester")
	r = A.eq(strict.transition_item(open_item.id, "held", "tester"), "", "open lifecycle permits off-flow without note")
	db.close(); return r

func test_registry_refresh_observes_published_project_revision_without_cross_project_leak() -> Variant:
	var db := _db("reload"); var first := TypeRegistry.new(db, "Reload"); var second := TypeRegistry.new(db, "Reload"); var writer_guard := TypeRegistry.new(db, "Reload")
	_define(first, "new_kind")
	var r = A.is_true(second.get_type("new_kind").has("error"), "registry snapshot remains stable before explicit refresh")
	if r is String: db.close(); return r
	second.refresh_if_changed()
	r = A.is_true(not second.get_type("new_kind").has("error"), "refresh invalidates registry snapshot after canonical publish")
	if r is String: db.close(); return r
	var made := writer_guard.create_item({"type":"new_kind","title":"Fresh"}, "tester")
	r = A.is_true(not made.has("error") and made.item.type_id == first.get_type("new_kind").id, "mutating operations reload changed project definitions before validation and publish")
	db.close(); return r

func test_app_and_tool_contexts_expose_project_owned_registries() -> Variant:
	var state := AppState.new(); state.create_dct(DIR + "/context-a.dct"); state.create_and_add_project(DIR + "/context-b.dct")
	var projects := state.get_project_dbs(); var names: Array = projects.keys()
	var r = A.is_true(names.size() == 2 and state.get_type_registry(str(names[0])) != state.get_type_registry(str(names[1])), "AppState keeps one registry per loaded project")
	if r is String:
		for name in names: state.remove_project(str(name))
		return r
	var tools := ToolRegistry.new(); tools.init(TypeRegistryBootstrap.load_shipped_schema(), state.db, projects)
	var retained := state.get_type_registry(str(names[0]))
	r = A.is_true(tools.get_type_registry(str(names[0])) == retained and tools.get_type_registry(str(names[1])).get_type("discussion").project == str(names[1]), "AppState and tool context share one registry for each DB and resolve the selected project")
	if not r is String:
		var primary_name := state.db.get_project_name(); var shared := state.get_type_registry(primary_name); _define(shared, "shared_kind")
		_rewrite_definition(state.db.get_path(), "shared_kind", Callable(self, "_spoof_protected_behavior"))
		state.reload_all(); var from_tools := tools.get_type_registry(primary_name)
		r = A.is_true(from_tools == shared and shared.get_diagnostic().contains("protected behavior") and state.registry_diagnostics.has(primary_name) and tools.get_type_registry_diagnostics().has(primary_name), "the shared registry exposes one read-only failure diagnostic through both interfaces")
	for name in names: state.remove_project(str(name))
	if not r is String: r = A.contains(retained.get_diagnostic(), "database is closed", "held registries surface a read-only diagnostic after their project closes")
	return r

func test_held_app_registry_reloads_external_definition_before_publish() -> Variant:
	var path := DIR + "/held-reload.dct"; var state := AppState.new(); state.load_dct(path); var project := state.db.get_project_name(); var held := state.get_type_registry(project)
	var external := DocketDBJsonl.open_jsonl(path); var external_registry := TypeRegistry.for_db(external, project); _define(external_registry, "external_kind"); external.close()
	var reloaded := state.reload_stale()
	var r = A.is_true(reloaded.has(project) and state.get_type_registry(project) == held and not held.get_type("external_kind").has("error"), "AppState refreshes its held shared registry before reporting an external reload")
	state.remove_project(project); return r

func test_opened_semantically_invalid_and_spoofed_definitions_are_read_only() -> Variant:
	var malformed_path := DIR + "/semantic-invalid.dct"; var db := DocketDBJsonl.create_new_jsonl(malformed_path); var registry := TypeRegistry.new(db); _define(registry); db.close()
	_rewrite_definition(malformed_path, "widget", Callable(self, "_add_unsupported_guard"))
	db = DocketDBJsonl.open_jsonl(malformed_path); registry = TypeRegistry.new(db)
	var r = A.is_true(registry.get_diagnostic().contains("guard property") and registry.get_type("widget").read_only, "opened semantic snapshots with ignored guard vocabulary are refused read-only")
	db.close()
	if r is String: return r
	var spoof_path := DIR + "/protected-spoof.dct"; db = DocketDBJsonl.create_new_jsonl(spoof_path); registry = TypeRegistry.new(db); _define(registry); db.close()
	_rewrite_definition(spoof_path, "widget", Callable(self, "_spoof_protected_behavior"))
	db = DocketDBJsonl.open_jsonl(spoof_path); registry = TypeRegistry.new(db)
	r = A.is_true(registry.get_diagnostic().contains("protected behavior") and registry.create_item({"type":"widget","title":"blocked"}).has("error"), "custom canonical definitions cannot acquire protected built-in effects")
	db.close(); return r

func test_resolved_outputs_do_not_alias_immutable_registry_snapshots() -> Variant:
	var db := _db("copies"); var registry := TypeRegistry.new(db); _define(registry); var made := registry.create_item({"type":"widget","title":"Copy"}, "tester")
	var first := registry.resolve_item(made.item); first.definition.label = "Mutated"; first.revision.definition.description = "Mutated"
	var second := registry.resolve_item(made.item)
	var r = A.is_true(second.definition.label == "Widget" and second.revision.definition.description == "Tracks widget records", "resolved definition and revision results are defensive deep copies")
	db.close(); return r

func test_missing_pinned_revision_reports_read_only_unknown_semantics() -> Variant:
	var db := _db("missing-pin"); var registry := TypeRegistry.new(db); _define(registry)
	var made := registry.create_item({"type":"widget","title":"Missing pin"}, "tester")
	var item: Dictionary = made.item.duplicate(true); item.type_revision = "type:widget@missing"
	var resolved := registry.resolve_item(item)
	var r = A.is_true(resolved.read_only and resolved.semantics == "unknown" and resolved.error.contains("missing pinned revision"), "missing pinned revision stays visible without inferred meaning")
	db.close(); return r

func test_invalid_historical_status_is_visible_and_blocks_lifecycle() -> Variant:
	var db := _db("history"); var registry := TypeRegistry.new(db); _define(registry)
	var made := registry.create_item({"type":"widget","title":"History"}, "tester")
	db._exec("UPDATE items SET status='removed-history' WHERE id=?;", [made.id])
	var semantics := registry.resolve_item(db.get_item(made.id))
	var r = A.is_true(semantics.read_only and semantics.semantics == "unknown" and semantics.error.contains("historical status"), "invalid history remains visible with unknown semantics")
	if r is String: db.close(); return r
	r = A.contains(registry.transition_item(made.id, "done", "tester", "repair"), "historical status", "lifecycle refuses implicit historical repair")
	if r is String: db.close(); return r
	var repair_error := registry.repair_item_status(made.id, "queued", "reviewer", "validated historical correction")
	r = A.is_true(repair_error.is_empty() and db.get_item(made.id).status == "queued" and db.get_events(made.id)[-1].event_type == "status_repaired", "explicit validated repair restores declared semantics with an audit event")
	db.close(); return r

func test_protected_builtin_and_custom_blocked_behavior_are_distinct() -> Variant:
	var db := _db("protected"); var registry := TypeRegistry.new(db)
	var secret := registry.create_item({"type":"secret","title":"No"}, "tester")
	var custom_def := _definition("custom_blocked"); custom_def.protected = true; custom_def.protected_behavior = {"regular_creation_allowed":false,"blocking":{"enabled":true,"state":"blocked"}}; custom_def.lifecycle.states.append({"key":"blocked","state_category":"waiting","state_outcome":""}); custom_def.lifecycle.transitions.queued.append("blocked"); custom_def.lifecycle.transitions.blocked = []
	var custom := registry.define_type("custom_blocked", custom_def, "tester", "custom blocked"); registry.activate_type("custom_blocked", custom.type.current_revision, "tester", "activate")
	var made := registry.create_item({"type":"custom_blocked","title":"Allowed"}, "tester")
	var stored: Dictionary = registry.get_type("custom_blocked").definition
	var r = A.is_true(secret.has("error") and not made.has("error") and stored.protected == false and not stored.protected_behavior.has("blocking"), "custom definitions cannot spoof protected creation or work-item effects")
	db.close(); return r

func test_protected_work_item_blocking_effect_and_skill_outcome_field() -> Variant:
	var db := _db("protected-effects"); var registry := TypeRegistry.new(db)
	var blocker := registry.create_item({"type":"work_item","title":"Dependency"}, "tester")
	var blocked := registry.create_item({"type":"work_item","title":"Dependent"}, "tester")
	var error := registry.transition_item(blocked.id, "open", "tester")
	if error.is_empty(): error = registry.transition_item(blocked.id, "in_progress", "tester")
	if error.is_empty(): error = registry.transition_item(blocked.id, "blocked", "tester", "waiting", {"blocked_by":blocker.id})
	var links := db.get_links(blocker.id)
	var r = A.is_true(error.is_empty() and links.size() == 1 and links[0].to == blocked.id and links[0].relation == "blocks", "protected work-item metadata creates the declared blocking relation")
	if r is String: db.close(); return r
	var skill := registry.create_item({"type":"skill","title":"Pipeline","outcome":"Keep this instruction"}, "tester")
	var semantics := registry.resolve_item(skill.item)
	r = A.is_true(skill.item.outcome == "Keep this instruction" and semantics.state_outcome == "", "derived lifecycle outcome does not overwrite the skill outcome field")
	db.close(); return r

func test_legacy_sqlite_registry_keeps_builtin_create_update_transition() -> Variant:
	var path := DIR + "/legacy.sqlite"; var created := DocketDB.create_new(path)
	var r = A.is_true(created != null and created.is_open(), "legacy SQLite fixture is created with its schema")
	if r is String: return r
	created.close(); var db := DocketDB.new(); db.open(path); var registry := TypeRegistry.new(db, "Legacy SQLite")
	var made := registry.create_item({"type":"discussion","title":"Legacy"}, "tester")
	r = A.is_true(db.is_open() and not made.has("error") and made.has("id"), "existing legacy SQLite reopens before typed operations")
	if r is String: db.close(); return r
	var error := registry.update_item(made.id, {"description":"flat update"}, "tester")
	if error.is_empty(): error = registry.transition_item(made.id, "resolved", "tester")
	var item := db.get_item(made.id)
	var events: Array = db.get_events(made.id)
	var event_types: Array = []
	for event: Dictionary in events:
		event_types.append(event.get("event_type", ""))
	r = A.is_true(error.is_empty() and item.description == "flat update" and item.status == "resolved" and event_types == ["created", "typed_update", "transition"], "legacy SQLite built-ins retain flat values and record creation, typed update, and transition semantics")
	db.close(); return r


func test_legacy_sqlite_creation_event_is_atomic_with_item_and_counter() -> Variant:
	var path: String = DIR + "/legacy-creation-audit.sqlite"
	var db: DocketDB = DocketDB.create_new(path)
	if db == null or not db.is_open():
		return "legacy SQLite fixture could not be created"
	var registry: TypeRegistry = TypeRegistry.new(db, "Legacy SQLite")
	var made: Dictionary = registry.create_item({"type":"discussion","title":"Audited legacy"}, "creator")
	var r = A.is_true(not made.has("error") and db.get_events(made.id).size() == 1 and db.get_events(made.id)[0].event_type == "created", "legacy SQLite creation stores the item and creation audit together")
	if r is String:
		db.close()
		return r
	var counter_before: int = db.get_counter()
	db._exec("CREATE TRIGGER reject_legacy_created BEFORE INSERT ON item_events WHEN NEW.event_type='created' BEGIN SELECT RAISE(FAIL, 'legacy creation audit rejected'); END;")
	var refused: Dictionary = registry.create_item({"type":"discussion","title":"Refused legacy"}, "creator")
	var refused_items: Array = db.execute_query({"filter":{"title":"Refused legacy"}})
	r = A.is_true(refused.has("error") and refused_items.is_empty() and db.get_counter() == counter_before, "legacy SQLite audit failure rolls back its item and allocated sequence")
	db.close()
	return r

func test_additive_evolution_keeps_old_pins_until_explicit_selected_apply() -> Variant:
	var db := _db("evolve"); var registry := TypeRegistry.new(db); _define(registry)
	var made := registry.create_item({"type":"widget","title":"Pinned"}, "tester")
	var old_pin: String = str(made.item.type_revision)
	db.save_query("widget queue", {"filter":{"conditions":[{"field":"type","op":"eq","value":"widget"},{"field":"status","op":"eq","value":"queued"}]}})
	var evolved := _definition(); evolved.fields.append({"key":"reviewer","type":"string","required":false,"nullable":true,"default":"unassigned"}); evolved.lifecycle.states.append({"key":"review","state_category":"active","state_outcome":""}); evolved.lifecycle.transitions.queued.append("review"); evolved.lifecycle.transitions.review = ["done"]
	var preview := registry.preview_evolution("widget", evolved, old_pin, [])
	var impact_check = A.is_true(preview.saved_query_impact.size() == 1 and preview.saved_query_impact[0].name == "widget queue", "evolution preview reports actual saved-query references")
	if impact_check is String: db.close(); return impact_check
	var error := registry.apply_evolution(preview, "tester", "add optional review")
	var r = A.is_true(error.is_empty() and db.get_item(made.id).type_revision == old_pin and not db.get_item(made.id).fields.has("reviewer"), "publishing additive revision neither repins nor applies defaults to old items")
	if r is String: db.close(); return r
	var current: String = str(registry.get_type("widget").current_revision)
	preview = registry.preview_evolution("widget", evolved, current, [made.id])
	error = registry.apply_evolution(preview, "tester", "apply selected pin")
	r = A.is_true(error.is_empty() and db.get_item(made.id).type_revision == current and db.get_item(made.id).fields.reviewer == "unassigned" and db.get_events(made.id)[-1].event_type == "type_revision_changed" and registry.get_revision(current).parent_revision == old_pin, "explicit selected apply advances pin with its default, immutable parent chain, and audit")
	db.close(); return r

func test_breaking_stale_and_injected_durable_evolution_failures_preserve_state() -> Variant:
	var db := _db("evolve-fail"); var registry := TypeRegistry.new(db); _define(registry)
	var current := registry.get_type("widget"); var breaking: Dictionary = current.definition.duplicate(true); breaking.fields.remove_at(1)
	var r = A.contains(registry.preview_evolution("widget", breaking, current.current_revision).error, "remove", "breaking field removal is refused")
	if r is String: db.close(); return r
	r = A.contains(registry.preview_evolution("widget", current.definition, "stale").error, "stale", "stale pointer is refused")
	if r is String: db.close(); return r
	var discussion := registry.get_type("discussion")
	r = A.contains(registry.preview_evolution("discussion", discussion.definition, discussion.current_revision).error, "protected", "protected built-in definitions cannot be evolved")
	if r is String: db.close(); return r
	var array_definition := _definition("array_kind"); array_definition.fields.append({"key":"payloads","type":"array","required":false,"nullable":true})
	var array_type := registry.define_type("array_kind", array_definition, "tester", "unconstrained array"); registry.activate_type("array_kind", array_type.type.current_revision, "tester", "activate")
	var tightened: Dictionary = registry.get_type("array_kind").definition.duplicate(true); tightened.fields[-1].items = {"type":"string"}
	r = A.contains(registry.preview_evolution("array_kind", tightened, registry.get_type("array_kind").current_revision).error, "items", "evolution cannot silently tighten an existing array item constraint")
	if r is String: db.close(); return r
	var additive: Dictionary = current.definition.duplicate(true); additive.fields.append({"key":"new_optional","type":"string","required":false,"nullable":true})
	var preview := registry.preview_evolution("widget", additive, current.current_revision)
	db._atomic_write_hook = func(_path, _text): return "injected evolution failure"
	var error := registry.apply_evolution(preview, "tester", "failure")
	db._atomic_write_hook = Callable(); registry.reload()
	r = A.is_true(error.contains("injected") and registry.get_type("widget").current_revision == current.current_revision, "durable failure restores registry pointer")
	db.close(); return r

func test_evolution_revalidates_untrusted_preview_and_rejects_indirect_retype() -> Variant:
	var db := _db("evolve-revalidate"); var registry := TypeRegistry.new(db); _define(registry); _define(registry, "other")
	var widget := registry.get_type("widget"); var evolved: Dictionary = widget.definition.duplicate(true); evolved.label = "Clearer Widget"
	var other := registry.create_item({"type":"other","title":"Other"}, "tester")
	var preview := registry.preview_evolution("widget", evolved, widget.current_revision)
	preview.items = [other.id]
	var error := registry.apply_evolution(preview, "tester", "tampered selection")
	var r = A.is_true(error.contains("another type") and registry.get_type("widget").current_revision == widget.current_revision and db.get_item(other.id).type == "other", "apply revalidates selected ownership and refuses indirect retype")
	if r is String: db.close(); return r
	var breaking: Dictionary = widget.definition.duplicate(true); breaking.lifecycle.transitions.queued.append("held")
	r = A.contains(registry.preview_evolution("widget", breaking, widget.current_revision).error, "transition graph", "evolution cannot add a new edge between existing states")
	db.close(); return r

func test_evolution_preview_refuses_invalid_selected_item_semantics() -> Variant:
	var db := _db("evolve-invalid-selection"); var registry := TypeRegistry.new(db); _define(registry); _define(registry, "other")
	var widget := registry.get_type("widget"); var item := registry.create_item({"type":"widget","title":"Selected"}, "tester"); var evolved: Dictionary = widget.definition.duplicate(true); evolved.label = "Evolved Widget"
	db._exec("UPDATE items SET type_revision='missing-pin' WHERE id=?;", [item.id])
	var preview := registry.preview_evolution("widget", evolved, widget.current_revision, [item.id])
	var r = A.is_true(preview.error.contains("missing pinned revision") and registry.get_type("widget").current_revision == widget.current_revision, "preview refuses a selected item with a missing revision before registry writes")
	if r is String: db.close(); return r
	db._exec("UPDATE items SET type_revision=?,status='removed-history' WHERE id=?;", [widget.current_revision,item.id])
	preview = registry.preview_evolution("widget", evolved, widget.current_revision, [item.id])
	r = A.contains(preview.error, "historical status", "preview refuses selected invalid historical status")
	if r is String: db.close(); return r
	var other := registry.get_type("other")
	db._exec("UPDATE items SET status='queued',type_revision=? WHERE id=?;", [other.current_revision,item.id])
	preview = registry.preview_evolution("widget", evolved, widget.current_revision, [item.id])
	r = A.contains(preview.error, "conflicts", "preview refuses a forged cross-type revision pin")
	db.close(); return r

func test_evolution_validates_new_descriptors_against_preserved_opaque_values() -> Variant:
	var path := DIR + "/opaque-evolution.dct"; var db := DocketDBJsonl.create_new_jsonl(path); var registry := TypeRegistry.new(db); _define(registry)
	var invalid_item := registry.create_item({"type":"widget","title":"Invalid opaque"}, "tester")
	var valid_item := registry.create_item({"type":"widget","title":"Valid opaque"}, "tester")
	db.update_item_fields_checked(invalid_item.id, {"fields":{"later_count":"wrong"}})
	db.update_item_fields_checked(valid_item.id, {"fields":{"later_count":0,"later_flag":false,"later_note":"","later_null":null}})
	var current := registry.get_type("widget"); var evolved: Dictionary = current.definition.duplicate(true)
	evolved.fields.append_array([{"key":"later_count","type":"integer","required":false,"nullable":true,"default":7},{"key":"later_flag","type":"boolean","required":false,"nullable":true,"default":true},{"key":"later_note","type":"string","required":false,"nullable":true,"default":"default"},{"key":"later_null","type":"string","required":false,"nullable":true,"default":"default"}])
	var before_text := FileAccess.get_file_as_string(path); var before_events := db.get_events(invalid_item.id); var before_pin: String = str(db.get_item(invalid_item.id).type_revision)
	var preview := registry.preview_evolution("widget", evolved, current.current_revision, [invalid_item.id])
	var r = A.is_true(preview.error.contains("later_count") and registry.get_type("widget").current_revision == current.current_revision and db.get_item(invalid_item.id).type_revision == before_pin and db.get_events(invalid_item.id) == before_events and FileAccess.get_file_as_string(path) == before_text, "preview rejects a new descriptor incompatible with preserved opaque data without mutation")
	if r is String: db.close(); return r
	var tampered := {"slug":"widget","expected_current":current.current_revision,"definition":evolved,"items":[invalid_item.id]}
	var error := registry.apply_evolution(tampered, "tester", "tampered opaque apply")
	r = A.is_true(error.contains("later_count") and FileAccess.get_file_as_string(path) == before_text and db.get_item(invalid_item.id).type_revision == before_pin, "apply revalidates opaque values and preserves canonical state on refusal")
	if r is String: db.close(); return r
	preview = registry.preview_evolution("widget", evolved, current.current_revision, [valid_item.id])
	error = registry.apply_evolution(preview, "tester", "valid opaque apply")
	var stored: Dictionary = db.get_item(valid_item.id).fields
	r = A.is_true(error.is_empty() and stored.later_count == 0 and stored.later_flag == false and stored.later_note == "" and stored.has("later_null") and stored.later_null == null, "explicit upgrade preserves false, zero, null, and empty opaque values instead of applying defaults")
	db.close(); return r

func test_creation_event_is_atomic_with_registry_item() -> Variant:
	var db: DocketDBJsonl = _db("creation-audit")
	var registry: TypeRegistry = TypeRegistry.new(db)
	_define(registry)
	var made: Dictionary = registry.create_item({"type":"widget","title":"Audited"}, "creator")
	var r = A.is_true(not made.has("error") and db.get_events(made.id).size() == 1 and db.get_events(made.id)[0].event_type == "created", "typed creation durably records its creation event")
	if r is String: db.close(); return r
	var before: String = FileAccess.get_file_as_string(db.get_path())
	db._exec("CREATE TRIGGER reject_created BEFORE INSERT ON item_events WHEN NEW.event_type='created' BEGIN SELECT RAISE(FAIL, 'creation audit rejected'); END;")
	var refused: Dictionary = registry.create_item({"type":"widget","title":"Refused"}, "creator")
	r = A.is_true(refused.has("error") and db.execute_query({"filter":{"title":"Refused"}}).is_empty() and FileAccess.get_file_as_string(db.get_path()) == before, "creation audit failure rolls back the item and canonical publication")
	db.close(); return r

func test_protected_historical_timestamp_is_preserved_but_malformed_and_custom_values_refuse() -> Variant:
	var db: DocketDBJsonl = _db("historical-time")
	var registry: TypeRegistry = TypeRegistry.new(db)
	var skill: Dictionary = registry.create_item({"type":"skill","title":"Old skill","steps":"one"}, "tester")
	if skill.has("error"):
		db.close()
		return "builtin setup failed: %s" % skill.error
	var historical: String = "2026-09-12T12:34:56"
	var seed_error: String = db.update_item_fields_checked(skill.id, {"last_reviewed":historical})
	var update_error: String = registry.update_item(skill.id, {"title":"Still old"}, "tester")
	var transition_error: String = registry.transition_item(skill.id, "active", "tester")
	var text: String = FileAccess.get_file_as_string(db.get_path())
	var r = A.is_true(seed_error.is_empty() and update_error.is_empty() and transition_error.is_empty() and db.get_item(skill.id).last_reviewed == historical and text.contains(historical), "ordinary builtin edits preserve a valid historical UTC timestamp byte value")
	if r is String:
		db.close()
		return r
	var malformed_seed: String = db.update_item_fields_checked(skill.id, {"last_reviewed":"2026-09-12T25:34:56"})
	if not malformed_seed.is_empty():
		db.close()
		return "malformed fixture seed failed: %s" % malformed_seed
	var malformed_error: String = registry.update_item(skill.id, {"title":"Must refuse"}, "tester")
	r = A.contains(malformed_error, "ISO timestamp", "malformed historical builtin timestamp remains invalid")
	if r is String:
		db.close()
		return r
	_define(registry, "widget")
	var custom: Dictionary = registry.create_item({"type":"widget","title":"Custom"}, "tester")
	var custom_error: String = registry.update_item(custom.id, {"fields":{"at":historical}}, "tester")
	r = A.contains(custom_error, "ISO timestamp", "custom timestamps require an explicit zone")
	db.close()
	return r
