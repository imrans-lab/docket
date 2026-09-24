extends Node
class_name TestProjectTypesPanel

const AppShell := preload("res://scripts/ui/app_shell.gd")
const ProjectTypesPanel := preload("res://scripts/ui/project_types_panel.gd")

const A = preload("res://test/assert_helpers.gd")
const DIR := "user://fixtures/project_types_panel"
var _open: Array[DocketDB] = []

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))

func before_each() -> void:
	JSONLMigration.verification_failure_hook = Callable()
	JSONLTypeUpgrade.cache_delete_failure_hook = Callable()
	_reset_fixtures()

func teardown() -> void:
	JSONLMigration.verification_failure_hook = Callable()
	JSONLTypeUpgrade.cache_delete_failure_hook = Callable()
	_reset_fixtures()

func _reset_fixtures() -> void:
	for db in _open:
		if db != null and db.is_open():
			db.close()
	_open.clear()
	for child in get_children():
		remove_child(child)
		child.free()
	for filename in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [DIR, filename]))

func _state(name: String) -> AppState:
	var path := "%s/%s.dct" % [DIR,name]
	var db := DocketDBJsonl.create_new_jsonl(path)
	assert(db != null, "failed to create JSONL fixture %s" % path)
	_open.append(db)
	var state := AppState.new(); state.schema = TypeRegistryBootstrap.load_shipped_schema(); state.db = db; state.dct_path = path; state._project_dbs = {name:db}; state._type_registries = {name:TypeRegistry.for_db(db, name)}
	return state

func _panel(state: AppState) -> ProjectTypesPanel:
	var panel := ProjectTypesPanel.new(); add_child(panel); panel.init(LocalDocketSource.new(state)); return panel

func _sqlite_state(name: String) -> AppState:
	var path := "%s/%s.dct" % [DIR, name]
	var db := DocketDB.create_new(path)
	assert(db != null, "failed to create SQLite fixture %s" % path)
	_open.append(db)
	db.set_project_name(name)
	db.insert_item("TST-0001", {"type":"bug", "status":"new", "title":"Legacy", "created_at":"2026-09-12T12:00:00Z", "updated_at":"2026-09-12T12:00:00Z"})
	var state := AppState.new()
	state.schema = TypeRegistryBootstrap.load_shipped_schema()
	state.db = db
	state.dct_path = path
	state._project_dbs = {name:db}
	state._type_registries = {name:TypeRegistry.for_db(db, name)}
	return state

func _definition() -> Dictionary:
	return {"slug":"code_review","label":"Code review","description":"Review a revision","use_when":"A change needs review","protected":false,"protected_behavior":{"regular_creation_allowed":true},"fields":[{"key":"revision","type":"string","required":true,"nullable":false,"mutable":true,"label":"Revision","help":"Commit or change identifier"}],"lifecycle":{"initial_state":"requested","states":[{"key":"requested","label":"Requested","state_category":"queued","state_outcome":""},{"key":"approved","label":"Approved","state_category":"terminal","state_outcome":"success"}],"terminal_states":["approved"],"transitions":{"requested":["approved"],"approved":[]},"guards":{"approved":{"required_fields":["revision"]}},"enforcement":"strict"}}

func _author(panel: ProjectTypesPanel) -> void:
	panel._author.text = "tester"; panel._reason.text = "behavioral test"

