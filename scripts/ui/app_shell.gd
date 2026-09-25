extends VBoxContainer
## Top-level VBoxContainer: MenuBar + content area with work-entry switching.
## Each open query or item is a "work entry" listed in the Work menu.

const MenuBuilder := preload("menu_builder.gd")
const ProjectTypesPanel := preload("project_types_panel.gd")
const QueryGrid := preload("query_grid.gd")
const RecordForm := preload("record_form.gd")

enum ViewMode { QUERY, DETAIL, SPLIT, TYPES }

var _src  # DocketSource
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
# The form's load generation when _confirm_reload_dialog asked about its
# item: confirming acts only while the form still shows that load.
var _reload_asked_generation := -1
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

# Recent files (kept by the DocketSource)
const _MAX_RECENTS := 5
var _recent_files: PackedStringArray = []

# Inside a host: the shell leaves the host's window, root theme and process
# alone (no quit, title, zoom or sizing of its own), and fills its parent.
var _embedded := false
# Whether `theme` is the shell's own copy (made inside a host the first time
# a font size is applied, which is at start).
var _owns_theme := false

# External change polling
var _poll_timer: Timer
var _last_projects_token: String = ""
# True while an external-change poll is running, so timer ticks do not stack.
var _polling := false
# Why a project cannot be read as its file now (DocketSource.unavailable), as
# shown; {} when all can be. A retryable one is read again by a poll at
# _retry_at_msec, backing off to a minute; any other waits for the person
# (Reload from Disk, closing the project) or another change to the files.
var _unavailable: Dictionary = {}
var _unavailable_banner: Label
var _retry_at_msec := 0
var _retry_backoff_msec := 0
# How many refusals have been shown, so a poll knows whether one came in
# while it looked at the open item.
var _unavailable_shown := 0
# Set by Reload from Disk: the next poll checks readiness whatever the token.
var _recheck := false
# The source's reload_revision the view was last brought up to.
var _reconciled_revision := ""
# The open item's changed version last asked about (project|id|token), so a
# change is asked about once.
var _prompted_for := ""
# Bumped by each new-item catalog rebuild, so a slower earlier one is dropped.
var _catalog_generation := 0


## `source` is a DocketSource (LocalDocketSource in the standalone app);
## `embedded` when a host shows the shell inside its own window.
func init(source, embedded := false) -> void:
	_src = source
	_embedded = embedded
	_build_ui()


func _ready() -> void:
	if _embedded:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		# Viewport is available now that we're in the tree.
		size = get_viewport().get_visible_rect().size
		get_viewport().size_changed.connect(_on_viewport_resized)

	# Restore persisted UI settings (zoom, font size)
	_restore_ui_settings()

	# Restore last query if available, otherwise start with "All Items"
	var last_q: Dictionary = _src.last_query()
	if last_q.is_empty():
		_add_work_entry("query", "All Items", "", "")
	else:
		_add_work_entry("query", last_q.label, last_q.filter, "")
	_activate_work_entry(0)
	var not_restored: String = _src.last_query_refusal()
	if not not_restored.is_empty():
		_info_dialog.title = "Last query not restored"
		_info_dialog.dialog_text = not_restored
		_info_dialog.popup_centered.call_deferred()

	# Poll for external DB changes (e.g. MCP writes) every 3 seconds
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 3.0
	_poll_timer.timeout.connect(_on_poll_external_changes)
	add_child(_poll_timer)
	_poll_timer.start()
	_last_projects_token = await _src.change_token()
	_reconciled_revision = await _src.reload_revision()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _embedded:
		_save_current_work_state()
		_persist_last_query()
		get_tree().quit()
	elif what == NOTIFICATION_PREDELETE and _src != null:
		_src.stop_watching()


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
	var not_kept: String = _src.save_last_query(entry.filter, entry.label)
	if not not_kept.is_empty():
		print("Docket: %s" % not_kept)


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
	var type_keys: Array = _src.schema().types.keys()
	type_keys.sort()
	var type_names := PackedStringArray()
	for t in type_keys:
		type_names.append(t)
	var mbar := _menu_builder.build(type_names, _embedded)
	if _embedded:
		# Menu shortcuts too act only while focus is within the shell.
		mbar.shortcut_context = self

	_load_recent_files()
	_menu_builder.set_recent_files(_recent_files)
	if not _src.primary_path().is_empty():
		_add_to_recent(_src.primary_path())

	var menu_row := HBoxContainer.new()
	menu_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu_row.add_child(mbar)

	# Spacer pushes filename to the right
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu_row.add_child(spacer)

	_file_label = Label.new()
	_file_label.text = _src.primary_path().get_file()
	_file_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	menu_row.add_child(_file_label)

	menu_panel.add_child(menu_row)
	add_child(menu_panel)

	_unavailable_banner = Label.new()
	_unavailable_banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_unavailable_banner.add_theme_color_override("font_color", Color(1.0, 0.75, 0.35))
	_unavailable_banner.visible = false
	add_child(_unavailable_banner)

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
	_query_grid.init(_src)
	_query_grid.item_selected.connect(_on_item_selected)
	_query_grid.item_activated.connect(_on_item_activated)

	_record_form = RecordForm.new()
	_record_form.custom_minimum_size.x = 400
	_record_form.init(_src)
	_record_form.item_changed.connect(_on_item_changed)
	_record_form.back_pressed.connect(_on_back_pressed)
	_record_form.child_opened.connect(_open_item_entry)
	_project_types = ProjectTypesPanel.new()
	_project_types.init(_src)
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
	_build_new_item_dialog()

	# A .dct that could not be opened (conflict markers, corruption)
	_src.load_failed.connect(_on_load_failed)

	# Populate Close Project submenu with current projects
	_update_project_menu()

	# Listen for project changes to update menu and persist session
	_src.file_changed.connect(_on_file_changed)
	_src.open_item_changed_elsewhere.connect(_on_open_item_changed_elsewhere)
	_src.open_item_unchecked.connect(_on_open_item_unchecked)
	_src.watch_open_item(_open_item)
	_src.open_item_requested.connect(func(id: String, project: String): _open_item_entry.call_deferred(id, project))
	_src.open_query_requested.connect(_on_open_query_from_mcp)
	_src.unavailable.connect(_show_unavailable)

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

