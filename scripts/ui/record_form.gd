extends VBoxContainer
class_name RecordForm
## Item detail form with editable type/status, type-adaptive fields,
## transition buttons, and event log.

signal item_changed
signal back_pressed
signal child_opened(id: String, project: String)

var _state: AppState
var _current_id: String = ""
var _fields_grid: GridContainer
var _title_edit: LineEdit
var _type_option: OptionButton
var _status_option: OptionButton
var _priority_option: OptionButton
var _severity_option: OptionButton
var _assigned_edit: LineEdit
var _tags_edit: LineEdit
var _desc_edit: TextEdit
var _transition_bar: HBoxContainer
var _events_list: ItemList
var _id_label: Label
var _back_btn: Button

# Off-flow transition note prompt
var _transition_note_dialog: ConfirmationDialog
var _transition_note_edit: LineEdit
var _pending_status: String = ""
var _pending_changes: Dictionary = {}
var _pending_revision: String = ""
var _pending_item_token: String = ""
var _loaded_revision: String = ""
var _loaded_item_token: String = ""
var _dynamic_fields: DynamicFieldEditor

# Type-adaptive field widgets + their labels
var _resolution_edit: LineEdit
var _resolution_label: Label
var _environment_edit: LineEdit
var _environment_label: Label
var _assumed_edit: LineEdit
var _assumed_label: Label
var _corrected_edit: LineEdit
var _corrected_label: Label
var _repro_steps_edit: TextEdit
var _repro_steps_label: Label
var _findings_edit: TextEdit
var _findings_label: Label
var _answer_edit: TextEdit
var _answer_label: Label
var _occurred_at_edit: LineEdit
var _occurred_at_label: Label
var _detected_at_edit: LineEdit
var _detected_at_label: Label
var _value_edit: TextEdit
var _value_label: Label
var _component_edit: LineEdit
var _component_label: Label
var _key_edit: LineEdit
var _key_label: Label
var _why_chain_edit: TextEdit
var _why_chain_label: Label
var _contributing_factors_edit: TextEdit
var _contributing_factors_label: Label
var _significant_events_edit: TextEdit
var _significant_events_label: Label
var _reported_at_edit: LineEdit
var _reported_at_label: Label
var _topic_edit: LineEdit
var _topic_label: Label
var _subtopic_edit: LineEdit
var _subtopic_label: Label
var _retrieval_count_spin: SpinBox
var _retrieval_count_label: Label
var _research_cost_spin: SpinBox
var _research_cost_label: Label
var _blocked_by_edit: LineEdit
var _blocked_by_label: Label
var _confidence_spin: SpinBox
var _confidence_label: Label
var _surprise_spin: SpinBox
var _surprise_label: Label
var _surfaced_from_edit: LineEdit
var _surfaced_from_label: Label
var _test_setup_label: Label
var _test_setup_edit: TextEdit
var _test_steps_label: Label
var _test_steps_edit: TextEdit
var _expected_result_label: Label
var _expected_result_edit: TextEdit
var _parent_edit: LineEdit

# Secret + Encrypted Note fields
var _identity_edit: LineEdit
var _identity_label: Label
var _secret_value_label: Label
var _secret_value_container: HBoxContainer
var _secret_value_edit: LineEdit
var _secret_show_btn: Button
var _secret_copy_btn: Button
var _secret_generate_btn: Button
var _secret_2fa_check: CheckBox
var _secret_2fa_dialog: ConfirmationDialog
var _secret_2fa_input: LineEdit
var _secret_vault_error_label: Label
var _secret_value_decrypted: String = ""
var _encrypted_notes_label: Label
var _encrypted_notes_edit: TextEdit
var _encrypted_notes_show_btn: Button
var _encrypted_notes_copy_btn: Button
var _encrypted_notes_decrypted: String = ""
var _secret_history_toggle: Button
var _secret_history_container: VBoxContainer

# Knowledge type fields (skill, prompt, kb)
var _steps_edit: TextEdit
var _steps_label: Label
var _preconditions_edit: TextEdit
var _preconditions_label: Label
var _outcome_edit: TextEdit
var _outcome_label: Label
var _command_edit: TextEdit
var _command_label: Label
var _usage_edit: LineEdit
var _usage_label: Label
var _prompt_text_edit: TextEdit
var _prompt_text_label: Label
var _parameters_edit: LineEdit
var _parameters_label: Label
var _article_edit: TextEdit
var _article_label: Label
var _summary_edit: TextEdit
var _summary_label: Label

# Data-driven field descriptor table: [field_name, label_widget, edit_widget]
# Used by _hide_all_optional_fields, _update_field_visibility, _save_changes,
# _save_draft, load_item, _clear_fields to avoid parallel enumeration.
var _field_map: Array = []

var _desc_drag: Control  # bottom drag handle
var _desc_dragging: bool = false
var _desc_drag_top_dragging: bool = false
var _desc_drag_start_y: float = 0.0
var _desc_drag_start_height: float = 0.0
var _fields_scroll: ScrollContainer

var _events_toggle: Button
var _events_container: VBoxContainer

var _children_toggle: Button
var _children_container: VBoxContainer
var _children_list: ItemList

var _comments_toggle: Button
var _comments_container: VBoxContainer
var _comments_list: VBoxContainer
var _comment_input: TextEdit
var _comment_add_btn: Button
var _body_vbox: VBoxContainer

var _loading: bool = false  # guard against signal loops during load
var _is_draft: bool = false  # true when item hasn't been saved to DB yet
var _draft_item: Dictionary = {}  # in-memory item before first save
var _current_project: String = ""  # project name that owns current item
var _project_label: Label  # shows [project] badge in header
var _project_option: OptionButton  # project selector for new items (visible when 2+ projects)
var _project_inline_label: Label  # "Project:" label next to _project_option in meta row
var _move_btn: Button  # "Move to..." button (visible when 2+ projects, item saved)


func init(state: AppState) -> void:
	_state = state
	_state.file_changed.connect(_on_file_changed)
	_build_ui()


func _on_file_changed() -> void:
	if not _current_id.is_empty():
		_id_label.text = "%s — project changed; review before saving" % _current_id


func _clear_fields() -> void:
	_loading = true
	_title_edit.text = ""
	_type_option.selected = 0
	_rebuild_status_options(_get_type_name(0))
	_priority_option.selected = 0
	_severity_option.selected = 0
	_assigned_edit.text = ""
	_tags_edit.text = ""
	_desc_edit.text = ""
	_loaded_revision = ""
	_loaded_item_token = ""
	if _dynamic_fields != null:
		_dynamic_fields.load_definition({"fields":[]})
	# Clear all mapped fields
	for entry in _field_map:
		var edit = entry[2]
		if edit is SpinBox:
			edit.value = 0
		else:
			edit.text = ""
	# Non-mapped fields
	_parent_edit.text = ""
	_identity_edit.text = ""
	_secret_value_edit.text = ""
	_secret_value_edit.secret = true
	_secret_show_btn.text = "Show"
	_secret_value_decrypted = ""
	_secret_2fa_check.button_pressed = false
	_secret_vault_error_label.text = ""
	_secret_vault_error_label.visible = false
	_encrypted_notes_edit.text = ""
	_encrypted_notes_decrypted = ""
	_encrypted_notes_show_btn.text = "Show"
	for child in _secret_history_container.get_children():
		child.queue_free()
	_hide_all_optional_fields()
	for child in _transition_bar.get_children():
		child.queue_free()
	_events_list.clear()
	_loading = false


