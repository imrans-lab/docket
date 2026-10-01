extends Node
class_name TestDynamicItemGUI

const A = preload("res://test/assert_helpers.gd")
const DIR := "user://fixtures/dynamic_item_gui"
var _dbs: Array[DocketDB] = []

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))

func before_each() -> void:
	_reset_fixtures()

func teardown() -> void:
	_reset_fixtures()

func _reset_fixtures() -> void:
	for db in _dbs:
		if db != null and db.is_open():
			db.close()
	_dbs.clear()
	for child in get_children():
		remove_child(child)
		child.free()
	for filename in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [DIR, filename]))

func _definition() -> Dictionary:
	return {"slug":"review","label":"Review","description":"Review a revision","use_when":"approval is required","protected":false,"protected_behavior":{"regular_creation_allowed":true},"fields":[{"key":"revision","label":"Revision","help":"Commit identifier","type":"string","required":true,"nullable":false,"mutable":true},{"key":"source","label":"Source","help":"Immutable review source","type":"string","required":true,"nullable":false,"mutable":false},{"key":"findings","label":"Findings","help":"Review findings","type":"markdown","required":false,"nullable":true,"mutable":true},{"key":"attempts","label":"Attempts","type":"integer","required":false,"nullable":true,"mutable":true},{"key":"score","label":"Score","type":"number","required":false,"nullable":true,"mutable":true},{"key":"approved","label":"Approved","type":"boolean","required":false,"nullable":false,"mutable":true},{"key":"decision","label":"Decision","type":"enum","values":["accept","reject"],"required":false,"nullable":true,"mutable":true},{"key":"due_date","label":"Due date","type":"date","required":false,"nullable":true,"mutable":true},{"key":"reviewed_at","label":"Reviewed at","type":"timestamp","required":false,"nullable":true,"mutable":true},{"key":"subject","label":"Subject","type":"item_ref","required":false,"nullable":true,"mutable":true},{"key":"related","label":"Related","type":"reference_list","items":{"type":"string"},"required":false,"nullable":true,"mutable":true},{"key":"labels","label":"Labels","type":"array","items":{"type":"string"},"required":false,"nullable":true,"mutable":true},{"key":"metadata","label":"Metadata","type":"object","required":false,"nullable":true,"mutable":true}],"lifecycle":{"initial_state":"requested","states":[{"key":"requested","label":"Requested","state_category":"queued","state_outcome":""},{"key":"approved","label":"Approved","state_category":"terminal","state_outcome":"success"}],"terminal_states":["approved"],"transitions":{"requested":["approved"],"approved":[]},"guards":{"approved":{"required_fields":["findings"]}},"enforcement":"strict"}}

func _state(name: String) -> AppState:
	var path := "%s/%s.dct" % [DIR, name]
	var db := DocketDBJsonl.create_new_jsonl(path)
	assert(db != null, "failed to create JSONL fixture %s" % path)
	_dbs.append(db)
	return _state_over({name:db})

## A state over already open project databases; the first is the primary one.
func _state_over(dbs: Dictionary) -> AppState:
	var state := AppState.new()
	state.schema = TypeRegistryBootstrap.load_shipped_schema()
	state.prefs = UserPrefs.new()
	var primary := str(dbs.keys()[0])
	state.db = dbs[primary]
	state.dct_path = "%s/%s.dct" % [DIR, primary]
	for name: String in dbs:
		state._project_dbs[name] = dbs[name]
		state._type_registries[name] = TypeRegistry.for_db(dbs[name], name)
	return state

func _active_registry(state: AppState, project: String) -> TypeRegistry:
	var registry := state.get_type_registry(project)
	var definition := _definition()
	var made: Dictionary = registry.define_type("review", definition, "tester", "GUI behavior")
	if not made.has("error"):
		registry.activate_type("review", made.type.current_revision, "tester", "ready")
	return registry

func _set_dynamic_text(form: RecordForm, key: String, value: String) -> void:
	var row: Dictionary = form._dynamic_fields._rows[key]
	(row.mode as OptionButton).select((row.mode as OptionButton).get_item_index(0))
	if row.editor is TextEdit:
		(row.editor as TextEdit).text = value
	else:
		(row.editor as LineEdit).text = value

func test_dynamic_editor_preserves_value_modes_and_rejects_invalid_kinds() -> Variant:
	var editor := DynamicFieldEditor.new()
	add_child(editor)
	editor.load_definition(_definition(), {"fields":{"revision":"abc", "source":"origin", "approved":false, "attempts":3.0, "score":0.0, "labels":[], "metadata":{}, "unknown":{"keep":true}}}, true)
	var immutable_mode: OptionButton = editor._rows.source.mode
	var r = A.is_true(editor._rows.revision.editor is LineEdit and editor._rows.findings.editor is TextEdit and editor._rows.attempts.editor is LineEdit and editor._rows.score.editor is LineEdit and editor._rows.approved.editor is CheckBox and editor._rows.decision.editor is OptionButton and editor._rows.due_date.editor is LineEdit and editor._rows.reviewed_at.editor is LineEdit and editor._rows.subject.editor is LineEdit and editor._rows.related.editor is TextEdit and editor._rows.labels.editor is TextEdit and editor._rows.metadata.editor is TextEdit, "all supported descriptor kinds receive an ordinary typed or per-field JSON control")
	if r is String:
		return r
	var patch := editor.collect_patch()
	r = A.is_true(immutable_mode.disabled and patch.fields.approved == false and patch.fields.attempts == 3 and (editor._rows.attempts.editor as LineEdit).text == "3" and patch.fields.score == 0.0 and patch.fields.labels == [] and patch.fields.metadata == {}, "existing immutable fields are read-only while integral JSON numbers, false, zero, and empty containers remain valid explicit values")
	if r is String:
		return r
	r = A.is_true(not patch.fields.has("unknown") and editor._rows.unknown.unknown, "unknown stored fields remain visible and read-only")
	if r is String:
		return r
	(editor._rows.findings.mode as OptionButton).select((editor._rows.findings.mode as OptionButton).get_item_index(1))
	(editor._rows.revision.mode as OptionButton).select((editor._rows.revision.mode as OptionButton).get_item_index(2))
	patch = editor.collect_patch()
	r = A.is_true(patch.fields.has("findings") and patch.fields.findings == null and patch.unset_fields.has("revision"), "explicit null and unset are distinct modes")
	if r is String:
		return r
	(editor._rows.score.editor as LineEdit).text = "not-a-number"
	r = A.is_true(editor.collect_patch().has("error"), "invalid numeric control content reports a field error")
	if r is String:
		return r
	editor.load_definition(_definition(), {"fields":{"revision":"abc", "source":"origin", "attempts":3.5}}, true)
	r = A.is_true((editor._rows.attempts.editor as LineEdit).text == "3.5" and editor.collect_patch().has("error"), "fractional stored values remain visible and invalid for integer descriptors")
	if r is String:
		return r
	editor.load_definition(_definition(), {"fields":{"revision":"abc", "source":"origin", "attempts":3.000001}}, true)
	r = A.is_true((editor._rows.attempts.editor as LineEdit).text == "3.000001" and editor.collect_patch().has("error"), "near-integer fractional values are not rounded into valid integer edits")
	if r is String:
		return r
	editor.load_definition(_definition(), {})
	return A.is_false((editor._rows.source.mode as OptionButton).disabled, "required immutable fields remain editable during creation")

