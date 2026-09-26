extends ConfirmationDialog
class_name MemoryProjectsDialog
## Asks what to do with memory projects that hold outstanding items before they
## would be lost (quitting, or closing one of them): spill them to session
## files, promote them to project files in a chosen folder, or discard them.
## Emits resolved() once every listed project was written or dropped. When any
## step fails it shows the failure and asks again for the projects still in
## memory; Cancel leaves everything as it was.

signal resolved

var _state: AppState
var _names: PackedStringArray = []
var _folder_dialog: FileDialog


func init(state: AppState) -> void:
	_state = state
	title = "Memory projects"
	ok_button_text = "Spill to session files"
	add_button("Promote to folder…", false, "promote")
	add_button("Discard", false, "discard")
	confirmed.connect(_on_spill)
	custom_action.connect(_on_custom_action)
	_folder_dialog = FileDialog.new()
	_folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_folder_dialog.title = "Promote memory projects into folder"
	_folder_dialog.dir_selected.connect(_on_promote_folder)
	add_child(_folder_dialog)


func ask(pending: Dictionary, failure: String = "") -> void:
	## `pending` maps project name -> outstanding item count.
	_names = PackedStringArray(pending.keys())
	var lines: PackedStringArray = []
	for proj_name in _names:
		lines.append("  %s — %d outstanding item(s)" % [proj_name, int(pending[proj_name])])
	var text := "These memory projects exist only in this process and would be lost:\n\n%s\n\nSpill them to session files, promote them to project files in a folder, or discard them." % "\n".join(lines)
	dialog_text = text if failure.is_empty() else "%s\n\n%s" % [failure, text]
	popup_centered()


func _on_custom_action(action: StringName) -> void:
	hide()
	if action == &"promote":
		_folder_dialog.popup_centered(Vector2i(600, 400))
	elif action == &"discard":
		for proj_name in _names:
			_state.remove_project(proj_name)
		_finish(PackedStringArray())


func _on_spill() -> void:
	_persist_each(SessionProject.MODE_SESSION_FILE, "")


func _on_promote_folder(folder: String) -> void:
	_persist_each(SessionProject.MODE_DURABLE, folder)


func _persist_each(mode: String, folder: String) -> void:
	var errors: PackedStringArray = []
	for proj_name in _names:
		var path := "" if folder.is_empty() else folder.path_join(proj_name + ".dct")
		var result := MemoryProject.persist(_state.get_project_dbs(), proj_name, mode, path, _state.add_project_result, _state.remove_project)
		if result.has("error"):
			errors.append("%s: %s" % [proj_name, result.error])
	_finish(errors)


func _finish(errors: PackedStringArray) -> void:
	var remaining := MemoryProject.outstanding_projects(_state.get_project_dbs())
	var still_listed := {}
	for proj_name in _names:
		if remaining.has(proj_name):
			still_listed[proj_name] = remaining[proj_name]
	if errors.is_empty() and still_listed.is_empty():
		resolved.emit()
		return
	ask(still_listed, "Not done:\n" + "\n".join(errors))
