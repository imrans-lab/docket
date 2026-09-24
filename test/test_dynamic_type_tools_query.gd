extends Node
## End-to-end registry tools, typed SQL bindings, and transfer behavior.

var A := AssertHelpers
const DIR := "user://test_dynamic_type_tools_query"

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

func _definition(label: String = "Widget") -> Dictionary:
	return {"slug":"widget","label":label,"description":"Tracks typed widgets","use_when":"Use for widget work","fields":[{"key":"title","type":"string","required":true,"nullable":false},{"key":"score","type":"number","required":false,"nullable":true},{"key":"enabled","type":"boolean","required":false,"nullable":true},{"key":"memo","type":"string","required":false,"nullable":true},{"key":"research_cost","type":"string","required":false,"nullable":true}],"lifecycle":{"initial_state":"queued","states":[{"key":"queued","state_category":"queued","state_outcome":""},{"key":"done","state_category":"terminal","state_outcome":"unspecified"},{"key":"dead","state_category":"terminal","state_outcome":"unspecified"}],"terminal_states":["done","dead"],"transitions":{"queued":["done","dead"],"done":[],"dead":[]},"guards":{"done":{"required_fields":["memo"]},"dead":{"required_fields":["memo"]}},"enforcement":"strict"},"protected":false,"protected_behavior":{"regular_creation_allowed":true}}

func _registry_with_widget(db: DocketDBJsonl, label: String = "Widget") -> TypeRegistry:
	var registry: TypeRegistry = TypeRegistry.for_db(db, db.get_project_name())
	var defined: Dictionary = registry.define_type("widget", _definition(label), "tester", "define widget")
	assert(not defined.has("error"), "widget fixture definition failed: %s" % defined.get("error", "unknown error"))
	registry.activate_type("widget", str(defined.type.current_revision), "tester", "activate widget")
	return registry

func test_type_tools_discover_validate_define_activate_and_stale_item_context() -> Variant:
	var db: DocketDBJsonl = _db("Tools")
	var tools: ToolRegistry = ToolRegistry.new(); tools.init({}, db, {"Tools":db})
	var invalid: Dictionary = tools.call_tool("docket_type_validate", {"project":"Tools","slug":"widget","definition":{"label":"Incomplete"}})
	var r = A.is_true(invalid.get("valid") == false and invalid.error is String, "validation tool refuses incomplete definitions")
	if r is String: db.close(); return r
	var defined: Dictionary = tools.call_tool("docket_type_define", {"project":"Tools","slug":"widget","definition":_definition(),"author":"tester","reason":"tool definition"})
	r = A.is_true(not defined.has("error") and defined.get("type", {}).get("lifecycle") == "draft", "define tool creates a draft: %s" % defined.get("error", "missing type result"))
	if r is String: db.close(); return r
	var activated: Dictionary = tools.call_tool("docket_type_activate", {"project":"Tools","type":defined.type.id,"action":"activate","expected_revision":defined.type.current_revision,"author":"tester","reason":"ready"})
	if activated.has("error"): db.close(); return "activation failed: %s" % activated.error
	var evolved_definition: Dictionary = activated.type.definition.duplicate(true); evolved_definition.label = "Widget Record"
	var evolved: Dictionary = tools.call_tool("docket_type_evolve", {"project":"Tools","type":defined.type.id,"definition":evolved_definition,"expected_revision":activated.type.current_revision,"apply":true,"author":"tester","reason":"clearer label"})
	if evolved.has("error"): db.close(); return "evolution failed: %s" % evolved.error
	var listed: Dictionary = tools.call_tool("docket_type_list", {"project":"Tools","search":"typed widgets"})
	var discovered: Dictionary = tools.call_tool("docket_type_get", {"project":"Tools","type":defined.type.id})
	r = A.is_true(listed.count == 1 and listed.types[0].id == defined.type.id and not listed.types[0].has("definition") and discovered.definition.lifecycle.guards.done.required_fields == ["memo"], "compact list and complete get expose identity and lifecycle")
	if r is String: db.close(); return r
	var mismatched: Dictionary = tools.call_tool("docket_type_get", {"project":"Tools","type":"discussion","revision":discovered.current_revision})
	r = A.contains(str(mismatched.get("error", "")), "does not belong", "type and revision selectors must identify the same definition")
	if r is String: db.close(); return r
	var machine: Dictionary = tools.call_tool("docket_get_state_machine", {"project":"Tools","type":defined.type.id})
	r = A.is_true(not machine.has("error") and machine.type_id == defined.type.id and machine.lifecycle.enforcement == "strict", "state-machine discovery resolves the selected project's registry identity")
	if r is String: db.close(); return r
	var made: Dictionary = tools.call_tool("docket_create", {"project":"Tools","type":"widget","title":"One","fields":{"score":0,"enabled":false}})
	if made.has("error"): db.close(); return "create failed: %s" % made.error
	var fetched: Dictionary = tools.call_tool("docket_get", {"project":"Tools","id":made.id})
	var stale: Dictionary = tools.call_tool("docket_update", {"project":"Tools","id":made.id,"fields":{"memo":"late"},"expected_revision":made.type_revision,"expected_item_token":"forged"})
	r = A.is_true(stale.error.contains("stale expected item token") and db.get_item(made.id).fields.get("memo") == null, "stale form token refuses mutation")
	if r is String: db.close(); return r
	var updated: Dictionary = tools.call_tool("docket_update", {"project":"Tools","id":made.id,"fields":{"memo":"ready"},"expected_revision":made.type_revision,"expected_item_token":fetched.item_token})
	r = A.is_true(not updated.has("error") and updated.get("item_token", "") != fetched.item_token, "checked typed update returns new content token: %s" % updated.get("error", "token unchanged"))
	if r is String: db.close(); return r
	var transitioned: Dictionary = tools.call_tool("docket_transition", {"project":"Tools","id":made.id,"to":"dead","expected_revision":made.type_revision,"expected_item_token":updated.item_token})
	r = A.is_true(not transitioned.has("error") and transitioned.status == "dead", "dynamic state key is routed as a state and transition commits")
	if r is String: db.close(); return r
	var queried: Dictionary = tools.call_tool("docket_query", {"project":"Tools","filter":{"field":"state_category","type_id":defined.type.id,"op":"eq","value":"terminal"},"sort":[{"field_key":"score","type_id":defined.type.id,"dir":"desc","nulls":"last"}]})
	r = A.is_true(not queried.has("error") and queried.count == 1 and queried.items[0].id == made.id, "public query tool executes stable typed filter and sort bindings")
	db.close(); return r