func test_form_commits_unsaved_fields_with_transition_and_refuses_partial_guard_failure() -> Variant:
	var state := _state("form")
	var registry := _active_registry(state, "form")
	var created := registry.create_item({"type":"review", "title":"Review", "revision":"abc", "source":"origin"}, "tester")
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_item(str(created.id), "form")
	_set_dynamic_text(form, "findings", "Looks good")
	form._select_status_by_name("approved")
	await form._save_changes()
	var stored := state.db.get_item(str(created.id))
	var r = A.is_true(stored.status == "approved" and stored.fields.findings == "Looks good", "transition and unsaved descriptor fields commit through one shared operation")
	if r is String:
		return r
	var second := registry.create_item({"type":"review", "title":"Second", "revision":"abc", "source":"origin"}, "tester")
	form.load_item(str(second.id), "form")
	(form._dynamic_fields._rows.revision.mode as OptionButton).select((form._dynamic_fields._rows.revision.mode as OptionButton).get_item_index(2))
	form._select_status_by_name("approved")
	await form._save_changes()
	stored = state.db.get_item(str(second.id))
	return A.is_true(stored.status == "requested" and stored.fields.revision == "abc", "failed complete-candidate validation leaves fields and status unchanged")

func test_record_form_creation_keeps_required_immutable_field_editable_and_saves_it() -> Variant:
	var state := _state("form")
	_active_registry(state, "form")
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_draft("review", {"type":"review", "status":"requested", "title":"", "fields":{}}, "form")
	var source_row: Dictionary = form._dynamic_fields._rows.source
	var r = A.is_false((source_row.mode as OptionButton).disabled, "actual RecordForm draft keeps required immutable fields editable during creation")
	if r is String:
		return r
	(source_row.mode as OptionButton).select((source_row.mode as OptionButton).get_item_index(0))
	(source_row.editor as LineEdit).text = "origin"
	var revision_row: Dictionary = form._dynamic_fields._rows.revision
	(revision_row.mode as OptionButton).select((revision_row.mode as OptionButton).get_item_index(0))
	(revision_row.editor as LineEdit).text = "abc"
	form._title_edit.text = "Created review"
	await form._save_changes()
	var stored := state.db.get_item(form._current_id)
	return A.is_true(not stored.is_empty() and stored.fields.source == "origin", "creation persists a required immutable field before existing-item controls become read-only")

func test_record_form_values_and_unknown_fields_survive_canonical_reopen() -> Variant:
	var state := _state("form")
	var registry := state.get_type_registry("form")
	var definition := _definition()
	definition.fields.append({"key":"resolution", "label":"Custom resolution", "type":"string", "required":false, "nullable":true, "mutable":true})
	var made := registry.define_type("review", definition, "tester", "durable controls")
	if made.has("error"):
		return str(made.error)
	var activate_error := registry.activate_type("review", made.type.current_revision, "tester", "ready")
	if not activate_error.is_empty():
		return activate_error
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_draft("review", {"type":"review", "status":"requested", "title":"", "fields":{}}, "form")
	form._title_edit.text = "Durable values"
	_set_dynamic_text(form, "revision", "abc")
	_set_dynamic_text(form, "source", "immutable-origin")
	_set_dynamic_text(form, "attempts", "3")
	_set_dynamic_text(form, "labels", "[\"one\",\"two\"]")
	_set_dynamic_text(form, "metadata", "{\"depth\":2}")
	_set_dynamic_text(form, "related", "[]")
	_set_dynamic_text(form, "resolution", "custom-value")
	var findings_row: Dictionary = form._dynamic_fields._rows.findings
	(findings_row.mode as OptionButton).select((findings_row.mode as OptionButton).get_item_index(1))
	var approved_row: Dictionary = form._dynamic_fields._rows.approved
	(approved_row.mode as OptionButton).select((approved_row.mode as OptionButton).get_item_index(0))
	(approved_row.editor as CheckBox).button_pressed = false
	var create_error = await form._save_changes()
	if not create_error is String:
		return "creation save returned no explicit result"
	if not str(create_error).is_empty():
		return create_error
	var id := form._current_id
	var created := state.db.get_item(id)
	var fields: Dictionary = created.fields.duplicate(true)
	fields["opaque_future"] = {"keep":true}
	var storage_error := state.db.update_item_fields_checked(id, {"fields":fields})
	if not storage_error.is_empty():
		return storage_error
	form.load_item(id, "form")
	form._title_edit.text = "Updated without loss"
	var update_error = await form._save_changes()
	if not update_error is String:
		return "unrelated update save returned no explicit result"
	if not str(update_error).is_empty():
		return update_error
	var path := state.dct_path
	state.db.close()
	JSONLCache.delete_cache_family(path)
	var reopened := DocketDBJsonl.open_jsonl(path)
	if reopened == null:
		return "failed to reopen durable form fixture"
	_dbs.append(reopened)
	var stored := reopened.get_item(id)
	var r = A.is_true(stored.title == "Updated without loss" and stored.fields.revision == "abc" and stored.fields.source == "immutable-origin", "reopen preserves universal edits plus mutable and immutable creation strings: %s" % JSON.stringify(stored))
	if r is String:
		return r
	r = A.is_true(int(stored.fields.attempts) == 3 and stored.fields.labels == ["one", "two"] and stored.fields.related == [], "reopen preserves integer, array, and reference-list controls: %s" % JSON.stringify(stored.fields))
	if r is String:
		return r
	var metadata: Dictionary = stored.fields.get("metadata", {})
	r = A.is_true(int(metadata.get("depth", -1)) == 2, "reopen preserves object JSON with numeric value semantics: %s" % JSON.stringify(metadata))
	if r is String:
		return r
	r = A.is_true(stored.fields.has("findings") and stored.fields.findings == null and stored.fields.has("approved") and stored.fields.approved == false and not stored.fields.has("score"), "reopen distinguishes explicit null and false from unset: %s" % JSON.stringify(stored.fields))
	if r is String:
		return r
	r = A.is_true(stored.fields.get("opaque_future") == {"keep":true}, "form update preserves unknown opaque fields: %s" % JSON.stringify(stored.fields.get("opaque_future")))
	if r is String:
		return r
	r = A.eq(stored.fields.get("resolution"), "custom-value", "custom collision value remains under fields after reopen")
	if r is String:
		return r
	var flat_resolution: Variant = stored.get("resolution", null)
	var flat_unused: bool = flat_resolution == null or (flat_resolution is String and (flat_resolution as String).is_empty())
	return A.is_true(flat_unused and flat_resolution != "custom-value", "unused legacy flat resolution stays absent/null/empty and never receives the custom value; actual=%s" % str(flat_resolution))

