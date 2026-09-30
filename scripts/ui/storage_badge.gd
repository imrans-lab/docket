extends Label
class_name StorageBadge
## One word beside the record form's id (scenes/ui/storage_badge.tscn) saying
## whether the open item survives a quit without being saved:
##   file      — a durable item of a durable (file-backed) project;
##   ephemeral — an ephemeral item (ItemStorage) of a durable project;
##   memory    — any item of a session_file or memory project (SessionProject).
## word() is the single derivation: the record form, the grid's Storage column
## and that column's sort all call it.
##
## Saving an ephemeral item (ItemStorage.keep) is the only change that moves a
## word while the form stays open (ephemeral -> file), and it usually arrives
## from the MCP server process, which the GUI's poll does not see. So while the
## word is "ephemeral" each tick of the scene's RecheckTimer re-reads the one storage
## cell; other words skip the tick. data_changed covers in-process changes.

## Query field / grid column name; its filter values are the stored
## items.storage values (ItemStorage.MODES), the ones docket_query takes.
const FIELD := "storage"
const FILE := "file"
const EPHEMERAL := "ephemeral"
const MEMORY := "memory"
const _COLORS := {FILE: Color(0.6, 0.62, 0.66), EPHEMERAL: Color(1.0, 0.72, 0.25), MEMORY: Color(0.78, 0.55, 0.95)}
const _TIPS := {
	FILE: "Saved to the project file.",
	EPHEMERAL: "Ephemeral: held in this machine's cache and never written to the project file until saved. Quit asks to save or delete it.",
	MEMORY: "This project is not a durable project file (memory or session). Promote records to keep them.",
}

var _state: AppState
var _project: String = ""
var _item_id: String = ""


static func word(project_mode: String, item_storage: String) -> String:
	if project_mode in [SessionProject.MODE_SESSION_FILE, SessionProject.MODE_MEMORY]: return MEMORY
	return EPHEMERAL if item_storage == ItemStorage.EPHEMERAL else FILE


static func project_modes(project_dbs: Dictionary) -> Dictionary:
	## Project name -> storage mode, read once per grid pass.
	var modes := {}
	for project_name in project_dbs:
		var db: DocketDB = project_dbs[project_name]
		if db != null: modes[project_name] = SessionProject.mode_of(db)
	return modes


static func sort_rows(rows: Array, word_of: Callable, descending: bool) -> void:
	## Orders query rows by word_of(row), ties by id, so the sort key is the
	## word the column shows.
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var wa: String = word_of.call(a)
		var wb: String = word_of.call(b)
		if wa != wb: return (wa > wb) if descending else (wa < wb)
		return str(a.get("id", "")) < str(b.get("id", "")))


func show_for(state: AppState, project: String, item_id: String) -> void:
	if _state == null:
		_state = state
		_state.data_changed.connect(_refresh)
	_project = project
	_item_id = item_id
	_refresh()


func clear() -> void:
	_item_id = ""
	text = ""
	tooltip_text = ""


func _on_recheck_timeout() -> void:
	if text == EPHEMERAL: _refresh()


func _refresh() -> void:
	var db: DocketDB = _state.get_db_for_project(_project) if _state != null and not _item_id.is_empty() else null
	if db == null or not db.is_open():
		clear()
		return
	var rows := db._exec_select("SELECT storage FROM items WHERE id=? LIMIT 1;", [_item_id])
	if rows.is_empty():
		clear()
		return
	var shown := word(SessionProject.mode_of(db), str(rows[0].get("storage", "")))
	text = shown
	tooltip_text = _TIPS[shown]
	add_theme_color_override("font_color", _COLORS[shown])
