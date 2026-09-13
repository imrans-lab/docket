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
	var state := AppState.new()
	state.schema = TypeRegistryBootstrap.load_shipped_schema()
	state.prefs = UserPrefs.new()
	state.db = db
	state.dct_path = path
	state._project_dbs = {name:db}
	state._type_registries = {name:TypeRegistry.for_db(db, name)}
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
	editor.load_definition(_definition(), {"fields":{"revision":"abc", "source":"origin", "approved":false, "score":0.0, "labels":[], "metadata":{}, "unknown":{"keep":true}}}, true)
	var immutable_mode: OptionButton = editor._rows.source.mode
	var r = A.is_true(editor._rows.revision.editor is LineEdit and editor._rows.findings.editor is TextEdit and editor._rows.attempts.editor is LineEdit and editor._rows.score.editor is LineEdit and editor._rows.approved.editor is CheckBox and editor._rows.decision.editor is OptionButton and editor._rows.due_date.editor is LineEdit and editor._rows.reviewed_at.editor is LineEdit and editor._rows.subject.editor is LineEdit and editor._rows.related.editor is TextEdit and editor._rows.labels.editor is TextEdit and editor._rows.metadata.editor is TextEdit, "all supported descriptor kinds receive an ordinary typed or per-field JSON control")
	if r is String:
		return r
	var patch := editor.collect_patch()
	r = A.is_true(immutable_mode.disabled and patch.fields.approved == false and patch.fields.score == 0.0 and patch.fields.labels == [] and patch.fields.metadata == {}, "existing immutable fields are read-only while false, zero, and empty containers remain explicit values")
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
	if create_error is String and not str(create_error).is_empty():
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
	if update_error is String and not str(update_error).is_empty():
		return update_error
	var path := state.dct_path
	state.db.close()
	JSONLCache.delete_cache_family(path)
	var reopened := DocketDBJsonl.open_jsonl(path)
	if reopened == null:
		return "failed to reopen durable form fixture"
	_dbs.append(reopened)
	var stored := reopened.get_item(id)
	return A.is_true(stored.title == "Updated without loss" and stored.fields.revision == "abc" and stored.fields.source == "immutable-origin" and stored.fields.attempts == 3 and stored.fields.labels == ["one", "two"] and stored.fields.metadata == {"depth":2} and stored.fields.related == [] and stored.fields.findings == null and stored.fields.approved == false and not stored.fields.has("score") and stored.fields.opaque_future == {"keep":true} and stored.fields.resolution == "custom-value" and str(stored.get("resolution", "")).is_empty(), "form value modes, containers, immutable creation value, opaque fields, and a custom field colliding with an unused legacy flat column survive canonical reopen")

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

func test_result_columns_require_pinned_type_identity() -> Variant:
	var state := _state("fields")
	var registry := _active_registry(state, "fields")
	var created := registry.create_item({"type":"review", "title":"Columns", "revision":"abc", "source":"origin", "findings":"visible"}, "tester")
	var item := state.db.get_item(str(created.id))
	item.project = "fields"
	var type := registry.get_type("review")
	var grid := QueryGrid.new()
	add_child(grid)
	grid.init(state)
	var binding := {"project":"fields", "type_id":type.id, "field_key":"findings", "label":"Findings"}
	var wrong := binding.duplicate(true)
	wrong.type_id = "type:unrelated"
	var r = A.eq(grid._render_bound_column(item, binding), "visible", "custom result column renders from fields under the pinned descriptor")
	if r is String:
		return r
	r = A.eq(grid._render_bound_column(item, wrong), "", "unrelated type identity cannot reinterpret a custom result column")
	if r is String:
		return r
	var builtin := registry.get_type("bug")
	var builtin_item := {"type":"bug", "type_id":builtin.id, "type_revision":builtin.current_revision, "status":"new", "resolution":"fixed", "fields":{}, "project":"fields"}
	var builtin_binding := {"project":"fields", "type_id":builtin.id, "field_key":"resolution", "label":"Resolution"}
	return A.eq(grid._render_bound_column(builtin_item, builtin_binding), "fixed", "builtin descriptor columns use their flat storage authority")

func test_column_picker_and_sort_keep_identity_for_colliding_field_keys() -> Variant:
	var state := _state("fields")
	var registry := _active_registry(state, "fields")
	var second_definition := _definition()
	second_definition.slug = "audit"
	second_definition.label = "Audit"
	var second := registry.define_type("audit", second_definition, "tester", "collision")
	registry.activate_type("audit", second.type.current_revision, "tester", "ready")
	var grid := QueryGrid.new()
	add_child(grid)
	grid.init(state)
	grid._rebuild_type_catalog()
	var anchor := Button.new()
	grid.add_child(anchor)
	grid._show_columns_menu(anchor)
	var findings_candidates: Array[int] = []
	var all_findings_count := 0
	var builtin_findings_present := false
	var review_type: Dictionary = registry.get_type("review")
	var custom_type_ids: Array[String] = [str(review_type.id), str(second.type.id)]
	for i in grid._column_candidates.size():
		var candidate: Dictionary = grid._column_candidates[i]
		if candidate.field_key == "findings":
			all_findings_count += 1
			if str(candidate.type_id) in custom_type_ids:
				findings_candidates.append(i)
			else:
				builtin_findings_present = true
	var r = A.is_true(findings_candidates.size() == 2 and all_findings_count >= 3 and builtin_findings_present, "actual Columns menu keeps both exact custom type identities alongside the builtin findings field")
	if r is String:
		return r
	grid._toggle_result_column(findings_candidates[0])
	grid._toggle_result_column(findings_candidates[1])
	var custom_column := grid._col_fields.size() - 1
	grid._toggle_sort(custom_column)
	return A.is_true(grid._dcq_columns.size() == 2 and grid._dcq_columns[0].type_id != grid._dcq_columns[1].type_id and grid._sort_binding.project == "fields" and not str(grid._sort_binding.type_id).is_empty() and grid._sort_binding.field_key == "findings", "column selection and sort persist complete project/type/field identity")

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
