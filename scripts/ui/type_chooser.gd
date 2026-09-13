extends VBoxContainer
class_name TypeChooser
## Searchable multi-select control for query type predicates. The list owns no
## query semantics; stable catalog IDs are retained while search changes what
## is visible, and ItemList supplies native keyboard navigation.

signal selection_changed(values: Array)
signal shortcuts_changed(pinned: Array, recent: Array)

var _catalog: Array = []
var _selected: Array = []
var _pinned: Array = []
var _recent: Array = []
var _project_key := ""
var _button: Button
var _popup: PopupPanel
var _search: LineEdit
var _list: ItemList
var _selected_label: Label
var _shortcut_box: HFlowContainer
var _shortcut_scroll: ScrollContainer
var _empty_label: Label
var _historical: CheckButton
var _shortcut_error: Label
var _cursor_index := -1
const _CURSOR_COLOR := Color(0.24, 0.38, 0.58, 0.75)


func _init() -> void:
	_button = Button.new()
	_button.text = "Any type"
	# Ellipsis removes label length from the button's minimum-width contract, so
	# a registry-provided label cannot expand the surrounding query row.
	_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_button.pressed.connect(_request_open_popup)
	_button.gui_input.connect(_on_button_gui_input)
	add_child(_button)

	_popup = PopupPanel.new()
	_popup.transparent_bg = false
	add_child(_popup)
	var panel := PanelContainer.new()
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.105, 0.105, 0.115, 1.0)
	panel_style.border_color = Color(0.32, 0.32, 0.36, 1.0)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", panel_style)
	_popup.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(500, 350)
	margin.add_child(content)
	_search = LineEdit.new()
	_search.placeholder_text = "Search type name, purpose, slug, or alias"
	_search.text_changed.connect(func(_value): _rebuild())
	_search.gui_input.connect(_on_search_gui_input)
	content.add_child(_search)
	_selected_label = Label.new()
	# Keep the complete selection in the tooltip while reserving one stable row
	# in the popup. An autowrapped Label computes a large minimum height before
	# its container has established a width, allowing long selections to push
	# the scrollable catalog outside the requested window bounds.
	_selected_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_selected_label.clip_text = true
	_selected_label.custom_minimum_size.y = 24
	_selected_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_selected_label)
	_shortcut_scroll = ScrollContainer.new()
	_shortcut_scroll.custom_minimum_size.y = 48
	_shortcut_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(_shortcut_scroll)
	_shortcut_box = HFlowContainer.new()
	_shortcut_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shortcut_scroll.add_child(_shortcut_box)
	_shortcut_error = Label.new()
	_shortcut_error.add_theme_color_override("font_color", Color(1.0, 0.55, 0.3))
	_shortcut_error.visible = false
	content.add_child(_shortcut_error)
	_historical = CheckButton.new()
	_historical.text = "Include deprecated types"
	_historical.toggled.connect(func(_value): _rebuild())
	content.add_child(_historical)
	_list = ItemList.new()
	_list.select_mode = ItemList.SELECT_MULTI
	_list.focus_mode = Control.FOCUS_ALL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.tooltip_text = "Use arrow keys and Space to select. Right-click a type to pin it."
	_list.multi_selected.connect(func(idx, _selected_state): _on_selection_changed(idx))
	_list.item_clicked.connect(_on_item_clicked)
	_list.gui_input.connect(_on_list_gui_input)
	content.add_child(_list)
	_empty_label = Label.new()
	_empty_label.text = "No matching types"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_empty_label)


func configure(catalog: Array, project_key: String) -> void:
	_catalog = TypeCatalog.sorted(catalog)
	_project_key = project_key
	var shortcuts := UserPrefs.load_type_shortcuts(project_key)
	_pinned = shortcuts.pinned
	_recent = shortcuts.recent
	UserPrefs.save_type_shortcuts(_project_key, _pinned, _recent)
	_rebuild()