func _build_ui() -> void:
	# Back button row (outside scroll — always visible)
	var back_bar := HBoxContainer.new()
	_back_btn = Button.new()
	_back_btn.text = "<  Back"
	_back_btn.pressed.connect(func(): back_pressed.emit())
	back_bar.add_child(_back_btn)
	add_child(back_bar)

	# Header (outside scroll — always visible)
	var header := HBoxContainer.new()
	_id_label = Label.new()
	_id_label.text = "(select or create an item)"
	_id_label.add_theme_font_size_override("font_size", 16)
	header.add_child(_id_label)
	_project_label = Label.new()
	_project_label.text = ""
	_project_label.add_theme_font_size_override("font_size", 13)
	_project_label.add_theme_color_override("font_color", Color(0.45, 0.7, 0.9))
	header.add_child(_project_label)
	add_child(header)

	# Title row (outside scroll — always visible)
	_title_edit = LineEdit.new()
	_title_edit.placeholder_text = "Item title"
	_title_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_title_edit)

	# Outer scroll wraps everything below the title so nothing is clipped
	var _body_scroll := ScrollContainer.new()
	_body_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_body_scroll)

	_body_vbox = VBoxContainer.new()
	_body_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_scroll.add_child(_body_vbox)

	# Scrollable fields area (resizable via top drag handle)
	_fields_scroll = ScrollContainer.new()
	_fields_scroll.custom_minimum_size.y = 160
	_fields_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_body_vbox.add_child(_fields_scroll)

	var fields_vbox := VBoxContainer.new()
	fields_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_scroll.add_child(fields_vbox)

	# Type / Status / Severity / Priority on one line
	var meta_row := HBoxContainer.new()
	meta_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	meta_row.add_child(_make_inline_label("Type:"))
	_type_option = OptionButton.new()
	_type_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_type_option.item_selected.connect(_on_type_changed)
	meta_row.add_child(_type_option)
	var initial_project := _state.db.get_project_name() if _state.db != null else ""
	_rebuild_type_options(initial_project)

	meta_row.add_child(_make_inline_label("Status:"))
	_status_option = OptionButton.new()
	_status_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_option.item_selected.connect(_on_status_changed)
	meta_row.add_child(_status_option)

	meta_row.add_child(_make_inline_label("Sev:"))
	_severity_option = OptionButton.new()
	for i in range(5):
		_severity_option.add_item(str(i), i)
	meta_row.add_child(_severity_option)

	meta_row.add_child(_make_inline_label("Pri:"))
	_priority_option = OptionButton.new()
	for i in range(5):
		_priority_option.add_item(str(i), i)
	meta_row.add_child(_priority_option)

	# Project selector (visible when 2+ projects loaded)
	_project_option = OptionButton.new()
	_project_option.visible = false
	_project_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_project_option.size_flags_stretch_ratio = 0.5
	_project_option.item_selected.connect(_on_draft_project_changed)
	_project_inline_label = _make_inline_label("Project:")
	_project_inline_label.visible = false
	meta_row.add_child(_project_inline_label)
	meta_row.add_child(_project_option)

	fields_vbox.add_child(meta_row)

	# Remaining fields grid (2-column)
	_fields_grid = GridContainer.new()
	_fields_grid.columns = 2

	_add_label("Assigned:")
	_assigned_edit = LineEdit.new()
	_assigned_edit.placeholder_text = "Person assigned"
	_assigned_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_assigned_edit)

	_add_label("Tags:")
	_tags_edit = LineEdit.new()
	_tags_edit.placeholder_text = "comma,separated"
	_tags_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_tags_edit)

	_add_label("Parent:")
	_parent_edit = LineEdit.new()
	_parent_edit.placeholder_text = "DKT-0009"
	_parent_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_parent_edit)

	# Type-adaptive optional fields (hidden by default)
	_resolution_label = _add_label_ref("Resolution:")
	_resolution_edit = LineEdit.new()
	_resolution_edit.placeholder_text = "fixed, wont_fix, by_design, duplicate, not_repro"
	_resolution_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_resolution_edit)

	_environment_label = _add_label_ref("Environment:")
	_environment_edit = LineEdit.new()
	_environment_edit.placeholder_text = "OS, browser, version..."
	_environment_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_environment_edit)

	_assumed_label = _add_label_ref("Assumed:")
	_assumed_edit = LineEdit.new()
	_assumed_edit.placeholder_text = "What was believed to be true"
	_assumed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_assumed_edit)

	_corrected_label = _add_label_ref("Corrected:")
	_corrected_edit = LineEdit.new()
	_corrected_edit.placeholder_text = "What turned out to be true"
	_corrected_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_corrected_edit)

	_occurred_at_label = _add_label_ref("Occurred At:")
	_occurred_at_edit = LineEdit.new()
	_occurred_at_edit.placeholder_text = "YYYY-MM-DD"
	_occurred_at_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_occurred_at_edit)

	_detected_at_label = _add_label_ref("Detected At:")
	_detected_at_edit = LineEdit.new()
	_detected_at_edit.placeholder_text = "YYYY-MM-DD"
	_detected_at_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_detected_at_edit)

	_reported_at_label = _add_label_ref("Reported At:")
	_reported_at_edit = LineEdit.new()
	_reported_at_edit.placeholder_text = "YYYY-MM-DD"
	_reported_at_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_reported_at_edit)

	_component_label = _add_label_ref("Component:")
	_component_edit = LineEdit.new()
	_component_edit.placeholder_text = "e.g. docket, godot, build"
	_component_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_component_edit)

	_key_label = _add_label_ref("Key:")
	_key_edit = LineEdit.new()
	_key_edit.placeholder_text = "e.g. test, build, path"
	_key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_key_edit)

	_topic_label = _add_label_ref("Topic:")
	_topic_edit = LineEdit.new()
	_topic_edit.placeholder_text = "e.g. architecture, workflow, debugging"
	_topic_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_topic_edit)

	_subtopic_label = _add_label_ref("Subtopic:")
	_subtopic_edit = LineEdit.new()
	_subtopic_edit.placeholder_text = "e.g. state-machine, column-resize"
	_subtopic_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_subtopic_edit)

	_retrieval_count_label = _add_label_ref("Retrievals:")
	_retrieval_count_spin = SpinBox.new()
	_retrieval_count_spin.min_value = 0
	_retrieval_count_spin.max_value = 99999
	_fields_grid.add_child(_retrieval_count_spin)

	_research_cost_label = _add_label_ref("Research Cost:")
	_research_cost_spin = SpinBox.new()
	_research_cost_spin.min_value = 0
	_research_cost_spin.max_value = 99999
	_research_cost_spin.suffix = " turns"
	_fields_grid.add_child(_research_cost_spin)

	_confidence_label = _add_label_ref("Confidence:")
	_confidence_spin = SpinBox.new()
	_confidence_spin.min_value = 0
	_confidence_spin.max_value = 100
	_confidence_spin.suffix = "%"
	_fields_grid.add_child(_confidence_spin)

	_surprise_label = _add_label_ref("Surprise:")
	_surprise_spin = SpinBox.new()
	_surprise_spin.min_value = 0
	_surprise_spin.max_value = 100
	_surprise_spin.suffix = "%"
	_fields_grid.add_child(_surprise_spin)

	_surfaced_from_label = _add_label_ref("Surfaced From:")
	_surfaced_from_edit = LineEdit.new()
	_surfaced_from_edit.placeholder_text = "e.g. debugging, code review, incident"
	_surfaced_from_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_surfaced_from_edit)

	_blocked_by_label = _add_label_ref("Blocked By:")
	_blocked_by_edit = LineEdit.new()
	_blocked_by_edit.placeholder_text = "DKT-0042 or project:DKT-0042"
	_blocked_by_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_blocked_by_edit)

	_identity_label = _add_label_ref("Identity:")
	_identity_edit = LineEdit.new()
	_identity_edit.placeholder_text = "username or email"
	_identity_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_grid.add_child(_identity_edit)

	fields_vbox.add_child(_fields_grid)
	_dynamic_fields = DynamicFieldEditor.new()
	fields_vbox.add_child(_dynamic_fields)

	# Description - top drag handle (resizes fields scroll area)
	var _desc_drag_top := Control.new()
	_desc_drag_top.custom_minimum_size = Vector2(0, 8)
	_desc_drag_top.mouse_default_cursor_shape = Control.CURSOR_VSIZE
	_desc_drag_top.gui_input.connect(_on_desc_drag_top_input)
	_body_vbox.add_child(_desc_drag_top)

	_add_section_label("Description")
	_desc_edit = TextEdit.new()
	_desc_edit.custom_minimum_size.y = 80
	_desc_edit.placeholder_text = "Describe the item..."
	_desc_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_desc_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_desc_edit)

	# Drag handle for resizing description
	_desc_drag = Control.new()
	_desc_drag.custom_minimum_size = Vector2(0, 8)
	_desc_drag.mouse_default_cursor_shape = Control.CURSOR_VSIZE
	_desc_drag.gui_input.connect(_on_desc_drag_input)
	_body_vbox.add_child(_desc_drag)

	# Value (multi-line, for Hint type)
	_value_label = Label.new()
	_value_label.text = "Value"
	_value_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_value_label)
	_value_edit = TextEdit.new()
	_value_edit.custom_minimum_size.y = 80
	_value_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_value_edit.placeholder_text = "The actionable fact or command..."
	_value_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_value_edit)

	# Repro Steps (multi-line, for Bug type)
	_repro_steps_label = Label.new()
	_repro_steps_label.text = "Repro Steps"
	_repro_steps_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_repro_steps_label)
	_repro_steps_edit = TextEdit.new()
	_repro_steps_edit.custom_minimum_size.y = 80
	_repro_steps_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_repro_steps_edit.placeholder_text = "1. ...\n2. ...\n3. ..."
	_repro_steps_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_repro_steps_edit)

	# Test Setup (multi-line, for Test type)
	_test_setup_label = Label.new()
	_test_setup_label.text = "Test Setup"
	_test_setup_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_test_setup_label)
	_test_setup_edit = TextEdit.new()
	_test_setup_edit.custom_minimum_size.y = 80
	_test_setup_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_test_setup_edit.placeholder_text = "Conda env, libraries, resources..."
	_test_setup_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_test_setup_edit)

	# Test Steps (multi-line, for Test type)
	_test_steps_label = Label.new()
	_test_steps_label.text = "Test Steps"
	_test_steps_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_test_steps_label)
	_test_steps_edit = TextEdit.new()
	_test_steps_edit.custom_minimum_size.y = 80
	_test_steps_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_test_steps_edit.placeholder_text = "1. ...\n2. ...\n3. ..."
	_test_steps_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_test_steps_edit)

	# Expected Result (multi-line, for Test type)
	_expected_result_label = Label.new()
	_expected_result_label.text = "Expected Result"
	_expected_result_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_expected_result_label)
	_expected_result_edit = TextEdit.new()
	_expected_result_edit.custom_minimum_size.y = 80
	_expected_result_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_expected_result_edit.placeholder_text = "Expected outcome..."
	_expected_result_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_expected_result_edit)

	# Findings (research summary, for Question type)
	_findings_label = Label.new()
	_findings_label.text = "Findings"
	_findings_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_findings_label)
	_findings_edit = TextEdit.new()
	_findings_edit.custom_minimum_size.y = 80
	_findings_edit.placeholder_text = "Research findings so far..."
	_findings_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_findings_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_findings_edit)

	# Answer (larger text area, for Question type)
	_answer_label = Label.new()
	_answer_label.text = "Answer"
	_answer_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_answer_label)
	_answer_edit = TextEdit.new()
	_answer_edit.custom_minimum_size.y = 80
	_answer_edit.placeholder_text = "Answer to the question..."
	_answer_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_answer_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_answer_edit)

	# Why Chain (multi-line, for RCA type)
	_why_chain_label = Label.new()
	_why_chain_label.text = "Why Chain"
	_why_chain_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_why_chain_label)
	_why_chain_edit = TextEdit.new()
	_why_chain_edit.custom_minimum_size.y = 80
	_why_chain_edit.placeholder_text = "Why? → Because... → Why? → Because..."
	_why_chain_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_why_chain_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_why_chain_edit)

	# Contributing Factors (multi-line, for RCA type)
	_contributing_factors_label = Label.new()
	_contributing_factors_label.text = "Contributing Factors"
	_contributing_factors_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_contributing_factors_label)
	_contributing_factors_edit = TextEdit.new()
	_contributing_factors_edit.custom_minimum_size.y = 80
	_contributing_factors_edit.placeholder_text = "Factors that contributed to the issue..."
	_contributing_factors_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_contributing_factors_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_contributing_factors_edit)

	# Significant Events (multi-line, for RCA type)
	_significant_events_label = Label.new()
	_significant_events_label.text = "Significant Events"
	_significant_events_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_significant_events_label)
	_significant_events_edit = TextEdit.new()
	_significant_events_edit.custom_minimum_size.y = 80
	_significant_events_edit.placeholder_text = "Key events in the timeline..."
	_significant_events_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_significant_events_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_significant_events_edit)

	# Secret Value section (for Secret type)
	_secret_value_label = Label.new()
	_secret_value_label.text = "Secret Value"
	_secret_value_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_secret_value_label)

	_secret_value_container = HBoxContainer.new()
	_secret_value_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_secret_value_edit = LineEdit.new()
	_secret_value_edit.secret = true
	_secret_value_edit.placeholder_text = "Secret value (encrypted at rest)"
	_secret_value_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_secret_value_container.add_child(_secret_value_edit)

	_secret_show_btn = Button.new()
	_secret_show_btn.text = "Show"
	_secret_show_btn.toggle_mode = true
	_secret_show_btn.pressed.connect(_on_secret_show_toggle)
	_secret_value_container.add_child(_secret_show_btn)

	_secret_copy_btn = Button.new()
	_secret_copy_btn.text = "Copy"
	_secret_copy_btn.pressed.connect(_on_secret_copy)
	_secret_value_container.add_child(_secret_copy_btn)

	_secret_generate_btn = Button.new()
	_secret_generate_btn.text = "Generate"
	_secret_generate_btn.pressed.connect(_on_secret_generate)
	_secret_value_container.add_child(_secret_generate_btn)
	_body_vbox.add_child(_secret_value_container)

	# 2FA checkbox
	_secret_2fa_check = CheckBox.new()
	_secret_2fa_check.text = "Requires secondary password"
	_body_vbox.add_child(_secret_2fa_check)

	# Vault error label
	_secret_vault_error_label = Label.new()
	_secret_vault_error_label.text = ""
	_secret_vault_error_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
	_secret_vault_error_label.visible = false
	_body_vbox.add_child(_secret_vault_error_label)

	# Encrypted Notes section (for Secret and Encrypted Note types)
	_encrypted_notes_label = Label.new()
	_encrypted_notes_label.text = "Encrypted Notes"
	_encrypted_notes_label.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(_encrypted_notes_label)

	_encrypted_notes_edit = TextEdit.new()
	_encrypted_notes_edit.custom_minimum_size.y = 80
	_encrypted_notes_edit.placeholder_text = "Encrypted text (stored securely)..."
	_encrypted_notes_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_encrypted_notes_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_encrypted_notes_edit)

	var enc_notes_btns := HBoxContainer.new()
	_encrypted_notes_show_btn = Button.new()
	_encrypted_notes_show_btn.text = "Show"
	_encrypted_notes_show_btn.toggle_mode = true
	_encrypted_notes_show_btn.pressed.connect(_on_encrypted_notes_show_toggle)
	enc_notes_btns.add_child(_encrypted_notes_show_btn)

	_encrypted_notes_copy_btn = Button.new()
	_encrypted_notes_copy_btn.text = "Copy"
	_encrypted_notes_copy_btn.pressed.connect(_on_encrypted_notes_copy)
	enc_notes_btns.add_child(_encrypted_notes_copy_btn)
	_body_vbox.add_child(enc_notes_btns)

	# Secret version history (collapsible, for Secret type)
	_secret_history_toggle = Button.new()
	_secret_history_toggle.text = "> Version History"
	_secret_history_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_secret_history_toggle.flat = true
	_secret_history_toggle.add_theme_font_size_override("font_size", 14)
	_secret_history_toggle.pressed.connect(_on_secret_history_toggle)
	_body_vbox.add_child(_secret_history_toggle)

	_secret_history_container = VBoxContainer.new()
	_secret_history_container.visible = false
	_body_vbox.add_child(_secret_history_container)

	# Steps (multi-line, for skill type — the main pipeline content)
	_steps_label = Label.new()
	_steps_label.text = "Steps"
	_steps_label.add_theme_font_size_override("font_size", 14)
	_steps_label.tooltip_text = "The executable pipeline — ordered commands/actions for an LLM to follow"
	_body_vbox.add_child(_steps_label)
	_steps_edit = TextEdit.new()
	_steps_edit.custom_minimum_size.y = 200
	_steps_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_steps_edit.placeholder_text = "Step 1: ...\nStep 2: ...\nStep 3: ..."
	_steps_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_steps_edit)

	# Outcome (multi-line, for skill type)
	_outcome_label = Label.new()
	_outcome_label.text = "Outcome"
	_outcome_label.add_theme_font_size_override("font_size", 14)
	_outcome_label.tooltip_text = "What success looks like when the skill completes"
	_body_vbox.add_child(_outcome_label)
	_outcome_edit = TextEdit.new()
	_outcome_edit.custom_minimum_size.y = 60
	_outcome_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_outcome_edit.placeholder_text = "Expected deliverables or end state..."
	_outcome_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_outcome_edit)

	# Command (multi-line, for skill type)
	_command_label = Label.new()
	_command_label.text = "Command"
	_command_label.add_theme_font_size_override("font_size", 14)
	_command_label.tooltip_text = "The executable command, script, or code snippet"
	_body_vbox.add_child(_command_label)
	_command_edit = TextEdit.new()
	_command_edit.custom_minimum_size.y = 80
	_command_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_command_edit.placeholder_text = "The command or code snippet..."
	_command_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_command_edit)

	# Usage (single-line, for skill type)
	_usage_label = Label.new()
	_usage_label.text = "Usage"
	_usage_label.add_theme_font_size_override("font_size", 14)
	_usage_label.tooltip_text = "How to invoke — like a man page synopsis"
	_body_vbox.add_child(_usage_label)
	_usage_edit = LineEdit.new()
	_usage_edit.placeholder_text = "e.g. cmd [options] <arg>"
	_usage_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_vbox.add_child(_usage_edit)

	# Prompt Text (multi-line, for prompt type)
	_prompt_text_label = Label.new()
	_prompt_text_label.text = "Prompt Text"
	_prompt_text_label.add_theme_font_size_override("font_size", 14)
	_prompt_text_label.tooltip_text = "Instruction text for an agent or LLM"
	_body_vbox.add_child(_prompt_text_label)
	_prompt_text_edit = TextEdit.new()
	_prompt_text_edit.custom_minimum_size.y = 80
	_prompt_text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_prompt_text_edit.placeholder_text = "The prompt or instruction text..."
	_prompt_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_prompt_text_edit)

	# Preconditions (multi-line, for skill type)
	_preconditions_label = Label.new()
	_preconditions_label.text = "Preconditions"
	_preconditions_label.add_theme_font_size_override("font_size", 14)
	_preconditions_label.tooltip_text = "What must be true before using this skill"
	_body_vbox.add_child(_preconditions_label)
	_preconditions_edit = TextEdit.new()
	_preconditions_edit.custom_minimum_size.y = 80
	_preconditions_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preconditions_edit.placeholder_text = "Requirements before invoking this skill..."
	_preconditions_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_preconditions_edit)

	# Parameters (single-line, for prompt type)
	_parameters_label = Label.new()
	_parameters_label.text = "Parameters"
	_parameters_label.add_theme_font_size_override("font_size", 14)
	_parameters_label.tooltip_text = "Variables or placeholders in the prompt, e.g. {{language}}"
	_body_vbox.add_child(_parameters_label)
	_parameters_edit = LineEdit.new()
	_parameters_edit.placeholder_text = "e.g. {{language}}, {{topic}}"
	_parameters_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_vbox.add_child(_parameters_edit)

	# Article (multi-line, for kb type)
	_article_label = Label.new()
	_article_label.text = "Article"
	_article_label.add_theme_font_size_override("font_size", 14)
	_article_label.tooltip_text = "The full article body (long-form content)"
	_body_vbox.add_child(_article_label)
	_article_edit = TextEdit.new()
	_article_edit.custom_minimum_size.y = 200
	_article_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_article_edit.placeholder_text = "Article body (markdown supported)..."
	_article_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_article_edit)

	# Summary (multi-line, for kb type)
	_summary_label = Label.new()
	_summary_label.text = "Summary"
	_summary_label.add_theme_font_size_override("font_size", 14)
	_summary_label.tooltip_text = "Short preview (1-2 sentences) for search results"
	_body_vbox.add_child(_summary_label)
	_summary_edit = TextEdit.new()
	_summary_edit.custom_minimum_size.y = 80
	_summary_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_edit.placeholder_text = "Brief summary for search results..."
	_summary_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body_vbox.add_child(_summary_edit)

	# 2FA dialog (shown on demand)
	_secret_2fa_dialog = ConfirmationDialog.new()
	_secret_2fa_dialog.title = "Secondary Password Required"
	_secret_2fa_dialog.ok_button_text = "Unlock"
	var dialog_vbox := VBoxContainer.new()
	var dialog_label := Label.new()
	dialog_label.text = "Enter secondary password:"
	dialog_vbox.add_child(dialog_label)
	_secret_2fa_input = LineEdit.new()
	_secret_2fa_input.secret = true
	_secret_2fa_input.placeholder_text = "Secondary password"
	dialog_vbox.add_child(_secret_2fa_input)
	_secret_2fa_dialog.add_child(dialog_vbox)

	_hide_all_optional_fields()

	# Save + Move buttons row
	var save_row := HBoxContainer.new()
	var save_btn := Button.new()
	save_btn.text = "Save Changes"
	save_btn.pressed.connect(_save_changes)
	save_row.add_child(save_btn)

	_move_btn = Button.new()
	_move_btn.text = "Move to..."
	_move_btn.visible = false
	_move_btn.pressed.connect(_on_move_pressed)
	save_row.add_child(_move_btn)
	_body_vbox.add_child(save_row)

	# Children (collapsible)
	_children_toggle = Button.new()
	_children_toggle.text = "> Children"
	_children_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_children_toggle.flat = true
	_children_toggle.add_theme_font_size_override("font_size", 14)
	_children_toggle.pressed.connect(_on_children_toggle)
	_body_vbox.add_child(_children_toggle)

	_children_container = VBoxContainer.new()
	_children_container.visible = false
	_body_vbox.add_child(_children_container)

	_children_list = ItemList.new()
	_children_list.auto_height = true
	_children_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_children_list.item_activated.connect(_on_child_activated)
	_children_container.add_child(_children_list)

	# Comments (collapsible)
	_comments_toggle = Button.new()
	_comments_toggle.text = "> Comments"
	_comments_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_comments_toggle.flat = true
	_comments_toggle.add_theme_font_size_override("font_size", 14)
	_comments_toggle.pressed.connect(_on_comments_toggle)
	_body_vbox.add_child(_comments_toggle)

	_comments_container = VBoxContainer.new()
	_comments_container.visible = false
	_body_vbox.add_child(_comments_container)

	_comments_list = VBoxContainer.new()
	_comments_container.add_child(_comments_list)

	var comment_input_row := HBoxContainer.new()
	comment_input_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_comment_input = TextEdit.new()
	_comment_input.custom_minimum_size = Vector2(0, 40)
	_comment_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_comment_input.placeholder_text = "Add a comment..."
	_comment_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	comment_input_row.add_child(_comment_input)
	_comment_add_btn = Button.new()
	_comment_add_btn.text = "Add"
	_comment_add_btn.pressed.connect(_on_add_comment)
	comment_input_row.add_child(_comment_add_btn)
	_comments_container.add_child(comment_input_row)

	# Transitions + Events (collapsible)
	_events_toggle = Button.new()
	_events_toggle.text = "> Transitions & Events"
	_events_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_events_toggle.flat = true
	_events_toggle.add_theme_font_size_override("font_size", 14)
	_events_toggle.pressed.connect(_on_events_toggle)
	_body_vbox.add_child(_events_toggle)

	_events_container = VBoxContainer.new()
	_events_container.visible = false
	_body_vbox.add_child(_events_container)

	_transition_bar = HBoxContainer.new()
	_events_container.add_child(_transition_bar)

	_events_list = ItemList.new()
	_events_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_events_list.auto_height = true
	_events_container.add_child(_events_list)

	# Build the field descriptor table — each entry is [field_name, label, edit_widget].
	# Used by _hide_all_optional_fields, _update_field_visibility, _save_changes, etc.
	_field_map = [
		["resolution", _resolution_label, _resolution_edit],
		["environment", _environment_label, _environment_edit],
		["assumed", _assumed_label, _assumed_edit],
		["corrected", _corrected_label, _corrected_edit],
		["occurred_at", _occurred_at_label, _occurred_at_edit],
		["detected_at", _detected_at_label, _detected_at_edit],
		["reported_at", _reported_at_label, _reported_at_edit],
		["why_chain", _why_chain_label, _why_chain_edit],
		["contributing_factors", _contributing_factors_label, _contributing_factors_edit],
		["significant_events", _significant_events_label, _significant_events_edit],
		["repro_steps", _repro_steps_label, _repro_steps_edit],
		["findings", _findings_label, _findings_edit],
		["answer", _answer_label, _answer_edit],
		["test_setup", _test_setup_label, _test_setup_edit],
		["test_steps", _test_steps_label, _test_steps_edit],
		["expected_result", _expected_result_label, _expected_result_edit],
		["value", _value_label, _value_edit],
		["component", _component_label, _component_edit],
		["key", _key_label, _key_edit],
		["topic", _topic_label, _topic_edit],
		["subtopic", _subtopic_label, _subtopic_edit],
		["retrieval_count", _retrieval_count_label, _retrieval_count_spin],
		["research_cost", _research_cost_label, _research_cost_spin],
		["confidence", _confidence_label, _confidence_spin],
		["surprise", _surprise_label, _surprise_spin],
		["surfaced_from", _surfaced_from_label, _surfaced_from_edit],
		["blocked_by", _blocked_by_label, _blocked_by_edit],
		["steps", _steps_label, _steps_edit],
		["outcome", _outcome_label, _outcome_edit],
		["command", _command_label, _command_edit],
		["usage", _usage_label, _usage_edit],
		["prompt_text", _prompt_text_label, _prompt_text_edit],
		["preconditions", _preconditions_label, _preconditions_edit],
		["parameters", _parameters_label, _parameters_edit],
		["article", _article_label, _article_edit],
		["summary", _summary_label, _summary_edit],
	]