func _on_file_changed() -> void:
	## Project list changed — update menus and persist session.
	_update_project_menu()
	_save_session()
	_restore_ui_settings()


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
	if _polling:
		return
	_polling = true
	await _poll_external_changes()
	_polling = false


func _poll_external_changes() -> void:
	# A change on disk is looked at once; a failure to read it stays shown and,
	# when retryable, is tried again here though nothing has changed since.
	# What was read again is known by the source's reload_revision, whichever
	# read took it in, so a lookup that reloaded first does not hide it.
	var current_token: String = await _src.change_token()
	var retry_due := _recheck or (bool(_unavailable.get("retryable", false)) and Time.get_ticks_msec() >= _retry_at_msec)
	var revision: String = await _src.reload_revision()
	if current_token == _last_projects_token and not retry_due and revision == _reconciled_revision:
		return
	_last_projects_token = current_token
	_recheck = false

	# The open item as the form loaded it (its own token, never a fresh look).
	var open_item := _open_item()
	var generation: int = _record_form._load_generation if _record_form else -1

	var reloaded: Array = await _src.reload_stale()
	var failure: Dictionary = await _src.readiness_failure()
	if not failure.is_empty():
		if bool(failure.get("retryable", false)):
			_retry_backoff_msec = clampi(_retry_backoff_msec * 2, 3000, 60000)
			_retry_at_msec = Time.get_ticks_msec() + _retry_backoff_msec
		_show_unavailable(failure)
		return
	var recovered := not _unavailable.is_empty()
	_clear_unavailable()
	revision = await _src.reload_revision()
	if revision == _reconciled_revision and reloaded.is_empty() and not recovered:
		return
	if _query_grid and _query_grid.is_visible_in_tree():
		_query_grid.refresh()

	# Item-scoped policy: an external change to some *other* item is none of the
	# open form's business, so reload silently. Only a change to the item under
	# edit is worth interrupting for — the user may have unsaved edits, and
	# saving them would overwrite what just arrived.
	if not open_item.is_empty():
		var shown := _unavailable_shown
		var now: String = await _item_revision(str(open_item.id), str(open_item.project))
		if _unavailable_shown != shown:
			return  # not looked up: shown as unavailable, and looked at again
		if now != str(open_item.token) and _record_form._still_showing(generation):
			var seen := "%s|%s|%s" % [open_item.project, open_item.id, now]
			if seen != _prompted_for:
				_prompted_for = seen
				_ask_about_open_item("The item you have open was deleted on disk." if now.is_empty()
					else "The item you have open changed on disk.", now.is_empty(), "Item changed on disk",
					"Load from disk", generation)
	_reconciled_revision = revision


