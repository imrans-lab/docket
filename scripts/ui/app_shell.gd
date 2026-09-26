extends VBoxContainer
class_name AppShell
## Top-level VBoxContainer: MenuBar + content area with work-entry switching.
## Each open query or item is a "work entry" listed in the Work menu.

enum ViewMode { QUERY, DETAIL, SPLIT, TYPES }

var _state: AppState
var _menu_builder: MenuBuilder
var _content_area: PanelContainer
var _query_grid: QueryGrid
var _record_form: RecordForm
var _split_container: HSplitContainer
var _project_types: ProjectTypesPanel
var _current_mode: ViewMode = ViewMode.QUERY

var _file_label: Label
var _open_dialog: FileDialog
var _save_dialog: FileDialog
var _new_dialog: FileDialog
var _info_dialog: AcceptDialog
var _confirm_reload_dialog: ConfirmationDialog
var _memory_dialog: MemoryProjectsDialog
var _promote_dialog: PromoteDialog
var _subscriptions_dialog: SubscriptionsDialog
var _after_memory_resolved: Callable
var _add_project_dialog: FileDialog
var _open_query_dialog: FileDialog
var _save_query_dialog: FileDialog
var _prefs_dialog: ConfirmationDialog
var _prefs_first: LineEdit
var _prefs_last: LineEdit
var _prefs_vault_pw: LineEdit
var _prefs_vault_hint: LineEdit
var _new_item_dialog: ConfirmationDialog
var _new_item_project: OptionButton
var _new_item_search: LineEdit
var _new_item_list: ItemList
var _new_item_catalog: Array = []

# Zoom levels
const _ZOOM_LEVELS := [0.75, 0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0, 2.5]
var _current_zoom_idx: int = 2  # 1.0 default
const _FONT_SIZES := {"small": 12, "medium": 14, "large": 18}
var _current_font_size: String = "medium"

# Work entries: each is {type: "query"|"item", label: String, filter: String, item_id: String}
var _work_entries: Array = []
var _current_work_idx: int = -1
var _nav_history: Array = []  # Stack of previous _current_work_idx values

# Recent files
const _RECENTS_PATH := "user://recent_dockets.json"
const _MAX_RECENTS := 5
var _recent_files: PackedStringArray = []

# External change polling
var _poll_timer: Timer
var _last_poll_mtime: int = 0
var _last_projects_token: String = ""


func init(state: AppState) -> void:
	_state = state
	_build_ui()


func _ready() -> void:
	# Quitting waits for the memory-project answer instead of exiting on close.
	get_tree().set_auto_accept_quit(false)
	# Viewport is available now that we're in the tree.
	size = get_viewport().get_visible_rect().size
	get_viewport().size_changed.connect(_on_viewport_resized)

	# Restore persisted UI settings (zoom, font size)
	_restore_ui_settings()

	# Restore last query if available, otherwise start with "All Items"
	var last_q := UserPrefs.load_last_query()
	if last_q.is_empty():
		_add_work_entry("query", "All Items", "", "")
	else:
		_add_work_entry("query", last_q.label, last_q.filter, "")
	_activate_work_entry(0)

	# Poll for external DB changes (e.g. MCP writes) every 3 seconds
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 3.0
	_poll_timer.timeout.connect(_on_poll_external_changes)
	add_child(_poll_timer)
	_poll_timer.start()
	_last_poll_mtime = _get_dct_mtime()
	_last_projects_token = _get_projects_token()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_request_quit()


func _request_quit() -> void:
	## Memory projects with outstanding items are resolved (spill, promote or
	## discard) before the process exits; the quit waits for that answer.
	var pending := MemoryProject.outstanding_projects(_state.get_project_dbs())
	if not pending.is_empty():
		_after_memory_resolved = _quit
		_memory_dialog.ask(pending)
		return
	_quit()


func _quit() -> void:
	_save_current_work_state()
	_persist_last_query()
	get_tree().quit()


func _on_memory_resolved() -> void:
	_update_window_title()
	_update_project_menu()
	_save_session()
	_query_grid.refresh()
	if _after_memory_resolved.is_valid():
		_after_memory_resolved.call()
	_after_memory_resolved = Callable()


func _on_records_promoted(summary: String) -> void:
	_query_grid.refresh()
	_info_dialog.title = "Records promoted"
	_info_dialog.dialog_text = summary
	_info_dialog.popup_centered()


func _persist_last_query() -> void:
	# Find the current (or most recent) query work entry and save its filter/label.
	var entry: Dictionary = {}
	if _current_work_idx >= 0 and _current_work_idx < _work_entries.size():
		var cur: Dictionary = _work_entries[_current_work_idx]
		if cur.type == "query":
			entry = cur
	# If the current entry isn't a query, walk backwards to find the last one.
	if entry.is_empty():
		for i in range(_work_entries.size() - 1, -1, -1):
			if _work_entries[i].type == "query":
				entry = _work_entries[i]
				break
	if entry.is_empty():
		return
	UserPrefs.save_last_query(entry.filter, entry.label)