func _make_inline_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	return lbl


func _add_label(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	_fields_grid.add_child(lbl)


func _add_label_ref(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	_fields_grid.add_child(lbl)
	return lbl


func _add_section_label(text: String) -> void:
	var sep := HSeparator.new()
	_body_vbox.add_child(sep)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	_body_vbox.add_child(lbl)


# -- Project selector helpers -----------------------------------------------

func _rebuild_project_options() -> void:
	_project_option.clear()
	if _state._project_dbs.size() <= 1:
		_project_option.visible = false
		_project_inline_label.visible = false
		return
	_project_option.visible = true
	_project_inline_label.visible = true
	for proj_name in _state._project_dbs:
		_project_option.add_item(proj_name)


func _get_selected_project_db() -> DocketDB:
	if _state._project_dbs.size() <= 1:
		return _state.db
	if _project_option.item_count == 0:
		return _state.db
	var proj_name: String = _project_option.get_item_text(_project_option.selected)
	var pdb: DocketDB = _state.get_db_for_project(proj_name)
	return pdb if pdb else _state.db


# -- Type / status helpers -------------------------------------------------

func _get_type_name(idx: int) -> String:
	return str(_type_option.get_item_metadata(idx)) if idx >= 0 and idx < _type_option.item_count else ""

func _rebuild_type_options(project: String, selected_slug: String = "") -> void:
	_type_option.clear()
	var registry := _state.get_type_registry(project)
	if registry == null:
		return
	for type_value in registry.list_types(false):
		var type: Dictionary = type_value
		if type.has("error") or (type.lifecycle != "active" and type.slug != selected_slug):
			continue
		if type.slug != selected_slug and not bool(type.definition.get("protected_behavior", {}).get("regular_creation_allowed", true)):
			continue
		_type_option.add_item(str(type.label))
		_type_option.set_item_metadata(_type_option.item_count - 1, type.slug)
		if type.slug == selected_slug:
			_type_option.select(_type_option.item_count - 1)

func _on_draft_project_changed(_index: int) -> void:
	if not _is_draft or _loading:
		return
	var previous := _get_type_name(_type_option.selected)
	var project := _project_option.get_item_text(_project_option.selected)
	_rebuild_type_options(project, previous)
	if _type_option.item_count == 0 or _get_type_name(_type_option.selected) != previous:
		_id_label.text = "(new — unsaved) Draft retained, but type '%s' is unavailable in %s. Choose a compatible project or type before saving." % [previous, project]
		return
	_on_type_changed(_type_option.selected)


func _select_type_by_name(type_name: String) -> void:
	for i in range(_type_option.item_count):
		if _type_option.get_item_text(i) == type_name:
			_type_option.selected = i
			return


func _rebuild_status_options(type_name: String) -> void:
	_status_option.clear()
	var project := _current_project
	if project.is_empty() and _project_option.item_count > 0:
		project = _project_option.get_item_text(_project_option.selected)
	if project.is_empty() and _state.db != null:
		project = _state.db.get_project_name()
	var registry := _state.get_type_registry(project)
	if registry == null:
		return
	var type: Dictionary = registry.get_type(type_name)
	if type.has("error"):
		return
	for state_value in type.definition.lifecycle.states:
		var state: Dictionary = state_value
		_status_option.add_item(str(state.get("label", state.key)))
		_status_option.set_item_metadata(_status_option.item_count - 1, state.key)


func _select_status_by_name(status_name: String) -> void:
	for i in range(_status_option.item_count):
		if str(_status_option.get_item_metadata(i)) == status_name:
			_status_option.selected = i
			return


func _on_type_changed(idx: int) -> void:
	if _loading:
		return
	var new_type := _get_type_name(idx)
	_rebuild_status_options(new_type)
	_update_field_visibility(new_type)


func _on_status_changed(_idx: int) -> void:
	if _loading:
		return
	# Status dropdown change is applied on save, no immediate side-effects needed.
	pass


# -- Field visibility ------------------------------------------------------

func _hide_all_optional_fields() -> void:
	for entry in _field_map:
		entry[1].visible = false  # label
		entry[2].visible = false  # edit widget
	# Secret-specific fields (not in _field_map — completely custom UI)
	_set_field_pair_visible(_identity_label, _identity_edit, false)
	_secret_value_label.visible = false
	_secret_value_container.visible = false
	_secret_2fa_check.visible = false
	_secret_vault_error_label.visible = false
	_encrypted_notes_label.visible = false
	_encrypted_notes_edit.visible = false
	_encrypted_notes_show_btn.get_parent().visible = false
	_secret_history_toggle.visible = false
	_secret_history_container.visible = false


func _set_field_pair_visible(label: Label, edit: Control, vis: bool) -> void:
	label.visible = vis
	edit.visible = vis


func _update_field_visibility(type_name: String) -> void:
	_hide_all_optional_fields()
	if type_name == "encrypted_note":
		_encrypted_notes_label.text = "Encrypted Body"
		_encrypted_notes_label.visible = true
		_encrypted_notes_edit.visible = true
		_encrypted_notes_show_btn.get_parent().visible = true
		return
	if type_name != "secret":
		_encrypted_notes_label.text = "Encrypted Notes"
		return
	if not _state.schema.types.has(type_name):
		return
	var opt_fields: Array = _state.schema.types[type_name].optional_fields
	var req_fields: Array = _state.schema.types[type_name].get("required_fields", [])

	for entry in _field_map:
		var field_name: String = entry[0]
		if opt_fields.has(field_name) or req_fields.has(field_name):
			entry[1].visible = true  # label
			entry[2].visible = true  # edit widget

	# Secret type: relabel fields and show secret-specific UI
	if type_name == "secret":
		_surfaced_from_label.visible = false
		_surfaced_from_edit.visible = false
		_environment_label.text = "Where:"
		_set_field_pair_visible(_environment_label, _environment_edit, true)
		_environment_edit.placeholder_text = "URL or location (e.g. mail.aol.com)"
		_set_field_pair_visible(_identity_label, _identity_edit, true)
		_key_label.text = "Secret Name:"
		_set_field_pair_visible(_key_label, _key_edit, true)
		_key_edit.placeholder_text = "e.g. password, API key"
		_secret_value_label.visible = true
		_secret_value_container.visible = true
		_secret_2fa_check.visible = true
		_encrypted_notes_label.visible = true
		_encrypted_notes_edit.visible = true
		_encrypted_notes_show_btn.get_parent().visible = true
		_secret_history_toggle.visible = true
	else:
		# Reset labels to defaults
		_environment_label.text = "Environment:"
		_environment_edit.placeholder_text = "OS, browser, version..."
		_key_label.text = "Key:"
		_key_edit.placeholder_text = "e.g. test, build, path"

	# Encrypted Note type: show encrypted notes as main body
	if type_name == "encrypted_note":
		_encrypted_notes_label.text = "Encrypted Body"
		_encrypted_notes_label.visible = true
		_encrypted_notes_edit.visible = true
		_encrypted_notes_show_btn.get_parent().visible = true
	elif type_name != "secret":
		_encrypted_notes_label.text = "Encrypted Notes"

	# surfaced_from shown for insight via _surfaced_from_edit, for secret via _identity_edit


# -- Load / Save -----------------------------------------------------------

func get_current_id() -> String:
	## ID of the item currently being edited, or "" for a draft or empty form.
	## Drafts return "" deliberately: they do not exist on disk, so an external
	## change can never conflict with them.
	if _is_draft:
		return ""
	return _current_id

func get_current_project() -> String:
	return _current_project

func attach_to_current(filename: String, data: PackedByteArray, mime: String = "application/octet-stream", description: String = "") -> Dictionary:
	if _current_id.is_empty() or _current_project.is_empty():
		return {"error":"no project-scoped item is open"}
	var item_db: DocketDB = _state.get_db_for_project(_current_project)
	if item_db == null or not item_db.has_item(_current_id):
		return {"error":"originating project is closed or item is missing"}
	return item_db.attach_file(_current_id, filename, data, mime, description)


func load_item(id: String, project: String = "") -> void:
	_loading = true
	_current_id = id
	_is_draft = false
	_draft_item = {}

	# Search across all project DBs for the item
	var item_db: DocketDB = _state.get_db_for_project(project) if not project.is_empty() else null
	if item_db == null:
		_id_label.text = "(item not found)"
		_project_label.text = ""
		_current_project = ""
		_loading = false
		return

	_current_project = project
	_project_option.visible = false  # Hide selector for existing items
	_project_inline_label.visible = false
	# Show Move button when 2+ projects and item is saved
	_move_btn.visible = _state._project_dbs.size() > 1
	var item: Dictionary = item_db.get_item(id)
	var registry := _state.get_type_registry(_current_project)
	if registry == null:
		_id_label.text = "(type registry unavailable)"
		_loading = false
		return
	var resolved: Dictionary = registry.resolve_item(item)
	if resolved.has("error"):
		_id_label.text = "%s — %s" % [id, resolved.error]
		_loading = false
		return
	_loaded_revision = str(item.get("type_revision", resolved.revision.id))
	_loaded_item_token = registry.item_token(item)
	# Display short ID for UUID7, full for legacy
	if DocketDB._is_uuid7(id):
		_id_label.text = item_db.short_id(id)
		_id_label.tooltip_text = id
	else:
		_id_label.text = id
		_id_label.tooltip_text = ""
	# Show project badge when multi-project
	if _state._project_dbs.size() > 1 and not _current_project.is_empty():
		_project_label.text = "  [%s]" % _current_project
	else:
		_project_label.text = ""
	_title_edit.text = str(item.get("title", ""))

	var type_name: String = str(item.get("type", ""))
	_rebuild_type_options(_current_project, type_name)
	_select_type_by_name(type_name)
	_rebuild_status_options(type_name)
	_select_status_by_name(str(item.get("status", "")))

	_priority_option.selected = int(item.get("priority", 0))
	_severity_option.selected = int(item.get("severity", 0))
	_assigned_edit.text = str(item.get("assigned_to", ""))
	_desc_edit.text = str(item.get("description", ""))

	var tags: Array = item.get("tags", [])
	var tag_strings: PackedStringArray = PackedStringArray()
	for t in tags:
		tag_strings.append(str(t))
	_tags_edit.text = ",".join(tag_strings)

	# Type-adaptive fields
	_update_field_visibility(type_name)
	_type_option.disabled = true
	_dynamic_fields.load_definition(resolved.definition, item, true)
	for entry in _field_map:
		var edit = entry[2]
		if edit is SpinBox:
			edit.value = float(item.get(entry[0], 0))
		else:
			edit.text = str(item.get(entry[0], ""))
	_parent_edit.text = str(item.get("parent", ""))

	# Secret type: load identity + decrypt secret value + encrypted notes
	_identity_edit.text = str(item.get("surfaced_from", ""))
	if type_name == "secret":
		_load_secret_value(item_db)
		_load_encrypted_notes(item_db, id + ":notes")
		_populate_secret_history(item_db)
	elif type_name == "encrypted_note":
		_load_encrypted_notes(item_db, id)

	_build_transition_buttons(item)
	_populate_events(item)
	_populate_children()
	# For discussion items, auto-expand comments and enlarge description.
	_desc_edit.custom_minimum_size.y = 200 if type_name == "discussion" else 80
	if type_name == "discussion":
		_comments_container.visible = true
		_comments_toggle.text = "v Comments"
	_populate_comments()
	_loading = false


func load_draft(type_name: String, item: Dictionary, project: String = "") -> void:
	## Load an unsaved draft item into the form. Will be inserted into DB on Save.
	_loading = true
	_is_draft = true
	_draft_item = item.duplicate(true)
	_current_id = ""
	_current_project = ""
	_loaded_revision = ""
	_loaded_item_token = ""
	_id_label.text = "(new — unsaved)"
	_project_label.text = ""
	_rebuild_project_options()
	if not project.is_empty():
		for i in _project_option.item_count:
			if _project_option.get_item_text(i) == project:
				_project_option.select(i)
				break
	var initial_project := _project_option.get_item_text(_project_option.selected) if _project_option.item_count > 0 else (_state.db.get_project_name() if _state.db != null else "")
	_rebuild_type_options(initial_project, type_name)

	_title_edit.text = str(item.get("title", ""))
	_select_type_by_name(type_name)
	_rebuild_status_options(type_name)
	_select_status_by_name(str(item.get("status", "")))

	_priority_option.selected = int(item.get("priority", 0))
	_severity_option.selected = int(item.get("severity", 0))
	_assigned_edit.text = str(item.get("assigned_to", ""))
	_desc_edit.text = str(item.get("description", ""))
	_tags_edit.text = ""

	_update_field_visibility(type_name)
	_type_option.disabled = false
	var draft_project := _project_option.get_item_text(_project_option.selected) if _project_option.item_count > 0 else (_state.db.get_project_name() if _state.db != null else "")
	var draft_registry := _state.get_type_registry(draft_project)
	if draft_registry != null:
		var draft_type: Dictionary = draft_registry.get_type(type_name)
		if not draft_type.has("error"):
			_dynamic_fields.load_definition(draft_type.definition, item, false)
	_resolution_edit.text = ""
	_environment_edit.text = ""
	_repro_steps_edit.text = ""
	_assumed_edit.text = str(item.get("assumed", ""))
	_corrected_edit.text = str(item.get("corrected", ""))
	_findings_edit.text = ""
	_answer_edit.text = ""
	_test_setup_edit.text = ""
	_test_steps_edit.text = ""
	_expected_result_edit.text = ""
	_occurred_at_edit.text = ""
	_detected_at_edit.text = ""
	_reported_at_edit.text = ""
	_why_chain_edit.text = ""
	_contributing_factors_edit.text = ""
	_significant_events_edit.text = ""
	_value_edit.text = str(item.get("value", ""))
	_component_edit.text = ""
	_key_edit.text = ""
	_topic_edit.text = ""
	_subtopic_edit.text = ""
	_retrieval_count_spin.value = 0
	_research_cost_spin.value = 0
	_confidence_spin.value = 0
	_surprise_spin.value = 0
	_surfaced_from_edit.text = ""
	_blocked_by_edit.text = ""
	_parent_edit.text = ""
	_identity_edit.text = ""
	_secret_value_edit.text = ""
	_secret_value_edit.secret = true
	_secret_show_btn.text = "Show"
	_secret_value_decrypted = ""
	_secret_2fa_check.button_pressed = false
	_encrypted_notes_edit.text = ""
	_encrypted_notes_decrypted = ""
	_command_edit.text = ""
	_usage_edit.text = ""
	_prompt_text_edit.text = ""
	_preconditions_edit.text = ""
	_parameters_edit.text = ""
	_article_edit.text = ""
	_summary_edit.text = ""

	# No transitions or events for drafts
	for child in _transition_bar.get_children():
		child.queue_free()
	_events_list.clear()

	# For discussion drafts, auto-expand comments and enlarge description.
	if type_name == "discussion":
		_desc_edit.custom_minimum_size.y = 200
		_comments_container.visible = true
		_comments_toggle.text = "v Comments"
	else:
		_desc_edit.custom_minimum_size.y = 80
		_comments_container.visible = false
		_comments_toggle.text = "> Comments"

	_loading = false


func _build_transition_buttons(item: Dictionary) -> void:
	for child in _transition_bar.get_children():
		child.queue_free()

	var status_str: String = str(item.get("status", ""))
	var registry := _state.get_type_registry(_current_project)
	if registry == null:
		return
	var resolved: Dictionary = registry.resolve_item(item)
	if resolved.has("error"):
		return
	var valid: Array = resolved.definition.lifecycle.transitions.get(status_str, [])
	for target in valid:
		var btn := Button.new()
		btn.text = str(target).capitalize()
		btn.pressed.connect(_on_transition.bind(str(target)))
		_transition_bar.add_child(btn)


func _populate_events(item: Dictionary) -> void:
	_events_list.clear()
	var events: Array = item.get("events", [])
	for i in range(events.size() - 1, -1, -1):
		var ev: Dictionary = events[i]
		var ts: String = str(ev.get("timestamp", ""))
		var etype: String = str(ev.get("event_type", ""))
		var note: String = str(ev.get("note", ""))
		_events_list.add_item("[%s] %s: %s" % [ts, etype, note])


func _save_changes() -> Variant:
	if _is_draft:
		return await _save_draft()
	var item_db: DocketDB = _state.get_db_for_project(_current_project)
	if _current_id.is_empty() or item_db == null:
		_id_label.text = "Save refused: the originating project is closed."
		return
	var registry := _state.get_type_registry(_current_project)
	if registry == null:
		_id_label.text = "Save refused: type registry unavailable."
		return
	var refresh_error := registry.refresh_if_changed()
	if not refresh_error.is_empty():
		_id_label.text = "Save refused: %s" % refresh_error
		return
	var item: Dictionary = item_db.get_item(_current_id)
	if item.is_empty():
		_id_label.text = "Save refused: item no longer exists in %s." % _current_project
		return
	var old_status: String = str(item.get("status", ""))
	var type_name := str(item.get("type", ""))
	var protected := type_name in ["secret", "encrypted_note"]
	var prepared_payload: Dictionary = {"operations":[]}
	if protected:
		prepared_payload = await _prepare_protected_payload(item_db, _current_id, type_name)
	if prepared_payload.has("error"):
		_id_label.text = "Save refused: %s" % prepared_payload.error
		_show_vault_error(str(prepared_payload.error))
		return str(prepared_payload.error)
	var new_status: String = str(_status_option.get_item_metadata(_status_option.selected))
	var changes := _collect_changes()
	if changes.has("error"):
		_id_label.text = "Save refused: %s" % changes.error
		return
	if new_status != old_status:
		var resolved := registry.resolve_item(item)
		if resolved.has("error"):
			_id_label.text = "Save refused: %s" % resolved.error
			return
		var normal := resolved.definition.lifecycle.transitions.get(old_status, []).has(new_status)
		if normal or resolved.definition.lifecycle.enforcement != "guided":
			await _do_status_transition(new_status, "", changes)
		else:
			_prompt_transition_note(new_status, changes)
		return
	var error := registry._begin_item_mutation() if protected else ""
	if error.is_empty():
		error = registry.update_item(_current_id, changes, "user", _loaded_revision, _loaded_item_token)
	if error.is_empty() and protected:
		error = _apply_prepared_payload(item_db, prepared_payload.operations)
	if protected:
		error = registry._complete_item_mutation(error)
	if not error.is_empty():
		_id_label.text = "Save refused: %s" % error
		_show_vault_error(error)
		return error
	_after_shared_save(item_db)
	return ""

func _collect_changes() -> Dictionary:
	var parent_text := _parent_edit.text.strip_edges()
	if not parent_text.is_empty() and not parent_text.contains(":"):
		parent_text = "%s:%s" % [_current_project, parent_text]
	var changes := {"title":_title_edit.text, "description":_desc_edit.text, "priority":_priority_option.selected, "severity":_severity_option.selected, "assigned_to":_assigned_edit.text, "parent":parent_text}
	var tags: Array = []
	for part in _tags_edit.text.split(","):
		if not part.strip_edges().is_empty():
			tags.append(part.strip_edges())
	changes.tags = tags
	var dynamic := _dynamic_fields.collect_patch()
	if dynamic.has("error"):
		return dynamic
	changes.fields = dynamic.fields
	changes.unset_fields = dynamic.unset_fields
	var registry := _state.get_type_registry(_current_project)
	if registry != null:
		var type := registry.get_type(_get_type_name(_type_option.selected))
		if not type.has("error") and bool(type.definition.get("protected", false)):
			for entry in _field_map:
				if not entry[2].visible:
					continue
				changes[entry[0]] = int(entry[2].value) if entry[2] is SpinBox else str(entry[2].text)
			if type.slug == "secret":
				changes.surfaced_from = _identity_edit.text
	return changes

func _after_shared_save(item_db: DocketDB) -> void:
	item_changed.emit()
	load_item(_current_id, _current_project)


func _save_draft() -> Variant:
	var type_name := _get_type_name(_type_option.selected)
	var target_db: DocketDB = _get_selected_project_db()
	var project := target_db.get_project_name()
	_current_project = project
	var registry := _state.get_type_registry(project)
	var fields := _collect_changes()
	if fields.has("error"):
		_id_label.text = "(new) Error: %s" % fields.error
		return str(fields.error)
	fields.type = type_name
	var type_record: Dictionary = registry.get_type(type_name)
	var protected := not type_record.has("error") and bool(type_record.definition.get("protected", false))
	var regular_allowed := bool(type_record.get("definition", {}).get("protected_behavior", {}).get("regular_creation_allowed", true))
	var prepared_payload: Dictionary = {"operations":[]}
	if protected:
		prepared_payload = await _prepare_protected_payload(target_db, "", type_name)
	if prepared_payload.has("error"):
		_id_label.text = "(new) Error: %s" % prepared_payload.error
		return str(prepared_payload.error)
	var transaction_error := registry._begin_item_mutation() if protected else ""
	if not transaction_error.is_empty():
		_id_label.text = "(new) Error: %s" % transaction_error
		return transaction_error
	var created := registry.create_item(fields, "user")
	if created.has("error") and protected and not regular_allowed and type_name in ["secret", "encrypted_note"]:
		created = _create_protected_draft(target_db, type_name, fields)
	if created.has("error"):
		if protected:
			registry._complete_item_mutation(str(created.error))
		_id_label.text = "(new) Error: %s" % created.error
		return str(created.error)
	var id := str(created.id)
	if protected:
		for operation_value in prepared_payload.operations:
			var operation: Dictionary = operation_value
			if str(operation.handle).is_empty():
				operation.handle = id + str(operation.get("suffix", ""))
				operation.owner = id
		transaction_error = _apply_prepared_payload(target_db, prepared_payload.operations)
		transaction_error = registry._complete_item_mutation(transaction_error)
	if not transaction_error.is_empty():
		_id_label.text = "(new) Protected item unchanged: %s" % transaction_error
		_show_vault_error(transaction_error)
		return transaction_error

	_is_draft = false
	_draft_item = {}
	_current_id = id
	item_changed.emit()
	load_item(id, project)
	return ""

func _create_protected_draft(target_db: DocketDB, type_name: String, fields: Dictionary) -> Dictionary:
	var flat := fields.duplicate(true)
	flat.erase("type")
	flat.erase("unset_fields")
	var custom: Dictionary = flat.get("fields", {})
	flat.erase("fields")
	for key in custom:
		flat[key] = custom[key]
	var item := DataModel.create_item(_state.schema, type_name, flat)
	if item.has("error"):
		return item
	var id := target_db.next_uuid7_id()
	var error := target_db.insert_item(id, item)
	if error is String and not error.is_empty():
		return {"error":error}
	return {"id":id, "item":target_db.get_item(id)}


func _on_desc_drag_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_desc_dragging = true
				_desc_drag_start_y = event.global_position.y
				_desc_drag_start_height = _desc_edit.custom_minimum_size.y
			else:
				_desc_dragging = false
	elif event is InputEventMouseMotion and _desc_dragging:
		var delta: float = event.global_position.y - _desc_drag_start_y
		_desc_edit.custom_minimum_size.y = maxf(40, _desc_drag_start_height + delta)


func _on_desc_drag_top_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_desc_drag_top_dragging = true
				_desc_drag_start_y = event.global_position.y
				_desc_drag_start_height = _fields_scroll.custom_minimum_size.y
			else:
				_desc_drag_top_dragging = false
	elif event is InputEventMouseMotion and _desc_drag_top_dragging:
		var delta: float = event.global_position.y - _desc_drag_start_y
		_fields_scroll.custom_minimum_size.y = maxf(60, _desc_drag_start_height + delta)


func _on_children_toggle() -> void:
	_children_container.visible = not _children_container.visible
	if _children_container.visible:
		_children_toggle.text = "v Children"
	else:
		_children_toggle.text = "> Children"


func _populate_children() -> void:
	_children_list.clear()
	if _current_id.is_empty():
		_children_toggle.text = "> Children"
		return

	# Build qualified ID for cross-project search
	var qualified_id: String = _current_id
	if not _current_project.is_empty():
		qualified_id = "%s:%s" % [_current_project, _current_id]

	# Search across ALL loaded projects for children
	var children: Array
	if _state._project_dbs.size() > 1:
		children = _state.find_children_across_projects(qualified_id)
	elif _state.db:
		children = _state.db.execute_query({"filter": {"parent": _current_id}})
	else:
		children = []

	var toggle_prefix := "v" if _children_container.visible else ">"
	if children.size() > 0:
		_children_toggle.text = "%s Children (%d)" % [toggle_prefix, children.size()]
	else:
		_children_toggle.text = "%s Children" % toggle_prefix

	var is_multi := _state._project_dbs.size() > 1
	for child in children:
		var child_id: String = str(child.get("id", ""))
		var child_type: String = str(child.get("type", ""))
		var child_status: String = str(child.get("status", ""))
		var child_title: String = str(child.get("title", ""))
		var child_project: String = str(child.get("project", ""))
		var display: String
		if is_multi and not child_project.is_empty():
			display = "[%s] %s (%s) — %s" % [child_project, child_id, child_type, child_title]
		else:
			display = "[%s] %s (%s) — %s" % [child_id, child_title, child_type, child_status]
		_children_list.add_item(display)
		_children_list.set_item_metadata(_children_list.item_count - 1, {"id":child_id, "project":child_project if not child_project.is_empty() else _current_project})


func _on_child_activated(idx: int) -> void:
	var reference: Dictionary = _children_list.get_item_metadata(idx)
	var child_id: String = str(reference.get("id", ""))
	if not child_id.is_empty():
		child_opened.emit(child_id, str(reference.get("project", "")))


func _on_move_pressed() -> void:
	## Show a popup to select target project, then move the item.
	if _current_id.is_empty() or _state._project_dbs.size() < 2:
		return
	# Build list of other projects
	var popup := PopupMenu.new()
	var idx := 0
	for proj_name in _state._project_dbs:
		if proj_name != _current_project:
			popup.add_item(proj_name, idx)
			idx += 1
	popup.id_pressed.connect(func(menu_id: int):
		var target_name: String = popup.get_item_text(menu_id)
		var result := _state.move_item(_current_id, target_name, _current_project)
		if result.has("error"):
			_id_label.text = "%s — Move failed: %s" % [_current_id, str(result.error)]
		else:
			var new_id: String = str(result.new_id)
			item_changed.emit()
			load_item(new_id, target_name)
		popup.queue_free()
	)
	add_child(popup)
	popup.popup(Rect2i(int(_move_btn.global_position.x), int(_move_btn.global_position.y + _move_btn.size.y), 150, 0))


func _on_events_toggle() -> void:
	_events_container.visible = not _events_container.visible
	if _events_container.visible:
		_events_toggle.text = "v Transitions & Events"
	else:
		_events_toggle.text = "> Transitions & Events"


func _on_comments_toggle() -> void:
	_comments_container.visible = not _comments_container.visible
	if _comments_container.visible:
		_comments_toggle.text = "v Comments"
	else:
		_comments_toggle.text = "> Comments"


func _on_add_comment() -> void:
	if _current_id.is_empty():
		return
	var text := _comment_input.text.strip_edges()
	if text.is_empty():
		return
	var comment_db: DocketDB = _state.get_db_for_project(_current_project)
	if comment_db == null:
		return
	var author := _state.prefs.get_display_name()
	comment_db.add_comment(_current_id, author, text)
	_comment_input.text = ""
	_refresh_comments_and_events()


func _on_accept_comment(comment_id: int) -> void:
	var comment_db: DocketDB = _state.get_db_for_project(_current_project)
	if comment_db == null:
		return
	var author := _state.prefs.get_display_name()
	comment_db.resolve_comment(comment_id, "accepted", author)
	_refresh_comments_and_events()


func _on_reject_comment(comment_id: int) -> void:
	var comment_db: DocketDB = _state.get_db_for_project(_current_project)
	if comment_db == null:
		return
	var author := _state.prefs.get_display_name()
	comment_db.resolve_comment(comment_id, "rejected", author)
	_refresh_comments_and_events()


func _on_reply_comment(comment_id: int) -> void:
	if _current_id.is_empty():
		return
	var text := _comment_input.text.strip_edges()
	if text.is_empty():
		return
	var comment_db: DocketDB = _state.get_db_for_project(_current_project)
	if comment_db == null:
		return
	var author := _state.prefs.get_display_name()
	comment_db.add_comment(_current_id, author, text, comment_id)
	_comment_input.text = ""
	_refresh_comments_and_events()


func _refresh_comments_and_events() -> void:
	_populate_comments()
	var ev_db: DocketDB = _state.get_db_for_project(_current_project)
	if ev_db != null and ev_db.has_item(_current_id):
		_populate_events(ev_db.get_item(_current_id))
	item_changed.emit()


func _populate_comments() -> void:
	for child in _comments_list.get_children():
		child.queue_free()
	if _current_id.is_empty():
		return
	var cmt_db: DocketDB = _state.get_db_for_project(_current_project)
	if cmt_db == null:
		return
	var comments := cmt_db.list_comments(_current_id)

	# Update toggle label with count
	var prefix := "v" if _comments_container.visible else ">"
	if comments.size() > 0:
		_comments_toggle.text = "%s Comments (%d)" % [prefix, comments.size()]
	else:
		_comments_toggle.text = "%s Comments" % prefix

	for c in comments:
		var cid: int = int(c.get("id", 0))
		var parent_id: int = int(c.get("parent_id", 0))
		var status_str: String = str(c.get("status", "open"))
		var author_str: String = str(c.get("author", ""))
		var text_str: String = str(c.get("text", ""))

		var comment_vbox := VBoxContainer.new()
		comment_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		# Indent replies
		if parent_id > 0:
			var margin := MarginContainer.new()
			margin.add_theme_constant_override("margin_left", 24)
			margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			margin.add_child(comment_vbox)
			_comments_list.add_child(margin)
		else:
			_comments_list.add_child(comment_vbox)

		# Header row: indicator + initials + status badge
		var header := HBoxContainer.new()
		var indicator := Label.new()
		match status_str:
			"open":
				indicator.text = "o"
				indicator.add_theme_color_override("font_color", Color(1.0, 0.7, 0.2))
			"accepted":
				indicator.text = "+"
				indicator.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))
			"rejected":
				indicator.text = "-"
				indicator.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		header.add_child(indicator)

		var initials_label := Label.new()
		var parts := author_str.split(" ")
		var initials := ""
		for p in parts:
			if not p.is_empty():
				initials += p[0].to_upper()
		if initials.is_empty():
			initials = "?"
		initials_label.text = "[%s]" % initials
		initials_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
		header.add_child(initials_label)

		if parent_id > 0:
			var reply_tag := Label.new()
			reply_tag.text = "reply"
			reply_tag.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			reply_tag.add_theme_font_size_override("font_size", 11)
			header.add_child(reply_tag)

		comment_vbox.add_child(header)

		# Comment text
		var text_label := Label.new()
		text_label.text = text_str
		text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		comment_vbox.add_child(text_label)

		# Action buttons (small, inline) for open comments
		if status_str == "open":
			var btn_row := HBoxContainer.new()
			btn_row.add_theme_constant_override("separation", 4)

			var accept_btn := Button.new()
			accept_btn.text = "Accept"
			accept_btn.add_theme_font_size_override("font_size", 11)
			accept_btn.pressed.connect(_on_accept_comment.bind(cid))
			btn_row.add_child(accept_btn)

			var reject_btn := Button.new()
			reject_btn.text = "Reject"
			reject_btn.add_theme_font_size_override("font_size", 11)
			reject_btn.pressed.connect(_on_reject_comment.bind(cid))
			btn_row.add_child(reject_btn)

			var reply_btn := Button.new()
			reply_btn.text = "Reply"
			reply_btn.add_theme_font_size_override("font_size", 11)
			reply_btn.pressed.connect(_on_reply_comment.bind(cid))
			btn_row.add_child(reply_btn)

			comment_vbox.add_child(btn_row)