## The form's open item as the source compares changes made elsewhere with
## it: {project, id, token} (the token the form loaded), or {}.
func _open_item() -> Dictionary:
	var open_id := _record_form.get_current_id() if _record_form else ""
	if open_id.is_empty():
		return {}
	return {"project": _record_form.get_current_project(), "id": open_id, "token": _record_form.get_loaded_token()}


# Emitted right after the source saw the form still showing that item.
func _on_open_item_changed_elsewhere(_project: String, _id: String, deleted: bool) -> void:
	var generation: int = _record_form._load_generation
	if deleted:
		_ask_about_open_item("The item you have open was deleted elsewhere.", true,
			"Item changed elsewhere", "Go back to the list", generation)
	else:
		_ask_about_open_item("The item you have open was changed elsewhere.", false,
			"Item changed elsewhere", "Load the new version", generation)


func _on_open_item_unchecked(_project: String, _id: String, error: String) -> void:
	_info_dialog.title = "Could not check the open item"
	_info_dialog.dialog_text = ("It may have been changed elsewhere, but it could not be looked up: %s\n\n"
		% error + "Your edits are kept.")
	_info_dialog.popup_centered()


## Ask about the open item as the form showed it at load `generation`.
func _ask_about_open_item(what_happened: String, deleted: bool, title: String, load_text: String,
		generation: int) -> void:
	_confirm_reload_dialog.title = title
	_confirm_reload_dialog.ok_button_text = load_text
	_confirm_reload_dialog.dialog_text = what_happened + "\n\n" + (
		"Discard it and go back to the list, or keep your copy open to re-save it?" if deleted
		else "Load the new version, or keep your unsaved edits?")
	_ask_to_reload(generation)


func _ask_to_reload(generation: int) -> void:
	_reload_asked_generation = generation
	_confirm_reload_dialog.popup_centered()


func _item_revision(item_id: String, project: String = "") -> String:
	return await _src.item_token(project, item_id)


## Shows why a project cannot be read as its file (DocketSource.unavailable):
## what is on screen stays, dimmed, and every change is refused (with this
## reason) until it can be.
func _show_unavailable(failure: Dictionary) -> void:
	_unavailable_shown += 1
	if bool(failure.get("retryable", false)) and _retry_backoff_msec == 0:
		_retry_backoff_msec = 3000
		_retry_at_msec = Time.get_ticks_msec() + _retry_backoff_msec
	_unavailable = failure
	_unavailable_banner.text = "%s. What is shown may not be current, and changes wait until %s" % [
		str(failure.get("message", "")),
		"it can be read again (retrying)" if bool(failure.get("retryable", false)) else "the project is reloaded from disk or opened again"]
	_unavailable_banner.visible = true
	_content_area.modulate = Color(1, 1, 1, 0.6)


func _clear_unavailable() -> void:
	_retry_backoff_msec = 0
	if _unavailable.is_empty():
		return
	_unavailable = {}
	_unavailable_banner.visible = false
	_content_area.modulate = Color(1, 1, 1, 1)


func _on_reload_from_disk() -> void:
	## File > Reload from Disk — unconditional re-read, discarding cache.
	_recheck = true
	var open_id := _record_form.get_current_id() if _record_form else ""
	var open_project := _record_form.get_current_project() if _record_form else ""
	var generation: int = _record_form._load_generation if _record_form else -1
	var reloaded: Array = await _src.reload_all()
	_last_projects_token = await _src.change_token()
	# What this reload brings is dealt with here, not asked about again by a poll.
	_reconciled_revision = await _src.reload_revision()

	if _query_grid and _query_grid.is_visible_in_tree():
		_query_grid.refresh()
	if not open_id.is_empty():
		var gone: bool = (await _item_revision(open_id, open_project)).is_empty()
		if not _record_form._still_showing(generation):
			pass  # the form moved on meanwhile; nothing to ask about
		elif gone:
			_on_back_pressed()  # the open item no longer exists on disk
		else:
			_confirm_reload_dialog.title = "Item changed on disk"
			_confirm_reload_dialog.ok_button_text = "Load from disk"
			_confirm_reload_dialog.dialog_text = "Reloaded project data is available. Load it and discard the current form edits, or keep reviewing the unsaved form?"
			_ask_to_reload(generation)

	if reloaded.is_empty():
		_info_dialog.title = "Reload from Disk"
		_info_dialog.dialog_text = "Nothing to reload — no JSONL projects are open."
		_info_dialog.popup_centered()


