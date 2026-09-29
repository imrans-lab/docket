extends ConfirmationDialog
class_name EphemeralItemsDialog
## Quit and project close with ephemeral items outstanding
## (scenes/ui/ephemeral_items_dialog.tscn): Keep writes them to their project
## files (ItemStorage.keep, then the normal settle), Drop deletes them, Cancel
## returns and the quit or close does not happen. After Keep or Drop the caller's
## continuation runs; when any item fails, the dialog asks again for what is left.

var _state: AppState
var _pending: Dictionary = {}
var _after: Callable


func init(state: AppState) -> void:
	_state = state
	add_button("Drop", false, "drop")
	confirmed.connect(_on_keep)
	custom_action.connect(_on_custom_action)
	canceled.connect(func() -> void: _after = Callable())


func ask(pending: Dictionary, after: Callable, failure: String = "") -> void:
	## `pending` is ItemStorage.outstanding() for the projects concerned.
	_pending = pending
	_after = after
	var items: ItemList = %Items
	items.clear()
	for project_name in pending:
		for row in pending[project_name]:
			items.add_item("%s — %s (%s)" % [project_name, str(row.title), str(row.id).left(12)])
	var message: Label = %Message
	var text := "These items are ephemeral: they were never written to their project files and will be lost.\nKeep saves them to their project files. Drop deletes them. Cancel goes back."
	message.text = text if failure.is_empty() else "Not done:\n%s\n\n%s" % [failure, text]
	popup_centered()


func _on_keep() -> void:
	_resolve(func(db: DocketDB) -> PackedStringArray: return ItemStorage.keep_all(db, "user", _state.get_project_dbs()))


func _on_custom_action(action: StringName) -> void:
	if action != &"drop": return
	hide()
	_resolve(func(db: DocketDB) -> PackedStringArray: return ItemStorage.drop_all(db))


func _resolve(apply: Callable) -> void:
	var errors: PackedStringArray = []
	var project_dbs := _state.get_project_dbs()
	for project_name in _pending:
		var db: DocketDB = project_dbs.get(project_name)
		if db == null: continue
		for error: String in apply.call(db):
			errors.append("%s: %s" % [project_name, error])
	var remaining := ItemStorage.outstanding(_only(project_dbs, _pending.keys()))
	if not errors.is_empty() or not remaining.is_empty():
		ask(remaining, _after, "\n".join(errors))
		return
	var after := _after
	_after = Callable()
	if after.is_valid(): after.call()


static func _only(project_dbs: Dictionary, names: Array) -> Dictionary:
	var subset := {}
	for project_name in names:
		if project_dbs.has(project_name): subset[project_name] = project_dbs[project_name]
	return subset