func _build_ui() -> void:
	# Menu bar inside a colored panel
	var menu_panel := PanelContainer.new()
	menu_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var menu_bg := StyleBoxFlat.new()
	menu_bg.bg_color = Color(0.18, 0.18, 0.22)
	menu_bg.content_margin_left = 4
	menu_bg.content_margin_right = 4
	menu_bg.content_margin_top = 2
	menu_bg.content_margin_bottom = 2
	menu_panel.add_theme_stylebox_override("panel", menu_bg)

	_menu_builder = MenuBuilder.new()
	_menu_builder.action_triggered.connect(_on_menu_action)
	var type_keys: Array = _state.schema.types.keys()
	type_keys.sort()
	var type_names := PackedStringArray()
	for t in type_keys:
		type_names.append(t)
	var mbar := _menu_builder.build(type_names)

	_load_recent_files()
	_menu_builder.set_recent_files(_recent_files)
	if not _state.dct_path.is_empty():
		_add_to_recent(_state.dct_path)

	var menu_row := HBoxContainer.new()
	menu_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu_row.add_child(mbar)

	# Spacer pushes filename to the right
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu_row.add_child(spacer)

	_file_label = Label.new()
	_file_label.text = _state.dct_path.get_file()
	_file_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	menu_row.add_child(_file_label)

	menu_panel.add_child(menu_row)
	add_child(menu_panel)

	# Content area with margin
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	_content_area = PanelContainer.new()
	_content_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(_content_area)

	# Build child panels (not yet parented to content_area)
	_query_grid = QueryGrid.new()
	_query_grid.custom_minimum_size.x = 400
	_query_grid.init(_state)
	_query_grid.item_selected.connect(_on_item_selected)
	_query_grid.item_activated.connect(_on_item_activated)

	_record_form = RecordForm.new()
	_record_form.custom_minimum_size.x = 400
	_record_form.init(_state)
	_record_form.item_changed.connect(_on_item_changed)
	_record_form.back_pressed.connect(_on_back_pressed)
	_record_form.child_opened.connect(_open_item_entry)
	_project_types = ProjectTypesPanel.new()
	_project_types.init(_state)
	_project_types.registry_changed.connect(func(_project: String): _query_grid.refresh())

	_split_container = HSplitContainer.new()
	_split_container.split_offset = 500
	_split_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_split_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# File dialogs
	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.add_filter("*.dct", "Docket Files")
	_open_dialog.file_selected.connect(_on_open_file_selected)
	add_child(_open_dialog)

	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_save_dialog.add_filter("*.dct", "Docket Files")
	_save_dialog.file_selected.connect(_on_save_as_file_selected)
	add_child(_save_dialog)

	_new_dialog = FileDialog.new()
	_new_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_new_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_new_dialog.add_filter("*.dct", "Docket Files")
	_new_dialog.file_selected.connect(_on_new_file_selected)
	add_child(_new_dialog)

	# Add Project dialog
	_add_project_dialog = FileDialog.new()
	_add_project_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_add_project_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_add_project_dialog.add_filter("*.dct", "Docket Files")
	_add_project_dialog.file_selected.connect(_on_add_project_selected)
	add_child(_add_project_dialog)

	# Open Query dialog (.dcq)
	_open_query_dialog = FileDialog.new()
	_open_query_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_query_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_query_dialog.add_filter("*.dcq", "Docket Query Files")
	_open_query_dialog.file_selected.connect(_on_open_query_selected)
	add_child(_open_query_dialog)

	# Save Query dialog (.dcq)
	_save_query_dialog = FileDialog.new()
	_save_query_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_query_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_save_query_dialog.add_filter("*.dcq", "Docket Query Files")
	_save_query_dialog.file_selected.connect(_on_save_query_selected)
	add_child(_save_query_dialog)

	# Reusable info dialog for Help menu
	_info_dialog = AcceptDialog.new()
	add_child(_info_dialog)

	# Asks what to do when the item currently open changed on disk underneath us
	_confirm_reload_dialog = ConfirmationDialog.new()
	_confirm_reload_dialog.title = "Item changed on disk"
	_confirm_reload_dialog.ok_button_text = "Load from disk"
	_confirm_reload_dialog.cancel_button_text = "Keep my edits"
	_confirm_reload_dialog.confirmed.connect(_on_reload_open_item_confirmed)
	add_child(_confirm_reload_dialog)

	_memory_dialog = MemoryProjectsDialog.new()
	_memory_dialog.init(_state)
	_memory_dialog.resolved.connect(_on_memory_resolved)
	add_child(_memory_dialog)

	_promote_dialog = PromoteDialog.new()
	_promote_dialog.init(_state)
	_promote_dialog.promoted.connect(_on_records_promoted)
	add_child(_promote_dialog)

	_subscriptions_dialog = (load("res://scenes/ui/subscriptions_dialog.tscn") as PackedScene).instantiate() as SubscriptionsDialog
	_subscriptions_dialog.init(_state)
	add_child(_subscriptions_dialog)
	_build_new_item_dialog()

	# A .dct that could not be opened (conflict markers, corruption)
	_state.load_failed.connect(_on_load_failed)

	# Populate Close Project submenu with current projects
	_update_project_menu()

	# Listen for project changes to update menu and persist session
	_state.file_changed.connect(_on_file_changed)
	_state.open_item_requested.connect(func(id: String, project: String): _open_item_entry.call_deferred(id, project))
	_state.open_query_requested.connect(_on_open_query_from_mcp)

	# Preferences dialog
	_prefs_dialog = ConfirmationDialog.new()
	_prefs_dialog.title = "Preferences"
	_prefs_dialog.ok_button_text = "Save"
	_prefs_dialog.confirmed.connect(_on_prefs_confirmed)
	var prefs_vbox := VBoxContainer.new()
	prefs_vbox.add_theme_constant_override("separation", 8)

	var fn_label := Label.new()
	fn_label.text = "First Name"
	prefs_vbox.add_child(fn_label)
	_prefs_first = LineEdit.new()
	_prefs_first.placeholder_text = "First name"
	prefs_vbox.add_child(_prefs_first)

	var ln_label := Label.new()
	ln_label.text = "Last Name"
	prefs_vbox.add_child(ln_label)
	_prefs_last = LineEdit.new()
	_prefs_last.placeholder_text = "Last name"
	prefs_vbox.add_child(_prefs_last)

	var initials_note := Label.new()
	initials_note.text = "Initials are derived from your name (e.g. IP)."
	initials_note.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	prefs_vbox.add_child(initials_note)

	# Vault password section
	var vault_sep := HSeparator.new()
	prefs_vbox.add_child(vault_sep)

	var vault_label := Label.new()
	vault_label.text = "Vault Password"
	prefs_vbox.add_child(vault_label)

	_prefs_vault_pw = LineEdit.new()
	_prefs_vault_pw.secret = true
	_prefs_vault_pw.placeholder_text = "Vault password for secrets"
	prefs_vbox.add_child(_prefs_vault_pw)

	var vault_note := Label.new()
	vault_note.text = "Used to encrypt/decrypt secrets in docket files.\nShare with collaborators who need access."
	vault_note.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	prefs_vbox.add_child(vault_note)

	var hint_label := Label.new()
	hint_label.text = "Password Hint"
	prefs_vbox.add_child(hint_label)

	_prefs_vault_hint = LineEdit.new()
	_prefs_vault_hint.placeholder_text = "Optional hint (shown when password is needed)"
	prefs_vbox.add_child(_prefs_vault_hint)

	var hint_note := Label.new()
	hint_note.text = "This hint is NOT encrypted. Keep it vague."
	hint_note.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	prefs_vbox.add_child(hint_note)

	_prefs_dialog.add_child(prefs_vbox)
	add_child(_prefs_dialog)