func update_catalog(catalog: Array, project_key: String) -> void:
	## File changes replace available records but not the user's active chooser
	## state. Unknown selected identities remain visible for historical queries.
	_catalog = TypeCatalog.sorted(catalog)
	if project_key != _project_key:
		_project_key = project_key
		var shortcuts := UserPrefs.load_type_shortcuts(project_key)
		_pinned = shortcuts.pinned
		_recent = shortcuts.recent
	_rebuild()


func _request_open_popup() -> void:
	# Opening after the activating release is fully dispatched prevents the same
	# mouse event from being treated as an outside click by the new popup window.
	call_deferred("_open_popup")


func _on_button_gui_input(event: InputEvent) -> void:
	# Button.pressed covers keyboard activation. Queue explicitly from mouse
	# release as well so platform-specific Button signal ordering cannot expose
	# the popup to the release that created it.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_request_open_popup()


func _open_popup() -> void:
	if _popup.visible:
		return
	var anchor := _button.get_screen_position()
	var below := Vector2i(roundi(anchor.x), roundi(anchor.y + _button.size.y + 2.0))
	_popup.popup(Rect2i(below, Vector2i(522, 360)))
	_search.call_deferred("grab_focus")


func _on_search_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_DOWN and _list.item_count > 0:
		_list.grab_focus()
		_set_cursor(0)
		accept_event()


func _on_list_gui_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return
	if event.keycode == KEY_UP and _cursor_index == 0:
		_search.grab_focus()
		accept_event()
	elif event.keycode in [KEY_UP, KEY_DOWN] and _list.item_count > 0:
		var direction := -1 if event.keycode == KEY_UP else 1
		_set_cursor(clampi(_cursor_index + direction, 0, _list.item_count - 1))
		accept_event()
	elif event.keycode == KEY_SPACE and _cursor_index >= 0:
		if _list.is_selected(_cursor_index): _list.deselect(_cursor_index)
		else: _list.select(_cursor_index, false)
		_on_selection_changed(_cursor_index)
		accept_event()


func _set_cursor(index: int) -> void:
	if _cursor_index >= 0 and _cursor_index < _list.item_count:
		_list.set_item_custom_bg_color(_cursor_index, Color.TRANSPARENT)
	_cursor_index = index
	if _cursor_index >= 0 and _cursor_index < _list.item_count:
		_list.set_item_custom_bg_color(_cursor_index, _CURSOR_COLOR)
		call_deferred("_scroll_cursor_visible")


func _scroll_cursor_visible() -> void:
	if _cursor_index < 0 or _cursor_index >= _list.item_count:
		return
	var rect: Rect2 = _list.get_item_rect(_cursor_index)
	var scroll: VScrollBar = _list.get_v_scroll_bar()
	if rect.position.y < 0:
		scroll.value += rect.position.y
	elif rect.end.y > _list.size.y:
		scroll.value += rect.end.y - _list.size.y


func set_selected_values(values: Array) -> void:
	_selected.clear()
	for value in values:
		var key := str(value)
		if not key.is_empty() and not _selected.has(key): _selected.append(key)
	_rebuild()


func selected_values() -> Array:
	return _selected.duplicate()


func _rebuild() -> void:
	if _list == null:
		return
	_list.clear()
	var matches := TypeCatalog.filter(_catalog, _search.text, _historical.button_pressed)
	for record_value in matches:
		var record: Dictionary = record_value
		var project := str(record.get("project", ""))
		var suffix := " — %s" % project if not project.is_empty() else ""
		var purpose := str(record.get("description", ""))
		var marker := "★ " if _pinned.has(record.key) else ""
		var count := int(record.item_count)
		var text := "%s%s%s  ·  %d %s" % [marker, record.label, suffix, count, "item" if count == 1 else "items"]
		if not purpose.is_empty():
			var brief := purpose if purpose.length() <= 80 else purpose.left(77) + "..."
			text += "  —  %s" % brief
		_list.add_item(text)
		var idx := _list.item_count - 1
		_list.set_item_metadata(idx, record.key)
		_list.set_item_tooltip(idx, purpose if not purpose.is_empty() else "%s type" % record.label)
		if _selected.has(record.key):
			_list.select(idx, false)
	_empty_label.visible = matches.is_empty()
	_set_cursor(mini(_cursor_index, _list.item_count - 1))
	_update_summary()