func _on_transition(target: String) -> void:
	if _current_id.is_empty():
		return
	var changes := _collect_changes()
	if changes.has("error"):
		_show_transition_error(str(changes.error))
		return
	await _do_status_transition(target, "", changes)


func _do_status_transition(target: String, note: String, changes: Dictionary = {}) -> bool:
	var trans_db: DocketDB = _state.get_db_for_project(_current_project)
	if trans_db == null:
		_show_transition_error("The originating project is closed.")
		return false
	var registry := _state.get_type_registry(_current_project)
	var item: Dictionary = trans_db.get_item(_current_id)
	var type_name := str(item.get("type", ""))
	var protected := type_name in ["secret", "encrypted_note"]
	var prepared_payload: Dictionary = {"operations":[]}
	if protected:
		prepared_payload = await _prepare_protected_payload(trans_db, _current_id, type_name)
	if prepared_payload.has("error"):
		_show_transition_error(str(prepared_payload.error))
		return false
	var error := registry._begin_item_mutation() if protected else ""
	if error.is_empty():
		error = registry.transition_item(_current_id, target, "user", note, changes, _loaded_revision, _loaded_item_token)
	if error.is_empty() and protected:
		error = _apply_prepared_payload(trans_db, prepared_payload.operations)
	if protected:
		error = registry._complete_item_mutation(error)
	if not error.is_empty():
		_show_transition_error(error)
		_show_vault_error(error)
		return false
	_after_shared_save(trans_db)
	return true


