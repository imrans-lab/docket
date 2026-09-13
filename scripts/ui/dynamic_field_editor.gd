extends VBoxContainer
class_name DynamicFieldEditor

var _rows: Dictionary = {}
var _definition: Dictionary = {}

func load_definition(definition: Dictionary, item: Dictionary = {}, existing_item: bool = false) -> void:
	_definition = definition.duplicate(true)
	_rows.clear()
	for child in get_children():
		child.queue_free()
	var values: Dictionary = item.get("fields", {}).duplicate(true) if item.get("fields", {}) is Dictionary else {}
	if bool(definition.get("protected", false)):
		return
	for descriptor_value in definition.get("fields", []):
		var descriptor: Dictionary = descriptor_value
		var key := str(descriptor.key)
		if key in TypeRegistry.UNIVERSAL_MUTABLE:
			continue
		_add_descriptor(descriptor, values.has(key), values.get(key), existing_item)
	for key_value in values:
		var key := str(key_value)
		if not _rows.has(key):
			_add_unknown(key, values[key])

func _add_descriptor(descriptor: Dictionary, present: bool, value: Variant, existing_item: bool) -> void:
	var box := VBoxContainer.new()
	var header := HBoxContainer.new()
	var label := Label.new()
	label.text = str(descriptor.get("label", descriptor.key)) + (" *" if bool(descriptor.get("required", false)) else "")
	label.tooltip_text = _descriptor_help(descriptor)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)
	var mode := OptionButton.new()
	mode.add_item("Set", 0)
	if bool(descriptor.get("nullable", false)):
		mode.add_item("Null", 1)
	mode.add_item("Unset", 2)
	var selected_id := 0
	if not present:
		selected_id = 2
	elif value == null and bool(descriptor.get("nullable", false)):
		selected_id = 1
	mode.select(mode.get_item_index(selected_id))
	header.add_child(mode)
	box.add_child(header)
	var editor := _make_editor(descriptor)
	box.add_child(editor)
	_set_value(editor, descriptor, value)
	mode.item_selected.connect(func(_index: int): editor.visible = mode.get_selected_id() == 0)
	editor.visible = mode.get_selected_id() == 0
	if existing_item and not bool(descriptor.get("mutable", true)):
		mode.disabled = true
		editor.mouse_filter = Control.MOUSE_FILTER_IGNORE
		editor.focus_mode = Control.FOCUS_NONE
		label.text += " — immutable"
	add_child(box)
	_rows[str(descriptor.key)] = {"descriptor":descriptor, "mode":mode, "editor":editor, "unknown":false, "editable":not existing_item or bool(descriptor.get("mutable", true))}

func _descriptor_help(descriptor: Dictionary) -> String:
	var parts: Array[String] = []
	var help := str(descriptor.get("help", descriptor.get("description", "")))
	if not help.is_empty():
		parts.append(help)
	parts.append("Type: %s" % descriptor.type)
	for key in ["minimum", "maximum", "min_length", "max_length"]:
		if descriptor.has(key):
			parts.append("%s: %s" % [key, descriptor[key]])
	return "\n".join(parts)

func _make_editor(descriptor: Dictionary) -> Control:
	var kind := str(descriptor.type)
	if kind == "boolean":
		var check := CheckBox.new()
		check.text = "Enabled"
		return check
	if kind == "enum":
		var options := OptionButton.new()
		for option in descriptor.get("values", []):
			options.add_item(str(option))
		return options
	if kind in ["integer", "number"]:
		var number := LineEdit.new()
		number.placeholder_text = "Integer" if kind == "integer" else "Number"
		return number
	if kind in ["markdown", "array", "object", "reference_list"]:
		var text := TextEdit.new()
		text.custom_minimum_size.y = 75
		text.placeholder_text = "JSON array" if kind in ["array", "reference_list"] else ("JSON object" if kind == "object" else "Markdown")
		return text
	var line := LineEdit.new()
	line.placeholder_text = "YYYY-MM-DD" if kind == "date" else ("ISO-8601 timestamp" if kind == "timestamp" else ("Item ID" if kind == "item_ref" else ""))
	return line

func _set_value(editor: Control, descriptor: Dictionary, value: Variant) -> void:
	if value == null:
		return
	if editor is CheckBox:
		editor.button_pressed = bool(value)
	elif editor is OptionButton:
		for i in editor.item_count:
			if editor.get_item_text(i) == str(value):
				editor.select(i)
				break
	elif editor is TextEdit:
		editor.text = JSON.stringify(value, "  ") if str(descriptor.type) in ["array", "object", "reference_list"] else str(value)
	elif editor is LineEdit:
		editor.text = str(value)

func _add_unknown(key: String, value: Variant) -> void:
	var label := Label.new()
	label.text = "%s — unknown in pinned revision (read-only): %s" % [key, JSON.stringify(value)]
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(label)
	_rows[key] = {"unknown":true}

func collect_patch() -> Dictionary:
	var fields: Dictionary = {}
	var unset: Array = []
	for key_value in _rows:
		var key := str(key_value)
		var row: Dictionary = _rows[key]
		if bool(row.unknown):
			continue
		if not bool(row.editable):
			continue
		var mode: OptionButton = row.mode
		if mode.get_selected_id() == 2:
			unset.append(key)
		elif mode.get_selected_id() == 1:
			fields[key] = null
		else:
			var parsed := _read_value(row.editor, row.descriptor)
			if parsed.has("error"):
				return {"error":"%s: %s" % [key, parsed.error]}
			fields[key] = parsed.value
	return {"fields":fields, "unset_fields":unset}

func _read_value(editor: Control, descriptor: Dictionary) -> Dictionary:
	var kind := str(descriptor.type)
	if editor is CheckBox:
		return {"value":editor.button_pressed}
	if editor is OptionButton:
		return {"value":editor.get_item_text(editor.selected)}
	var text := str(editor.get("text"))
	if kind == "integer":
		if not text.is_valid_int():
			return {"error":"expected integer"}
		return {"value":int(text)}
	if kind == "number":
		if not text.is_valid_float():
			return {"error":"expected number"}
		return {"value":float(text)}
	if kind in ["array", "object", "reference_list"]:
		var value: Variant = JSON.parse_string(text)
		if value == null and text.strip_edges() != "null":
			return {"error":"invalid JSON"}
		return {"value":value}
	return {"value":text}
