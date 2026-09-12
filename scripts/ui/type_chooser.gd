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
var _empty_label: Label
var _historical: CheckButton


func _init() -> void:
	_button = Button.new()
	_button.text = "Any type"
	_button.pressed.connect(func(): _popup.popup(Rect2i(Vector2i(_button.global_position), Vector2i(520, 380))))
	add_child(_button)

	_popup = PopupPanel.new()
	add_child(_popup)
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(500, 350)
	_popup.add_child(content)
	_search = LineEdit.new()
	_search.placeholder_text = "Search type name, purpose, slug, or alias"
	_search.text_changed.connect(func(_value): _rebuild())
	content.add_child(_search)
	_selected_label = Label.new()
	_selected_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_selected_label)
	_historical = CheckButton.new()
	_historical.text = "Include deprecated types"
	_historical.toggled.connect(func(_value): _rebuild())
	content.add_child(_historical)
	_list = ItemList.new()
	_list.select_mode = ItemList.SELECT_MULTI
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.tooltip_text = "Use arrow keys and Space to select. Right-click a type to pin it."
	_list.item_selected.connect(_on_selection_changed)
	_list.multi_selected.connect(func(_idx, _selected_state): _on_selection_changed(-1))
	_list.item_clicked.connect(_on_item_clicked)
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
	_rebuild()


func set_selected_values(values: Array) -> void:
	_selected.clear()
	for value in values:
		var slug := str(value)
		if not slug.is_empty() and not _selected.has(slug):
			_selected.append(slug)
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
		var marker := "★ " if _pinned.has(record.slug) else ""
		var text := "%s%s%s  (%d)" % [marker, record.label, suffix, int(record.item_count)]
		if not purpose.is_empty():
			text += "\n%s" % purpose
		_list.add_item(text)
		var idx := _list.item_count - 1
		_list.set_item_metadata(idx, record.slug)
		if _selected.has(record.slug):
			_list.select(idx, false)
	_empty_label.visible = matches.is_empty()
	var shortcuts := []
	if not _pinned.is_empty():
		shortcuts.append("Pinned: %s" % ", ".join(_pinned))
	if not _recent.is_empty():
		shortcuts.append("Recent: %s" % ", ".join(_recent))
	_selected_label.text = ("Selected: %s" % ", ".join(_selected) if not _selected.is_empty() else "Selected: none") + ("\n" + "  |  ".join(shortcuts) if not shortcuts.is_empty() else "")
	_button.text = "Any type" if _selected.is_empty() else ", ".join(_selected)


func _on_selection_changed(_index: int) -> void:
	# Only visible entries are reconciled. Hidden selections survive filtering.
	var visible := []
	for i in _list.item_count:
		visible.append(str(_list.get_item_metadata(i)))
	for slug in visible:
		_selected.erase(slug)
	for idx in _list.get_selected_items():
		var slug := str(_list.get_item_metadata(idx))
		_selected.append(slug)
		_recent.erase(slug)
		_recent.push_front(slug)
	if _recent.size() > 12:
		_recent.resize(12)
	UserPrefs.save_type_shortcuts(_project_key, _pinned, _recent)
	_rebuild()
	selection_changed.emit(selected_values())


func _on_item_clicked(index: int, _position: Vector2, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_RIGHT:
		return
	var slug := str(_list.get_item_metadata(index))
	if _pinned.has(slug):
		_pinned.erase(slug)
	else:
		_pinned.append(slug)
	UserPrefs.save_type_shortcuts(_project_key, _pinned, _recent)
	_rebuild()
	shortcuts_changed.emit(_pinned.duplicate(), _recent.duplicate())