# -- Work entries ----------------------------------------------------------

func _add_work_entry(type: String, label: String, filter: String, item_id: String, project: String = "") -> int:
	var entry := {"type": type, "label": label, "filter": filter, "item_id": item_id, "project":project}
	_work_entries.append(entry)
	_rebuild_work_menu()
	return _work_entries.size() - 1


func _activate_work_entry(idx: int) -> void:
	# Save state of current entry before switching away
	_save_current_work_state()

	if _current_work_idx >= 0 and _current_work_idx != idx:
		_nav_history.append(_current_work_idx)
	_current_work_idx = idx
	var entry: Dictionary = _work_entries[idx]

	if entry.type == "query":
		_query_grid.set_filter(entry.filter)
		switch_view(ViewMode.QUERY)
	elif entry.type == "item":
		switch_view(ViewMode.DETAIL)
		_record_form.load_item(entry.item_id, str(entry.get("project", "")))
	elif entry.type == "types":
		_project_types.refresh()
		switch_view(ViewMode.TYPES)

	_rebuild_work_menu()


func _save_current_work_state() -> void:
	if _current_work_idx < 0 or _current_work_idx >= _work_entries.size():
		return
	var entry: Dictionary = _work_entries[_current_work_idx]
	if entry.type == "query":
		entry.filter = _query_grid.get_filter()
		entry.label = _query_grid.get_filter_summary()


func _find_item_work_entry(item_id: String, project: String = "") -> int:
	for i in range(_work_entries.size()):
		if _work_entries[i].type == "item" and _work_entries[i].item_id == item_id and str(_work_entries[i].get("project", "")) == project:
			return i
	return -1


func _rebuild_work_menu() -> void:
	var popup: PopupMenu = _menu_builder.work_popup
	popup.clear()
	for i in range(_work_entries.size()):
		var entry: Dictionary = _work_entries[i]
		var prefix := "* " if i == _current_work_idx else "  "
		popup.add_item(prefix + entry.label, i)


# -- View switching --------------------------------------------------------

func switch_view(mode: ViewMode) -> void:
	_detach_all()
	_current_mode = mode
	match mode:
		ViewMode.QUERY:
			_content_area.add_child(_query_grid)
		ViewMode.DETAIL:
			_content_area.add_child(_record_form)
		ViewMode.SPLIT:
			_content_area.add_child(_split_container)
			_split_container.add_child(_query_grid)
			_split_container.add_child(_record_form)
		ViewMode.TYPES:
			_content_area.add_child(_project_types)


func _detach_all() -> void:
	if _query_grid and _query_grid.get_parent():
		_query_grid.get_parent().remove_child(_query_grid)
	if _record_form and _record_form.get_parent():
		_record_form.get_parent().remove_child(_record_form)
	if _split_container and _split_container.get_parent():
		_split_container.get_parent().remove_child(_split_container)
	if _project_types and _project_types.get_parent():
		_project_types.get_parent().remove_child(_project_types)


# -- External change polling -----------------------------------------------

func _get_dct_mtime() -> int:
	## Get modification time of the .dct file (or its WAL).
	var path := _state.dct_path
	if path.is_empty():
		return 0
	# Check WAL file first — it changes on every write
	var wal_path := path + "-wal"
	if FileAccess.file_exists(wal_path):
		return FileAccess.get_modified_time(wal_path)
	if FileAccess.file_exists(path):
		return FileAccess.get_modified_time(path)
	return 0

func _get_projects_token() -> String:
	var parts: Array[String] = []
	var projects: Array = _state.get_project_dbs().keys()
	projects.sort()
	for project in projects:
		var pdb: DocketDB = _state.get_db_for_project(str(project))
		var path := pdb.get_path()
		var canonical_hash := FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "missing"
		var wal := path + "-wal"
		var wal_stamp := str(FileAccess.get_modified_time(wal)) if FileAccess.file_exists(wal) else ""
		parts.append("%s:%s:%s" % [project, canonical_hash, wal_stamp])
	return "|".join(parts)


func _on_file_changed() -> void:
	## Project list changed — update menus and persist session.
	_update_project_menu()
	_save_session()