func test_duplicate_ids_route_form_and_comments_to_explicit_project() -> Variant:
	var alpha := _state("alpha")
	var beta_path := "%s/beta.dct" % DIR
	var beta_db := DocketDBJsonl.create_new_jsonl(beta_path)
	_dbs.append(beta_db)
	alpha._project_dbs.beta = beta_db
	alpha._type_registries.beta = TypeRegistry.for_db(beta_db, "beta")
	var alpha_registry := _active_registry(alpha, "alpha")
	var beta_registry := _active_registry(alpha, "beta")
	var a := alpha_registry.create_item({"type":"review", "title":"Alpha", "revision":"a", "source":"origin"}, "tester")
	var b := beta_registry.create_item({"type":"review", "title":"Beta", "revision":"b", "source":"origin"}, "tester")
	var duplicate_id := str(a.id)
	var beta_item := beta_db.export_item_full(str(b.id))
	beta_db.delete_item(str(b.id))
	beta_db.import_item_full(duplicate_id, beta_item)
	var form := RecordForm.new()
	add_child(form)
	form.init(alpha)
	form.load_item(duplicate_id, "beta")
	form._title_edit.text = "Beta edited"
	await form._save_changes()
	var r = A.is_true(alpha.db.get_item(duplicate_id).title == "Alpha" and beta_db.get_item(duplicate_id).title == "Beta edited", "duplicate IDs save only to the explicit origin project")
	if r is String:
		return r
	form._comment_input.text = "Beta comment"
	form._on_add_comment()
	r = A.is_true(alpha.db.list_comments(duplicate_id).is_empty() and beta_db.list_comments(duplicate_id).size() == 1, "comment service routing retains the explicit project origin")
	if r is String:
		return r
	var attached := form.attach_to_current("proof.txt", "beta".to_utf8_buffer(), "text/plain")
	return A.is_true(not attached.has("error") and alpha.db.list_attachments(duplicate_id).is_empty() and beta_db.list_attachments(duplicate_id).size() == 1, "attachment service routing retains the explicit project origin")

func test_duplicate_id_activation_and_back_navigation_retain_project_origin() -> Variant:
	var state := _state("alpha")
	var beta_path := "%s/beta.dct" % DIR
	var beta_db := DocketDBJsonl.create_new_jsonl(beta_path)
	_dbs.append(beta_db)
	state._project_dbs.beta = beta_db
	state._type_registries.beta = TypeRegistry.for_db(beta_db, "beta")
	var alpha_registry := _active_registry(state, "alpha")
	var beta_registry := _active_registry(state, "beta")
	var alpha_item := alpha_registry.create_item({"type":"review", "title":"Alpha", "revision":"a", "source":"origin"}, "tester")
	var beta_item := beta_registry.create_item({"type":"review", "title":"Beta", "revision":"b", "source":"origin"}, "tester")
	var duplicate_id := str(alpha_item.id)
	var beta_export := beta_db.export_item_full(str(beta_item.id))
	beta_db.delete_item(str(beta_item.id))
	beta_db.import_item_full(duplicate_id, beta_export)
	var shell := AppShell.new()
	shell.init(state)
	add_child(shell)
	shell._on_item_activated(duplicate_id, "alpha")
	shell._on_item_activated(duplicate_id, "beta")
	shell._on_back_pressed()
	var entry: Dictionary = shell._work_entries[shell._current_work_idx]
	return A.is_true(entry.item_id == duplicate_id and entry.project == "alpha" and shell._record_form._current_project == "alpha" and shell._record_form._title_edit.text == "Alpha", "activation and Back distinguish duplicate item IDs by their project origin")

func test_context_copy_extracts_id_from_selected_origin_metadata() -> Variant:
	var state := _state("fields")
	var grid := QueryGrid.new()
	add_child(grid)
	grid.init(state)
	grid._tree.clear()
	var root := grid._tree.create_item()
	var row := grid._tree.create_item(root)
	row.set_metadata(0, {"id":"DUPLICATE-ID", "project":"fields"})
	row.select(0)
	grid._on_context_menu_id_pressed(0)
	return A.eq(grid._last_context_copy_id, "DUPLICATE-ID", "Copy ID callback extracts the identifier from project-scoped selected-row metadata")

func test_children_use_qualified_origin_and_isolate_bare_refs_by_project() -> Variant:
	var state := _state("alpha")
	var alpha_registry := _active_registry(state, "alpha")
	var parent := alpha_registry.create_item({"type":"review", "title":"Parent", "revision":"p", "source":"origin"}, "tester")
	if parent.has("error"):
		return str(parent.error)
	var parent_id := str(parent.id)
	var alpha_child := alpha_registry.create_item({"type":"review", "title":"Alpha qualified", "revision":"a", "source":"origin", "parent":"alpha:%s" % parent_id}, "tester")
	if alpha_child.has("error"):
		return str(alpha_child.error)
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_item(parent_id, "alpha")
	var r = A.eq(form._children_list.item_count, 1, "single-project form resolves one qualified child reference")
	if r is String:
		return r
	var single_origin: Dictionary = form._children_list.get_item_metadata(0)
	r = A.eq(single_origin.project, "alpha", "single-project child metadata retains its origin")
	if r is String:
		return r
	var beta_path := "%s/beta.dct" % DIR
	var beta_db := DocketDBJsonl.create_new_jsonl(beta_path)
	_dbs.append(beta_db)
	state._project_dbs.beta = beta_db
	state._type_registries.beta = TypeRegistry.for_db(beta_db, "beta")
	var beta_registry := _active_registry(state, "beta")
	var beta_qualified := beta_registry.create_item({"type":"review", "title":"Beta qualified", "revision":"bq", "source":"origin", "parent":"alpha:%s" % parent_id}, "tester")
	var beta_bare := beta_registry.create_item({"type":"review", "title":"Beta bare", "revision":"bb", "source":"origin", "parent":parent_id}, "tester")
	if beta_qualified.has("error") or beta_bare.has("error"):
		return "child fixture creation failed"
	form._populate_children()
	var origins: Dictionary = {}
	for i in form._children_list.item_count:
		var origin: Dictionary = form._children_list.get_item_metadata(i)
		origins["%s:%s" % [origin.project, origin.id]] = true
	var navigated: Dictionary = {}
	form.child_opened.connect(func(id: String, project: String):
		navigated["id"] = id
		navigated["project"] = project
	)
	form._on_child_activated(0)
	return A.is_true(form._children_list.item_count == 2 and origins.has("alpha:%s" % alpha_child.id) and origins.has("beta:%s" % beta_qualified.id) and not origins.has("beta:%s" % beta_bare.id) and not navigated.is_empty() and origins.has("%s:%s" % [navigated.project, navigated.id]), "multi-project qualified children resolve across projects while bare references stay in the parent owning project and navigation retains origin")

func test_draft_save_refuses_closed_origin_without_falling_back_or_losing_edits() -> Variant:
	var state := _state("alpha")
	var beta_path := "%s/beta.dct" % DIR
	var beta_db := DocketDBJsonl.create_new_jsonl(beta_path)
	_dbs.append(beta_db)
	state._project_dbs.beta = beta_db
	state._type_registries.beta = TypeRegistry.for_db(beta_db, "beta")
	_active_registry(state, "alpha")
	_active_registry(state, "beta")
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_draft("review", {"type":"review", "status":"requested", "title":"", "fields":{}}, "beta")
	form._title_edit.text = "Retained draft"
	_set_dynamic_text(form, "revision", "abc")
	_set_dynamic_text(form, "source", "origin")
	state._project_dbs.erase("beta")
	state._type_registries.erase("beta")
	var save_error = await form._save_changes()
	return A.is_true(save_error is String and str(save_error).contains("originating project is closed") and state.db.execute_query({}, "lean").is_empty() and form._title_edit.text == "Retained draft" and form._is_draft, "closed draft origin refuses save without fallback writes and retains local edits")