func test_pinned_json_fields_distinguish_values_and_reject_incompatible_operators() -> Variant:
	var db: DocketDBJsonl = _db("Query"); var registry: TypeRegistry = _registry_with_widget(db)
	var zero: Dictionary = registry.create_item({"type":"widget","title":"Zero","score":0,"enabled":false}, "tester")
	var null_value: Dictionary = registry.create_item({"type":"widget","title":"Null","score":null}, "tester")
	var missing: Dictionary = registry.create_item({"type":"widget","title":"Missing"}, "tester")
	var type_id: String = registry.get_type("widget").id
	var zero_rows: Array = db.execute_registry_query({"filter":{"$and":[{"field":"type","type_id":type_id,"op":"eq","value":"widget"},{"field_key":"score","type_id":type_id,"op":"eq","value":0}]}}, registry)
	var r = A.is_true(zero_rows.size() == 1 and zero_rows[0].id == zero.id and zero_rows[0].fields.enabled == false, "zero and false survive typed SQL hydration")
	if r is String: db.close(); return r
	var empty_rows: Array = db.execute_registry_query({"filter":{"field_key":"score","type_id":type_id,"op":"is_empty"}}, registry)
	var ids: Array = []
	for item in empty_rows: ids.append(item.id)
	r = A.is_true(ids.has(null_value.id) and ids.has(missing.id) and not ids.has(zero.id), "missing and null are empty while numeric zero is not")
	if r is String: db.close(); return r
	var null_rows: Array = db.execute_registry_query({"filter":{"field_key":"score","type_id":type_id,"op":"is_null"}}, registry)
	var missing_rows: Array = db.execute_registry_query({"filter":{"field_key":"score","type_id":type_id,"op":"is_missing"}}, registry)
	r = A.is_true(null_rows.size() == 1 and null_rows[0].id == null_value.id and missing_rows.size() == 1 and missing_rows[0].id == missing.id, "explicit null and missing operators remain distinct")
	if r is String: db.close(); return r
	db.execute_registry_query({"filter":{"field_key":"enabled","type_id":type_id,"op":"contains","value":"f"}}, registry)
	r = A.contains(db.last_query_error, "incompatible", "boolean fields reject text operators")
	if r is String: db.close(); return r
	db.execute_registry_query({"filter":{"field_key":"enabled","type_id":type_id,"op":"eq","value":"false"}}, registry)
	r = A.contains(db.last_query_error, "boolean operand", "string false cannot masquerade as boolean false")
	if r is String: db.close(); return r
	db.execute_registry_query({"filter":{"field_key":"score","type_id":type_id,"op":"gt","value":{"number":0}}}, registry)
	r = A.contains(db.last_query_error, "numeric operand", "numeric comparison refuses object operands")
	if r is String: db.close(); return r
	db.execute_registry_query({"filter":{"$or":{"field":"title","op":"eq","value":"Zero"}}}, registry)
	r = A.contains(db.last_query_error, "array", "malformed boolean tree is refused without dropping its predicate")
	db.close(); return r

func test_empty_typed_in_matches_nothing_without_hiding_an_or_sibling() -> Variant:
	var db: DocketDBJsonl = _db("EmptyIn"); var registry: TypeRegistry = _registry_with_widget(db)
	var zero: Dictionary = registry.create_item({"type":"widget","title":"Zero","score":0}, "tester")
	var empty_in := {"field_key":"score","type_id":registry.get_type("widget").id,"op":"in","value":[]}
	var alone: Array = db.execute_registry_query({"filter":empty_in}, registry)
	var r = A.is_true(alone.is_empty() and db.last_query_error.is_empty(), "an empty in matches nothing and is not an error: %s" % db.last_query_error)
	if r is String: db.close(); return r
	var either: Array = db.execute_registry_query({"filter":{"$or":[empty_in, {"field":"title","op":"eq","value":"Zero"}]}}, registry)
	r = A.is_true(either.size() == 1 and either[0].id == zero.id and db.last_query_error.is_empty(), "the other branch of an or still matches: %s" % db.last_query_error)
	db.close(); return r

func test_same_slug_projects_and_branch_local_bindings_do_not_share_meaning() -> Variant:
	var alpha: DocketDBJsonl = _db("Alpha"); var beta: DocketDBJsonl = _db("Beta")
	var ar: TypeRegistry = _registry_with_widget(alpha, "Alpha Widget"); var br: TypeRegistry = _registry_with_widget(beta, "Beta Widget")
	var ai: Dictionary = ar.create_item({"type":"widget","title":"Alpha","score":1}, "tester")
	var bi: Dictionary = br.create_item({"type":"widget","title":"Beta","score":2}, "tester")
	var state: AppState = AppState.new(); state.db = alpha; state._project_dbs = {"Alpha":alpha,"Beta":beta}; state._type_registries = {"Alpha":ar,"Beta":br}
	var query: Dictionary = {"filter":{"$or":[{"$and":[{"field":"project","op":"eq","value":"Alpha"},{"field_key":"score","type_id":ar.get_type("widget").id,"op":"eq","value":1}]},{"$and":[{"field":"project","op":"eq","value":"Beta"},{"field_key":"score","type_id":br.get_type("widget").id,"op":"eq","value":2}]}]},"sort":[{"field":"project","dir":"desc"},{"field_key":"score","type_id":ar.get_type("widget").id,"dir":"asc","nulls":"last"}]}
	var rows: Array = state.execute_cross_project_query(query)
	var r = A.is_true(state.last_cross_project_query_error.is_empty() and rows.size() == 2 and rows[0].id == bi.id and rows[1].id == ai.id, "OR branches preserve project-owned identities and merged multi-sort")
	if r is String: alpha.close(); beta.close(); return r
	alpha.execute_registry_query({"filter":{"field_key":"score","type_id":br.get_type("widget").id,"op":"eq","value":2}}, ar)
	r = A.contains(alpha.last_query_error, "not present", "foreign same-slug type identity is refused")
	alpha.close(); beta.close(); return r

func test_unbound_derived_query_uses_each_pinned_revision_and_preserves_skill_outcome() -> Variant:
	var db: DocketDBJsonl = _db("Derived"); var registry: TypeRegistry = _registry_with_widget(db)
	var made: Dictionary = registry.create_item({"type":"widget","title":"Done","memo":"ok"}, "tester")
	var transition_error: String = registry.transition_item(made.id, "done", "tester")
	var rows: Array = db.execute_registry_query({"filter":{"field":"is_terminal","op":"eq","value":true}}, registry)
	var r = A.is_true(transition_error.is_empty() and db.last_query_error.is_empty() and rows.size() == 1 and rows[0].is_terminal == true and rows[0].state_outcome == "unspecified", "unbound derived filter evaluates pinned semantics across types: transition=%s query=%s" % [transition_error,db.last_query_error])
	if r is String: db.close(); return r
	var skill_type: Dictionary = registry.get_type("skill")
	var skill_id: String = db.next_uuid7_id()
	var now: String = Time.get_datetime_string_from_system(true)
	db.insert_item(skill_id, {"type":"skill","type_id":skill_type.id,"type_revision":skill_type.current_revision,"status":"draft","title":"Skill","outcome":"user-authored","created_at":now,"updated_at":now})
	var fetched: Dictionary = db.get_item(skill_id)
	r = A.eq(fetched.get("outcome"), "user-authored", "derived state outcome does not overwrite skill outcome")
	db.close(); return r