func test_panel_invalid_preview_and_draft_definition() -> Variant:
	var state := _state("draft"); var panel := _panel(state); panel._new_draft(); panel._slug.text = "Bad Slug"; panel._label.text = "Broken"
	var invalid: Dictionary = await panel._validate_preview(); var r = A.is_true(invalid.has("error"), "panel reports invalid definitions before a write"); if r is String: return r
	var definition := _definition(); panel._slug.text = definition.slug; panel._label.text = definition.label; panel._description.text = definition.description; panel._use_when.text = definition.use_when; panel._definition.text = JSON.stringify({"fields":definition.fields,"lifecycle":definition.lifecycle}); _author(panel); panel._save_definition()
	var saved: Dictionary = state.get_type_registry("draft").get_type("code_review")
	r = A.eq(saved.lifecycle, "draft", "panel saves new definitions as drafts"); if r is String: return r
	var create: Dictionary = state.get_type_registry("draft").create_item({"type":"code_review","title":"Must refuse","revision":"abc"}, "tester")
	return A.is_true(create.has("error") and str(create.error).contains("draft") and str(create.error).contains("cannot create"), "draft types cannot create ordinary items")

func test_panel_activate_evolve_repin_history_and_deprecate() -> Variant:
	var state := _state("lifecycle"); var registry := state.get_type_registry("lifecycle"); var definition := _definition(); var made: Dictionary = registry.define_type("code_review", definition, "tester", "initial draft")
	var panel := _panel(state); panel._load_type("code_review"); _author(panel); panel._set_lifecycle("active")
	var active: Dictionary = registry.get_type("code_review"); var r = A.eq(active.lifecycle, "active", "panel explicitly activates a draft"); if r is String: return r
	var item: Dictionary = registry.create_item({"type":"code_review","title":"Review","revision":"abc"}, "tester"); if item.has("error"): return str(item.error)
	var evolved := definition.duplicate(true); evolved.label = "Change review"; evolved.fields.append({"key":"reviewer","type":"string","required":false,"nullable":true,"mutable":true,"label":"Reviewer","help":"Assigned reviewer"})
	panel._load_type("code_review"); panel._label.text = evolved.label; panel._definition.text = JSON.stringify({"fields":evolved.fields,"lifecycle":evolved.lifecycle}); panel._selected_items.text = str(item.id); _author(panel); panel._save_definition()
	var current: Dictionary = registry.get_type("code_review"); var stored: Dictionary = state.db.get_item(item.id)
	r = A.is_true(current.label == "Change review" and stored.type_revision == current.current_revision and registry.revisions_for_type(current.id).size() == 2, "compatible evolution creates immutable history and repins selected items"); if r is String: return r
	panel._load_type("code_review"); _author(panel); panel._set_lifecycle("deprecated")
	return A.eq(registry.get_type("code_review").lifecycle, "deprecated", "panel explicitly deprecates a type")

func test_panel_stale_revision_requires_review() -> Variant:
	var state := _state("stale"); var registry := state.get_type_registry("stale"); var definition := _definition(); registry.define_type("code_review", definition, "tester", "draft")
	var panel := _panel(state); panel._load_type("code_review"); var stale_revision: String = panel._expected_revision
	var evolved := definition.duplicate(true); evolved.description = "Externally evolved"; var preview := registry.preview_evolution("code_review", evolved, stale_revision); var error := registry.apply_evolution(preview, "other", "concurrent update"); if not error.is_empty(): return error
	_author(panel); panel._set_lifecycle("active")
	return A.is_true(panel._status.text.contains("proposal is stale") and registry.get_type("code_review").lifecycle == "draft", "stale panel proposal explains reload and does not mutate lifecycle")

func test_upgrade_preview_is_read_only_and_acknowledgement_required() -> Variant:
	var source := "res://test/fixtures/dynamic_types_legacy_v1.jsonl"; var target := "%s/legacy-copy.dct" % DIR
	var copy_error := DirAccess.copy_absolute(ProjectSettings.globalize_path(source), ProjectSettings.globalize_path(target)); if copy_error != OK: return "fixture copy failed"
	var before := FileAccess.get_sha256(target); var preview := JSONLTypeUpgrade.preview(target)
	var r = A.is_true(preview.ok and FileAccess.get_sha256(target) == before and not FileAccess.file_exists(target + ".pre-v2.bak"), "upgrade preview reports a plan without mutating source or backup"); if r is String: return r
	var refused := JSONLTypeUpgrade.apply(target, preview, {}, false)
	return A.is_true(not refused.ok and str(refused.error).contains("incompatible writers stopped") and FileAccess.get_sha256(target) == before, "upgrade apply requires explicit exclusive-writer acknowledgement")