func test_result_columns_render_by_pinned_type_declaration() -> Variant:
	var state := _state("fields")
	var registry := _active_registry(state, "fields")
	var created := registry.create_item({"type":"review", "title":"Columns", "revision":"abc", "source":"origin", "findings":"visible"}, "tester")
	var item := state.db.get_item(str(created.id))
	item.project = "fields"
	var grid := QueryGrid.new()
	add_child(grid)
	grid.init(state)
	var r = A.eq(grid._render_typed_column(item, "findings"), "visible", "a custom field renders from the fields envelope under the pinned descriptor")
	if r is String:
		return r
	var builtin := registry.get_type("bug")
	var builtin_item := {"type":"bug", "type_id":builtin.id, "type_revision":builtin.current_revision, "status":"new", "resolution":"fixed", "findings":"stray", "fields":{"findings":"stray"}, "project":"fields"}
	r = A.eq(grid._render_typed_column(builtin_item, "findings"), "", "a field the row's pinned type does not declare renders blank, whatever the row holds")
	if r is String:
		return r
	return A.eq(grid._render_typed_column(builtin_item, "resolution"), "fixed", "builtin descriptor columns use their flat storage authority")

## Two custom types declare "findings" (so does the builtin question): one
## column shows it for both, and sorting on it orders both types' rows.
func test_colliding_field_keys_share_one_column() -> Variant:
	var state := _state("fields")
	var registry := _active_registry(state, "fields")
	var second_definition := _definition()
	second_definition.slug = "audit"
	second_definition.label = "Audit"
	var second := registry.define_type("audit", second_definition, "tester", "collision")
	registry.activate_type("audit", second.type.current_revision, "tester", "ready")
	registry.create_item({"type":"review", "title":"review", "revision":"abc", "source":"origin", "findings":"b"}, "tester")
	registry.create_item({"type":"audit", "title":"audit", "revision":"abc", "source":"origin", "findings":"a"}, "tester")
	registry.create_item({"type":"bug", "title":"bug"}, "tester")
	var grid := _chooser_grid(state)
	var label := _chooser_label(grid, "findings")
	var r = A.is_true(grid._column_candidates.count("findings") == 1 and label.begins_with("Findings — ") and ["review", "audit", "question"].all(func(slug: String) -> bool: return label.contains(slug)), "the chooser offers findings once, naming every type that declares it: %s" % label)
	if r is String:
		return r
	grid._toggle_result_column(grid._column_candidates.find("findings"))
	var title_column := grid._col_fields.find("title")
	var findings_column := grid._col_fields.find("findings")
	r = A.is_true(grid._dcq_columns.has("id") and grid._dcq_columns.has("status") and grid._dcq_columns.has("title") and _column_cells(grid, title_column, findings_column) == {"fields/review":"b", "fields/audit":"a"}, "the first tick keeps the displayed defaults and one column shows both types' findings")
	if r is String:
		return r
	grid._toggle_sort(findings_column)
	return A.is_true(_row_order(grid, title_column) == ["fields/audit", "fields/review", "fields/bug"] and grid._sort_spec() == {"field_key":"findings", "dir":"asc", "nulls":"last"}, "sorting the shared column orders both types' rows by the field, the bug last")

## review stores "score" as a number, audit as a string; the shared column
## sorts numbers first, numerically, then text, whatever order the rows come in.
func test_shared_field_holding_numbers_and_text_sorts_consistently() -> Variant:
	var state := _state("fields")
	var registry := _active_registry(state, "fields")
	var audit := _definition()
	audit.slug = "audit"
	audit.label = "Audit"
	for descriptor: Dictionary in audit.fields:
		if descriptor.key == "score":
			descriptor.type = "string"
	registry.activate_type("audit", registry.define_type("audit", audit, "tester", "text score").type.current_revision, "tester", "ready")
	for made: Dictionary in [
		registry.create_item({"type":"review", "title":"30", "revision":"a", "source":"o", "score":30}, "tester"),
		registry.create_item({"type":"audit", "title":"text b", "revision":"a", "source":"o", "score":"b"}, "tester"),
		registry.create_item({"type":"review", "title":"2", "revision":"a", "source":"o", "score":2}, "tester"),
		registry.create_item({"type":"audit", "title":"text 10", "revision":"a", "source":"o", "score":"10"}, "tester"),
	]:
		if made.has("error"):
			return "fixture: %s" % made.error
	var grid := QueryGrid.new()
	add_child(grid)
	grid.init(state)
	grid.set_result_columns(["title", "score"])
	var ascending := ["fields/2", "fields/30", "fields/text 10", "fields/text b"]
	grid._toggle_sort(1)
	var r = A.eq(_row_order(grid, 0), ascending, "ascending: numbers by value, then text")
	if r is String:
		return r
	var forward: Array = grid._current_results.duplicate()
	var backward: Array = forward.duplicate()
	backward.reverse()
	var titles := func(rows: Array) -> Array: return rows.map(func(item: Dictionary) -> String: return "fields/%s" % item.title)
	var registries := {"fields": registry}
	r = A.eq([titles.call(state._sorted_query_rows(forward, [grid._sort_spec()], registries)), titles.call(state._sorted_query_rows(backward, [grid._sort_spec()], registries))], [ascending, ascending], "the same rows in either input order sort the same")
	if r is String:
		return r
	grid._toggle_sort(1)
	var descending := ascending.duplicate()
	descending.reverse()
	return A.eq(_row_order(grid, 0), descending, "descending reverses that order exactly")

func test_column_menu_uses_query_branch_scope() -> Variant:
	var state := _state("alpha")
	var beta_db := DocketDBJsonl.create_new_jsonl("%s/beta.dct" % DIR)
	_dbs.append(beta_db)
	state._project_dbs.beta = beta_db
	state._type_registries.beta = TypeRegistry.for_db(beta_db, "beta")
	_active_registry(state, "alpha")
	_active_registry(state, "beta")
	var grid := QueryGrid.new()
	add_child(grid)
	grid.init(state)
	grid._rebuild_type_catalog()
	grid.set_filter(JSON.stringify({"conditions":[{"field":"project", "op":"eq", "value":"alpha"}, {"field":"type", "op":"eq", "value":"review", "conj":"and"}]}))
	_open_chooser(grid)
	var r = A.eq(_sorted(_type_section(grid)), _declared_fields(state, "alpha", "review"), "a known type scope limits the type fields to that type's")
	if r is String:
		return r
	r = A.eq(grid._column_candidates.slice(0, ColumnBinding.item_entries().size()), ColumnBinding.ITEM_COLUMNS + RegistryQuery.DERIVED_FIELDS, "the columns every row has are offered whatever the scope")
	if r is String:
		return r
	grid._toggle_result_column(grid._column_candidates.find("revision"))
	grid.set_filter(JSON.stringify({"conditions":[{"field":"type", "op":"eq", "value":"bug"}]}))
	_open_chooser(grid)
	var revision_id := grid._column_candidates.find("revision")
	r = A.is_true(revision_id >= 0 and grid._columns_menu.is_item_checked(grid._columns_menu.get_item_index(revision_id)), "a shown type column stays offered, ticked, when the query scope no longer reaches it")
	if r is String:
		return r
	grid.set_filter(JSON.stringify({"conditions":[{"field":"project", "op":"eq", "value":"alpha"}, {"field":"type", "op":"eq", "value":"review", "conj":"and"}, {"field":"title", "op":"contains", "value":"open branch", "conj":"or"}]}))
	_open_chooser(grid)
	var fields := _type_section(grid)
	return A.is_true(fields.has("revision") and fields.has("repro_steps") and fields.has("component"), "an unconstrained OR branch expands the type fields to every possible type")