func test_legacy_sqlite_builtin_uses_compatibility_registry_for_derived_query() -> Variant:
	var path: String = DIR + "/legacy.db"; var db: DocketDB = DocketDB.create_new(path)
	var now: String = Time.get_datetime_string_from_system(true)
	var insert_error: String = db.insert_item("LEG-1", {"type":"discussion","status":"resolved","title":"Historical","created_at":now,"updated_at":now})
	var registry: TypeRegistry = TypeRegistry.for_db(db, "legacy")
	var rows: Array = db.execute_registry_query({"filter":{"field":"state_category","op":"eq","value":"waiting"}}, registry)
	var r = A.is_true(insert_error.is_empty() and rows.size() == 1 and rows[0].id == "LEG-1", "legacy SQLite items use compatibility registry without format upgrade")
	db.close(); return r

func test_new_descriptor_does_not_reinterpret_old_opaque_value_until_explicit_repin() -> Variant:
	var db: DocketDBJsonl = _db("Opaque"); var registry: TypeRegistry = _registry_with_widget(db)
	# The fixture starts with the descriptor, so create a distinct type whose first
	# revision lacks it and then evolve forward.
	var base: Dictionary = _definition("Opaque Widget"); base.slug = "opaque_widget"; base.fields = base.fields.filter(func(field): return field.key != "research_cost")
	var defined: Dictionary = registry.define_type("opaque_widget", base, "tester", "opaque base")
	if defined.has("error"): db.close(); return "opaque type definition failed: %s" % defined.error
	registry.activate_type("opaque_widget", defined.type.current_revision, "tester", "activate")
	var made: Dictionary = registry.create_item({"type":"opaque_widget","title":"Opaque"}, "tester")
	var defaulted: Dictionary = registry.create_item({"type":"opaque_widget","title":"Defaulted"}, "tester")
	db.update_item_fields_checked(made.id, {"fields":{"research_cost":"kept"}})
	var evolved: Dictionary = base.duplicate(true); evolved.fields.append({"key":"research_cost","type":"string","required":false,"nullable":true,"default":"planned"})
	var preview: Dictionary = registry.preview_evolution("opaque_widget", evolved, defined.type.current_revision, [])
	var apply_error: String = registry.apply_evolution(preview, "tester", "publish descriptor")
	var current: Dictionary = registry.get_type("opaque_widget")
	var before_rows: Array = db.execute_registry_query({"filter":{"field_key":"research_cost","type_id":current.id,"op":"eq","value":"kept"}}, registry)
	var current_item: Dictionary = registry.create_item({"type":"opaque_widget","title":"Current","research_cost":"aaa"}, "tester")
	var before_sorted: Array = db.execute_registry_query({"sort":[{"field_key":"research_cost","type_id":current.id,"dir":"asc","nulls":"last"}]}, registry)
	var r = A.is_true(apply_error.is_empty() and before_rows.is_empty() and before_sorted.size() == 3 and before_sorted[0].id == current_item.id, "old pins keep formerly opaque keys outside typed filter and sort meaning")
	if r is String: db.close(); return r
	var repin: Dictionary = registry.preview_evolution("opaque_widget", evolved, current.current_revision, [made.id, defaulted.id])
	if repin.has("error"): db.close(); return "selected default preview failed: %s" % repin.error
	apply_error = registry.apply_evolution(repin, "tester", "explicit repin")
	var after_rows: Array = db.execute_registry_query({"filter":{"field_key":"research_cost","type_id":current.id,"op":"eq","value":"kept"}}, registry)
	r = A.is_true(apply_error.is_empty() and after_rows.size() == 1 and db.get_item(defaulted.id).fields.research_cost == "planned", "selected repin preserves opaque values and applies a custom default despite the unrelated materialized legacy column")
	if r is String: db.close(); return r
	var path: String = db.get_path(); db.close(); db = DocketDBJsonl.open_jsonl(path)
	r = A.eq(db.get_item(defaulted.id).fields.research_cost, "planned", "custom upgrade default persists through reopen")
	db.close(); return r

func test_saved_query_roundtrip_keeps_identity_field_state_and_sort_bindings() -> Variant:
	var db: DocketDBJsonl = _db("Saved"); var registry: TypeRegistry = _registry_with_widget(db); var type_id: String = registry.get_type("widget").id
	var query: Dictionary = {"filter":{"$and":[{"field":"type","type_id":type_id,"op":"eq","value":"widget"},{"field_key":"score","type_id":type_id,"op":"gte","value":0},{"field":"status","type_id":type_id,"op":"eq","value":"queued"}]},"sort":[{"field_key":"score","type_id":type_id,"dir":"desc","nulls":"last"}]}
	var error: String = db.save_query_checked("typed", query)
	var loaded: Dictionary = db.load_query("typed")
	var loaded_conditions: Array = loaded.get("filter", {}).get("$and", [])
	var r = A.is_true(error.is_empty() and loaded_conditions.size() == 3 and loaded_conditions[0].type_id == type_id and loaded_conditions[1].field_key == "score" and float(loaded_conditions[1].value) == 0.0 and loaded_conditions[2].value == "queued" and loaded.get("sort", []).size() == 1 and loaded.sort[0].field_key == "score" and loaded.sort[0].type_id == type_id and loaded.sort[0].dir == "desc" and loaded.sort[0].nulls == "last", "saved query preserves stable bindings and all sort metadata across JSON numeric representation")
	if r is String: db.close(); return r
	var preview: Dictionary = registry.preview_evolution("widget", registry.get_type("widget").definition, registry.get_type("widget").current_revision)
	r = A.is_true(preview.saved_query_impact.size() == 1 and preview.saved_query_impact[0].references.has("field:score") and preview.saved_query_impact[0].references.has("status:queued"), "evolution impact reads actual typed field and state bindings")
	db.close(); return r

func test_dcq_roundtrip_preserves_typed_sort_binding_verbatim() -> Variant:
	var db: DocketDBJsonl = _db("DCQ"); var registry: TypeRegistry = _registry_with_widget(db); var type_id: String = registry.get_type("widget").id
	var state: AppState = AppState.new(); state.db = db; state.schema = {}; state._project_dbs = {"DCQ":db}; state._type_registries = {"DCQ":registry}
	var grid: QueryGrid = QueryGrid.new(); add_child(grid); grid.init(LocalDocketSource.new(state))
	grid._dcq_columns = ["id", "score", "state_category"]
	grid._sort_field = "score"; grid._sort_dir = "desc"; grid._sort_binding = {"field_key":"score","type_id":type_id,"nulls":"first"}
	var path: String = DIR + "/typed.dcq"; grid.save_dcq(path)
	var loaded: QueryGrid = QueryGrid.new(); add_child(loaded); loaded.init(LocalDocketSource.new(state)); loaded.load_dcq(path)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var r = A.is_true(parsed is Dictionary and parsed.sort[0].type_id == type_id and parsed.columns == ["id", "score", "state_category"] and loaded._dcq_columns == parsed.columns and loaded._sort_binding.type_id == type_id and loaded._sort_binding.nulls == "first" and loaded._sort_dir == "desc", "dcq load/save keeps stable field identity, columns, and null ordering")
	grid.queue_free(); loaded.queue_free(); db.close(); return r