func _on_load_failed(path: String, reason: String) -> void:
	## A .dct was refused (most often unresolved git conflict markers). Say so
	## plainly — the file is intact and needs the user to repair it.
	_info_dialog.title = "Could not open project"
	_info_dialog.dialog_text = "%s\n\n%s" % [path, reason]
	_info_dialog.popup_centered()


func _on_poll_external_changes() -> void:
	## Pick up external edits to the .dct (git pull, MCP server, another
	## instance). Re-querying alone is not enough: the grid reads the SQLite
	## cache, so without an actual reload it would redisplay stale rows.
	var current_token := _get_projects_token()
	if current_token == _last_projects_token:
		return
	_last_projects_token = current_token

	# Snapshot the open item before reloading so we can tell whether the reload
	# affected what the user is looking at.
	var open_id := _record_form.get_current_id() if _record_form else ""
	var open_project := _record_form.get_current_project() if _record_form else ""
	var before := _item_revision(open_id, open_project)

	var reloaded := _state.reload_stale()
	if reloaded.is_empty():
		return

	if _query_grid and _query_grid.is_visible_in_tree():
		_query_grid.refresh()

	if open_id.is_empty():
		return

	# Item-scoped policy: an external change to some *other* item is none of the
	# open form's business, so reload silently. Only a change to the item under
	# edit is worth interrupting for — the user may have unsaved edits, and
	# saving them would overwrite what just arrived.
	var after := _item_revision(open_id, open_project)
	if after == before:
		return

	if after.is_empty():
		_confirm_reload_dialog.dialog_text = (
			"The item you have open was deleted in %s on disk.\n\n" % ", ".join(PackedStringArray(reloaded))
			+ "Discard it and go back to the list, or keep your copy open to re-save it?"
		)
	else:
		_confirm_reload_dialog.dialog_text = (
			"The item you have open changed on disk (%s).\n\n" % ", ".join(PackedStringArray(reloaded))
			+ "Load the new version, or keep your unsaved edits?"
		)
	_confirm_reload_dialog.popup_centered()


func _item_revision(item_id: String, project: String = "") -> String:
	if item_id.is_empty():
		return ""
	var item_db: DocketDB = _state.get_db_for_project(project)
	if item_db == null:
		return ""
	var item: Dictionary = item_db.get_item(item_id)
	if item.is_empty():
		return ""
	var registry := _state.get_type_registry(project)
	return registry.item_token(item) if registry != null else ""


func _on_reload_from_disk() -> void:
	## File > Reload from Disk — unconditional re-read, discarding cache.
	var open_id := _record_form.get_current_id() if _record_form else ""
	var open_project := _record_form.get_current_project() if _record_form else ""
	var reloaded := _state.reload_all()
	_last_poll_mtime = _get_dct_mtime()
	_last_projects_token = _get_projects_token()

	if _query_grid and _query_grid.is_visible_in_tree():
		_query_grid.refresh()
	if not open_id.is_empty():
		if _item_revision(open_id, open_project).is_empty():
			_on_back_pressed()  # the open item no longer exists on disk
		else:
			_confirm_reload_dialog.dialog_text = "Reloaded project data is available. Load it and discard the current form edits, or keep reviewing the unsaved form?"
			_confirm_reload_dialog.popup_centered()

	if reloaded.is_empty():
		_info_dialog.title = "Reload from Disk"
		_info_dialog.dialog_text = "Nothing to reload — no JSONL projects are open."
		_info_dialog.popup_centered()


func _on_reload_open_item_confirmed() -> void:
	## User chose to take the on-disk version, discarding unsaved form edits.
	var open_id := _record_form.get_current_id() if _record_form else ""
	var open_project := _record_form.get_current_project() if _record_form else ""
	if open_id.is_empty():
		return
	if _item_revision(open_id, open_project).is_empty():
		_on_back_pressed()  # item is gone — return to the list
	else:
		_record_form.load_item(open_id, open_project)


# -- Menu actions ----------------------------------------------------------