func _prompt_transition_note(target: String, changes: Dictionary = {}) -> void:
	_pending_status = target
	_pending_changes = changes.duplicate(true)
	_pending_revision = _loaded_revision
	_pending_item_token = _loaded_item_token
	if _transition_note_dialog == null:
		_transition_note_dialog = ConfirmationDialog.new()
		_transition_note_dialog.title = "Reason required"
		var vbox := VBoxContainer.new()
		var label := Label.new()
		label.text = "This change is outside the normal promotion flow.\nBriefly note why:"
		vbox.add_child(label)
		_transition_note_edit = LineEdit.new()
		_transition_note_edit.custom_minimum_size.x = 380
		vbox.add_child(_transition_note_edit)
		_transition_note_dialog.add_child(vbox)
		_transition_note_dialog.confirmed.connect(_on_transition_note_confirmed)
		_transition_note_dialog.register_text_enter(_transition_note_edit)
		add_child(_transition_note_dialog)
	_transition_note_edit.text = ""
	_transition_note_dialog.popup_centered()
	_transition_note_edit.grab_focus()


func _on_transition_note_confirmed() -> void:
	var note := _transition_note_edit.text.strip_edges()
	var target := _pending_status
	_pending_status = ""
	if note.is_empty() or target.is_empty() or _current_id.is_empty():
		return
	_loaded_revision = _pending_revision
	_loaded_item_token = _pending_item_token
	await _do_status_transition(target, note, _pending_changes)
	_pending_changes = {}
	_pending_revision = ""
	_pending_item_token = ""