## The shipped types, in one project and in two: the columns every row has,
## then each type-declared field once.
func test_column_chooser_offers_each_field_once() -> Variant:
	var dbs: Dictionary = {}
	for name: String in ["alpha", "beta"]:
		var db := DocketDBJsonl.create_new_jsonl("%s/%s.dct" % [DIR, name])
		_dbs.append(db)
		dbs[name] = db
	var state := _state_over(dbs)
	var grid := _chooser_grid(state)
	var r = _unique_candidates(grid)
	if r is String:
		return r
	var keys := grid._column_candidates
	r = A.is_true(keys.count("created_by") == 1 and keys.count("created_at") == 1 and keys.count("component") == 1 and RegistryQuery.DERIVED_FIELDS.all(func(key: String) -> bool: return keys.count(key) == 1), "created_by, created_at, component and each derived column are offered once")
	if r is String:
		return r
	r = A.is_true(_chooser_label(grid, "component").begins_with("Component — hint"), "a type field is labelled with the types that declare it: %s" % _chooser_label(grid, "component"))
	if r is String:
		return r
	for name: String in dbs:
		r = A.eq(_chooser_entries(_chooser_grid(_state_over({name: dbs[name]}))), _chooser_entries(grid), "two projects offer the same chooser entries as %s alone" % name)
		if r is String:
			return r
	grid.set_filter(JSON.stringify({"conditions":[{"field":"type", "op":"eq", "value":"bug"}]}))
	_open_chooser(grid)
	var bug_fields := _declared_fields(state, "alpha", "bug")
	r = A.is_true(not bug_fields.is_empty() and _sorted(_type_section(grid)) == bug_fields, "with type = bug the type fields are bug's: %s" % [_type_section(grid)])
	if r is String:
		return r
	# A shown derived column is no type's field; it stays in the first section only.
	grid._toggle_result_column(grid._column_candidates.find("state_category"))
	_open_chooser(grid)
	r = _unique_candidates(grid)
	if r is String:
		return r
	return A.is_true(grid._column_candidates.count("state_category") == 1 and not _type_section(grid).has("state_category"), "a shown state_category is offered once, among the columns every row has")

## alpha: a hint, a kb and a test carrying component, a bug and a review
## (revision "r2", "r1"); beta: a test carrying component and a bug. Every
## builtin row names its creator; the review's creator is the actor.
func test_ticked_field_columns_fill_and_sort_in_one_project_and_two() -> Variant:
	var dbs: Dictionary = {}
	for name: String in ["alpha", "beta"]:
		var db := DocketDBJsonl.create_new_jsonl("%s/%s.dct" % [DIR, name])
		_dbs.append(db)
		dbs[name] = db
	var state := _state_over(dbs)
	var alpha := _active_registry(state, "alpha")
	var beta := state.get_type_registry("beta")
	alpha.create_item({"type":"hint", "title":"hint", "value":"v", "component":"c", "created_by":"ann"}, "tester")
	alpha.create_item({"type":"kb", "title":"kb", "component":"a", "created_by":"ann"}, "tester")
	alpha.create_item({"type":"bug", "title":"bug", "created_by":"bob"}, "tester")
	alpha.create_item({"type":"review", "title":"review 2", "revision":"r2", "source":"origin"}, "tester")
	alpha.create_item({"type":"review", "title":"review 1", "revision":"r1", "source":"origin"}, "tester")
	beta.create_item({"type":"test", "title":"test", "component":"b", "created_by":"cy"}, "tester")
	beta.create_item({"type":"bug", "title":"bug", "created_by":"dee"}, "tester")
	var grid := _chooser_grid(state)
	grid._toggle_result_column(grid._column_candidates.find("created_by"))
	var title_column := grid._col_fields.find("title")
	var r = A.eq(_column_cells(grid, title_column, grid._col_fields.find("created_by")), {"alpha/hint":"ann", "alpha/kb":"ann", "alpha/bug":"bob", "alpha/review 2":"tester", "alpha/review 1":"tester", "beta/test":"cy", "beta/bug":"dee"}, "Created by fills the rows of every type")
	if r is String:
		return r
	grid._toggle_result_column(grid._column_candidates.find("component"))
	var component_column := grid._col_fields.find("component")
	r = A.eq(_column_cells(grid, title_column, component_column), {"alpha/hint":"c", "alpha/kb":"a", "beta/test":"b"}, "Component fills the rows whose type declares it and leaves bug and review rows blank")
	if r is String:
		return r
	grid._toggle_result_column(grid._column_candidates.find("created_at"))
	r = A.eq(_column_cells(grid, title_column, grid._col_fields.find("created_at")).size(), 7, "created_at shows a value on every row")
	if r is String:
		return r
	var lacking := ["alpha/bug", "alpha/review 1", "alpha/review 2", "beta/bug"]
	grid._toggle_sort(component_column)
	var order := _row_order(grid, title_column)
	r = A.is_true(state.last_cross_project_query_error.is_empty() and order.slice(0, 3) == ["alpha/kb", "beta/test", "alpha/hint"] and _sorted(order.slice(3)) == lacking, "two projects: sorting on Component orders every project's rows by it, rows lacking it last: %s" % [order])
	if r is String:
		return r
	grid._toggle_sort(component_column)
	order = _row_order(grid, title_column)
	r = A.is_true(order.slice(0, 3) == ["alpha/hint", "beta/test", "alpha/kb"] and _sorted(order.slice(3)) == lacking, "a descending sort reverses the rows carrying the field and keeps the rest last: %s" % [order])
	if r is String:
		return r
	var one := QueryGrid.new()
	add_child(one)
	one.init(_state_over({"alpha": dbs.alpha}))
	one.set_result_columns(["id", "title", "component", "revision", "project"])
	var all_alpha := {"alpha/hint":"alpha", "alpha/kb":"alpha", "alpha/bug":"alpha", "alpha/review 2":"alpha", "alpha/review 1":"alpha"}
	r = A.eq(_column_cells(one, 1, 4), all_alpha, "one project, unsorted: the Project column names the project on every row")
	if r is String:
		return r
	# A type field sorts on the cross-project path, which tags each row with its
	# project; an items-table column sorts in SQL, whose rows carry no project.
	for field: String in ["component", "revision", "title"]:
		one._toggle_sort(one._col_fields.find(field))
		r = A.is_true(one._current_results.size() == 5 and one._tree.get_root() != null, "one project: sorting on %s runs: %s" % [field, one._count_label.text])
		if r is String:
			return r
		var routed := field != "title"
		r = A.eq(one._current_results.all(func(item: Dictionary) -> bool: return item.has("project")), routed, "one project: %s sorts %s" % [field, "on the cross-project path" if routed else "in SQL"])
		if r is String:
			return r
		var expected: Array = {"component": ["alpha/kb", "alpha/hint"], "revision": ["alpha/review 1", "alpha/review 2"], "title": ["alpha/bug", "alpha/hint"]}[field]
		r = A.eq(_row_order(one, 1).slice(0, 2), expected, "one project: sorting on %s orders the rows by it, those carrying it first" % field)
		if r is String:
			return r
		r = A.eq(_column_cells(one, 1, 4), all_alpha, "one project, sorted on %s: the Project column names the project on every row" % field)
		if r is String:
			return r
	return true