func test_custom_field_colliding_with_builtin_column_keeps_custom_kind_and_authority() -> Variant:
	var path: String = DIR + "/Collision.dct"; var db: DocketDBJsonl = DocketDBJsonl.create_new_jsonl(path); db.set_project_name_checked("Collision")
	var registry: TypeRegistry = _registry_with_widget(db)
	var made: Dictionary = registry.create_item({"type":"widget","title":"Collision","research_cost":"expensive"}, "tester")
	var r = A.is_true(not made.has("error") and made.item.fields.research_cost == "expensive" and int(made.item.get("research_cost", 0)) == 0, "custom descriptor owns a colliding builtin column name")
	if r is String: db.close(); return r
	db.close(); db = DocketDBJsonl.open_jsonl(path); registry = TypeRegistry.for_db(db, "Collision")
	var type_id: String = registry.get_type("widget").id
	var rows: Array = db.execute_registry_query({"filter":{"field_key":"research_cost","type_id":type_id,"op":"eq","value":"expensive"}}, registry)
	r = A.is_true(rows.size() == 1 and rows[0].fields.research_cost == "expensive", "reopen and typed JSON query retain custom authority")
	if r is String: db.close(); return r
	var invalid: Dictionary = _definition(); invalid.fields[0].type = "number"
	r = A.contains(registry.validate_definition(invalid), "universal field", "custom definitions cannot change universal field kinds")
	db.close(); return r

func test_move_refuses_owned_vault_and_preserves_threaded_comments_on_success() -> Variant:
	var source: DocketDBJsonl = _db("Source"); var target: DocketDBJsonl = _db("Target")
	var registry: TypeRegistry = _registry_with_widget(source); var item: Dictionary = registry.create_item({"type":"widget","title":"Move"}, "tester")
	var evolved: Dictionary = registry.get_type("widget").definition; evolved.description = "New presentation"
	var evolution: Dictionary = registry.preview_evolution("widget", evolved, registry.get_type("widget").current_revision)
	var evolution_error: String = registry.apply_evolution(evolution, "tester", "new presentation")
	if not evolution_error.is_empty(): source.close(); target.close(); return "evolution setup failed: %s" % evolution_error
	source.update_item_fields_checked(item.id, {"extras":{"future_payload":{"kept":true}}})
	source.attach_file(item.id, "payload.bin", PackedByteArray([0,1,255]))
	var parent: Dictionary = source.add_comment(item.id, "tester", "parent")
	source.add_comment(item.id, "tester", "child", int(parent.id))
	source.set_secret_checked("unusual-handle", PackedByteArray([1]), PackedByteArray([2]), PackedByteArray([3]), false, item.id)
	var mover: DocketMove = DocketMove.new(); var projects: Dictionary = {"Source":source,"Target":target}
	var refused: Dictionary = mover.execute({"id":item.id,"source_project":"Source","target_project":"Target","import_definition":true,"author":"tester","reason":"move"}, {}, source, projects)
	var r = A.is_true(refused.error.contains("vault") and source.has_item(item.id) and not target.has_item(item.id), "any owned vault handle blocks transfer")
	if r is String: source.close(); target.close(); return r
	source.delete_secret_checked("unusual-handle")
	source.set_secret_checked(item.id, PackedByteArray([4]), PackedByteArray([5]), PackedByteArray([6]), false, "")
	refused = mover.execute({"id":item.id,"source_project":"Source","target_project":"Target","import_definition":true,"author":"tester","reason":"move"}, {}, source, projects)
	r = A.is_true(refused.error.contains("vault") and source.has_item(item.id) and not target.has_item(item.id), "unowned conventional legacy ciphertext also blocks transfer")
	if r is String: source.close(); target.close(); return r
	source.delete_secret_checked(item.id)
	var moved: Dictionary = mover.execute({"id":item.id,"source_project":"Source","target_project":"Target","import_definition":true,"author":"tester","reason":"move"}, {}, source, projects)
	if moved.has("error"): source.close(); target.close(); return "move failed: %s" % moved.error
	var comments: Array = target.list_comments(moved.new_id); var moved_item: Dictionary = target.get_item(moved.new_id)
	var moved_semantics: Dictionary = TypeRegistry.for_db(target, "Target").resolve_item(moved_item)
	r = A.is_true(not source.has_item(item.id) and target.has_item(moved.new_id) and comments.size() == 2 and int(comments[1].parent_id) == int(comments[0].id) and target.list_attachments(moved.new_id).size() == 1 and moved_item.extras.future_payload.kept == true and moved_semantics.revision.id == item.item.type_revision and moved_semantics.definition.description == "Tracks typed widgets", "durable target copy preserves exact historical meaning, opaque data, attachment, and remapped comment thread")
	source.close(); target.close(); return r

func test_move_failure_order_preserves_source_and_reports_durable_partial_copy() -> Variant:
	var source: DocketDBJsonl = _db("FailSource"); var target: DocketDBJsonl = _db("FailTarget")
	var registry: TypeRegistry = _registry_with_widget(source); var item: Dictionary = registry.create_item({"type":"widget","title":"Stable"}, "tester")
	var mover: DocketMove = DocketMove.new(); var projects: Dictionary = {"FailSource":source,"FailTarget":target}
	var held_target_registry: TypeRegistry = TypeRegistry.for_db(target, "FailTarget")
	target._exec("CREATE TRIGGER reject_import BEFORE INSERT ON items BEGIN SELECT RAISE(FAIL, 'target rejected'); END;")
	var failed: Dictionary = mover.execute({"id":item.id,"source_project":"FailSource","target_project":"FailTarget","import_definition":true,"author":"tester","reason":"failure order"}, {}, source, projects)
	var r = A.is_true(str(failed.get("error", "")).contains("Target write failed") and source.has_item(item.id) and not target.has_item(item.id) and held_target_registry.get_type("widget").has("error"), "target failure rolls back imported definition, refreshes an already-held registry, and never deletes source: %s" % failed.get("error", "missing error"))
	if r is String: source.close(); target.close(); return r
	target._exec("DROP TRIGGER IF EXISTS reject_import;")
	source._exec("CREATE TRIGGER reject_source_delete BEFORE DELETE ON items BEGIN SELECT RAISE(FAIL, 'source rejected'); END;")
	var partial: Dictionary = mover.execute({"id":item.id,"source_project":"FailSource","target_project":"FailTarget","import_definition":true,"author":"tester","reason":"partial copy"}, {}, source, projects)
	r = A.is_true(partial.get("partial_copy") == true and source.has_item(item.id) and target.has_item(item.id), "source deletion failure reports durable target copy without rolling it back")
	source.close(); target.close(); return r