func test_app_shell_navigation_reaches_project_types() -> Variant:
	var state := _state("navigation"); var shell := AppShell.new(); shell.init(LocalDocketSource.new(state)); add_child(shell); shell._on_menu_action("project_types")
	return A.is_true(shell._current_work_idx >= 0 and shell._work_entries[shell._current_work_idx].type == "types" and shell._project_types.get_parent() != null, "File > Project Types opens a reusable management work entry")

func test_sqlite_promotion_requires_ack_and_reopens_jsonl_with_backup() -> Variant:
	var state := _sqlite_state("promotion")
	var path := state.dct_path
	var refused: Dictionary = state.promote_project_to_jsonl("promotion", false)
	var r = A.is_true(not refused.success and JSONLMigration.detect_format(path) == "sqlite", "promotion requires stopped-writer acknowledgement and leaves SQLite unchanged")
	if r is String:
		return r
	var promoted: Dictionary = state.promote_project_to_jsonl("promotion", true)
	r = A.is_true(promoted.success and promoted.path == path and promoted.backup_path == path + ".sqlite.bak", "promotion reports the real in-place destination and backup")
	if r is String:
		return r
	r = A.is_true(JSONLMigration.detect_format(path) == "jsonl" and JSONLMigration.detect_format(promoted.backup_path) == "sqlite", "promotion writes JSONL and preserves the SQLite original")
	if r is String:
		return r
	var reopened: DocketDB = state.get_db_for_project("promotion")
	_open.append(reopened)
	return A.is_true(reopened is DocketDBJsonl and state.get_type_registry("promotion").is_legacy(), "promotion reopens the project and refreshes its legacy JSONL registry before the separate v2 upgrade")

func test_no_project_and_invalid_registry_show_diagnostics_without_fake_rows() -> Variant:
	var empty_state := AppState.new()
	empty_state.schema = TypeRegistryBootstrap.load_shipped_schema()
	var empty_panel := _panel(empty_state)
	var r = A.is_true(empty_panel._types.item_count == 0 and empty_panel._summary.text.contains("Open a project"), "no-project panel refuses editing with an actionable diagnostic")
	if r is String:
		return r
	var state := _state("invalid")
	var registry := state.get_type_registry("invalid")
	registry._load_error = "type registry is read-only: malformed stored revision"
	var panel := _panel(state)
	return A.is_true(panel._types.item_count == 0 and panel._summary.text.contains("malformed stored revision"), "invalid registry diagnostic is visible and is not rendered as a type row")

func test_passive_refresh_preserves_editor_origin_and_project_switch_discards_it() -> Variant:
	var state := _state("origin-a")
	var second_path := "%s/origin-b.dct" % DIR
	var second := DocketDBJsonl.create_new_jsonl(second_path)
	_open.append(second)
	state._project_dbs["origin-b"] = second
	state._type_registries["origin-b"] = TypeRegistry.for_db(second, "origin-b")
	var panel := _panel(state)
	panel._new_draft()
	panel._slug.text = "unsaved_type"
	panel.refresh()
	var r = A.is_true(panel._editor_project == "origin-a" and panel._slug.text == "unsaved_type", "passive refresh preserves the editor proposal and its origin")
	if r is String:
		return r
	panel._on_project_selected(1)
	return A.is_true(panel._editor_project == "origin-a" and panel._slug.text == "unsaved_type" and panel._active_project == "origin-a" and panel._status.text.contains("retained"), "project switching refuses to discard or reinterpret an unsaved proposal")