func _show_transition_error(msg: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Transition failed"
	dlg.dialog_text = msg
	dlg.confirmed.connect(dlg.queue_free)
	dlg.close_requested.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


# -- Secret / Encrypted Note helpers ----------------------------------------

func _derive_vault_key(db: DocketDB) -> PackedByteArray:
	## Derive vault key from stored password. Returns empty on failure.
	var password := UserPrefs.load_vault_password()
	if password.is_empty():
		return PackedByteArray()
	if not db.has_vault():
		return PackedByteArray()
	var salt := db.get_vault_salt()
	var key := VaultCrypto.derive_key(password, salt, db.get_vault_iterations())
	if not db.verify_vault(key):
		return PackedByteArray()
	return key


func _ensure_vault(db: DocketDB) -> PackedByteArray:
	## Get or initialize vault key. Returns empty on failure.
	var password := UserPrefs.load_vault_password()
	if password.is_empty():
		_show_vault_error("Vault password not set. Go to Preferences first.")
		return PackedByteArray()
	if db.has_vault():
		var salt := db.get_vault_salt()
		var key := VaultCrypto.derive_key(password, salt, db.get_vault_iterations())
		if not db.verify_vault(key):
			_show_vault_error("Vault password does not match.")
			return PackedByteArray()
		return key
	else:
		var salt := VaultCrypto.generate_salt()
		var key := VaultCrypto.derive_key(password, salt, VaultCrypto.PBKDF2_ITERATIONS)
		db.init_vault(key, salt, VaultCrypto.PBKDF2_ITERATIONS)
		return key


func _show_vault_error(msg: String) -> void:
	_secret_vault_error_label.text = msg
	_secret_vault_error_label.visible = true


func _load_secret_value(item_db: DocketDB) -> void:
	## Decrypt and display secret value for current item.
	_secret_vault_error_label.visible = false
	var key := _derive_vault_key(item_db)
	if key.is_empty():
		_secret_value_edit.text = ""
		_secret_value_decrypted = ""
		if not UserPrefs.load_vault_password().is_empty():
			_show_vault_error("Vault password mismatch or no vault.")
		return

	var raw := item_db.get_secret_raw(_current_id)
	if raw.is_empty():
		_secret_value_edit.text = ""
		_secret_value_decrypted = ""
		return

	_secret_2fa_check.button_pressed = raw.get("requires_2fa", false)

	var plaintext: String
	if raw.get("requires_2fa", false):
		var secondary_pw := await _prompt_secondary_password()
		if secondary_pw.is_empty():
			_secret_value_edit.text = "********"
			_secret_value_decrypted = ""
			_show_vault_error("Secondary password required to view secret.")
			return
		var secondary_salt := item_db.get_vault_salt()
		var secondary_key := VaultCrypto.derive_key(secondary_pw, secondary_salt, item_db.get_vault_iterations())
		plaintext = VaultCrypto.decrypt_2fa(raw.ciphertext, raw.iv, raw.mac, key, secondary_key)
		if plaintext.is_empty():
			AuditLog.record(item_db.get_path(), AuditLog.READ, _current_id, false, "gui",
				"2FA decryption failed")
			_show_vault_error("Decryption failed. Wrong secondary password or corrupted data.")
			return
		AuditLog.record(item_db.get_path(), AuditLog.READ, _current_id, true, "gui", "2fa")
	else:
		plaintext = VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, key)
		if plaintext.is_empty():
			AuditLog.record(item_db.get_path(), AuditLog.READ, _current_id, false, "gui",
				"decryption failed")
			_show_vault_error("Decryption failed. Data may be corrupted.")
			return
		AuditLog.record(item_db.get_path(), AuditLog.READ, _current_id, true, "gui")

	_secret_value_decrypted = plaintext
	_secret_value_edit.text = "********"
	_secret_value_edit.secret = true
	_secret_show_btn.text = "Show"
	_secret_show_btn.button_pressed = false