## The person chose to take the stored version, discarding unsaved form
## edits: of the item asked about, and only while the form still shows it as
## it did then (it may have moved on, before or during the lookup).
func _on_reload_open_item_confirmed() -> void:
	var generation := _reload_asked_generation
	if not _record_form or not _record_form._still_showing(generation):
		return
	var open_id := _record_form.get_current_id()
	var open_project := _record_form.get_current_project()
	if open_id.is_empty():
		return
	var gone: bool = (await _item_revision(open_id, open_project)).is_empty()
	if not _record_form._still_showing(generation):
		return
	if gone:
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
		_create_and_edit_item(protected_type, _src.primary_project(), true)
		return
	if action.begins_with("work:"):
		var idx := int(action.substr("work:".length()))
		if idx >= 0 and idx < _work_entries.size():
			_activate_work_entry(idx)
		return
	if action.begins_with("open_recent:"):
		var recent_idx := int(action.split(":")[1])
		if recent_idx >= 0 and recent_idx < _recent_files.size():
			await _src.open_project(_recent_files[recent_idx])
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
				await _src.add_project(path)
				_add_to_recent(path)
				_update_window_title()
				_update_project_menu()
				_save_session()
		return
	if action.begins_with("close_project:"):
		var proj_name := action.substr("close_project:".length())
		await _src.remove_project(proj_name)
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
			_src.save_all()
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
			if _embedded:
				return
			_save_current_work_state()
			_persist_last_query()
			get_tree().quit()
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
	await _src.open_project(path)
	_add_to_recent(path)
	_update_window_title()
	_update_project_menu()
	_save_session()


func _on_save_as_file_selected(path: String) -> void:
	await _src.save_primary_as(path)
	_add_to_recent(path)
	_update_window_title()


func _on_new_file_selected(path: String) -> void:
	# Appended beside any projects already open.
	await _src.create_project(path)
	_add_to_recent(path)
	_update_window_title()
	_update_project_menu()
	_save_session()


func _update_window_title() -> void:
	var fname: String = _src.primary_path().get_file()
	_file_label.text = fname
	if not _embedded:
		DisplayServer.window_set_title("Docket — %s" % fname if not fname.is_empty() else "Docket")


func _update_project_menu() -> void:
	## Update the Close Project submenu with current project names.
	var names := PackedStringArray()
	for proj_name in _src.project_paths():
		names.append(proj_name)
	_menu_builder.set_project_list(names)


func _save_session() -> void:
	var project_paths: Dictionary = _src.project_paths()
	if project_paths.is_empty():
		return  # Don't clobber saved session with empty data
	var paths := PackedStringArray()
	for proj_name in project_paths:
		var p: String = project_paths[proj_name]
		if not p.is_empty():
			paths.append(ProjectSettings.globalize_path(p) if p.begins_with("res://") else p)
	_src.save_session(paths)


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
	for project in _src.project_names():
		_new_item_project.add_item(project)
	_new_item_search.text = ""
	await _rebuild_new_item_catalog()
	_new_item_dialog.popup_centered(Vector2i(560, 430))

func _rebuild_new_item_catalog() -> void:
	_catalog_generation += 1
	var generation := _catalog_generation
	# The previous project's entries go at once, and OK waits for this one's.
	_new_item_catalog.clear()
	_filter_new_item_catalog()
	_new_item_dialog.get_ok_button().disabled = true
	_new_item_dialog.dialog_text = ""
	if _new_item_project.item_count == 0:
		_new_item_dialog.get_ok_button().disabled = false
		return
	var project: String = _new_item_project.get_item_text(_new_item_project.selected)
	var listed_result: Dictionary = await _src.list_types(project)
	if generation != _catalog_generation:
		return
	_new_item_dialog.get_ok_button().disabled = listed_result.has("error")
	if listed_result.has("error"):
		_new_item_dialog.dialog_text = str(listed_result.error)
		_filter_new_item_catalog()
		return
	for type_value in listed_result.types:
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
	var type: Dictionary = await _src.get_type(project, type_name)
	if type.has("kind"):
		_info_dialog.title = "Not created"
		_info_dialog.dialog_text = str(type.error)
		_info_dialog.popup_centered()
		return
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
		var titled: Dictionary = await _src.item_title(project, id)
		if titled.has("title"):
			label = "[%s] %s: %s" % [project, id, str(titled.title)]
		# Another open of the same item may have added its entry meanwhile.
		idx = _find_item_work_entry(id, project)
		if idx < 0:
			idx = _add_work_entry("item", label, "", id, project)
		_activate_work_entry(idx)


