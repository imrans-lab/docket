extends VBoxContainer

signal registry_changed(project: String)

var _src  # DocketSource
var _project: OptionButton
var _search: LineEdit
var _show_deprecated: CheckBox
var _types: ItemList
var _summary: Label
var _slug: LineEdit
var _label: LineEdit
var _description: TextEdit
var _use_when: TextEdit
var _definition: TextEdit
var _author: LineEdit
var _reason: LineEdit
var _selected_items: LineEdit
var _status: Label
var _history: ItemList
var _upgrade_box: VBoxContainer
var _upgrade_ack: CheckBox
var _stale_dialog: AcceptDialog
var _editor_controls: Array[Control] = []
var _upgrade_preview: Dictionary = {}
var _active_project: String = ""
var _editor_project: String = ""
var _selected_slug: String = ""
var _expected_revision: String = ""
var _loaded_definition: Dictionary = {}
var _editor_baseline: String = ""
# Bumped by each list refresh, so an older one finishing late is dropped.
var _list_generation := 0
# Bumped when a type load, draft or history view starts (so a slower earlier
# one is dropped) and whenever the editor switches or clears (so a preview,
# history view or post-write reload begun before then drops its result).
var _type_generation := 0
# True while a type or project write is in flight, so a second click cannot
# repeat it.
var _writing := false
## Reported when the selected project or type changed while an action waited.
const PROJECT_CHANGED := "The selected project or type changed before this finished; nothing more was done."

func init(source) -> void:
	_src = source
	_build_ui()
	_src.file_changed.connect(refresh)
	refresh()

func _build_ui() -> void:
	var heading := Label.new()
	heading.text = "Project Types"
	heading.add_theme_font_size_override("font_size", 22)
	add_child(heading)
	var top := HBoxContainer.new()
	add_child(top)
	_project = OptionButton.new()
	_project.item_selected.connect(_on_project_selected)
	top.add_child(_project)
	_search = LineEdit.new()
	_search.placeholder_text = "Search names, slugs, descriptions, and guidance"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_value: String): _refresh_list())
	top.add_child(_search)
	_show_deprecated = CheckBox.new()
	_show_deprecated.text = "Show deprecated"
	_show_deprecated.toggled.connect(func(_value: bool): _refresh_list())
	top.add_child(_show_deprecated)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 320
	add_child(split)
	var left := VBoxContainer.new()
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_summary)
	_types = ItemList.new()
	_types.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_types.item_selected.connect(_type_selected)
	left.add_child(_types)
	split.add_child(left)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(scroll)
	var editor := VBoxContainer.new()
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(editor)
	_slug = _line(editor, "Slug", "lowercase_identifier")
	_label = _line(editor, "Display label", "Human-readable name")
	_description = _text(editor, "Description", 70)
	_use_when = _text(editor, "Use when", 55)
	var json_help := Label.new()
	json_help.text = "Fields and lifecycle JSON — complete snapshot. Field help/labels and lifecycle categories, outcomes, transitions, and guards live here."
	json_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	editor.add_child(json_help)
	_definition = TextEdit.new()
	_definition.custom_minimum_size.y = 280
	editor.add_child(_definition)
	_author = _line(editor, "Author / ratifier", "Recorded provenance; this is not identity authentication")
	_reason = _line(editor, "Reason", "Why this definition or lifecycle change is needed")
	_selected_items = _line(editor, "Repin item IDs (optional)", "Comma-separated IDs validated by evolution preview")
	_editor_controls.assign([_slug, _label, _description, _use_when, _definition, _author, _reason, _selected_items])
	var actions := HBoxContainer.new()
	editor.add_child(actions)
	_button(actions, "New draft", _new_draft)
	_button(actions, "Validate preview", _validate_preview)
	_button(actions, "Save draft / evolve", _save_definition)
	_button(actions, "Activate", func(): _set_lifecycle("active"))
	_button(actions, "Deprecate", func(): _set_lifecycle("deprecated"))
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.y = 70
	editor.add_child(_status)
	var history_label := Label.new()
	history_label.text = "Immutable revision history and provenance"
	editor.add_child(history_label)
	_history = ItemList.new()
	_history.custom_minimum_size.y = 130
	_history.item_selected.connect(_history_selected)
	editor.add_child(_history)
	_upgrade_box = VBoxContainer.new()
	editor.add_child(_upgrade_box)
	var upgrade_title := Label.new()
	upgrade_title.text = "Legacy project upgrade"
	upgrade_title.add_theme_font_size_override("font_size", 18)
	_upgrade_box.add_child(upgrade_title)
	var upgrade_note := Label.new()
	upgrade_note.text = "Legacy files stay unchanged until an explicit action. Stop Minerva and every incompatible writer first. SQLite promotion writes JSONL at the same .dct path and keeps the original at .sqlite.bak. After promotion, separately preview and apply the JSONL 2.0 upgrade."
	upgrade_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_upgrade_box.add_child(upgrade_note)
	_upgrade_ack = CheckBox.new()
	_upgrade_ack.text = "I confirm incompatible writers are stopped"
	_upgrade_box.add_child(_upgrade_ack)
	var upgrade_actions := HBoxContainer.new()
	_upgrade_box.add_child(upgrade_actions)
	_button(upgrade_actions, "Promote SQLite to JSONL", _promote_sqlite)
	_button(upgrade_actions, "Preview JSONL 2.0 upgrade", _preview_upgrade)
	_button(upgrade_actions, "Apply previewed upgrade", _apply_upgrade)
	_stale_dialog = AcceptDialog.new()
	_stale_dialog.title = "Definition changed"
	add_child(_stale_dialog)