func _load_encrypted_notes(item_db: DocketDB, handle: String) -> void:
	## Decrypt and display encrypted notes.
	var key := _derive_vault_key(item_db)
	if key.is_empty():
		_encrypted_notes_edit.text = ""
		_encrypted_notes_decrypted = ""
		return

	var raw := item_db.get_secret_raw(handle)
	if raw.is_empty():
		_encrypted_notes_edit.text = ""
		_encrypted_notes_decrypted = ""
		return

	var plaintext := VaultCrypto.decrypt(raw.ciphertext, raw.iv, raw.mac, key)
	if plaintext.is_empty():
		_encrypted_notes_edit.text = ""
		_encrypted_notes_decrypted = ""
		return

	_encrypted_notes_decrypted = plaintext
	_encrypted_notes_edit.text = "********"


func _populate_secret_history(item_db: DocketDB) -> void:
	## Show version history for current secret.
	for child in _secret_history_container.get_children():
		child.queue_free()

	var versions := item_db.get_secret_versions(_current_id)
	var toggle_prefix := "v" if _secret_history_container.visible else ">"
	if versions.size() > 0:
		_secret_history_toggle.text = "%s Version History (%d)" % [toggle_prefix, versions.size()]
	else:
		_secret_history_toggle.text = "%s Version History" % toggle_prefix

	for ver in versions:
		var row := HBoxContainer.new()
		var ver_label := Label.new()
		ver_label.text = "v%d — %s" % [ver.version, ver.created_at]
		ver_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(ver_label)

		if not str(ver.get("rotated_by", "")).is_empty():
			var by_label := Label.new()
			by_label.text = "by %s" % ver.rotated_by
			by_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			row.add_child(by_label)

		var show_btn := Button.new()
		show_btn.text = "Show"
		show_btn.add_theme_font_size_override("font_size", 11)
		show_btn.pressed.connect(_on_history_show.bind(ver, show_btn))
		row.add_child(show_btn)

		var copy_btn := Button.new()
		copy_btn.text = "Copy"
		copy_btn.add_theme_font_size_override("font_size", 11)
		copy_btn.pressed.connect(_on_history_copy.bind(ver))
		row.add_child(copy_btn)

		_secret_history_container.add_child(row)


func _on_history_show(ver: Dictionary, btn: Button) -> void:
	var item_db: DocketDB = _state.get_db_for_project(_current_project)
	if item_db == null:
		return
	var key := _derive_vault_key(item_db)
	if key.is_empty():
		return
	var plaintext := VaultCrypto.decrypt(ver.ciphertext, ver.iv, ver.mac, key)
	if plaintext.is_empty():
		btn.text = "(failed)"
		return
	if btn.text == "Show":
		btn.text = plaintext
	else:
		btn.text = "Show"


func _on_history_copy(ver: Dictionary) -> void:
	var item_db: DocketDB = _state.get_db_for_project(_current_project)
	if item_db == null:
		return
	var key := _derive_vault_key(item_db)
	if key.is_empty():
		return
	var plaintext := VaultCrypto.decrypt(ver.ciphertext, ver.iv, ver.mac, key)
	if not plaintext.is_empty():
		DisplayServer.clipboard_set(plaintext)