## Two projects each hold a review of the first "review" revision; beta then
## evolves review with "notes" and adds a review of the new revision, and alpha
## holds an audit that shares "findings". Last, beta gains a row pinned to the
## first revision whose fields envelope holds a stray "notes".
func test_saved_type_bindings_open_as_their_field_key() -> Variant:
	var dbs: Dictionary = {}
	for name: String in ["alpha", "beta"]:
		var db := DocketDBJsonl.create_new_jsonl("%s/%s.dct" % [DIR, name])
		_dbs.append(db)
		dbs[name] = db
	var state := _state_over(dbs)
	for name: String in dbs:
		_active_registry(state, name).create_item({"type":"review", "title":"old", "revision":"abc", "source":"origin", "findings":"%s old" % name}, "tester")
	var beta := state.get_type_registry("beta")
	var first_revision := str(beta.get_type("review").current_revision)
	var evolved := _definition()
	(evolved.fields as Array).append({"key":"notes", "label":"Notes", "type":"string", "required":false, "nullable":true, "mutable":true})
	var evolve_error := beta.apply_evolution(beta.preview_evolution("review", evolved, str(beta.get_type("review").current_revision)), "tester", "add notes")
	if not evolve_error.is_empty():
		return evolve_error
	beta.create_item({"type":"review", "title":"new", "revision":"def", "source":"origin", "findings":"beta new", "notes":"beta notes"}, "tester")
	var alpha := state.get_type_registry("alpha")
	var audit := _definition()
	audit.slug = "audit"
	audit.label = "Audit"
	alpha.activate_type("audit", alpha.define_type("audit", audit, "tester", "same field key").type.current_revision, "tester", "ready")
	alpha.create_item({"type":"audit", "title":"audit", "revision":"ghi", "source":"origin", "findings":"alpha zzz"}, "tester")
	alpha.create_item({"type":"bug", "title":"bug"}, "tester")
	var findings := {"alpha/old":"alpha old", "beta/old":"beta old", "beta/new":"beta new", "alpha/audit":"alpha zzz"}
	var grid := _chooser_grid(state)
	var r = A.is_true(grid._column_candidates.count("notes") == 1 and _chooser_label(grid, "notes") == "Notes — review", "a field one project's type revision adds is offered once")
	if r is String:
		return r
	var saved := {
		"project_bound": {"project":"beta", "type_id":str(beta.get_type("review").id), "field_key":"findings", "label":"Beta findings", "kind":"markdown"},
		"type_bound": {"type":"review", "field_key":"findings", "label":"Review — Findings", "kind":"markdown"},
	}
	for form: String in saved:
		var path := "%s/%s.dcq" % [DIR, form]
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify({"columns":["id", "project", "title", saved[form]], "sort":[(saved[form] as Dictionary).merged({"dir":"desc"})]}))
		file.close()
		grid.apply_dcq(QueryGrid.read_dcq(path))
		grid._run_query()
		r = A.is_true(grid._col_fields == ["id", "project", "title", "findings"] and _column_cells(grid, 2, 3) == findings, "a %s binding opens as the findings column for every project's rows whose type has it" % form)
		if r is String:
			return r
		r = A.is_true(state.last_cross_project_query_error.is_empty() and _row_order(grid, 2) == ["beta/old", "beta/new", "alpha/audit", "alpha/old", "alpha/bug"], "a %s sort opens as a descending findings sort across types: %s" % [form, _row_order(grid, 2)])
		if r is String:
			return r
	var path := "%s/resaved.dcq" % DIR
	grid.save_dcq(path)
	r = A.eq(QueryGrid.read_dcq(path).get("columns"), ["id", "project", "title", "findings"], "a reopened binding saves as its field key")
	if r is String:
		return r
	var review := beta.get_type("review")
	var now := Time.get_datetime_string_from_system(true)
	var stray_error: String = dbs.beta.insert_item(dbs.beta.next_uuid7_id(), {"type":"review", "type_id":str(review.id), "type_revision":first_revision, "status":"requested", "title":"stray", "created_at":now, "updated_at":now, "fields":{"revision":"x", "source":"origin", "notes":"stray notes"}})
	if not stray_error.is_empty():
		return stray_error
	grid.set_result_columns(["title", "notes"])
	grid._run_query()
	return A.eq(_column_cells(grid, 0, 1), {"beta/new":"beta notes"}, "notes shows only on the row pinned to the revision that declares it, not on rows of the first revision, even one holding a value")

func _open_chooser(grid: QueryGrid) -> void:
	var anchor := Button.new()
	grid.add_child(anchor)
	grid._show_columns_menu(anchor)

## A grid over `state` whose Columns chooser has been opened once.
func _chooser_grid(state: AppState) -> QueryGrid:
	var grid := QueryGrid.new()
	add_child(grid)
	grid.init(state)
	_open_chooser(grid)
	return grid

## The menu text of the chooser entry for `field_key`, or "".
func _chooser_label(grid: QueryGrid, field_key: String) -> String:
	var id := grid._column_candidates.find(field_key)
	return grid._columns_menu.get_item_text(grid._columns_menu.get_item_index(id)) if id >= 0 else ""

## "field key | menu text" of each chooser entry, in menu order.
func _chooser_entries(grid: QueryGrid) -> Array:
	var entries: Array = []
	for field_key: String in grid._column_candidates:
		entries.append("%s | %s" % [field_key, _chooser_label(grid, field_key)])
	return entries

## The field keys of the chooser's second section.
func _type_section(grid: QueryGrid) -> Array:
	return Array(grid._column_candidates.slice(ColumnBinding.item_entries().size()))

## The sorted keys `slug` declares in `project` that are read through the type.
func _declared_fields(state: AppState, project: String, slug: String) -> Array:
	var keys: Array = []
	for descriptor: Dictionary in state.get_type_registry(project).get_type(slug).definition.fields:
		if ColumnBinding.is_typed(str(descriptor.key)):
			keys.append(str(descriptor.key))
	return _sorted(keys)

func _sorted(values: Array) -> Array:
	var copy := values.duplicate()
	copy.sort()
	return copy

## A failure naming the first chooser entry offered twice, or null.
func _unique_candidates(grid: QueryGrid) -> Variant:
	var seen: Dictionary = {}
	for field_key: String in grid._column_candidates:
		if seen.has(field_key):
			return "duplicate chooser entry: %s" % field_key
		seen[field_key] = true
	return null

## "project/title" of the shown rows, in grid order.
func _row_order(grid: QueryGrid, title_column: int) -> Array:
	var order: Array = []
	for row: TreeItem in grid._tree.get_root().get_children():
		var origin: Dictionary = row.get_metadata(0)
		order.append("%s/%s" % [origin.project, row.get_text(title_column)])
	return order

## "project/title" -> text of `column`, for the rows where that text is not empty.
func _column_cells(grid: QueryGrid, title_column: int, column: int) -> Dictionary:
	var cells: Dictionary = {}
	for row: TreeItem in grid._tree.get_root().get_children():
		var origin: Dictionary = row.get_metadata(0)
		if not row.get_text(column).is_empty():
			cells["%s/%s" % [origin.project, row.get_text(title_column)]] = row.get_text(column)
	return cells