func _update_summary() -> void:
	var labels: Array = []
	for key in _selected: labels.append(_label_for_key(str(key)))
	var summary := "Selected: %s" % ", ".join(labels) if not labels.is_empty() else "Selected: none"
	_selected_label.text = summary
	_selected_label.tooltip_text = summary
	if labels.is_empty():
		_button.text = "Any type"
	elif labels.size() == 1:
		_button.text = labels[0]
	else:
		_button.text = "%d types selected" % labels.size()
	_button.tooltip_text = summary
	_rebuild_shortcuts()


func _label_for_key(key: String) -> String:
	var record := TypeCatalog.find_by_key(_catalog, key)
	if record.is_empty(): return "Unknown historical type (%s)" % key
	var projects := {}
	for value in _catalog:
		projects[str(value.project)] = true
	return "%s — %s" % [record.label, record.project] if projects.size() > 1 and not str(record.project).is_empty() else str(record.label)


func _rebuild_shortcuts() -> void:
	for child in _shortcut_box.get_children():
		_shortcut_box.remove_child(child)
		child.queue_free()
	for heading_and_values in [["Pinned", _pinned], ["Recent", _recent]]:
		if heading_and_values[1].is_empty(): continue
		var heading := Label.new(); heading.text = "%s:" % heading_and_values[0]; _shortcut_box.add_child(heading)
		for key in heading_and_values[1]:
			var shortcut := Button.new(); shortcut.text = _label_for_key(str(key)); shortcut.focus_mode = Control.FOCUS_ALL
			shortcut.pressed.connect(_activate_shortcut.bind(str(key)))
			_shortcut_box.add_child(shortcut)
	_shortcut_scroll.visible = _shortcut_box.get_child_count() > 0


func _activate_shortcut(key: String) -> void:
	if not _selected.has(key): _selected.append(key)
	_record_recent(key)
	UserPrefs.save_type_shortcuts(_project_key, _pinned, _recent)
	_rebuild(); selection_changed.emit(selected_values())


func _on_selection_changed(index: int) -> void:
	# Only visible entries are reconciled. Hidden selections survive filtering.
	if index >= 0:
		_set_cursor(index)
	var visible := []
	for i in _list.item_count:
		visible.append(str(_list.get_item_metadata(i)))
	for key in visible: _selected.erase(key)
	for idx in _list.get_selected_items():
		var key := str(_list.get_item_metadata(idx))
		_selected.append(key)
		_record_recent(key)
	UserPrefs.save_type_shortcuts(_project_key, _pinned, _recent)
	_update_summary()
	selection_changed.emit(selected_values())


func _on_item_clicked(index: int, _position: Vector2, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_RIGHT:
		return
	var key := str(_list.get_item_metadata(index))
	if _pinned.has(key):
		_pinned.erase(key)
	else:
		if _pinned.size() >= UserPrefs.MAX_QUERY_TYPE_PINS:
			_shortcut_error.text = "Pin limit reached (%d). Unpin a type before adding another." % UserPrefs.MAX_QUERY_TYPE_PINS
			_shortcut_error.visible = true
			return
		_pinned.append(key)
	_shortcut_error.visible = false
	UserPrefs.save_type_shortcuts(_project_key, _pinned, _recent)
	_rebuild()
	shortcuts_changed.emit(_pinned.duplicate(), _recent.duplicate())


func _record_recent(key: String) -> void:
	_recent.erase(key)
	_recent.push_front(key)
	if _recent.size() > UserPrefs.MAX_QUERY_TYPE_RECENTS:
		_recent.resize(UserPrefs.MAX_QUERY_TYPE_RECENTS)