func _prepare_protected_payload(db: DocketDB, item_id: String, type_name: String) -> Dictionary:
	var operations: Array = []
	var key := _ensure_vault(db)
	if key.is_empty():
		return {"error":_secret_vault_error_label.text}
	if type_name == "secret":
		var new_value := _secret_value_edit.text
		if not new_value.is_empty() and new_value != "********":
			var encrypted: Dictionary
			if _secret_2fa_check.button_pressed:
				var secondary_password := await _prompt_secondary_password()
				if secondary_password.is_empty():
					return {"error":"Secondary password required for 2FA secret."}
				var secondary_key := VaultCrypto.derive_key(secondary_password, db.get_vault_salt(), db.get_vault_iterations())
				encrypted = VaultCrypto.encrypt_2fa(new_value, key, secondary_key)
			else:
				encrypted = VaultCrypto.encrypt(new_value, key)
			operations.append({"handle":item_id, "owner":item_id, "suffix":"", "ciphertext":encrypted.ciphertext, "iv":encrypted.iv, "mac":encrypted.mac, "requires_2fa":_secret_2fa_check.button_pressed, "rotate":not item_id.is_empty() and not db.get_secret_raw(item_id).is_empty()})
		elif new_value == "********" and not item_id.is_empty():
			var current := db.get_secret_raw(item_id)
			if not current.is_empty() and bool(current.get("requires_2fa", false)) != _secret_2fa_check.button_pressed:
				operations.append({"handle":item_id, "two_factor_only":true, "requires_2fa":_secret_2fa_check.button_pressed})
		_prepare_notes_operation(operations, key, item_id, ":notes")
	elif type_name == "encrypted_note":
		_prepare_notes_operation(operations, key, item_id, "")
	return {"operations":operations}

func _prepare_notes_operation(operations: Array, key: PackedByteArray, item_id: String, suffix: String) -> void:
	var text := _encrypted_notes_edit.text
	if text.is_empty() or text == "********":
		return
	var encrypted: Dictionary = VaultCrypto.encrypt(text, key)
	operations.append({"handle":item_id + suffix, "owner":item_id, "suffix":suffix, "ciphertext":encrypted.ciphertext, "iv":encrypted.iv, "mac":encrypted.mac, "requires_2fa":false, "rotate":false})

func _apply_prepared_payload(db: DocketDB, operations: Array) -> String:
	for operation_value in operations:
		var operation: Dictionary = operation_value
		var handle := str(operation.handle)
		if bool(operation.get("two_factor_only", false)):
			if db is DocketDBJsonl:
				var two_factor_error := (db as DocketDBJsonl).set_secret_2fa_checked(handle, bool(operation.requires_2fa))
				if not two_factor_error.is_empty():
					return two_factor_error
			else:
				db.set_secret_2fa(handle, bool(operation.requires_2fa))
				if not db._last_sql_error.is_empty():
					return db._last_sql_error
			continue
		var error := ""
		if bool(operation.get("rotate", false)):
			if db is DocketDBJsonl:
				error = (db as DocketDBJsonl).rotate_secret_checked(handle, operation.ciphertext, operation.iv, operation.mac, _state.prefs.get_display_name(), bool(operation.requires_2fa))
			else:
				db.rotate_secret(handle, operation.ciphertext, operation.iv, operation.mac, _state.prefs.get_display_name(), bool(operation.requires_2fa))
				error = db._last_sql_error
		elif db is DocketDBJsonl:
			error = (db as DocketDBJsonl).set_secret_checked(handle, operation.ciphertext, operation.iv, operation.mac, bool(operation.requires_2fa), str(operation.owner))
		else:
			db.set_secret(handle, operation.ciphertext, operation.iv, operation.mac, bool(operation.requires_2fa), str(operation.owner))
			error = db._last_sql_error
		if not error.is_empty():
			return error
	return ""


func _save_encrypted_secret(db: DocketDB, item_id: String) -> String:
	## Encrypt and store (or rotate) the secret value for an item.
	var new_value := _secret_value_edit.text
	# Skip if masked display text and nothing changed
	if new_value == "********" and _secret_value_decrypted.is_empty():
		return ""
	# If showing masked text and we have a cached decrypted value, nothing changed
	if new_value == "********" and not _secret_value_decrypted.is_empty():
		# Check if only 2FA flag changed
		var raw := db.get_secret_raw(item_id)
		if not raw.is_empty():
			var old_2fa: bool = raw.get("requires_2fa", false)
			if old_2fa != _secret_2fa_check.button_pressed:
				if db is DocketDBJsonl:
					return (db as DocketDBJsonl).set_secret_2fa_checked(item_id, _secret_2fa_check.button_pressed)
				db.set_secret_2fa(item_id, _secret_2fa_check.button_pressed)
				return db._last_sql_error
		return ""
	if new_value.is_empty():
		return ""

	var key := _ensure_vault(db)
	if key.is_empty():
		return _secret_vault_error_label.text

	var requires_2fa := _secret_2fa_check.button_pressed
	var ciphertext: PackedByteArray
	var iv_bytes: PackedByteArray
	var mac_bytes: PackedByteArray

	if requires_2fa:
		# Double encrypt: inner with secondary key, outer with vault key
		var secondary_pw := await _prompt_secondary_password()
		if secondary_pw.is_empty():
			_show_vault_error("Secondary password required for 2FA secret.")
			return _secret_vault_error_label.text
		var secondary_salt := db.get_vault_salt()
		var secondary_key := VaultCrypto.derive_key(secondary_pw, secondary_salt, db.get_vault_iterations())
		var outer := VaultCrypto.encrypt_2fa(new_value, key, secondary_key)
		ciphertext = outer.ciphertext
		iv_bytes = outer.iv
		mac_bytes = outer.mac
	else:
		var encrypted := VaultCrypto.encrypt(new_value, key)
		ciphertext = encrypted.ciphertext
		iv_bytes = encrypted.iv
		mac_bytes = encrypted.mac

	# Rotate if existing secret
	var existing := db.get_secret_raw(item_id)
	var write_error := ""
	if not existing.is_empty():
		var author := _state.prefs.get_display_name()
		if db is DocketDBJsonl:
			write_error = (db as DocketDBJsonl).rotate_secret_checked(item_id, ciphertext, iv_bytes, mac_bytes, author, requires_2fa)
		else:
			db.rotate_secret(item_id, ciphertext, iv_bytes, mac_bytes, author, requires_2fa)
			write_error = db._last_sql_error
	else:
		if db is DocketDBJsonl:
			write_error = (db as DocketDBJsonl).set_secret_checked(item_id, ciphertext, iv_bytes, mac_bytes, requires_2fa, item_id)
		else:
			db.set_secret(item_id, ciphertext, iv_bytes, mac_bytes, requires_2fa, item_id)
			write_error = db._last_sql_error
	if not write_error.is_empty():
		return write_error

	# Write-time validation: read back and verify ciphertext != plaintext
	var readback := db.get_secret_raw(item_id)
	if not readback.is_empty():
		var raw_str := (readback.ciphertext as PackedByteArray).get_string_from_utf8()
		if raw_str == new_value:
			push_error("CRITICAL: Secret stored as plaintext! handle=%s" % item_id)
			_show_vault_error("CRITICAL: Encryption verification failed!")
			return _secret_vault_error_label.text
	return ""


func _save_encrypted_notes(db: DocketDB, item_id: String, handle_suffix: String) -> String:
	## Encrypt and store encrypted notes.
	var handle := item_id + handle_suffix
	var new_text := _encrypted_notes_edit.text
	# Skip if masked and no changes
	if new_text == "********":
		return ""
	if new_text.is_empty():
		return ""

	var key := _ensure_vault(db)
	if key.is_empty():
		return _secret_vault_error_label.text

	var encrypted := VaultCrypto.encrypt(new_text, key)
	if db is DocketDBJsonl:
		return (db as DocketDBJsonl).set_secret_checked(handle, encrypted.ciphertext, encrypted.iv, encrypted.mac, false, item_id)
	db.set_secret(handle, encrypted.ciphertext, encrypted.iv, encrypted.mac, false, item_id)
	return db._last_sql_error


func _prompt_secondary_password() -> String:
	## Show a blocking dialog for secondary password input. Returns empty on cancel.
	_secret_2fa_input.text = ""
	if not _secret_2fa_dialog.is_inside_tree():
		add_child(_secret_2fa_dialog)
	_secret_2fa_dialog.popup_centered(Vector2i(300, 150))
	var result: Array = await _wait_for_2fa_dialog()
	if result[0]:
		return _secret_2fa_input.text
	return ""


func _wait_for_2fa_dialog() -> Array:
	## Helper: returns [true] on confirm, [false] on cancel.
	var state := {"confirmed": false, "done": false}
	var on_confirm := func():
		state.confirmed = true
		state.done = true
	var on_cancel := func():
		state.done = true
	_secret_2fa_dialog.confirmed.connect(on_confirm, CONNECT_ONE_SHOT)
	_secret_2fa_dialog.canceled.connect(on_cancel, CONNECT_ONE_SHOT)
	while not state.done:
		await get_tree().process_frame
	return [state.confirmed]


func _on_secret_show_toggle() -> void:
	if _secret_show_btn.button_pressed:
		if not _secret_value_decrypted.is_empty():
			_secret_value_edit.text = _secret_value_decrypted
		_secret_value_edit.secret = false
		_secret_show_btn.text = "Hide"
	else:
		if not _secret_value_decrypted.is_empty():
			_secret_value_edit.text = "********"
		_secret_value_edit.secret = true
		_secret_show_btn.text = "Show"


func _on_secret_copy() -> void:
	if not _secret_value_decrypted.is_empty():
		DisplayServer.clipboard_set(_secret_value_decrypted)
	elif not _secret_value_edit.text.is_empty() and _secret_value_edit.text != "********":
		DisplayServer.clipboard_set(_secret_value_edit.text)


func _on_secret_generate() -> void:
	## Generate a random password.
	var length := 24
	var bytes := Crypto.new().generate_random_bytes(length)
	var chars := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
	var result := ""
	for i in range(length):
		result += chars[bytes[i] % chars.length()]
	_secret_value_edit.text = result
	_secret_value_edit.secret = false
	_secret_show_btn.text = "Hide"
	_secret_show_btn.button_pressed = true
	_secret_value_decrypted = ""  # Clear cached, user should save


func _on_encrypted_notes_show_toggle() -> void:
	if _encrypted_notes_show_btn.button_pressed:
		if not _encrypted_notes_decrypted.is_empty():
			_encrypted_notes_edit.text = _encrypted_notes_decrypted
		_encrypted_notes_show_btn.text = "Hide"
	else:
		if not _encrypted_notes_decrypted.is_empty():
			_encrypted_notes_edit.text = "********"
		_encrypted_notes_show_btn.text = "Show"


func _on_encrypted_notes_copy() -> void:
	if not _encrypted_notes_decrypted.is_empty():
		DisplayServer.clipboard_set(_encrypted_notes_decrypted)


func _on_secret_history_toggle() -> void:
	_secret_history_container.visible = not _secret_history_container.visible
	var count := _secret_history_container.get_child_count()
	var prefix := "v" if _secret_history_container.visible else ">"
	if count > 0:
		_secret_history_toggle.text = "%s Version History (%d)" % [prefix, count]
	else:
		_secret_history_toggle.text = "%s Version History" % prefix