func test_dcq_string_columns_round_trip_in_explicit_order() -> Variant:
	var state := _state("fields")
	var grid := QueryGrid.new()
	add_child(grid)
	grid.init(state)
	grid.set_result_columns(["title", "status"])
	var path := "%s/ordered.dcq" % DIR
	grid.save_dcq(path)
	var restored := QueryGrid.new()
	add_child(restored)
	restored.init(state)
	restored.load_dcq(path)
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	var r = A.is_true(parsed is Dictionary and parsed.columns == ["title", "status"], "saved DCQ retains explicit universal column order")
	if r is String:
		return r
	return A.is_true(restored._col_fields == ["title", "status"] and restored._col_titles == ["Title", "Status"], "loading an explicit string-column DCQ rebuilds the rendered order without default columns")

func test_searchable_creation_catalog_includes_active_zero_count_custom_type() -> Variant:
	var state := _state("fields")
	_active_registry(state, "fields")
	var shell := AppShell.new()
	shell.init(state)
	add_child(shell)
	shell._show_new_item_dialog()
	var r = A.is_true(shell._new_item_list.item_count > 0, "searchable creation catalog includes active registry types with zero items")
	if r is String:
		return r
	shell._new_item_search.text = "approval is required"
	shell._filter_new_item_catalog()
	var selection: Dictionary = shell._new_item_list.get_item_metadata(0)
	return A.is_true(shell._new_item_list.item_count == 1 and selection.slug == "review" and selection.project == "fields" and not str(selection.type_id).is_empty(), "creation search matches registry guidance and retains stable project and type identity")

func test_creation_chooser_opens_ordinary_builtin_and_custom_drafts() -> Variant:
	var state := _state("fields")
	_active_registry(state, "fields")
	var shell := AppShell.new()
	shell.init(state)
	add_child(shell)
	shell._show_new_item_dialog()
	shell._new_item_search.text = "bug"
	shell._filter_new_item_catalog()
	var builtin: Dictionary = shell._new_item_list.get_item_metadata(0)
	shell._create_and_edit_item(str(builtin.slug), str(builtin.project), false, str(builtin.type_id))
	var r = A.is_true(shell._record_form._is_draft and shell._record_form._get_type_name(shell._record_form._type_option.selected) == "bug", "chooser opens an ordinary shipped builtin through its regular creation policy")
	if r is String:
		return r
	shell._new_item_search.text = "approval is required"
	shell._filter_new_item_catalog()
	var custom: Dictionary = shell._new_item_list.get_item_metadata(0)
	shell._create_and_edit_item(str(custom.slug), str(custom.project), false, str(custom.type_id))
	return A.is_true(shell._record_form._is_draft and shell._record_form._get_type_name(shell._record_form._type_option.selected) == "review", "chooser opens an active custom type through its stable registry identity")

func test_ordinary_builtin_draft_saves_without_creating_or_unlocking_a_vault() -> Variant:
	var state := _state("fields")
	var previous_password := UserPrefs.load_vault_password()
	UserPrefs.clear_vault_password()
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_draft("bug", {"type":"bug", "status":"new", "title":"", "fields":{}}, "fields")
	form._title_edit.text = "Ordinary bug"
	var save_error = await form._save_changes()
	UserPrefs.save_vault_password(previous_password)
	if save_error is String and not str(save_error).is_empty():
		return save_error
	var stored := state.db.get_item(form._current_id)
	return A.is_true(stored.type == "bug" and stored.title == "Ordinary bug" and state.db.get_vault_salt().is_empty() and state.db.list_secrets().is_empty(), "ordinary builtin save follows registry creation without requiring credentials or initializing protected payload storage")

func test_secret_draft_binds_value_and_notes_handles_to_created_item() -> Variant:
	var state := _state("fields")
	var password := "fixture-secret-create"
	var salt := VaultCrypto.generate_salt()
	state.db.init_vault(VaultCrypto.derive_key(password, salt), salt)
	var previous_password := UserPrefs.load_vault_password()
	UserPrefs.save_vault_password(password)
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_draft("secret", {"type":"secret", "status":"active", "title":"", "fields":{}}, "fields")
	form._title_edit.text = "Credential"
	form._secret_value_edit.text = "secret-value"
	form._encrypted_notes_edit.text = "secret-notes"
	var save_error = await form._save_changes()
	UserPrefs.save_vault_password(previous_password)
	if save_error is String and not str(save_error).is_empty():
		return save_error
	var id := form._current_id
	var owners: Dictionary = {}
	for entry_value in state.db.list_secrets():
		var entry: Dictionary = entry_value
		owners[str(entry.handle)] = str(entry.owner_item_id)
	return A.is_true(owners.get(id) == id and owners.get(id + ":notes") == id and not owners.has(":notes"), "secret creation binds both prepared payload handles and ownership to the generated item ID")

func test_protected_types_stay_out_of_ordinary_creation_and_keep_specialized_path() -> Variant:
	var state := _state("fields")
	var registry := state.get_type_registry("fields")
	var refused := registry.create_item({"type":"secret", "title":"Credential"}, "tester")
	var r = A.is_true(refused.has("error") and str(refused.error).contains("protected creation path"), "shared registry keeps protected types out of ordinary creation")
	if r is String:
		return r
	var shell := AppShell.new()
	shell.init(state)
	add_child(shell)
	shell._show_new_item_dialog()
	for type_value in shell._new_item_catalog:
		if str(type_value.slug) == "secret" or str(type_value.slug) == "encrypted_note":
			return "ordinary creation catalog exposed a protected type"
	var form := shell._record_form
	var specialized := form._create_protected_draft(state.db, "secret", {"title":"Credential", "fields":{}, "unset_fields":[]})
	return A.is_true(not specialized.has("error") and state.db.get_item(str(specialized.id)).type == "secret", "existing specialized protected-item path remains available")

func test_guided_note_cancel_keeps_pending_fields_unsaved() -> Variant:
	var state := _state("form")
	var registry := state.get_type_registry("form")
	var definition := _definition()
	definition.lifecycle.enforcement = "guided"
	definition.lifecycle.states.insert(1, {"key":"reviewing", "label":"Reviewing", "state_category":"active", "state_outcome":""})
	definition.lifecycle.transitions.reviewing = []
	var made := registry.define_type("review", definition, "tester", "guided")
	registry.activate_type("review", made.type.current_revision, "tester", "ready")
	var created := registry.create_item({"type":"review", "title":"Review", "revision":"abc", "source":"origin"}, "tester")
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_item(str(created.id), "form")
	_set_dynamic_text(form, "findings", "unsaved")
	var changes := form._collect_changes()
	form._prompt_transition_note("reviewing", changes)
	form._transition_note_dialog.canceled.emit()
	var stored := state.db.get_item(str(created.id))
	return A.is_true(stored.status == "requested" and not stored.fields.has("findings") and form._pending_changes.fields.findings == "unsaved", "canceling a guided note prompt does not partially save its pending fields")