func _on_menu_action(action: String) -> void:
	if action.begins_with("new_item:"):
		var type_name := action.substr("new_item:".length())
		_create_and_edit_item(type_name)
		return
	if action.begins_with("new_protected:"):
		var protected_type := action.substr("new_protected:".length())
		var project := _state.db.get_project_name() if _state.db != null else ""
		_create_and_edit_item(protected_type, project, true)
		return
	if action.begins_with("work:"):
		var idx := int(action.substr("work:".length()))
		if idx >= 0 and idx < _work_entries.size():
			_activate_work_entry(idx)
		return
	if action.begins_with("open_recent:"):
		var recent_idx := int(action.split(":")[1])
		if recent_idx >= 0 and recent_idx < _recent_files.size():
			_state.load_dct(_recent_files[recent_idx])
			_add_to_recent(_recent_files[recent_idx])
			_update_window_title()
			_update_project_menu()
			_save_session()
		return
	if action.begins_with("add_recent:"):
		var recent_idx := int(action.split(":")[1])
		if recent_idx >= 0 and recent_idx < _recent_files.size():
			var path := _recent_files[recent_idx]
			if FileAccess.file_exists(path):
				_state.add_project(path)
				_add_to_recent(path)
				_update_window_title()
				_update_project_menu()
				_save_session()
		return
	if action.begins_with("close_project:"):
		var proj_name := action.substr("close_project:".length())
		var closing: DocketDB = _state.get_db_for_project(proj_name)
		if closing is DocketDBMemory:
			var pending := MemoryProject.outstanding_projects({proj_name: closing})
			if not pending.is_empty():
				_memory_dialog.ask(pending)
				return
		_state.remove_project(proj_name)
		_update_window_title()
		_update_project_menu()
		_save_session()
		_query_grid.refresh()
		return
	match action:
		"new_item":
			_show_new_item_dialog()
		"new_query":
			var idx := _add_work_entry("query", "All Items", "", "")
			_activate_work_entry(idx)
		"new_docket":
			_new_dialog.popup_centered(Vector2i(600, 400))
		"open":
			_open_dialog.popup_centered(Vector2i(600, 400))
		"save":
			_state.save()
		"reload":
			_on_reload_from_disk()
		"vault":
			_show_vault()
		"project_types":
			var existing := -1
			for i in range(_work_entries.size()):
				if _work_entries[i].type == "types":
					existing = i
					break
			if existing < 0:
				existing = _add_work_entry("types", "Project Types", "", "")
			_activate_work_entry(existing)
		"promote_records":
			var origin := _query_grid.get_selected_origin()
			_promote_dialog.open(str(origin.get("project", "")), str(origin.get("id", "")))
		"subscriptions":
			_subscriptions_dialog.open()
		"save_as":
			_save_dialog.popup_centered(Vector2i(600, 400))
		"add_project":
			_add_project_dialog.popup_centered(Vector2i(600, 400))
		"open_query":
			_open_query_dialog.popup_centered(Vector2i(600, 400))
		"save_query_as":
			_save_query_dialog.popup_centered(Vector2i(600, 400))
		"clear_recent":
			_recent_files = PackedStringArray()
			_save_recent_files()
			_menu_builder.set_recent_files(_recent_files)
		"quit":
			_request_quit()
		"view_query":
			switch_view(ViewMode.QUERY)
		"view_detail":
			switch_view(ViewMode.DETAIL)
		"view_split":
			switch_view(ViewMode.SPLIT)
		"zoom_in":
			_zoom_in()
		"zoom_out":
			_zoom_out()
		"zoom_reset":
			_zoom_reset()
		"font_small":
			_set_font_size("small")
		"font_medium":
			_set_font_size("medium")
		"font_large":
			_set_font_size("large")
		"help_mcp":
			_show_mcp_info()
		"help_about":
			_show_about()
		"preferences":
			_show_preferences()


# -- File dialog callbacks -------------------------------------------------

func _on_open_file_selected(path: String) -> void:
	_state.load_dct(path)
	_add_to_recent(path)
	_update_window_title()
	_update_project_menu()
	_save_session()


func _on_save_as_file_selected(path: String) -> void:
	_state.dct_path = path
	_state.save()
	_add_to_recent(path)
	_update_window_title()


func _on_new_file_selected(path: String) -> void:
	# If projects are already loaded, append instead of replacing
	if _state._project_dbs.size() > 0:
		_state.create_and_add_project(path)
	else:
		_state.create_dct(path)
	_add_to_recent(path)
	_update_window_title()
	_update_project_menu()
	_save_session()


func _update_window_title() -> void:
	if _state.dct_path.is_empty():
		DisplayServer.window_set_title("Docket")
		_file_label.text = ""
	else:
		var fname := _state.dct_path.get_file()
		DisplayServer.window_set_title("Docket — %s" % fname)
		_file_label.text = fname


func _update_project_menu() -> void:
	## Update the Close Project submenu: each entry shows the project's storage
	## mode beside its lifecycle stage, e.g. "scratch — session_file · stage: none".
	var names := PackedStringArray()
	var labels := PackedStringArray()
	for proj_name in _state.get_project_dbs():
		var pdb: DocketDB = _state.get_project_dbs()[proj_name]
		var stage := str(pdb.get_project_meta().get("stage", ""))
		names.append(proj_name)
		labels.append("%s — %s · stage: %s" % [proj_name, SessionProject.mode_of(pdb), stage if not stage.is_empty() else "none"])
	_menu_builder.set_project_list(names, labels)


func _save_session() -> void:
	if _state.get_project_dbs().is_empty():
		return  # Don't clobber saved session with empty data
	var paths := PackedStringArray()
	for proj_name in _state.get_project_dbs():
		var pdb: DocketDB = _state.get_project_dbs()[proj_name]
		var p := pdb.get_path()
		if not p.is_empty() and not pdb is DocketDBMemory:
			paths.append(ProjectSettings.globalize_path(p) if p.begins_with("res://") else p)
	UserPrefs.save_session(paths)


# -- Grid/form callbacks ---------------------------------------------------

func _build_new_item_dialog() -> void:
	_new_item_dialog = ConfirmationDialog.new()
	_new_item_dialog.title = "New item"
	_new_item_dialog.ok_button_text = "Create draft"
	_new_item_dialog.confirmed.connect(_on_new_item_confirmed)
	var content := VBoxContainer.new()
	_new_item_project = OptionButton.new()
	_new_item_project.item_selected.connect(func(_index: int): _rebuild_new_item_catalog())
	content.add_child(_new_item_project)
	_new_item_search = LineEdit.new()
	_new_item_search.placeholder_text = "Search type name, purpose, or slug"
	_new_item_search.text_changed.connect(func(_value: String): _filter_new_item_catalog())
	content.add_child(_new_item_search)
	_new_item_list = ItemList.new()
	_new_item_list.custom_minimum_size = Vector2(520, 320)
	_new_item_list.item_activated.connect(func(_index: int):
		_on_new_item_confirmed()
		_new_item_dialog.hide()
	)
	content.add_child(_new_item_list)
	_new_item_dialog.add_child(content)
	add_child(_new_item_dialog)

func _show_new_item_dialog() -> void:
	_new_item_project.clear()
	var projects: Array = _state.get_project_dbs().keys()
	projects.sort_custom(func(a, b): return str(a).nocasecmp_to(str(b)) < 0)
	for project in projects:
		_new_item_project.add_item(str(project))
	_new_item_search.text = ""
	_rebuild_new_item_catalog()
	_new_item_dialog.popup_centered(Vector2i(560, 430))