func test_mirror_validates_target_pin_and_commits_patch_transition_and_audit_together() -> Variant:
	var source: DocketDBJsonl = _db("MirrorSource"); var target: DocketDBJsonl = _db("MirrorTarget")
	var source_registry: TypeRegistry = _registry_with_widget(source); var target_registry: TypeRegistry = _registry_with_widget(target)
	var source_item: Dictionary = source_registry.create_item({"type":"widget","title":"Source","score":7,"memo":"ready"}, "tester")
	var target_item: Dictionary = target_registry.create_item({"type":"widget","title":"Target","score":1}, "tester")
	var mirror: DocketMirror = DocketMirror.new(); var projects: Dictionary = {"MirrorSource":source,"MirrorTarget":target}
	var result: Dictionary = mirror.execute({"source_id":source_item.id,"source_project":"MirrorSource","target_id":target_item.id,"target_project":"MirrorTarget","fields":["score","memo"],"transition_to":"done","expected_revision":target_item.item.type_revision}, {}, source, projects)
	var after: Dictionary = target.get_item(target_item.id)
	var r = A.is_true(not result.has("error") and after.status == "done" and after.fields.score == 7 and after.fields.memo == "ready" and target.list_comments(target_item.id).size() == 1, "mirror commits typed patch, guarded transition and audit: %s" % result.get("error", "unexpected persisted result"))
	if r is String: source.close(); target.close(); return r
	var canonical_before: String = FileAccess.get_file_as_string(target.get_path()); var token_before: String = target_registry.item_token(after)
	target._exec("CREATE TRIGGER reject_second_mirror BEFORE INSERT ON comments BEGIN SELECT RAISE(FAIL, 'audit rejected'); END;")
	var failed: Dictionary = target_registry.mirror_item(target_item.id, {"fields":{"score":9}}, "", "tester", "", "second mirror", after.type_revision, token_before)
	r = A.is_true(failed.has("error") and target.get_item(target_item.id).fields.score == 7 and FileAccess.get_file_as_string(target.get_path()) == canonical_before, "v2 audit failure rolls back the candidate patch and canonical publication")
	if r is String: source.close(); target.close(); return r
	var unknown: Dictionary = mirror.execute({"source_id":source_item.id,"source_project":"Missing","target_id":target_item.id,"target_project":"MirrorTarget","fields":["score"]}, {}, source, projects)
	r = A.contains(unknown.error, "Unknown source project", "unknown mirror project cannot fall back to primary")
	source.close(); target.close(); return r

func test_query_rejects_mixed_trees_unknown_conjunction_and_foreign_sort_identity() -> Variant:
	var db: DocketDBJsonl = _db("Validation"); var registry: TypeRegistry = _registry_with_widget(db)
	var made: Dictionary = registry.create_item({"type":"widget","title":"Visible"}, "tester")
	var type_id: String = registry.get_type("widget").id
	var malformed: Array = [
		{"filter":{"$and":[],"$or":[]}},
		{"filter":{"$and":[],"field":"title","op":"eq","value":"x"}},
		{"filter":{"conditions":[{"field":"title","op":"eq","value":"x"},{"conj":"xor","field":"title","op":"eq","value":"y"}]}},
		{"filter":{"field":"type","type_id":type_id,"op":"neq","value":"widget"}},
		{"sort":[{"field":"status","type_id":"type:foreign","dir":"asc"}]},
	]
	for query in malformed:
		db.execute_registry_query(query, registry)
		var check = A.is_true(not db.last_query_error.is_empty(), "malformed or foreign typed query is refused")
		if check is String: db.close(); return check
	var all_rows: Array = db.execute_registry_query({"filter":{"$and":[]}}, registry)
	var no_rows: Array = db.execute_registry_query({"filter":{"$or":[]}}, registry)
	var scoped_rows: Array = db.execute_registry_query({"filter":{"conditions":[{"field":"type","type_id":type_id,"op":"eq","value":"widget"},{"conj":"and","field":"status","op":"eq","value":"queued"}]}}, registry)
	var r = A.is_true(db.last_query_error.is_empty() and no_rows.is_empty() and all_rows.size() == 1 and all_rows[0].id == made.id and scoped_rows.size() == 1 and scoped_rows[0].id == made.id, "empty boolean identities and conditions-list sibling type scope retain their documented meaning")
	db.close(); return r

func test_saved_query_tool_validates_bindings_before_canonical_write() -> Variant:
	var db: DocketDBJsonl = _db("SavedTool"); var tools: ToolRegistry = ToolRegistry.new(); tools.init({}, db, {"SavedTool":db})
	var before: String = FileAccess.get_file_as_string(db.get_path())
	var result: Dictionary = tools.call_tool("docket_saved_query", {"project":"SavedTool","action":"save","name":"bad","filter":{"field_key":"score","type_id":"type:missing","op":"eq","value":1}})
	var r = A.is_true(result.has("error") and db.load_query("bad").is_empty() and FileAccess.get_file_as_string(db.get_path()) == before, "public saved-query tool refuses absent identities without changing canonical data")
	db.close(); return r

func test_move_source_relation_read_failure_copies_nothing() -> Variant:
	var source: DocketDBJsonl = _db("ReadSource"); var target: DocketDBJsonl = _db("ReadTarget")
	var registry: TypeRegistry = _registry_with_widget(source); var item: Dictionary = registry.create_item({"type":"widget","title":"Complete"}, "tester")
	var source_bytes: String = FileAccess.get_file_as_string(source.get_path()); var target_bytes: String = FileAccess.get_file_as_string(target.get_path())
	source._exec("DROP TABLE attachments;")
	var moved: Dictionary = DocketMove.new().execute({"id":item.id,"source_project":"ReadSource","target_project":"ReadTarget","import_definition":true,"author":"tester","reason":"read failure"}, {}, source, {"ReadSource":source,"ReadTarget":target})
	var held_target: TypeRegistry = TypeRegistry.for_db(target, "ReadTarget")
	var r = A.is_true(moved.has("error") and moved.error.contains("Source export failed") and FileAccess.get_file_as_string(source.get_path()) == source_bytes and FileAccess.get_file_as_string(target.get_path()) == target_bytes and source.has_item(item.id) and not target.has_item(item.id) and held_target.get_type("widget").has("error"), "relation read failure cannot copy a partial export or publish a ghost definition")
	source.close(); target.close(); return r