func test_guided_note_confirmation_commits_original_pending_snapshot() -> Variant:
	var state := _state("form")
	var registry := state.get_type_registry("form")
	var definition := _definition()
	definition.lifecycle.enforcement = "guided"
	definition.lifecycle.states.insert(1, {"key":"reviewing", "label":"Reviewing", "state_category":"active", "state_outcome":""})
	definition.lifecycle.transitions.reviewing = []
	var made := registry.define_type("review", definition, "tester", "guided")
	registry.activate_type("review", made.type.current_revision, "tester", "ready")
	var created := registry.create_item({"type":"review", "title":"Review", "revision":"abc", "source":"origin"}, "tester")
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_item(str(created.id), "form")
	_set_dynamic_text(form, "findings", "pending findings")
	form._prompt_transition_note("reviewing", form._collect_changes())
	form._transition_note_edit.text = "needed an early review"
	await form._on_transition_note_confirmed()
	var stored := state.db.get_item(str(created.id))
	var transition_audit_found := false
	for event_value in state.db.get_events(str(created.id)):
		var event: Dictionary = event_value
		if str(event.get("event_type", "")) == "transition" and str(event.get("note", "")).contains("needed an early review"):
			transition_audit_found = true
	return A.is_true(stored.status == "reviewing" and stored.fields.findings == "pending findings" and transition_audit_found, "guided confirmation commits pending fields, status, and reason audit in one transition")

func test_guided_note_confirmation_refuses_change_while_dialog_is_open_without_losing_edits() -> Variant:
	var state := _state("form")
	var registry := state.get_type_registry("form")
	var definition := _definition()
	definition.lifecycle.enforcement = "guided"
	definition.lifecycle.states.insert(1, {"key":"reviewing", "label":"Reviewing", "state_category":"active", "state_outcome":""})
	definition.lifecycle.transitions.reviewing = []
	var made := registry.define_type("review", definition, "tester", "guided")
	registry.activate_type("review", made.type.current_revision, "tester", "ready")
	var created := registry.create_item({"type":"review", "title":"Review", "revision":"abc", "source":"origin"}, "tester")
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_item(str(created.id), "form")
	_set_dynamic_text(form, "findings", "pending findings")
	form._prompt_transition_note("reviewing", form._collect_changes())
	var external_error := registry.update_item(str(created.id), {"title":"External change"}, "other")
	if not external_error.is_empty():
		return external_error
	form._transition_note_edit.text = "now stale"
	await form._on_transition_note_confirmed()
	var stored := state.db.get_item(str(created.id))
	var editor_text := (form._dynamic_fields._rows.findings.editor as TextEdit).text
	return A.is_true(stored.title == "External change" and stored.status == "requested" and not stored.fields.has("findings") and editor_text == "pending findings", "guided confirmation rechecks the original content token and retains local controls after a stale refusal")

func test_checked_protected_payload_failure_rolls_back_metadata_and_ciphertext() -> Variant:
	var state := _state("fields")
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	var created := form._create_protected_draft(state.db, "secret", {"title":"Credential", "fields":{}, "unset_fields":[]})
	if created.has("error"):
		return str(created.error)
	var item_id := str(created.id)
	var salt := VaultCrypto.generate_salt()
	var fixture_password := "fixture-vault-password"
	var key := VaultCrypto.derive_key(fixture_password, salt)
	state.db.init_vault(key, salt)
	var encrypted: Dictionary = VaultCrypto.encrypt("canonical-secret", key)
	state.db.set_secret(item_id, encrypted.ciphertext, encrypted.iv, encrypted.mac, false, item_id)
	var previous_password := UserPrefs.load_vault_password()
	UserPrefs.save_vault_password(fixture_password)
	var before_item: Dictionary = state.db.export_item_full(item_id)
	var before_payload: Dictionary = state.db.get_secret_raw(item_id)
	form.load_item(item_id, "fields")
	form._title_edit.text = "Changed metadata"
	form._secret_value_edit.text = "changed-secret"
	form._secret_value_decrypted = "canonical-secret"
	var trigger_error := state.db._exec_checked("CREATE TRIGGER reject_secret_rotation BEFORE UPDATE ON docket_secrets BEGIN SELECT RAISE(ABORT, 'injected encrypted payload write failure'); END;")
	if not trigger_error.is_empty():
		return trigger_error
	var save_error = await form._save_changes()
	UserPrefs.save_vault_password(previous_password)
	var reopened := DocketDBJsonl.open_jsonl(state.dct_path)
	if reopened == null:
		return "failed to reopen protected payload fixture"
	_dbs.append(reopened)
	var after_item: Dictionary = reopened.export_item_full(item_id)
	var after_payload: Dictionary = reopened.get_secret_raw(item_id)
	var metadata_unchanged := before_item == after_item
	var payload_unchanged := before_payload == after_payload
	var surfaced := save_error is String and str(save_error).contains("injected encrypted payload write failure") and form._id_label.text.contains("injected encrypted payload write failure") and form._secret_vault_error_label.visible
	return A.is_true(metadata_unchanged and payload_unchanged and surfaced, "checked payload write failure rolls back staged metadata, audit, and ciphertext before canonical flush and surfaces the error")

func test_form_uses_backend_content_token_to_refuse_stale_save() -> Variant:
	var state := _state("form")
	var registry := _active_registry(state, "form")
	var created := registry.create_item({"type":"review", "title":"Original", "revision":"abc", "source":"origin"}, "tester")
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_item(str(created.id), "form")
	var external_error := registry.update_item(str(created.id), {"title":"External"}, "other")
	if not external_error.is_empty():
		return external_error
	form._title_edit.text = "Local"
	await form._save_changes()
	return A.is_true(state.db.get_item(str(created.id)).title == "External" and form._id_label.text.contains("stale expected item token"), "full backend content token refuses a same-revision stale form save")

func test_form_refuses_stale_pinned_revision_after_selected_repin() -> Variant:
	var state := _state("form")
	var registry := _active_registry(state, "form")
	var created := registry.create_item({"type":"review", "title":"Original", "revision":"abc", "source":"origin"}, "tester")
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_item(str(created.id), "form")
	var evolved := _definition()
	evolved.label = "Review evolved"
	var current := registry.get_type("review")
	var preview := registry.preview_evolution("review", evolved, current.current_revision, [str(created.id)])
	var evolve_error := registry.apply_evolution(preview, "other", "repin")
	if not evolve_error.is_empty():
		return evolve_error
	form._title_edit.text = "Local"
	await form._save_changes()
	return A.is_true(state.db.get_item(str(created.id)).title == "Original" and form._id_label.text.contains("stale expected item revision"), "form keeps its pinned descriptor context and refuses a stale revision after external repin")

func test_draft_project_switch_retains_edits_when_type_is_unavailable() -> Variant:
	var state := _state("alpha")
	_active_registry(state, "alpha")
	var beta_path := "%s/beta.dct" % DIR
	var beta_db := DocketDBJsonl.create_new_jsonl(beta_path)
	_dbs.append(beta_db)
	state._project_dbs.beta = beta_db
	state._type_registries.beta = TypeRegistry.for_db(beta_db, "beta")
	var form := RecordForm.new()
	add_child(form)
	form.init(state)
	form.load_draft("review", {"type":"review", "title":"", "fields":{}}, "alpha")
	(form._dynamic_fields._rows.revision.editor as LineEdit).text = "unsaved"
	form._project_option.select(1)
	form._on_draft_project_changed(1)
	return A.is_true((form._dynamic_fields._rows.revision.editor as LineEdit).text == "unsaved" and form._id_label.text.contains("Draft retained"), "ordinary project selection retains draft controls and reports an unavailable type instead of discarding or reinterpreting edits")