func _line(parent: Control, caption: String, placeholder: String) -> LineEdit:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var title := Label.new()
	title.text = caption
	title.custom_minimum_size.x = 155
	row.add_child(title)
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)
	return edit

func _text(parent: Control, caption: String, height: float) -> TextEdit:
	var title := Label.new()
	title.text = caption
	parent.add_child(title)
	var edit := TextEdit.new()
	edit.custom_minimum_size.y = height
	parent.add_child(edit)
	return edit

func _button(parent: Control, caption: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(callback)
	parent.add_child(button)

func refresh() -> void:
	var wanted := _active_project
	_project.clear()
	var names: Array[String] = _src.project_names()
	for name in names:
		_project.add_item(str(name))
		if str(name) == wanted:
			_project.select(_project.item_count - 1)
	if _project.item_count == 0:
		_active_project = ""
		_refresh_list()
		return
	if wanted.is_empty() or not names.has(wanted):
		_active_project = _project.get_item_text(_project.selected)
	_refresh_list()

func _project_name() -> String:
	return _active_project

func _on_project_selected(index: int) -> void:
	var next_project := _project.get_item_text(index)
	if next_project == _active_project:
		return
	if _has_unsaved_editor():
		_select_project(_active_project)
		_message("Unsaved type proposal retained. Save it or restore its loaded values before switching projects.", true)
		return
	_active_project = next_project
	_upgrade_preview = {}
	_upgrade_ack.button_pressed = false
	_clear_editor("Project changed. Select a type or start a new draft.")
	_refresh_list()

func _select_project(project_name: String) -> void:
	for i in _project.item_count:
		if _project.get_item_text(i) == project_name:
			_project.select(i)
			return

func _clear_editor(message: String = "Select a type or start a new draft.") -> void:
	_type_generation += 1
	_editor_project = ""
	_selected_slug = ""
	_expected_revision = ""
	_loaded_definition = {}
	_slug.text = ""
	_slug.editable = true
	_label.text = ""
	_description.text = ""
	_use_when.text = ""
	_definition.text = ""
	_selected_items.text = ""
	_history.clear()
	_editor_baseline = _editor_snapshot()
	_message(message, false)

func _set_editor_enabled(enabled: bool) -> void:
	for control in _editor_controls:
		control.mouse_filter = Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
		control.modulate = Color.WHITE if enabled else Color(0.6, 0.6, 0.6)

func _refresh_list() -> void:
	_list_generation += 1
	var generation := _list_generation
	var overview: Dictionary = {"error": "Open a project to manage its types.", "kind": "no_project"} \
		if _project_name().is_empty() else await _src.types_overview(_project_name(), _show_deprecated.button_pressed)
	if generation != _list_generation:
		return
	_types.clear()
	if overview.has("error"):
		_summary.text = str(overview.error)
		_set_editor_enabled(false)
		match str(overview.get("kind", "")):
			"no_project":
				_upgrade_box.visible = false
			"unavailable":
				_message(_summary.text, true)
				_upgrade_box.visible = false
			"list_failed":
				_message(_summary.text, true)
		return
	var listed: Array = overview.types
	var counts: Dictionary = overview.counts
	var needle := _search.text.to_lower()
	var shown := 0
	for type_value in listed:
		var type: Dictionary = type_value
		var haystack := "%s %s %s %s" % [type.label, type.slug, type.description, type.use_when]
		if not needle.is_empty() and not haystack.to_lower().contains(needle):
			continue
		var text: String = "%s  [%s]  — %d items" % [type.label, type.lifecycle, int(counts.get(type.slug, 0))]
		_types.add_item(text)
		_types.set_item_metadata(_types.item_count - 1, type.slug)
		shown += 1
	_summary.text = "%s — %d matching types. Active types with zero items are included; drafts cannot create ordinary items." % [_project_name(), shown]
	_set_editor_enabled(true)
	_upgrade_box.visible = bool(overview.legacy)

func _type_selected(index: int) -> void:
	if _has_unsaved_editor():
		_message("Unsaved type proposal retained. Save it or restore its loaded values before selecting another type.", true)
		return
	_load_type(str(_types.get_item_metadata(index)))

## Load type `slug` into the editor; `context` prefixes what it reports when
## it cannot.
func _load_type(slug: String, context: String = "") -> void:
	var project := _project_name()
	if project.is_empty():
		_message("Open a project before selecting a type.", true)
		return
	_type_generation += 1
	var generation := _type_generation
	var shown := _editor_snapshot()
	var type: Dictionary = await _src.type_with_history(project, slug)
	if generation != _type_generation or project != _project_name():
		return
	if _editor_snapshot() != shown:
		_message("%sThe editor changed while %s loaded, so it was not replaced. Select the type again to load it." % [context, slug], true)
		return
	if type.has("error"):
		_message(context + str(type.error), true)
		return
	# The editor switches types only now: a preview begun while this load
	# waited belongs to the previous one.
	_type_generation += 1
	_editor_project = project
	_selected_slug = slug
	_expected_revision = str(type.current_revision)
	_slug.text = slug
	_slug.editable = false
	_label.text = str(type.label)
	_description.text = str(type.description)
	_use_when.text = str(type.use_when)
	_loaded_definition = type.definition.duplicate(true)
	_definition.text = JSON.stringify(_loaded_definition, "  ", false, true)
	_history.clear()
	for revision_value in type.revisions:
		var revision: Dictionary = revision_value
		_history.add_item("%s — %s — %s — %s" % [revision.created_at, revision.author, revision.reason, revision.id])
		_history.set_item_metadata(_history.item_count - 1, revision.id)
	_message("Current revision: %s\nLifecycle: %s\nProvenance: %s" % [type.current_revision, type.lifecycle, JSON.stringify(type.provenance)], false)
	_editor_baseline = _editor_snapshot()

func _history_selected(index: int) -> void:
	if _project_name().is_empty() or _editor_project != _project_name():
		_message("The editor does not belong to the selected project.", true)
		return
	var project := _project_name()
	# Each history view supersedes earlier ones, and edits made while it
	# waits are kept rather than replaced.
	_type_generation += 1
	var generation := _type_generation
	var edited := _editor_snapshot()
	var revision: Dictionary = await _src.type_revision(project, str(_history.get_item_metadata(index)))
	if generation != _type_generation or project != _project_name():
		return
	if _editor_snapshot() != edited:
		_message("The editor changed while the revision loaded; it was not replaced.", true)
		return
	if revision.has("error"):
		_message(str(revision.error), true)
		return
	_loaded_definition = revision.definition.duplicate(true)
	_definition.text = JSON.stringify(_loaded_definition, "  ", false, true)
	_label.text = str(revision.definition.label)
	_description.text = str(revision.definition.description)
	_use_when.text = str(revision.definition.get("use_when", ""))
	_message("Viewing immutable revision %s. Saving proposes evolution from current revision %s." % [revision.id, _expected_revision], false)
	_editor_baseline = _editor_snapshot()

func _new_draft() -> void:
	var project := _project_name()
	if project.is_empty():
		_message("Open a project before creating a type draft.", true)
		return
	_type_generation += 1
	var generation := _type_generation
	var shown := _editor_snapshot()
	var problem: String = await _src.types_problem(project)
	if generation != _type_generation or project != _project_name():
		return
	if _editor_snapshot() != shown:
		_message("The editor changed while the draft was prepared; it was not replaced.", true)
		return
	if not problem.is_empty():
		_message(problem, true)
		return
	_type_generation += 1  # as in _load_type
	_editor_project = project
	_selected_slug = ""
	_expected_revision = ""
	_slug.editable = true
	_slug.text = ""
	_label.text = ""
	_description.text = ""
	_use_when.text = ""
	_definition.text = JSON.stringify({"fields":[], "lifecycle":{"initial_state":"new", "states":[{"key":"new", "label":"New", "state_category":"queued", "state_outcome":""}], "terminal_states":[], "transitions":{"new":[]}, "guards":{}, "enforcement":"strict"}}, "  ", false, true)
	_history.clear()
	_message("New definitions are saved as drafts and require explicit activation.", false)
	_loaded_definition = {}
	_editor_baseline = _editor_snapshot()

func _candidate() -> Dictionary:
	if _editor_project.is_empty() or _editor_project != _project_name():
		return {"error":"The editor does not belong to the selected project. Select a type or start a new draft."}
	var parsed: Variant = JSON.parse_string(_definition.text)
	if not parsed is Dictionary:
		return {"error":"Fields and lifecycle must be a JSON object."}
	var candidate: Dictionary = _loaded_definition.duplicate(true)
	for key in parsed:
		candidate[key] = parsed[key]
	candidate.slug = _slug.text.strip_edges()
	candidate.label = _label.text.strip_edges()
	candidate.description = _description.text
	candidate.use_when = _use_when.text
	if _selected_slug.is_empty():
		candidate.protected = false
		candidate.protected_behavior = {"regular_creation_allowed":true}
	return candidate

func _editor_snapshot() -> String:
	return JSON.stringify([_editor_project, _selected_slug, _slug.text, _label.text, _description.text, _use_when.text, _definition.text, _selected_items.text])

func _has_unsaved_editor() -> bool:
	return not _editor_project.is_empty() and not _editor_baseline.is_empty() and _editor_snapshot() != _editor_baseline

func _item_ids() -> Array:
	var result: Array = []
	for part in _selected_items.text.split(","):
		if not part.strip_edges().is_empty():
			result.append(part.strip_edges())
	return result

func _validate_preview() -> Dictionary:
	return await _preview_for(_project_name())


## _validate_preview for `project`. If another project or type is selected
## while it waits, it reports PROJECT_CHANGED and previews nothing.
func _preview_for(project: String) -> Dictionary:
	if project.is_empty():
		var absent := {"error":"Open a project before validating a definition."}
		_message(absent.error, true)
		return absent
	var generation := _type_generation
	var problem: String = await _src.types_problem(project)
	if project != _project_name() or generation != _type_generation:
		return _changed()
	if not problem.is_empty():
		var unavailable := {"error":problem}
		_message(unavailable.error, true)
		return unavailable
	var candidate := _candidate()
	if candidate.has("error"):
		_message(str(candidate.error), true)
		return candidate
	var error: String = await _src.validate_type_definition(project, candidate)
	if project != _project_name() or generation != _type_generation:
		return _changed()
	if not error.is_empty():
		_message(error, true)
		return {"error":error}
	if _selected_slug.is_empty():
		_message("Valid draft definition. Saving will create it without allowing ordinary item creation.", false)
		return {"definition":candidate}
	var preview: Dictionary = await _src.preview_type_evolution(project, _selected_slug, candidate,
		_expected_revision, _item_ids())
	if project != _project_name() or generation != _type_generation:
		return _changed()
	if preview.has("error"):
		_message(str(preview.error), true)
		return preview
	_message("Compatible evolution preview: %d selected items will be validated and repinned. Saved-query impact: %s" % [preview.items.size(), JSON.stringify(preview.saved_query_impact)], false)
	return preview

func _changed() -> Dictionary:
	_message(PROJECT_CHANGED, true)
	return {"error": PROJECT_CHANGED}

## Run the write `step` unless another is in flight.
func _write_once(step: Callable) -> void:
	if _writing:
		return
	_writing = true
	await step.call()
	_writing = false

func _save_definition() -> void:
	await _write_once(_save_definition_now)

func _save_definition_now() -> void:
	var project := _project_name()
	var owner := _type_generation
	var written := _editor_snapshot()
	var preview: Dictionary = await _preview_for(project)
	if preview.has("error"):
		return
	if _author.text.strip_edges().is_empty() or _reason.text.strip_edges().is_empty():
		_message("Author and reason are required provenance metadata.", true)
		return
	var slug := _selected_slug
	if slug.is_empty():
		slug = str(preview.definition.slug)  # the slug that was validated
		var result: Dictionary = await _src.define_type(project, slug, preview.definition, _author.text, _reason.text)
		if result.has("error"):
			_message(str(result.error), true)
			return
	else:
		var error: String = await _src.apply_type_evolution(project, preview, _author.text, _reason.text)
		if not error.is_empty():
			_message(_stale_message(error), true)
			return
	await _after_type_write(project, slug, owner, written)

func _set_lifecycle(lifecycle: String) -> void:
	await _write_once(_set_lifecycle_now.bind(lifecycle))

func _set_lifecycle_now(lifecycle: String) -> void:
	var project := _project_name()
	var slug := _selected_slug
	var owner := _type_generation
	var written := _editor_snapshot()
	if _editor_project != project or slug.is_empty():
		_message("Select a saved type in this project first.", true)
		return
	var error: String = await _src.set_type_lifecycle(project, slug, lifecycle, _expected_revision,
		_author.text, _reason.text)
	if not error.is_empty():
		_message(_stale_message(error), true)
		return
	await _after_type_write(project, slug, owner, written)

## After type `slug` of `project` was written from the editor as it stood at
## `owner` (a _type_generation) with contents `written` (_editor_snapshot):
## tell listeners, and reload the list and the editor unless the user has
## since moved the editor or the project on, or edited it.
func _after_type_write(project: String, slug: String, owner: int, written: String) -> void:
	registry_changed.emit(project)
	if project != _project_name() or owner != _type_generation or _editor_snapshot() != written:
		_message("%s was saved; the editor has changed since, so it was not reloaded." % slug, false)
		if project == _project_name():
			await _refresh_list()
		return
	_type_generation += 1  # the editor now stands for `slug`
	var reloading := _type_generation
	await _refresh_list()
	if project != _project_name() or reloading != _type_generation or _editor_snapshot() != written:
		_message("%s was saved; the editor has changed since, so it was not reloaded." % slug, false)
		return
	await _load_type(slug, "%s was saved. " % slug)  # which keeps edits typed while it loads

func _stale_message(error: String) -> String:
	if error.contains("stale") or error.contains("source changed"):
		var explanation := "This proposal is stale because the current revision changed. Reload the type, review the newer revision, then preview again."
		_stale_dialog.dialog_text = explanation
		_stale_dialog.popup_centered(Vector2i(540, 180))
		return explanation
	return error

func _promote_sqlite() -> void:
	await _write_once(_promote_sqlite_now)

func _promote_sqlite_now() -> void:
	if not _upgrade_ack.button_pressed:
		_message("Confirm that incompatible writers are stopped before promoting SQLite.", true)
		return
	var project := _project_name()
	var result: Dictionary = await _src.promote_project(project)
	if project != _project_name():
		registry_changed.emit(project)
		_migrated_elsewhere(project, result)
		return
	if not bool(result.get("success", false)):
		_upgrade_preview = {}
		_upgrade_ack.button_pressed = false
		_message("%s Canonical format: %s. Project open: %s. Backup: %s. Review this state, then preview JSONL 2.0 if the active format is JSONL." % [result.get("error", "promotion failed"), result.get("actual_format", "unknown"), result.get("project_open", false), result.get("backup_path", "none")], true)
		refresh()
		return
	_upgrade_preview = {}
	_message("SQLite promotion complete at %s with %d items. Original backup: %s. Preview the separate JSONL 2.0 upgrade next." % [result.path, result.item_count, result.backup_path], false)
	registry_changed.emit(project)
	refresh()

## A migration of `project` finished after another project was selected.
func _migrated_elsewhere(project: String, result: Dictionary) -> void:
	var done := bool(result.get("success", result.get("ok", false)))
	var backup := str(result.get("backup_path", ""))
	_message("The migration of %s finished while another project was selected: %s. Backup: %s." % [project,
		"done" if done else str(result.get("error", "failed")), backup if not backup.is_empty() else "none"], not done)

func _preview_upgrade() -> void:
	var project := _project_name()
	var preview: Dictionary = await _src.preview_project_upgrade(project)
	if project != _project_name():
		_changed()
		return
	_upgrade_preview = preview
	if not bool(_upgrade_preview.get("ok", false)):
		_message(str(_upgrade_preview.get("error", "upgrade preview failed")), true)
		return
	_upgrade_ack.button_pressed = false
	_message("Preview only; the source was not changed. %d items will be bound to %d starter definitions. Rollback snapshot: %s. v2 cache: %s." % [_upgrade_preview.items, _upgrade_preview.definitions, _upgrade_preview.backup_path, _upgrade_preview.cache_path], false)

func _apply_upgrade() -> void:
	await _write_once(_apply_upgrade_now)

func _apply_upgrade_now() -> void:
	if _upgrade_preview.is_empty() or not bool(_upgrade_preview.get("ok", false)):
		_message("Preview the upgrade first.", true)
		return
	if not _upgrade_ack.button_pressed:
		_message("Confirm that incompatible writers are stopped before applying the upgrade.", true)
		return
	var project := _project_name()
	var result: Dictionary = await _src.apply_project_upgrade(project, _upgrade_preview)
	if project != _project_name():
		_upgrade_preview = {}
		registry_changed.emit(project)
		_migrated_elsewhere(project, result)
		return
	if bool(result.get("stale", false)):
		_upgrade_preview = {}
		_upgrade_ack.button_pressed = false
		_message(str(result.error), true)
		return
	if not bool(result.get("ok", false)):
		_upgrade_preview = {}
		_upgrade_ack.button_pressed = false
		_message("%s Canonical format: %s. Project open: %s. Backup: %s. Refresh the project state, then preview again only if it remains legacy JSONL." % [result.get("error", "upgrade failed"), result.get("actual_format", "unknown"), result.get("project_open", false), result.get("backup_path", "none")], true)
		refresh()
		return
	_upgrade_preview = {}
	_message("Upgrade complete. Rollback snapshot: %s. The project registry and cache were reopened from v2." % result.backup_path, false)
	registry_changed.emit(project)
	refresh()

func _message(text: String, failure: bool) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", Color.html("d65c5c") if failure else Color.html("6bbf7b"))