func test_query_scope_expands_compatible_multitype_field_and_keeps_grouped_status_identity() -> Variant:
	var catalog: Array = [
		{"id":"type:a","key":TypeCatalog.identity("P","type:a"),"slug":"alpha","project":"P","fields":["score"],"field_kinds":{"score":"number"}},
		{"id":"type:b","key":TypeCatalog.identity("P","type:b"),"slug":"beta","project":"P","fields":["score"],"field_kinds":{"score":"number"}},
	]
	var compiled: Dictionary = QueryTypeScope.compile_catalog_conditions([{"field":"type","op":"catalog_in","value":[catalog[0].key,catalog[1].key]},{"conj":"and","field":"score","op":"gte","value":1}], catalog, true)
	var encoded: String = JSON.stringify(compiled)
	var status: Dictionary = QueryTypeScope.compile_catalog_conditions([{"field":"type","op":"catalog_in","value":[catalog[0].key,catalog[1].key]},{"conj":"and","field":"status","op":"catalog_status","value":{"key":catalog[1].key,"status":"done"}}], catalog, true)
	var r = A.is_true(encoded.contains("type:a") and encoded.contains("type:b") and encoded.count("field_key") == 2 and JSON.stringify(status).contains("type:b") and JSON.stringify(status).contains("done"), "multi-type custom fields expand to explicit branches and grouped status retains its chosen identity")
	return r

func test_query_grid_compiles_multitype_field_and_status_choice_to_exact_identities() -> Variant:
	var db: DocketDBJsonl = _db("Grid"); var registry: TypeRegistry = _registry_with_widget(db)
	var second: Dictionary = _definition("Second"); second.slug = "second"
	var defined: Dictionary = registry.define_type("second", second, "tester", "second")
	if defined.has("error"): db.close(); return "second grid type definition failed: %s" % defined.error
	registry.activate_type("second", defined.type.current_revision, "tester", "ready")
	var state: AppState = AppState.new(); state.db = db; state.schema = {}; state._project_dbs = {"Grid":db}; state._type_registries = {"Grid":registry}
	var grid: QueryGrid = QueryGrid.new(); add_child(grid); grid.init(LocalDocketSource.new(state))
	var keys: Array = []
	for record in grid._type_catalog:
		if record.slug in ["widget","second"]: keys.append(record.key)
	grid.set_filter(JSON.stringify({"conditions":[{"field":"type","op":"catalog_in","value":keys},{"conj":"and","field":"score","op":"gte","value":0}]}))
	var compiled: Dictionary = grid._build_conditions_filter(); var encoded: String = JSON.stringify(compiled)
	var status_key: String = ""
	for record in grid._type_catalog:
		if record.slug == "second": status_key = str(record.key)
	grid.set_filter(JSON.stringify({"conditions":[{"field":"type","op":"catalog_in","value":keys},{"conj":"and","field":"status","op":"catalog_status","value":{"key":status_key,"status":"queued"}}]}))
	var status_encoded: String = JSON.stringify(grid._build_conditions_filter())
	var r = A.is_true(encoded.count("field_key") == 2 and encoded.contains(registry.get_type("widget").id) and encoded.contains(registry.get_type("second").id) and status_encoded.contains(status_key) == false and status_encoded.contains(registry.get_type("second").id), "QueryGrid emits explicit compatible field branches and preserves the selected status identity")
	grid.queue_free(); db.close(); return r

func test_uuid_move_retargets_qualified_incoming_and_declared_json_references_only() -> Variant:
	var source: DocketDBJsonl = _db("RefSource"); var target: DocketDBJsonl = _db("RefTarget"); var other: DocketDBJsonl = _db("Other")
	var definition: Dictionary = _definition("Reference Widget"); definition.fields.append({"key":"peer","type":"item_ref","required":false,"nullable":true}); definition.fields.append({"key":"peers","type":"reference_list","required":false,"nullable":true})
	var registry: TypeRegistry = TypeRegistry.for_db(source, "RefSource"); var defined: Dictionary = registry.define_type("widget", definition, "tester", "references")
	if defined.has("error"): source.close(); target.close(); other.close(); return "reference type definition failed: %s" % defined.error
	registry.activate_type("widget", defined.type.current_revision, "tester", "ready")
	var moved_item: Dictionary = registry.create_item({"type":"widget","title":"Moved"}, "tester")
	var remaining: Dictionary = registry.create_item({"type":"widget","title":"Remaining","peer":moved_item.id,"peers":["RefSource:%s" % moved_item.id]}, "tester")
	source.update_item_fields_checked(remaining.id, {"extras":{"opaque":"RefSource:%s" % moved_item.id}})
	source.add_link(remaining.id, "RefSource:%s" % moved_item.id, "depends_on")
	var discussion: Dictionary = TypeRegistry.for_db(other, "Other").get_type("discussion")
	var now: String = Time.get_datetime_string_from_system(true)
	other.insert_item(moved_item.id, {"type":"discussion","type_id":discussion.id,"type_revision":discussion.current_revision,"status":"active","title":"Local same ID","created_at":now,"updated_at":now})
	var other_dependent: String = other.next_uuid7_id(); other.insert_item(other_dependent, {"type":"discussion","type_id":discussion.id,"type_revision":discussion.current_revision,"status":"active","title":"Local ref","parent":moved_item.id,"created_at":now,"updated_at":now})
	var moved: Dictionary = DocketMove.new().execute({"id":moved_item.id,"source_project":"RefSource","target_project":"RefTarget","import_definition":true,"author":"tester","reason":"reference move"}, {}, source, {"RefSource":source,"RefTarget":target,"Other":other})
	if moved.has("error"): source.close(); target.close(); other.close(); return "move failed: %s" % moved.error
	var after: Dictionary = source.get_item(remaining.id); var links: Array = source.get_links(remaining.id)
	var destination: String = "RefTarget:%s" % moved.new_id
	var r = A.is_true(after.fields.peer == destination and after.fields.peers == [destination] and after.extras.opaque == "RefSource:%s" % moved_item.id and links.size() == 1 and links[0].to == destination and other.get_item(other_dependent).parent == moved_item.id, "UUID moves retarget qualified and source-local declared references while opaque strings and another project's local same-ID reference remain untouched")
	source.close(); target.close(); other.close(); return r

func test_sqlite_mirror_uses_typed_validation_and_rolls_back_audit_failure() -> Variant:
	var path: String = DIR + "/mirror.sqlite"; var db: DocketDB = DocketDB.create_new(path)
	var now: String = Time.get_datetime_string_from_system(true)
	var insert_error: String = db.insert_item("DISC-1", {"type":"discussion","status":"active","title":"Before","created_at":now,"updated_at":now})
	if not insert_error.is_empty(): db.close(); return "setup failed: %s" % insert_error
	db._exec("CREATE TRIGGER reject_mirror_comment BEFORE INSERT ON comments BEGIN SELECT RAISE(FAIL, 'audit rejected'); END;")
	var registry: TypeRegistry = TypeRegistry.for_db(db, "SQLite")
	var result: Dictionary = registry.mirror_item("DISC-1", {"fields":{"title":"After"}}, "resolved", "tester", "", "mirror")
	var after: Dictionary = db.get_item("DISC-1")
	var r = A.is_true(result.has("error") and after.title == "Before" and after.status == "active" and db.list_comments("DISC-1").is_empty(), "SQLite mirror validates and rolls back item, transition, event and audit as one unit")
	db.close(); return r