func test_loaded_snapshot_preserves_aliases_and_unknown_presentation_data() -> Variant:
	var state := _state("lifecycle")
	var registry := state.get_type_registry("lifecycle")
	var definition := _definition()
	definition.aliases = ["cr", "review-change"]
	definition["presentation"] = {"icon":"review", "accent":"blue"}
	definition["future_extension"] = {"mode":"preserve"}
	registry.define_type("code_review", definition, "tester", "complete snapshot")
	var panel := _panel(state)
	panel._load_type("code_review")
	panel._description.text = "Updated description"
	_author(panel)
	panel._save_definition()
	var current: Dictionary = registry.get_type("code_review")
	var revision: Dictionary = registry.get_revision(str(current.current_revision))
	return A.is_true(revision.definition.aliases == ["cr", "review-change"] and revision.definition.presentation.icon == "review" and revision.definition.future_extension.mode == "preserve", "load and evolve merge edited presentation fields into the complete immutable definition snapshot")

func test_upgrade_acknowledgement_is_bound_to_preview_project_and_source() -> Variant:
	var state := _state("origin-a")
	var second_path := "%s/origin-b.dct" % DIR
	var second := DocketDBJsonl.create_new_jsonl(second_path)
	_open.append(second)
	state._project_dbs["origin-b"] = second
	state._type_registries["origin-b"] = TypeRegistry.for_db(second, "origin-b")
	var panel := _panel(state)
	panel._upgrade_preview = {"ok":true, "project":"origin-a", "path":state.dct_path, "source_hash":FileAccess.get_sha256(state.dct_path)}
	panel._upgrade_ack.button_pressed = true
	panel._on_project_selected(1)
	return A.is_true(not panel._upgrade_ack.button_pressed and panel._upgrade_preview.is_empty() and panel._active_project == "origin-b", "writer acknowledgement and upgrade preview are cleared when the selected project changes")

func test_promotion_post_write_failure_adopts_actual_jsonl_and_reports_recovery_state() -> Variant:
	var state := _sqlite_state("promotion")
	JSONLMigration.verification_failure_hook = func() -> String:
		return "injected verification failure"
	var result: Dictionary = state.promote_project_to_jsonl("promotion", true)
	var active := state.get_db_for_project("promotion")
	return A.is_true(not result.success and result.actual_format == "jsonl" and result.project_open and active is DocketDBJsonl and FileAccess.file_exists(str(result.backup_path)) and state.get_type_registry("promotion").is_legacy(), "post-write promotion failure reports and adopts the actual JSONL source with backup and refreshed registry")

func test_upgrade_cache_failure_reopens_v2_and_invalidates_panel_preview() -> Variant:
	var source := "res://test/fixtures/dynamic_types_legacy_v1.jsonl"
	var target := "%s/legacy-copy.dct" % DIR
	var copy_error := DirAccess.copy_absolute(ProjectSettings.globalize_path(source), ProjectSettings.globalize_path(target))
	if copy_error != OK:
		return "fixture copy failed"
	var db := DocketDBJsonl.open_jsonl(target)
	_open.append(db)
	var state := AppState.new()
	state.schema = TypeRegistryBootstrap.load_shipped_schema()
	state.db = db
	state.dct_path = target
	state._project_dbs = {"legacy-copy":db}
	state._type_registries = {"legacy-copy":TypeRegistry.for_db(db, "legacy-copy")}
	var panel := _panel(state)
	panel._preview_upgrade()
	panel._upgrade_ack.button_pressed = true
	JSONLTypeUpgrade.cache_delete_failure_hook = func() -> String:
		return "injected cache deletion failure"
	panel._apply_upgrade()
	var active := state.get_db_for_project("legacy-copy")
	return A.is_true(active is DocketDBJsonl and not state.get_type_registry("legacy-copy").is_legacy() and panel._upgrade_preview.is_empty() and not panel._upgrade_ack.button_pressed and panel._status.text.contains("Canonical format: jsonl") and FileAccess.file_exists(target + ".pre-v2.bak"), "post-write cache failure reopens the actual v2 source, reports its backup, and requires a fresh next action")
