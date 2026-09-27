extends Button
class_name EnumValuePicker
## Searchable single-select dropdown of plain string values. The query builder
## uses one per condition row for every enumerated field (type, status,
## project, priority, ...). Values are shown and returned verbatim, sorted and
## de-duplicated; "" means any value. An optional trailing entry ("add…")
## emits add_requested instead of selecting. A value that is not in the list
## (e.g. from a saved query) stays selected and is labelled with missing_suffix.

signal value_changed(value: String)
signal add_requested

const ANY_LABEL := "(any)"

var missing_suffix := " (not available)"
var _values: Array = []
var _value := ""
var _add_label := ""
var _popup: PopupPanel
var _search: LineEdit
var _list: ItemList


func _init() -> void:
	text = ANY_LABEL
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	# Ellipsis keeps a long value from widening the condition row.
	text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# Deferred so the click that opens the popup is not seen as an outside click.
	pressed.connect(func(): call_deferred("_open_popup"))
	_popup = PopupPanel.new()
	add_child(_popup)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(260, 280)
	_popup.add_child(box)
	_search = LineEdit.new()
	_search.placeholder_text = "Type to filter"
	_search.text_changed.connect(func(_t): _rebuild())
	_search.text_submitted.connect(func(_t): choose_first_match())
	_search.gui_input.connect(_on_search_input)
	box.add_child(_search)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Arrow keys move the highlight; a click or Enter chooses.
	_list.item_clicked.connect(func(index, _at, button): if button == MOUSE_BUTTON_LEFT: _choose_index(index))
	_list.item_activated.connect(_choose_index)
	box.add_child(_list)
	_rebuild()


func set_values(values: Array) -> void:
	var seen := {}
	for value in values:
		var key := str(value)
		if not key.is_empty(): seen[key] = true
	_values = seen.keys()
	_values.sort_custom(func(a: String, b: String) -> bool: return a.to_lower() < b.to_lower())
	_rebuild()
	_update_text()


func values() -> Array:
	return _values.duplicate()


func set_add_entry(label: String) -> void:
	_add_label = label
	_rebuild()


func get_value() -> String:
	return _value


func set_value(value: String) -> void:
	_value = "" if value == ANY_LABEL else value
	_update_text()


func set_search(filter_text: String) -> void:
	## Same effect as typing into the popup's search box.
	_search.text = filter_text
	_rebuild()


func visible_entries() -> Array:
	var entries: Array = []
	for i in _list.item_count: entries.append(_list.get_item_text(i))
	return entries


func choose_first_match() -> void:
	## Enter in the search box picks the first listed entry.
	if _list.item_count > 0: _choose_index(0)


func _on_search_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_DOWN and _list.item_count > 0:
		_list.grab_focus()
		_list.select(0)
		_search.accept_event()


func _open_popup() -> void:
	if _popup.visible: return
	_search.text = ""
	_rebuild()
	var anchor := get_screen_position()
	_popup.popup(Rect2i(Vector2i(roundi(anchor.x), roundi(anchor.y + size.y + 2.0)), Vector2i(maxi(260, roundi(size.x)), 300)))
	_search.call_deferred("grab_focus")


func _rebuild() -> void:
	if _list == null: return
	_list.clear()
	var needle := _search.text.strip_edges().to_lower()
	if needle.is_empty(): _add_entry(ANY_LABEL, "any", "")
	for value in _values:
		if needle.is_empty() or str(value).to_lower().contains(needle): _add_entry(str(value), "value", str(value))
	if not _add_label.is_empty(): _add_entry(_add_label, "add", "")


func _add_entry(label: String, kind: String, value: String) -> void:
	_list.add_item(label)
	_list.set_item_metadata(_list.item_count - 1, {"kind": kind, "value": value})


func _choose_index(index: int) -> void:
	var entry: Dictionary = _list.get_item_metadata(index)
	_popup.hide()
	if entry.kind == "add":
		add_requested.emit()
		return
	_value = str(entry.value)
	_update_text()
	value_changed.emit(_value)


func _update_text() -> void:
	if _value.is_empty(): text = ANY_LABEL
	elif _values.has(_value): text = _value
	else: text = _value + missing_suffix
	tooltip_text = text