func test_historical_import_preserves_revision_metadata_and_current_pointer() -> Variant:
	var source: DocketDBJsonl = _db("HistorySource"); var target: DocketDBJsonl = _db("HistoryTarget")
	var source_registry: TypeRegistry = _registry_with_widget(source); var target_registry: TypeRegistry = TypeRegistry.for_db(target, "HistoryTarget")
	var source_type: Dictionary = source_registry.get_type("widget"); var original: Dictionary = source_registry.get_revision(source_type.current_revision)
	var error: String = target_registry.import_historical_revision(source_type, original, "importer", "install identity")
	if not error.is_empty(): source.close(); target.close(); return "initial import failed: %s" % error
	var evolved_definition: Dictionary = source_type.definition.duplicate(true); evolved_definition.label = "Widget History"
	var preview: Dictionary = source_registry.preview_evolution("widget", evolved_definition, source_type.current_revision)
	error = source_registry.apply_evolution(preview, "historian", "published wording")
	var historical: Dictionary = source_registry.get_revision(source_registry.get_type("widget").current_revision)
	var target_pointer: String = target_registry.get_type("widget").current_revision
	error = target_registry.import_historical_revision(source_registry.get_type("widget"), historical, "importer", "transfer exact history")
	var imported: Dictionary = target_registry.get_revision(historical.id); var target_type: Dictionary = target_registry.get_type("widget")
	var r = A.is_true(error.is_empty() and not imported.has("error") and imported.get("author") == historical.author and imported.get("created_at") == historical.created_at and imported.get("reason") == historical.reason and target_type.get("current_revision") == target_pointer and target_type.get("provenance", {}).get("imports", []).size() >= 2 and target_type.provenance.imports[-1].imported_by == "importer", "historical revision metadata stays immutable while import attribution is recorded separately and activation pointer is unchanged")
	source.close(); target.close(); return r

func test_trusted_builtin_historical_import_accepts_exact_snapshot_without_activation() -> Variant:
	var db: DocketDBJsonl = _db("BuiltinHistory"); var registry: TypeRegistry = TypeRegistry.for_db(db, "BuiltinHistory")
	var builtin: Dictionary = registry.get_type("discussion")
	if builtin.has("error"): db.close(); return "builtin registry unavailable: %s" % builtin.error
	var definition: Dictionary = builtin.definition.duplicate(true); definition.label = "Discussion (historical)"
	var revision_id: String = "%s@%s" % [builtin.id, TypeRegistryBootstrap._definition_hash(definition)]
	var revision: Dictionary = {"id":revision_id,"type_id":builtin.id,"parent_revision":builtin.current_revision,"definition":definition,"author":"old-release","created_at":"2025-01-01T00:00:00Z","reason":"published snapshot"}
	var pointer: String = builtin.current_revision
	var error: String = registry.import_historical_revision(builtin, revision, "importer", "older compatible pin")
	var imported: Dictionary = registry.get_revision(revision_id)
	var r = A.is_true(error.is_empty() and not imported.has("error") and imported.get("author") == "old-release" and registry.get_type("discussion").current_revision == pointer, "trusted protected builtin history can be installed exactly without activation")
	db.close(); return r

func test_move_reference_rewrite_failure_keeps_source_and_reports_durable_copy() -> Variant:
	var source: DocketDBJsonl = _db("RewriteSource"); var target: DocketDBJsonl = _db("RewriteTarget")
	var registry: TypeRegistry = _registry_with_widget(source); var moved_item: Dictionary = registry.create_item({"type":"widget","title":"Moved"}, "tester")
	var dependent: Dictionary = registry.create_item({"type":"widget","title":"Dependent","parent":moved_item.id}, "tester")
	source._exec("CREATE TRIGGER reject_ref_update BEFORE UPDATE ON items WHEN OLD.id='%s' BEGIN SELECT RAISE(FAIL, 'rewrite rejected'); END;" % dependent.id)
	var moved: Dictionary = DocketMove.new().execute({"id":moved_item.id,"source_project":"RewriteSource","target_project":"RewriteTarget","import_definition":true,"author":"tester","reason":"rewrite failure"}, {}, source, {"RewriteSource":source,"RewriteTarget":target})
	var r = A.is_true(moved.get("partial_copy") == true and source.has_item(moved_item.id) and target.has_item(moved_item.id) and source.get_item(dependent.id).parent == moved_item.id, "reference rewrite failure leaves source authoritative and reports the durable target copy: %s" % moved.get("error", "missing partial-copy error"))
	source.close(); target.close(); return r

func test_import_remaps_forward_ordered_comment_thread_and_refuses_missing_parent() -> Variant:
	var db: DocketDBJsonl = _db("Threads")
	var discussion: Dictionary = TypeRegistry.for_db(db, "Threads").get_type("discussion")
	if discussion.has("error"): db.close(); return "discussion registry unavailable: %s" % discussion.error
	var now: String = Time.get_datetime_string_from_system(true)
	var exported: Dictionary = {"item":{"type":"discussion","type_id":discussion.id,"type_revision":discussion.current_revision,"status":"active","title":"Thread","created_at":now,"updated_at":now,"fields":{},"extras":{}},"comments":[{"id":2,"parent_id":1,"author":"b","text":"child","status":"open","created_at":now},{"id":1,"parent_id":0,"author":"a","text":"parent","status":"open","created_at":now}],"tags":[],"events":[],"links":[],"attachments":[]}
	var first: String = db.import_item_full_checked(db.next_uuid7_id(), exported)
	var thread_rows: Array = db.execute_query({"filter":{"title":"Thread"}})
	if not first.is_empty() or thread_rows.is_empty(): db.close(); return "forward-thread setup failed: %s" % first
	var comments: Array = db.list_comments(str(thread_rows[0].id))
	var path: String = db.get_path(); db.close(); db = DocketDBJsonl.open_jsonl(path)
	if db == null or db.get_item(str(thread_rows[0].id)).is_empty(): return "valid imported comment thread did not reopen"
	var broken: Dictionary = exported.duplicate(true); broken.item.title = "Broken"; broken.comments = [{"id":3,"parent_id":99,"author":"x","text":"orphan","status":"open","created_at":now}]
	var before: String = FileAccess.get_file_as_string(db.get_path()); var second: String = db.import_item_full_checked(db.next_uuid7_id(), broken)
	var malformed: Dictionary = exported.duplicate(true); malformed.item.title = "Missing metadata"; malformed.comments[0].erase("created_at")
	var third: String = db.import_item_full_checked(db.next_uuid7_id(), malformed)
	var r = A.is_true(first.is_empty() and comments.size() == 2 and comments[1].parent_id == comments[0].id and second.contains("unresolved parent") and third.contains("missing id or created_at") and FileAccess.get_file_as_string(db.get_path()) == before and db.execute_query({"filter":{"title":"Broken"}}).is_empty() and db.execute_query({"filter":{"title":"Missing metadata"}}).is_empty(), "valid forward comment parents reopen while unresolved parents and missing required metadata leave canonical data unchanged")
	db.close(); return r