func _rebuild_new_item_catalog() -> void:
	_new_item_catalog.clear()
	_new_item_dialog.get_ok_button().disabled = false
	_new_item_dialog.dialog_text = ""
	if _new_item_project.item_count == 0:
		_filter_new_item_catalog()
		return
	var project: String = _new_item_project.get_item_text(_new_item_project.selected)
	var registry: TypeRegistry = _state.get_type_registry(project)
	if registry == null:
		_new_item_dialog.dialog_text = "Type registry unavailable for %s." % project
		_new_item_dialog.get_ok_button().disabled = true
		_filter_new_item_catalog()
		return
	var listed: Array = registry.list_types(false)
	if not listed.is_empty() and listed[0] is Dictionary and listed[0].has("error"):
		_new_item_dialog.dialog_text = "Type registry error: %s" % str(listed[0].error)
		_new_item_dialog.get_ok_button().disabled = true
		_filter_new_item_catalog()
		return
	for type_value in listed:
		var type: Dictionary = type_value
		if type.has("error") or type.lifecycle != "active":
			continue
		if not bool(type.definition.get("protected_behavior", {}).get("regular_creation_allowed", true)):
			continue
		var catalog_record: Dictionary = type.duplicate(true)
		catalog_record["project"] = project
		_new_item_catalog.append(catalog_record)
	_filter_new_item_catalog()

func _filter_new_item_catalog() -> void:
	_new_item_list.clear()
	var needle := _new_item_search.text.to_lower()
	for type_value in _new_item_catalog:
		var type: Dictionary = type_value
		var aliases: Array = type.definition.get("aliases", [])
		var searchable := "%s %s %s %s %s" % [type.label, type.slug, type.description, type.use_when, str(aliases)]
		if not needle.is_empty() and not searchable.to_lower().contains(needle):
			continue
		_new_item_list.add_item("%s — %s" % [type.label, type.description])
		_new_item_list.set_item_metadata(_new_item_list.item_count - 1, {"project":str(type.project), "type_id":type.id, "slug":type.slug})
	if _new_item_list.item_count > 0:
		_new_item_list.select(0)

func _on_new_item_confirmed() -> void:
	if _new_item_list.get_selected_items().is_empty() or _new_item_project.item_count == 0:
		return
	var index: int = _new_item_list.get_selected_items()[0]
	var selection: Dictionary = _new_item_list.get_item_metadata(index)
	_create_and_edit_item(str(selection.slug), str(selection.project), false, str(selection.type_id))

func _on_item_selected(id: String, project: String = "") -> void:
	if _record_form.is_inside_tree():
		_record_form.load_item(id, project)


func _create_and_edit_item(type_name: String, project: String = "", protected_path: bool = false, expected_type_id: String = "") -> void:
	var registry := _state.get_type_registry(project)
	if registry == null:
		return
	var type: Dictionary = registry.get_type(type_name)
	if type.has("error") or type.lifecycle != "active":
		return
	if not expected_type_id.is_empty() and str(type.id) != expected_type_id:
		return
	var regular_creation_allowed: bool = bool(type.definition.get("protected_behavior", {}).get("regular_creation_allowed", true))
	if not regular_creation_allowed and not protected_path:
		return
	var item := {"type":type_name, "status":type.definition.lifecycle.initial_state, "title":"", "fields":{}}
	_record_form.load_draft(type_name, item, project)
	switch_view(ViewMode.DETAIL)



func _on_item_activated(id: String, project: String = "") -> void:
	_on_item_selected(id, project)
	_open_item_entry(id, project)


func _open_item_entry(id: String, project: String = "") -> void:
	# Reuse existing work entry for this item, or create one
	var idx := _find_item_work_entry(id, project)
	if idx >= 0:
		_activate_work_entry(idx)
	else:
		var label := id
		var item_db: DocketDB = _state.get_db_for_project(project)
		if item_db != null and item_db.has_item(id):
			var item: Dictionary = item_db.get_item(id)
			label = "[%s] %s: %s" % [project, id, str(item.get("title", ""))]
		idx = _add_work_entry("item", label, "", id, project)
		_activate_work_entry(idx)


func _on_item_changed() -> void:
	_query_grid.refresh()
	# Update the work entry label if the title changed
	if _current_work_idx >= 0 and _current_work_idx < _work_entries.size():
		var entry: Dictionary = _work_entries[_current_work_idx]
		var item_db: DocketDB = _state.get_db_for_project(str(entry.get("project", "")))
		if entry.type == "item" and item_db != null and item_db.has_item(entry.item_id):
			var item: Dictionary = item_db.get_item(entry.item_id)
			entry.label = "[%s] %s: %s" % [entry.project, entry.item_id, str(item.get("title", ""))]
			_rebuild_work_menu()


func _on_back_pressed() -> void:
	if _nav_history.size() > 0:
		var prev_idx: int = _nav_history.pop_back()
		# Navigate without pushing to history (avoid back-loop)
		_save_current_work_state()
		_current_work_idx = prev_idx
		var entry: Dictionary = _work_entries[prev_idx]
		if entry.type == "query":
			_query_grid.set_filter(entry.filter)
			switch_view(ViewMode.QUERY)
		elif entry.type == "item":
			_record_form.load_item(entry.item_id, str(entry.get("project", "")))
			switch_view(ViewMode.DETAIL)
		_rebuild_work_menu()
	else:
		switch_view(ViewMode.QUERY)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE and _current_mode == ViewMode.DETAIL:
			_on_back_pressed()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ENTER and _current_mode == ViewMode.QUERY:
			var focused := get_viewport().gui_get_focus_owner()
			if focused is LineEdit or focused is TextEdit:
				return
			var origin := _query_grid.get_selected_origin()
			if not origin.is_empty():
				_open_item_entry(str(origin.id), str(origin.project))
				get_viewport().set_input_as_handled()