func _on_item_changed() -> void:
	_query_grid.refresh()
	# Update the work entry label if the title changed
	if _current_work_idx >= 0 and _current_work_idx < _work_entries.size():
		var entry: Dictionary = _work_entries[_current_work_idx]
		if entry.type != "item":
			return
		var titled: Dictionary = await _src.item_title(str(entry.get("project", "")), str(entry.item_id))
		if titled.has("title"):
			entry.label = "[%s] %s: %s" % [entry.project, entry.item_id, str(titled.title)]
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
	# Inside a host, keys are the shell's only while focus is within it.
	if _embedded:
		var focused := get_viewport().gui_get_focus_owner()
		if focused == null or not is_ancestor_of(focused):
			return
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
	await _src.add_project(path)
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
	var error: String = _query_grid.save_dcq(path)
	if not error.is_empty():
		_info_dialog.title = "Query not saved"
		_info_dialog.dialog_text = error
		_info_dialog.popup_centered()


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
	if _embedded:
		return
	var zoom_factor: float = _ZOOM_LEVELS[_current_zoom_idx]
	get_tree().root.content_scale_factor = zoom_factor
	_src.set_ui_setting("ui_scale", str(zoom_factor))


func _set_font_size(preset: String) -> void:
	_current_font_size = preset
	_apply_font_size(_FONT_SIZES.get(preset, 14))
	_src.set_ui_setting("ui_font_size", preset)


# The window's font size in the standalone app; inside a host, only the
# shell's own: a theme of its own (a copy of any it was given, which may be
# shared), which its children inherit.
func _apply_font_size(font_size: int) -> void:
	if not _embedded:
		get_tree().root.add_theme_font_size_override("font_size", font_size)
		return
	if not _owns_theme:
		theme = theme.duplicate() if theme != null else Theme.new()
		_owns_theme = true
	theme.default_font_size = font_size


## Apply the zoom and font size kept for this machine. Run again when the
## projects change, as a value not kept yet may come from the new primary
## project's file (DocketSource.ui_setting).
func _restore_ui_settings() -> void:
	var scale_str: String = await _src.ui_setting("ui_scale", "1.0")
	var zoom_factor := float(scale_str)
	for i in _ZOOM_LEVELS.size():
		if absf(_ZOOM_LEVELS[i] - zoom_factor) < 0.01:
			_current_zoom_idx = i
			break
	if not _embedded:
		get_tree().root.content_scale_factor = zoom_factor

	var font_preset: String = await _src.ui_setting("ui_font_size", "medium")
	_current_font_size = font_preset
	_apply_font_size(_FONT_SIZES.get(font_preset, 14))


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

		"Tools: %d registered — call tools/list for the full set.\n\n" % (await _src.tool_count()) +
		"File: %s" % _src.primary_path()
	)
	_info_dialog.popup_centered()


func _show_vault() -> void:
	## List vault entries that belong to no work item.
	##
	## These are created over MCP (docket_secret_set) and have no row in `items`,
	## so they cannot appear in the query grid — before this they were invisible
	## to anyone not driving the MCP surface. Values are never shown here; this
	## is an inventory, not a viewer.
	var lines: PackedStringArray = []
	var total := 0
	var listed: Dictionary = await _src.standalone_secrets()
	if listed.has("kind"):
		_info_dialog.title = "Vault"
		_info_dialog.dialog_text = str(listed.error)
		_info_dialog.popup_centered()
		return
	for proj_name in listed:
		var entries: Array = listed[proj_name]
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
	if _src.schema().has("types"):
		type_names = _src.schema().types.keys()
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
	_prefs_first.text = _src.prefs().first_name
	_prefs_last.text = _src.prefs().last_name
	var vault: Dictionary = await _src.vault_settings()
	_prefs_vault_pw.text = str(vault.password)
	_prefs_vault_hint.text = str(vault.hint)
	_prefs_dialog.popup_centered(Vector2i(300, 380))


func _on_prefs_confirmed() -> void:
	if _embedded:
		return  # the host keeps the person's preferences
	_src.prefs().first_name = _prefs_first.text.strip_edges()
	_src.prefs().last_name = _prefs_last.text.strip_edges()
	_src.prefs().save()
	# A changed password re-encrypts the vaults first (DocketSource).
	var error: String = await _src.set_vault_settings(_prefs_vault_pw.text, _prefs_vault_hint.text.strip_edges())
	if not error.is_empty():
		_info_dialog.title = "Vault password not changed"
		_info_dialog.dialog_text = error
		_info_dialog.popup_centered()


func _on_viewport_resized() -> void:
	size = get_viewport().get_visible_rect().size


func _load_recent_files() -> void:
	_recent_files = _src.recent_projects()


func _save_recent_files() -> void:
	_src.save_recent_projects(_recent_files)


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