func test_legacy_jsonl_mirror_uses_compatibility_registry_without_upgrade() -> Variant:
	var path: String = DIR + "/legacy-mirror.dct"; var file: FileAccess = FileAccess.open(path, FileAccess.WRITE); file.store_string(FileAccess.get_file_as_string("res://test/fixtures/dynamic_types_legacy_v1.jsonl")); file.close()
	var db: DocketDBJsonl = DocketDBJsonl.open_jsonl(path)
	var registry: TypeRegistry = TypeRegistry.for_db(db, "legacy-fixture")
	var result: Dictionary = registry.mirror_item("LEG-0001", {"fields":{"title":"Mirrored"}}, "resolved", "tester", "", "legacy audit")
	var after: Dictionary = db.get_item("LEG-0001")
	var before_bytes: String = FileAccess.get_file_as_string(path)
	var refused: Dictionary = registry.mirror_item("LEG-0001", {"fields":{"title":""}}, "", "tester", "", "invalid")
	var r = A.is_true(not result.has("error") and after.title == "Mirrored" and after.status == "resolved" and refused.has("error") and db.get_item("LEG-0001").title == "Mirrored" and FileAccess.get_file_as_string(path) == before_bytes and db.get_meta_value("jsonl_version", "") == "1.0.0", "legacy JSONL mirror shares candidate and lifecycle validation without upgrading format or partially applying invalid data")
	db.close(); return r

func test_public_query_wrappers_reject_malformed_conditions_without_persistence() -> Variant:
	var db: DocketDBJsonl = _db("MalformedPublic"); var registry: TypeRegistry = _registry_with_widget(db); var tools: ToolRegistry = ToolRegistry.new(); tools.init({}, db, {"MalformedPublic":db})
	var type_id: String = registry.get_type("widget").id
	var malformed: Array = [
		{"conditions":{"field_key":"score","type_id":type_id,"op":"eq","value":1}},
		{"conditions":[],"$or":[],"type_id":type_id},
		{"conditions":[],"field_key":"score","type_id":type_id},
	]
	var before: String = FileAccess.get_file_as_string(db.get_path())
	for filter_value in malformed:
		var queried: Dictionary = tools.call_tool("docket_query", {"project":"MalformedPublic","filter":filter_value})
		var query_check = A.is_true(queried.has("error") and str(queried.error).contains("condition"), "public query refuses malformed conditions wrapper")
		if query_check is String: db.close(); return query_check
		var saved: Dictionary = tools.call_tool("docket_saved_query", {"project":"MalformedPublic","action":"save","name":"invalid","filter":filter_value})
		var save_check = A.is_true(saved.has("error") and db.load_query("invalid").is_empty(), "public saved query refuses malformed conditions wrapper")
		if save_check is String: db.close(); return save_check
	var r = A.eq(FileAccess.get_file_as_string(db.get_path()), before, "malformed public queries never mutate canonical data")
	db.close(); return r

func test_invalid_registry_is_public_error_and_visible_empty_query_catalog() -> Variant:
	var db: DocketDBJsonl = _db("InvalidRegistry"); var registry: TypeRegistry = TypeRegistry.for_db(db, "InvalidRegistry")
	var tools: ToolRegistry = ToolRegistry.new(); tools.init({}, db, {"InvalidRegistry":db})
	var rows: Array = db._exec_select("SELECT id,definition_json FROM type_def_versions LIMIT 1;")
	if rows.is_empty(): db.close(); return "seeded definition missing"
	var malformed: Dictionary = JSON.parse_string(str(rows[0].definition_json)); malformed["lifecycle"] = {"states":"not-an-array"}
	db._exec("UPDATE type_def_versions SET definition_json=? WHERE id=?;", [JSON.stringify(malformed),str(rows[0].id)])
	var reload_error: String = registry.reload()
	var listed: Dictionary = tools.call_tool("docket_type_list", {"project":"InvalidRegistry"})
	var machines: Dictionary = tools.call_tool("docket_get_state_machine", {"project":"InvalidRegistry"})
	var state: AppState = AppState.new(); state.db = db; state.schema = TypeRegistryBootstrap.load_shipped_schema(); state._project_dbs = {"InvalidRegistry":db}; state._type_registries = {"InvalidRegistry":registry}
	var grid: QueryGrid = QueryGrid.new(); add_child(grid); grid.init(LocalDocketSource.new(state))
	var r = A.is_true(not reload_error.is_empty() and listed.has("error") and machines.has("error") and grid._type_catalog.is_empty() and grid._catalog_diagnostic.contains("read-only") and grid._count_label.text.contains("Type catalog unavailable"), "invalid stored definitions propagate through public discovery and remain visible without selectable schema fallback")
	grid.queue_free(); db.close(); return r

func test_public_flat_project_filter_must_match_routed_project() -> Variant:
	var alpha: DocketDBJsonl = _db("RoutedAlpha"); var beta: DocketDBJsonl = _db("RoutedBeta")
	var tools: ToolRegistry = ToolRegistry.new(); tools.init({}, alpha, {"RoutedAlpha":alpha,"RoutedBeta":beta})
	var created: Dictionary = tools.call_tool("docket_create", {"project":"RoutedAlpha","type":"discussion","title":"Alpha"})
	if created.has("error"): alpha.close(); beta.close(); return "project query setup failed: %s" % created.error
	var matching: Dictionary = tools.call_tool("docket_query", {"project":"RoutedAlpha","filter":{"project":"ROUTEDALPHA","type":"discussion"}})
	var mismatch: Dictionary = tools.call_tool("docket_query", {"project":"RoutedAlpha","filter":{"project":"RoutedBeta","type":"discussion"}})
	var invalid_shape: Dictionary = tools.call_tool("docket_query", {"project":"RoutedAlpha","filter":{"project":{"op":"eq","value":"RoutedAlpha"},"type":"discussion"}})
	var mixed_tree: Dictionary = tools.call_tool("docket_query", {"project":"RoutedAlpha","filter":{"project":"RoutedAlpha","$and":[{"field":"type","op":"eq","value":"discussion"}]}})
	var mixed_conditions: Dictionary = tools.call_tool("docket_query", {"project":"RoutedAlpha","filter":{"project":"RoutedAlpha","conditions":[{"field":"type","op":"eq","value":"discussion"}]}})
	var mixed_leaf: Dictionary = tools.call_tool("docket_query", {"project":"RoutedAlpha","filter":{"project":"RoutedAlpha","field":"type","op":"eq","value":"discussion"}})
	var r = A.is_true(not matching.has("error") and matching.count == 1 and matching.items[0].id == created.id and mismatch.has("error") and invalid_shape.has("error") and mixed_tree.has("error") and mixed_conditions.has("error") and mixed_leaf.has("error"), "only a matching genuinely flat project filter is normalized; mixed structured filters are refused intact")
	alpha.close(); beta.close(); return r