# -- Add Project / Query file callbacks ------------------------------------

func _on_open_query_from_mcp(filter: String, label: String) -> void:
	# Defer to next frame — signal may fire during HTTP _process()
	(func():
		var idx := _add_work_entry("query", label, filter, "")
		_activate_work_entry(idx)
	).call_deferred()


func _on_add_project_selected(path: String) -> void:
	_state.add_project(path)
	_add_to_recent(path)
	_update_project_menu()
	_save_session()


func _on_open_query_selected(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		return
	var label: String = str(parsed.get("name", path.get_file().get_basename()))
	var filter_json: String = JSON.stringify(parsed.get("filter", {}))
	var idx := _add_work_entry("query", label, filter_json, "")
	_activate_work_entry(idx)


func _on_save_query_selected(path: String) -> void:
	_query_grid.save_dcq(path)


# -- Zoom / Font size ------------------------------------------------------

func _zoom_in() -> void:
	if _current_zoom_idx < _ZOOM_LEVELS.size() - 1:
		_current_zoom_idx += 1
		_apply_zoom()


func _zoom_out() -> void:
	if _current_zoom_idx > 0:
		_current_zoom_idx -= 1
		_apply_zoom()


func _zoom_reset() -> void:
	_current_zoom_idx = 2  # 1.0
	_apply_zoom()


func _apply_zoom() -> void:
	var zoom_factor: float = _ZOOM_LEVELS[_current_zoom_idx]
	get_tree().root.content_scale_factor = zoom_factor
	if _state.db:
		_state.db.set_meta_value("ui_scale", str(zoom_factor))


func _set_font_size(preset: String) -> void:
	_current_font_size = preset
	var font_sz: int = _FONT_SIZES.get(preset, 14)
	get_tree().root.add_theme_font_size_override("font_size", font_sz)
	if _state.db:
		_state.db.set_meta_value("ui_font_size", preset)


func _restore_ui_settings() -> void:
	if not _state.db:
		return
	var scale_str := _state.db.get_meta_value("ui_scale", "1.0")
	var zoom_factor := float(scale_str)
	for i in _ZOOM_LEVELS.size():
		if absf(_ZOOM_LEVELS[i] - zoom_factor) < 0.01:
			_current_zoom_idx = i
			break
	get_tree().root.content_scale_factor = zoom_factor

	var font_preset := _state.db.get_meta_value("ui_font_size", "medium")
	_current_font_size = font_preset
	var font_size: int = _FONT_SIZES.get(font_preset, 14)
	get_tree().root.add_theme_font_size_override("font_size", font_size)


func _show_mcp_info() -> void:
	_info_dialog.title = "MCP Connection"
	_info_dialog.dialog_text = (
		"Docket MCP Server\n\n" +
		"Transport:  HTTP JSON-RPC 2.0\n" +
		"Endpoint:   POST http://127.0.0.1:3010/mcp\n" +
		"Port:       3010 (default, --port to override)\n\n" +
		"Start server:\n" +
		"  godot --headless --path <project> -- serve\n" +
		"  godot --headless --path <project> -- serve --port 3010\n\n" +

		"Tools: %d registered — call tools/list for the full set.\n\n" % _mcp_tool_count() +
		"File: %s" % _state.dct_path
	)
	_info_dialog.popup_centered()


func _mcp_tool_count() -> int:
	## Registered tool count, read from the registry rather than restated — a
	## hardcoded list here drifted out of date as tools were added.
	var reg := ToolRegistry.new()
	reg.init(_state.schema, _state.db, _state.get_project_dbs())
	return reg.list_tools().size()


func _show_vault() -> void:
	## List vault entries that belong to no work item.
	##
	## These are created over MCP (docket_secret_set) and have no row in `items`,
	## so they cannot appear in the query grid — before this they were invisible
	## to anyone not driving the MCP surface. Values are never shown here; this
	## is an inventory, not a viewer.
	var lines: PackedStringArray = []
	var total := 0
	for proj_name in _state.get_project_dbs():
		var pdb: DocketDB = _state.get_project_dbs()[proj_name]
		var entries: Array = pdb.list_standalone_secrets()
		if entries.is_empty():
			continue
		lines.append("%s:" % proj_name)
		for e in entries:
			total += 1
			var flag: String = "  [2FA]" if bool(e.get("requires_2fa", false)) else ""
			lines.append("   %s%s" % [str(e.get("handle", "")), flag])
			lines.append("      updated %s" % str(e.get("updated_at", "")))
		lines.append("")

	_info_dialog.title = "Vault — standalone secrets"
	if total == 0:
		_info_dialog.dialog_text = (
			"No standalone vault entries.\n\n"
			+ "Secrets attached to a Secret work item appear in the item list "
			+ "instead. Entries shown here are ones created directly in the vault, "
			+ "typically by an agent over MCP."
		)
	else:
		_info_dialog.dialog_text = (
			"%d entr%s belonging to no work item.\n" % [total, "y" if total == 1 else "ies"]
			+ "Promote one with docket_secret_promote to give it a title, status and history.\n\n"
			+ "\n".join(lines)
		)
	_info_dialog.popup_centered(Vector2i(560, 420))


func _show_about() -> void:
	_info_dialog.title = "About Docket"
	# Derive the type list from the schema rather than restating it — a
	# hardcoded count goes stale the moment a type is added.
	var type_names: Array = []
	if _state.schema.has("types"):
		type_names = _state.schema.types.keys()
	type_names.sort()

	_info_dialog.dialog_text = (
		"Docket — RAID-Inspired Work-Item Tracker\n" +
		"by Imran Peerbhai\n\n" +
		"%d item types, each with its own state machine:\n" % type_names.size() +
		"%s\n\n" % ", ".join(PackedStringArray(type_names)) +
		"Secrets and encrypted notes require a vault password (Preferences).\n" +
		"Data format: .dct (JSONL text, with a SQLite cache)\n" +
		"Schema: data/schema.json\n\n" +
		"Licensed under the Mozilla Public License 2.0."
	)
	_info_dialog.popup_centered()


func _show_preferences() -> void:
	_prefs_first.text = _state.prefs.first_name
	_prefs_last.text = _state.prefs.last_name
	_prefs_vault_pw.text = UserPrefs.load_vault_password()
	_prefs_vault_hint.text = UserPrefs.load_vault_password_hint()
	_prefs_dialog.popup_centered(Vector2i(300, 380))


func _on_prefs_confirmed() -> void:
	_state.prefs.first_name = _prefs_first.text.strip_edges()
	_state.prefs.last_name = _prefs_last.text.strip_edges()
	_state.prefs.save()

	# Save vault password hint
	UserPrefs.save_vault_password_hint(_prefs_vault_hint.text.strip_edges())

	# Handle vault password change
	var new_password := _prefs_vault_pw.text
	var old_password := UserPrefs.load_vault_password()
	if new_password != old_password:
		_reencrypt_vault_secrets(old_password, new_password)
		if new_password.is_empty():
			UserPrefs.clear_vault_password()
		else:
			UserPrefs.save_vault_password(new_password)


func _reencrypt_vault_secrets(old_password: String, new_password: String) -> void:
	## Re-encrypt all secrets in all open dockets when vault password changes.
	if old_password.is_empty() or new_password.is_empty():
		return
	for proj_name in _state.get_project_dbs():
		var pdb: DocketDB = _state.get_project_dbs()[proj_name]
		if not pdb.has_vault():
			continue
		var old_salt := pdb.get_vault_salt()
		# Unwrap at whatever cost this vault was built with...
		var old_key := VaultCrypto.derive_key(old_password, old_salt, pdb.get_vault_iterations())
		if not pdb.verify_vault(old_key):
			push_warning("Vault password mismatch for project '%s', skipping re-encryption" % proj_name)
			continue
		# A dual-password secret is encrypted twice: an inner layer under a key
		# derived from the SECONDARY password, and an outer layer under the vault
		# key. Only the outer layer can be re-wrapped here — the secondary
		# password is not known, and is deliberately never stored.
		#
		# That constrains what a password change may alter. The secondary key is
		# derived from (secondary password, vault salt, iteration count), so
		# changing the salt or the cost silently re-defines a key nobody can
		# reproduce, leaving the inner layer permanently undecryptable. The old
		# code regenerated the salt, raised the cost, and dropped requires_2fa —
		# any of which alone destroys a 2FA secret.
		var has_2fa := false
		for probe in pdb.get_all_secrets_raw():
			if bool(probe.get("requires_2fa", false)):
				has_2fa = true
				break

		# Reusing the salt is safe: a salt must be unique per vault, not per
		# password change, and the new password already yields a different key.
		var new_salt := old_salt
		var new_iters := pdb.get_vault_iterations()
		if not has_2fa:
			# No inner layer to strand, so take the opportunity to re-salt and
			# upgrade the KDF cost.
			new_salt = VaultCrypto.generate_salt()
			new_iters = VaultCrypto.PBKDF2_ITERATIONS
		elif pdb.get_vault_iterations() < VaultCrypto.PBKDF2_ITERATIONS:
			push_warning(
				"Project '%s' holds dual-password secrets, so its KDF cost cannot be " % proj_name
				+ "raised by a password change without their secondary passwords.")

		var new_key := VaultCrypto.derive_key(new_password, new_salt, new_iters)
		for secret in pdb.get_all_secrets_raw():
			# Single-layer decrypt is correct for both kinds: for a 2FA secret it
			# yields the still-encrypted inner blob, which is re-wrapped as-is.
			var payload := VaultCrypto.decrypt(secret.ciphertext, secret.iv, secret.mac, old_key)
			if payload.is_empty():
				push_warning("Failed to decrypt secret '%s' in '%s', skipping" % [secret.handle, proj_name])
				continue
			var encrypted := VaultCrypto.encrypt(payload, new_key)
			# requires_2fa must survive, or the reader will not know to peel the
			# inner layer and will hand back ciphertext as though it were plaintext.
			pdb.set_secret(secret.handle, encrypted.ciphertext, encrypted.iv, encrypted.mac,
				bool(secret.get("requires_2fa", false)))
		pdb.init_vault(new_key, new_salt, new_iters)


func _on_viewport_resized() -> void:
	size = get_viewport().get_visible_rect().size


func _load_recent_files() -> void:
	_recent_files = PackedStringArray()
	if not FileAccess.file_exists(_RECENTS_PATH):
		return
	var f := FileAccess.open(_RECENTS_PATH, FileAccess.READ)
	if not f:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Array:
		for p in parsed:
			_recent_files.append(str(p))


func _save_recent_files() -> void:
	var arr: Array = []
	for p in _recent_files:
		arr.append(p)
	var f := FileAccess.open(_RECENTS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(arr))


func _add_to_recent(path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	# Remove if already present, then prepend
	var updated := PackedStringArray()
	updated.append(abs_path)
	for p in _recent_files:
		if p != abs_path and updated.size() < _MAX_RECENTS:
			updated.append(p)
	_recent_files = updated
	_save_recent_files()
	_menu_builder.set_recent_files(_recent_files)
