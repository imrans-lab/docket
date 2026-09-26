extends ConfirmationDialog
class_name PromoteDialog
## File > Promote Session Records…: copies chosen records from a session_file or
## memory project into a durable project through SessionPromotion
## (scenes/ui/promote_dialog.tscn).
##
## The user picks the source and target projects and the records, then presses
## Preview, which lists what would be copied and every reference that cannot be
## resolved. Promote stays disabled until a preview matches the current choices,
## so the unresolved list is always seen before confirming. A failed promotion
## reopens the dialog with the error; a successful one emits promoted().

signal promoted(summary: String)

var _state: AppState
var _source: OptionButton
var _target: OptionButton
var _items: ItemList
var _comments: CheckBox
var _attachments: CheckBox
var _import_definition: CheckBox
var _report: TextEdit
var _previewed := false


func init(state: AppState) -> void:
	_state = state
	_source = %SourcePicker
	_target = %TargetPicker
	_items = %RecordList
	_comments = %IncludeComments
	_attachments = %IncludeAttachments
	_import_definition = %ImportDefinitions
	_report = %Report
	_source.item_selected.connect(func(_i: int) -> void: _fill_items(""))
	_target.item_selected.connect(func(_i: int) -> void: _invalidate())
	_items.multi_selected.connect(func(_i: int, _s: bool) -> void: _invalidate())
	for box: CheckBox in [_comments, _attachments, _import_definition]:
		box.toggled.connect(func(_on: bool) -> void: _invalidate())
	%PreviewButton.pressed.connect(_on_preview)
	confirmed.connect(_on_promote)


func open(project: String = "", item_id: String = "") -> void:
	## Opens with `project` as the source (when it is a session project) and
	## `item_id` preselected.
	_source.clear()
	_target.clear()
	for proj_name: String in _state.get_project_dbs():
		var pdb: DocketDB = _state.get_project_dbs()[proj_name]
		var mode := SessionProject.mode_of(pdb)
		if mode == SessionProject.MODE_DURABLE and not pdb is DocketDBMemory:
			_target.add_item(proj_name)
		else:
			_source.add_item("%s (%s)" % [proj_name, mode])
			_source.set_item_metadata(_source.item_count - 1, proj_name)
			if proj_name == project:
				_source.select(_source.item_count - 1)
	_report.text = ""
	if _source.item_count == 0 or _target.item_count == 0:
		_report.text = "Promotion needs an open session project (session_file or memory) and an open durable project."
	_fill_items(item_id)
	popup_centered(min_size)


func _fill_items(preselect: String) -> void:
	_items.clear()
	var source_db := _state.get_db_for_project(_source_name())
	if source_db != null:
		for item: Dictionary in source_db.execute_query({}):
			var id := str(item.get("id", ""))
			_items.add_item("%s  %s  [%s]" % [source_db.short_id(id), item.get("title", ""), item.get("status", "")])
			_items.set_item_metadata(_items.item_count - 1, id)
			if id == preselect:
				_items.select(_items.item_count - 1, false)
	_invalidate()


func _on_preview() -> void:
	var result := SessionPromotion.preview(_state.get_project_dbs(), _source_name(), _selected_ids(), _target_name(), _options())
	_previewed = not result.has("error")
	get_ok_button().disabled = not _previewed
	_report.text = str(result.error) if result.has("error") else _describe(result, "Would promote")


func _on_promote() -> void:
	if not _previewed:
		return
	var result := SessionPromotion.promote(_state.get_project_dbs(), _source_name(), _selected_ids(), _target_name(), _options())
	if result.has("error"):
		_invalidate()
		_report.text = "Not promoted: %s" % result.error
		popup_centered(min_size)
		return
	_state.data_changed.emit()
	promoted.emit(_describe(result, "Promoted"))


func _describe(result: Dictionary, verb: String) -> String:
	var records: Array = result.get("promoted", result.get("would_promote", []))
	var lines := PackedStringArray(["%s %d record(s) from %s into %s:" % [verb, records.size(), result.source_project, result.target_project]])
	for entry: Dictionary in records:
		lines.append("  %s → %s  %s" % [entry.old_id, entry.new_id, entry.title])
	var unresolved: Array = result.get("unresolved", [])
	if unresolved.is_empty():
		lines.append("All references resolve.")
	else:
		lines.append("Unresolved references (kept pointing at %s):" % result.source_project)
		for miss: Dictionary in unresolved:
			lines.append("  %s  %s → %s" % [miss.item, miss.field, miss.reference])
	return "\n".join(lines)


func _invalidate() -> void:
	_previewed = false
	get_ok_button().disabled = true


func _selected_ids() -> Array:
	var ids: Array = []
	for index in _items.get_selected_items():
		ids.append(str(_items.get_item_metadata(index)))
	return ids


func _options() -> Dictionary:
	return {
		"promoted_by": GuiPrincipal.id(),
		"include_comments": _comments.button_pressed,
		"include_attachments": _attachments.button_pressed,
		"import_definition": _import_definition.button_pressed,
	}


func _source_name() -> String:
	return str(_source.get_item_metadata(_source.selected)) if _source.selected >= 0 else ""


func _target_name() -> String:
	return _target.get_item_text(_target.selected) if _target.selected >= 0 else ""

