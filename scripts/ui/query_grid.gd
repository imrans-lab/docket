extends VBoxContainer
class_name QueryGrid
## Query panel: visual condition builder + spreadsheet-style results with resizable columns.
## Custom header row supports drag-to-resize and click-to-sort.

signal item_selected(id: String, project: String)
signal item_activated(id: String, project: String)

var _state: AppState
var _run_btn: Button
var _add_btn: Button
var _count_label: Label
var _tree: Tree
var _header: Control
var _context_menu: PopupMenu
var _current_results: Array = []

# Visual query builder
var _conditions_container: VBoxContainer
var _condition_rows: Array = []  # Array of {conj, field, op, value, hbox, remove_btn}
var _user_has_modified: bool = false  # Track if user has interacted with the builder

# Available fields for dropdown (ordered for usability)
const _QUERY_FIELDS := [
	"type", "status", "priority", "severity", "title", "description",
	"assigned_to", "directed_to", "tags", "has_attachment", "id", "component", "key",
	"resolution", "environment", "created_at", "updated_at", "project",
	"blocked_by", "parent",
]

# Field → applicable operators
const _TEXT_OPS := ["eq", "neq", "contains", "not_contains", "like", "is_empty", "is_not_empty"]
const _NUMERIC_OPS := ["eq", "neq", "gt", "lt", "gte", "lte", "is_empty", "is_not_empty"]
const _DATE_OPS := ["eq", "neq", "before", "after", "is_empty", "is_not_empty"]
const _BOOL_OPS := ["eq"]
const _TAG_OPS := ["eq", "neq", "contains", "not_contains"]

# Op labels for display
const _OP_LABELS := {
	"eq": "equals", "neq": "not equals",
	"contains": "contains", "not_contains": "not contains",
	"like": "like", "gt": ">", "lt": "<", "gte": ">=", "lte": "<=",
	"before": "before", "after": "after",
	"is_empty": "is empty", "is_not_empty": "is not empty",
}

# Fields with fixed-value dropdowns
## Values offered in the query builder's value dropdown.
##
## Types and statuses are derived from data/schema.json rather than listed here:
## the hardcoded copy fell six types behind (secret, encrypted_note, skill,
## prompt, kb, policy) and was missing every state those types introduced, so
## the GUI silently could not build queries the MCP surface could.
var _dropdown_values_cache: Dictionary = {}
var _type_catalog: Array = []
var _refreshing_scope := false


func _dropdown_values() -> Dictionary:
	if not _dropdown_values_cache.is_empty():
		return _dropdown_values_cache

	var types: Array = []
	var statuses := {}
	if _state != null and _state.schema.has("types"):
		for type_name in _state.schema.types:
			types.append(str(type_name))
			for st in _state.schema.types[type_name].get("states", []):
				statuses[str(st)] = true
	types.sort()
	var status_list: Array = statuses.keys()
	status_list.sort()

	# Non-schema fields keep fixed value sets.
	_dropdown_values_cache = {
		"type": types,
		"status": status_list,
		"priority": ["1", "2", "3", "4"],
		"severity": ["1", "2", "3", "4"],
		"has_attachment": ["true", "false"],
	}
	return _dropdown_values_cache

# Column index → data field name (dynamic — may include "project" when multi-project)
var _col_fields: Array = ["id", "type", "status", "priority", "title"]
var _col_titles: Array = ["ID", "Type", "Status", "Pri", "Title"]
var _col_min_widths: Array = [50, 40, 50, 30, 80]

# Column widths (pixel values, managed by header drag)
var _col_widths: Array = [90, 70, 100, 40, 0]  # last col = fill remaining

# Multi-project mode tracking
var _multi_project: bool = false

# Sort state
var _sort_field: String = ""
var _sort_dir: String = "asc"
var _sort_binding: Dictionary = {}
var _dcq_columns: Array = []
var _last_context_copy_id: String = ""
var _catalog_diagnostic: String = ""
var _columns_menu: PopupMenu
var _column_candidates: Array = []

# Header drag state
var _drag_col: int = -1   # index of column whose RIGHT edge is being dragged
var _drag_start_x: float = 0
var _drag_start_width: int = 0
const _DRAG_ZONE: int = 5  # pixels from column edge to trigger resize


func init(state: AppState) -> void:
	_state = state
	_state.file_changed.connect(_on_file_changed)
	_state.data_changed.connect(_on_file_changed)
	_rebuild_type_catalog()
	_build_ui()


func _on_file_changed() -> void:
	_rebuild_type_catalog()
	var shortcut_projects: Array = _state.get_project_dbs().keys()
	shortcut_projects.sort()
	var project_key := ",".join(shortcut_projects)
	for row in _condition_rows:
		row.type_chooser.update_catalog(_type_catalog, project_key)
	_refresh_scoped_controls()
	refresh()


func _rebuild_type_catalog() -> void:
	_type_catalog.clear()
	_catalog_diagnostic = ""
	var projects: Array = _state.get_project_dbs().keys()
	projects.sort()
	if projects.is_empty():
		_type_catalog = TypeCatalog.from_schema(_state.schema)
		return
	for project_value in projects:
		var project := str(project_value)
		var counts := {}
		var project_db = _state.get_db_for_project(project)
		if project_db != null:
			for item in project_db.execute_query({"filter": {}}):
				var slug: String = str(item.get("type", ""))
				counts[slug] = int(counts.get(slug, 0)) + 1
		var registry: TypeRegistry = _state.get_type_registry(project)
		var catalog_result: Dictionary = TypeCatalog.from_registry_checked(registry, counts) if registry != null else {"records":[],"error":"type registry is unavailable"}
		if registry != null and registry.get_diagnostic().is_empty() and str(catalog_result.error).is_empty():
			_type_catalog.append_array(catalog_result.records)
		else:
			var reason: String = registry.get_diagnostic() if registry != null and not registry.get_diagnostic().is_empty() else str(catalog_result.error)
			_catalog_diagnostic = "Type catalog unavailable for %s: %s" % [project, reason]
	_type_catalog = TypeCatalog.sorted(_type_catalog)


func _build_ui() -> void:
	# Condition rows container
	_conditions_container = VBoxContainer.new()
	_conditions_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_conditions_container)

	# Add first empty row
	_add_condition_row(true)

	# Buttons bar: [+ Add] [Run]
	var btn_bar := HBoxContainer.new()
	btn_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_add_btn = Button.new()
	_add_btn.text = "+ Add"
	_add_btn.pressed.connect(func():
		_user_has_modified = true
		_add_condition_row(false)
	)
	btn_bar.add_child(_add_btn)

	_run_btn = Button.new()
	_run_btn.text = "Run"
	_run_btn.pressed.connect(_run_query)
	btn_bar.add_child(_run_btn)
	var columns_button := Button.new()
	columns_button.text = "Columns..."
	columns_button.pressed.connect(_show_columns_menu.bind(columns_button))
	btn_bar.add_child(columns_button)
	_columns_menu = PopupMenu.new()
	_columns_menu.id_pressed.connect(_toggle_result_column)
	add_child(_columns_menu)

	add_child(btn_bar)

	# Custom column header (handles drag-resize + click-sort)
	_header = Control.new()
	_header.custom_minimum_size.y = 24
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.draw.connect(_draw_header)
	_header.gui_input.connect(_header_gui_input)
	_header.mouse_default_cursor_shape = Control.CURSOR_ARROW
	add_child(_header)

	# Tree (spreadsheet-style: flat rows, no built-in titles)
	_tree = Tree.new()
	_tree.select_mode = Tree.SELECT_ROW
	_tree.hide_root = true
	_tree.hide_folding = true
	_tree.allow_reselect = true
	_tree.allow_rmb_select = true
	_tree.column_titles_visible = false
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.columns = _col_titles.size()
	for i in range(_col_titles.size()):
		_tree.set_column_clip_content(i, true)
	_tree.item_selected.connect(_on_item_selected)
	_tree.item_activated.connect(_on_item_activated)
	_tree.item_mouse_selected.connect(_on_tree_item_mouse_selected)
	add_child(_tree)

	_context_menu = PopupMenu.new()
	_context_menu.add_item("Copy ID", 0)
	_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	add_child(_context_menu)

	# Status bar (count) at bottom
	_count_label = Label.new()
	_count_label.text = "0 items"
	_count_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	_count_label.add_theme_font_size_override("font_size", 12)
	add_child(_count_label)

	# Initial load
	_sync_tree_columns()
	_run_query()


# -- Dynamic column rebuilding ---------------------------------------------

func _rebuild_columns() -> void:
	## Rebuild column arrays for current multi-project state.
	var is_multi := _state._project_dbs.size() > 1
	_multi_project = is_multi
	if not _dcq_columns.is_empty():
		_col_fields = []
		_col_titles = []
		_col_min_widths = []
		_col_widths = []
	elif _multi_project:
		_col_fields = ["id", "project", "type", "status", "priority", "title"]
		_col_titles = ["ID", "Project", "Type", "Status", "Pri", "Title"]
		_col_min_widths = [50, 50, 40, 50, 30, 80]
		_col_widths = [90, 80, 70, 100, 40, 0]
	else:
		_col_fields = ["id", "type", "status", "priority", "title"]
		_col_titles = ["ID", "Type", "Status", "Pri", "Title"]
		_col_min_widths = [50, 40, 50, 30, 80]
		_col_widths = [90, 70, 100, 40, 0]
	for binding_value in _dcq_columns:
		if binding_value is String:
			var field_key := str(binding_value)
			_col_fields.append(field_key)
			_col_titles.append({"id":"ID", "project":"Project", "type":"Type", "status":"Status", "priority":"Pri", "title":"Title"}.get(field_key, field_key.capitalize()))
			_col_min_widths.append(50)
			_col_widths.append(120)
			continue
		if not binding_value is Dictionary:
			continue
		var binding: Dictionary = binding_value
		if str(binding.get("field_key", "")).is_empty():
			continue
		_col_fields.append(binding.duplicate(true))
		_col_titles.append(str(binding.get("label", binding.field_key)))
		_col_min_widths.append(60)
		_col_widths.append(120)
	if not _col_widths.is_empty():
		_col_widths[_col_widths.size() - 1] = 0

	if _tree:
		_tree.columns = _col_titles.size()
		for i in range(_col_titles.size()):
			_tree.set_column_clip_content(i, true)
		_sync_tree_columns()
	if _header:
		_header.queue_redraw()


# -- Column width management -----------------------------------------------

func _get_fill_width() -> int:
	## Width available for the last (fill) column.
	var total := int(_header.size.x) if _header else 400
	var fixed := 0
	for i in range(_col_widths.size() - 1):
		fixed += _col_widths[i]
	return maxi(total - fixed, _col_min_widths[_col_widths.size() - 1])


func _col_x(col: int) -> int:
	## Left x position of column col.
	var x := 0
	for i in range(col):
		if i == _col_widths.size() - 1:
			x += _get_fill_width()
		else:
			x += _col_widths[i]
	return x


func _col_w(col: int) -> int:
	## Width of column col.
	if col == _col_widths.size() - 1:
		return _get_fill_width()
	return _col_widths[col]


func _sync_tree_columns() -> void:
	## Push current column widths into the Tree.
	for i in range(_col_widths.size()):
		var w := _col_w(i)
		if i == _col_widths.size() - 1:
			_tree.set_column_expand(i, true)
			_tree.set_column_custom_minimum_width(i, w)
		else:
			_tree.set_column_expand(i, false)
			_tree.set_column_custom_minimum_width(i, w)


# -- Custom header drawing -------------------------------------------------

func _draw_header() -> void:
	var h := int(_header.size.y)
	var total_w := int(_header.size.x)

	# Background
	_header.draw_rect(Rect2(0, 0, total_w, h), Color(0.22, 0.22, 0.26))

	# Columns
	for i in range(_col_titles.size()):
		var x := _col_x(i)
		var w := _col_w(i)

		# Title text
		var title: String = _col_titles[i]
		var header_field: String = str(_col_fields[i].get("field_key", "")) if _col_fields[i] is Dictionary else str(_col_fields[i])
		var header_binding: Dictionary = _col_fields[i] if _col_fields[i] is Dictionary else {}
		if header_field == _sort_field and (header_binding.is_empty() or _same_binding(header_binding, _sort_binding)):
			title += "  v" if _sort_dir == "asc" else "  ^"
		var font := _header.get_theme_default_font()
		var font_size := _header.get_theme_default_font_size()
		var text_y := int((h + font.get_ascent(font_size)) / 2) - 2
		_header.draw_string(font, Vector2(x + 6, text_y), title, HORIZONTAL_ALIGNMENT_LEFT, w - 12, font_size, Color(0.8, 0.8, 0.85))

		# Right separator line
		if i < _col_titles.size() - 1:
			var sep_x := x + w
			_header.draw_line(Vector2(sep_x, 2), Vector2(sep_x, h - 2), Color(0.35, 0.35, 0.4), 1.0)

	# Bottom border
	_header.draw_line(Vector2(0, h - 1), Vector2(total_w, h - 1), Color(0.35, 0.35, 0.4), 1.0)


# -- Header input (sort click + drag resize) -------------------------------

func _header_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_header_mouse_button(event)
	elif event is InputEventMouseMotion:
		_header_mouse_motion(event)


func _header_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	if event.pressed:
		# Check if we're on a column separator → start drag
		var sep_col := _hit_separator(event.position.x)
		if sep_col >= 0:
			_drag_col = sep_col
			_drag_start_x = event.position.x
			_drag_start_width = _col_widths[sep_col]
		else:
			# Click on column title → sort toggle
			var col := _hit_column(event.position.x)
			if col >= 0:
				_toggle_sort(col)
	else:
		# Release → end drag
		if _drag_col >= 0:
			_drag_col = -1


func _header_mouse_motion(event: InputEventMouseMotion) -> void:
	if _drag_col >= 0:
		# Dragging a separator
		var delta := event.position.x - _drag_start_x
		var new_width := maxi(int(_drag_start_width + delta), _col_min_widths[_drag_col])
		_col_widths[_drag_col] = new_width
		_sync_tree_columns()
		_header.queue_redraw()
	else:
		# Hover: update cursor
		var sep_col := _hit_separator(event.position.x)
		if sep_col >= 0:
			_header.mouse_default_cursor_shape = Control.CURSOR_HSIZE
		else:
			_header.mouse_default_cursor_shape = Control.CURSOR_ARROW


func _hit_separator(mx: float) -> int:
	## Return column index whose right edge is near mx, or -1.
	for i in range(_col_widths.size() - 1):  # last col has no right separator
		var edge := _col_x(i) + _col_w(i)
		if absf(mx - edge) <= _DRAG_ZONE:
			return i
	return -1


func _hit_column(mx: float) -> int:
	## Return column index that contains mx, or -1.
	for i in range(_col_titles.size()):
		var x := _col_x(i)
		var w := _col_w(i)
		if mx >= x and mx < x + w:
			return i
	return -1


func _toggle_sort(col: int) -> void:
	var column: Variant = _col_fields[col]
	var field: String = str(column.get("field_key", "")) if column is Dictionary else str(column)
	var binding: Dictionary = column if column is Dictionary else {}
	if _sort_field == field and (binding.is_empty() or _same_binding(binding, _sort_binding)):
		if _sort_dir == "asc":
			_sort_dir = "desc"
		else:
			_sort_field = ""
			_sort_dir = "asc"
			_sort_binding.clear()
	else:
		_sort_field = field
		_sort_dir = "asc"
		_sort_binding.clear()
		if column is Dictionary:
			_sort_binding = binding.duplicate(true)
	_header.queue_redraw()
	_run_query()

func _same_binding(left: Dictionary, right: Dictionary) -> bool:
	return str(left.get("project", "")) == str(right.get("project", "")) and str(left.get("type_id", "")) == str(right.get("type_id", "")) and str(left.get("field_key", "")) == str(right.get("field_key", ""))


# -- Header resize on parent resize ----------------------------------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _header:
		_sync_tree_columns()
		_header.queue_redraw()


# -- Condition row builder -------------------------------------------------

const _GROUP_BAR_COLOR := Color(0.35, 0.55, 0.85)  # blue accent
const _GROUP_BAR_WIDTH: int = 3
const _GROUP_INDENT: int = 16

func _add_condition_row(is_first: bool) -> void:
	var row_data := {}

	# Outer container: [group_bar] [indent] [inner hbox with widgets]
	var outer := HBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Group bar — colored left bar visible for AND rows (group members)
	var group_bar := ColorRect.new()
	group_bar.color = _GROUP_BAR_COLOR
	group_bar.custom_minimum_size.x = _GROUP_BAR_WIDTH
	group_bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	group_bar.visible = false
	outer.add_child(group_bar)
	row_data["group_bar"] = group_bar

	# Indent spacer — visible for AND rows
	var indent := Control.new()
	indent.custom_minimum_size.x = _GROUP_INDENT
	indent.visible = false
	outer.add_child(indent)
	row_data["indent"] = indent

	# Inner hbox with all the condition widgets
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# AND/OR conjunction dropdown (hidden for first row)
	var conj_option := OptionButton.new()
	conj_option.add_item("AND", 0)
	conj_option.add_item("OR", 1)
	conj_option.custom_minimum_size.x = 65
	if is_first:
		conj_option.visible = false
	hbox.add_child(conj_option)
	row_data["conj"] = conj_option

	# Field dropdown
	var field_option := OptionButton.new()
	for f in _QUERY_FIELDS:
		field_option.add_item(f)
	field_option.custom_minimum_size.x = 120
	hbox.add_child(field_option)
	row_data["field"] = field_option

	# Operator dropdown
	var op_option := OptionButton.new()
	op_option.custom_minimum_size.x = 100
	hbox.add_child(op_option)
	row_data["op"] = op_option

	# Value input — LineEdit for free-form, OptionButton for fixed values
	var value_edit := LineEdit.new()
	value_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_edit.placeholder_text = "value"
	value_edit.text_changed.connect(func(_t): _user_has_modified = true)
	value_edit.text_submitted.connect(func(_t): _run_query())
	hbox.add_child(value_edit)
	row_data["value"] = value_edit

	var value_dropdown := OptionButton.new()
	value_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_dropdown.visible = false
	row_data["catalog_status_choice"] = {}
	value_dropdown.item_selected.connect(func(_idx):
		row_data["catalog_status_choice"] = {}
		_user_has_modified = true
		_refresh_scoped_controls()
	)
	hbox.add_child(value_dropdown)
	row_data["value_dropdown"] = value_dropdown

	var type_chooser := TypeChooser.new()
	type_chooser.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_chooser.visible = false
	var shortcut_projects: Array = _state.get_project_dbs().keys()
	shortcut_projects.sort()
	type_chooser.configure(_type_catalog, ",".join(shortcut_projects))
	type_chooser.selection_changed.connect(func(_values):
		_user_has_modified = true
		_refresh_scoped_controls()
	)
	hbox.add_child(type_chooser)
	row_data["type_chooser"] = type_chooser

	var validation_label := Label.new()
	validation_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.35))
	validation_label.visible = false
	validation_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row_data["validation"] = validation_label

	# Remove button
	var remove_btn := Button.new()
	remove_btn.text = "X"
	remove_btn.custom_minimum_size.x = 30
	hbox.add_child(remove_btn)
	row_data["remove_btn"] = remove_btn

	outer.add_child(hbox)
	var row_stack := VBoxContainer.new()
	row_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.remove_child(hbox)
	row_stack.add_child(hbox)
	row_stack.add_child(validation_label)
	outer.add_child(row_stack)
	row_data["hbox"] = outer  # outer is what gets added/removed from tree

	var row_idx := _condition_rows.size()
	# Rows can be removed from the middle. Resolve the current index when an
	# event arrives so a surviving control never acts on its former position.
	remove_btn.pressed.connect(func():
		var current_idx := _find_condition_row(row_data)
		if current_idx >= 0:
			_remove_condition_row(current_idx)
	)

	# Wire field change to update operators
	field_option.item_selected.connect(func(_idx):
		var current_idx := _find_condition_row(row_data)
		if current_idx < 0:
			return
		_user_has_modified = true
		_update_ops_for_row(current_idx)
		_refresh_scoped_controls()
	)

	# Wire conjunction change to update group visuals
	conj_option.item_selected.connect(func(_idx):
		if _find_condition_row(row_data) < 0:
			return
		_user_has_modified = true
		_update_group_visuals()
		_refresh_scoped_controls()
	)

	_condition_rows.append(row_data)
	_conditions_container.add_child(outer)

	# Populate initial operators
	_update_ops_for_row(row_idx)
	_update_remove_buttons()
	_update_group_visuals()
	_refresh_scoped_controls()


func _find_condition_row(target: Dictionary) -> int:
	for i in _condition_rows.size():
		if _condition_rows[i].hbox == target.hbox:
			return i
	return -1


func _remove_condition_row(idx: int) -> void:
	if _condition_rows.size() <= 1:
		return  # Keep at least one row
	var row: Dictionary = _condition_rows[idx]
	row["hbox"].queue_free()
	_condition_rows.remove_at(idx)

	# First row should hide conjunction
	if _condition_rows.size() > 0:
		_condition_rows[0]["conj"].visible = false

	_update_remove_buttons()
	_update_group_visuals()
	_refresh_scoped_controls()


func _update_remove_buttons() -> void:
	# Disable X on last remaining row
	for row in _condition_rows:
		row["remove_btn"].disabled = (_condition_rows.size() <= 1)


func _update_group_visuals() -> void:
	## Show/hide group bars and indents based on AND/OR conjunctions.
	## Rule: AND rows (non-first) are group members → show bar + indent.
	## OR rows and the first row are group leaders → no bar, no indent.
	for i in _condition_rows.size():
		var row: Dictionary = _condition_rows[i]
		var bar: ColorRect = row["group_bar"]
		var indent_ctrl: Control = row["indent"]
		if i == 0:
			# First row: always a group leader
			bar.visible = false
			indent_ctrl.visible = false
		else:
			var conj_opt: OptionButton = row["conj"]
			var is_and: bool = (conj_opt.selected == 0)
			bar.visible = is_and
			indent_ctrl.visible = is_and


func _get_ops_for_field(field_name: String) -> Array:
	match field_name:
		"priority", "severity", "retrieval_count", "research_cost":
			return _NUMERIC_OPS
		"created_at", "updated_at", "occurred_at", "detected_at":
			return _DATE_OPS
		"has_attachment":
			return _BOOL_OPS
		"tags":
			return _TAG_OPS
		_:
			return _TEXT_OPS


func _update_ops_for_row(row_idx: int) -> void:
	if row_idx >= _condition_rows.size():
		return
	var row: Dictionary = _condition_rows[row_idx]
	var field_option: OptionButton = row["field"]
	var op_option: OptionButton = row["op"]
	var value_edit: LineEdit = row["value"]
	var value_dropdown: OptionButton = row["value_dropdown"]
	var type_chooser: TypeChooser = row["type_chooser"]

	var field_name: String = field_option.get_item_text(field_option.selected)
	var ops := _get_ops_for_field(field_name)

	op_option.clear()
	for o in ops:
		op_option.add_item(_OP_LABELS.get(o, o))

	# Determine if this field uses a dropdown
	var use_dropdown: bool = _dropdown_values().has(field_name) and field_name != "type"
	type_chooser.visible = field_name == "type"

	if use_dropdown:
		# Populate dropdown with fixed values for this field
		value_dropdown.clear()
		value_dropdown.add_item("(any)")
		var values: Array = _dropdown_values()[field_name]
		for v in values:
			value_dropdown.add_item(str(v))
		value_dropdown.visible = true
		value_edit.visible = false
	else:
		value_dropdown.visible = false
		value_edit.visible = field_name != "type"
		value_edit.placeholder_text = "value"

	# Show/hide value widgets for is_empty/is_not_empty
	for connection in op_option.item_selected.get_connections():
		op_option.item_selected.disconnect(connection.callable)
	op_option.item_selected.connect(func(_idx):
		_user_has_modified = true
		var op_text: String = op_option.get_item_text(op_option.selected)
		var is_no_value: bool = (op_text == "is empty" or op_text == "is not empty")
		if is_no_value:
			value_edit.visible = false
			value_dropdown.visible = false
		elif field_name == "type" and _op_label_to_key(op_text) == "eq":
			type_chooser.visible = true
			value_edit.visible = false
			value_dropdown.visible = false
		elif field_name == "type":
			type_chooser.visible = false
			value_edit.visible = true
			value_dropdown.visible = false
		elif use_dropdown:
			value_dropdown.visible = true
			value_edit.visible = false
		else:
			value_edit.visible = true
			value_dropdown.visible = false
	)


func _condition_snapshots() -> Array:
	var conditions: Array = []
	for i in _condition_rows.size():
		var row: Dictionary = _condition_rows[i]
		var field: String = row.field.get_item_text(row.field.selected)
		var value: Variant = ""
		if field == "type" and row.type_chooser.visible:
			value = row.type_chooser.selected_values()
		elif row.value_dropdown.visible and row.value_dropdown.item_count > 0:
			value = _dropdown_stored_value(row.value_dropdown)
		else:
			value = row.value.text
		var op := _op_label_to_key(row.op.get_item_text(row.op.selected))
		if field == "type" and row.type_chooser.visible:
			op = "catalog_in"
		var condition := {"field": field, "op": op, "value": value}
		if i > 0:
			condition.conj = "or" if row.conj.selected == 1 else "and"
		conditions.append(condition)
	return conditions


func _refresh_scoped_controls() -> void:
	if _refreshing_scope or _condition_rows.is_empty():
		return
	_refreshing_scope = true
	var conditions := _condition_snapshots()
	for i in _condition_rows.size():
		var row: Dictionary = _condition_rows[i]
		var scope := QueryTypeScope.branch_scope(conditions, i, _type_catalog)
		var field_name: String = row.field.get_item_text(row.field.selected)
		var offered_fields := QueryTypeScope.fields(_type_catalog, scope)
		row.field.clear()
		for offered in offered_fields:
			row.field.add_item(str(offered))
		if not offered_fields.has(field_name):
			row.field.add_item(field_name)
		for field_idx in row.field.item_count:
			if row.field.get_item_text(field_idx) == field_name:
				row.field.selected = field_idx
				break
		var raw_value := ""
		if row.value_dropdown.visible and row.value_dropdown.item_count > 0:
			raw_value = str(_dropdown_stored_value(row.value_dropdown))
		if field_name == "status":
			row.value_dropdown.clear()
			row.value_dropdown.add_item("(any)")
			row.value_dropdown.set_item_metadata(0, "(any)")
			for group in QueryTypeScope.statuses(_type_catalog, scope):
				for status in group.values:
					var label := "%s — %s — %s" % [group.label, group.project, status] if not str(group.project).is_empty() else "%s — %s" % [group.label, status]
					row.value_dropdown.add_item(label)
					row.value_dropdown.set_item_metadata(row.value_dropdown.item_count - 1, {"key": group.key, "value": str(status), "type": group.type, "project": group.project})
			var pending_choice = row.catalog_status_choice
			var found := _select_status_choice(row.value_dropdown, pending_choice) if pending_choice is Dictionary and not pending_choice.is_empty() else _select_dropdown_metadata(row.value_dropdown, raw_value)
			if not raw_value.is_empty() and raw_value != "(any)" and not found:
				row.value_dropdown.add_item("Unavailable — %s" % raw_value)
				row.value_dropdown.set_item_metadata(row.value_dropdown.item_count - 1, raw_value)
				row.value_dropdown.selected = row.value_dropdown.item_count - 1
		var check := QueryTypeScope.validate_value(field_name, raw_value, _type_catalog, scope)
		row.validation.text = check.message
		row.validation.visible = not check.valid
	_refreshing_scope = false


func _select_dropdown_metadata(dropdown: OptionButton, value: String) -> bool:
	for i in dropdown.item_count:
		var metadata = dropdown.get_item_metadata(i)
		var stored = metadata.get("value", "") if metadata is Dictionary else metadata
		if (stored != null and str(stored) == value) or dropdown.get_item_text(i) == value:
			dropdown.selected = i
			return true
	return false


func _dropdown_stored_value(dropdown: OptionButton) -> Variant:
	if dropdown.item_count == 0:
		return ""
	var metadata = dropdown.get_item_metadata(dropdown.selected)
	if metadata is Dictionary:
		return metadata.get("value", "")
	return metadata if metadata != null else dropdown.get_item_text(dropdown.selected)


func _select_status_choice(dropdown: OptionButton, choice: Dictionary) -> bool:
	for i in dropdown.item_count:
		var metadata = dropdown.get_item_metadata(i)
		if metadata is Dictionary and metadata.get("key", "") == choice.get("key", "") and metadata.get("value", "") == choice.get("status", ""):
			dropdown.selected = i
			return true
	return false


func _op_label_to_key(label: String) -> String:
	for k in _OP_LABELS:
		if _OP_LABELS[k] == label:
			return k
	return "eq"


# -- Query -----------------------------------------------------------------

func _run_query() -> void:
	_rebuild_columns()
	if not _catalog_diagnostic.is_empty():
		_current_results.clear()
		_tree.clear()
		_count_label.text = _catalog_diagnostic
		return
	var filter := _build_conditions_filter()
	var query := {"filter": filter}
	if not _sort_field.is_empty():
		var sort_value: Dictionary = _sort_binding.duplicate(true)
		sort_value["field"] = _sort_field; sort_value["dir"] = _sort_dir
		query["sort"] = [sort_value]

	# Use cross-project query if multiple projects loaded
	if _state._project_dbs.size() > 1:
		_current_results = _state.execute_cross_project_query(query)
		if not _state.last_cross_project_query_error.is_empty():
			_tree.clear()
			_count_label.text = _state.last_cross_project_query_error
			return
	elif _state.db:
		var registry: TypeRegistry = _state.get_type_registry()
		_current_results = _state.db.execute_registry_query(query, registry) if registry != null else _state.db.execute_query(query)
		if not _state.db.last_query_error.is_empty():
			_tree.clear()
			_count_label.text = _state.db.last_query_error
			return
	else:
		_current_results = []
	_populate_tree()


func _build_conditions_filter() -> Dictionary:
	var conditions: Array = []
	for i in _condition_rows.size():
		var row: Dictionary = _condition_rows[i]
		var field_option: OptionButton = row["field"]
		var op_option: OptionButton = row["op"]
		var value_edit: LineEdit = row["value"]
		var value_dropdown: OptionButton = row["value_dropdown"]
		var conj_option: OptionButton = row["conj"]

		var field_name: String = field_option.get_item_text(field_option.selected)
		var op_label: String = op_option.get_item_text(op_option.selected)
		var op_key: String = _op_label_to_key(op_label)

		# Read value from dropdown or text input depending on field
		var raw_value: String
		if field_name == "type" and row["type_chooser"].visible:
			var selected_types: Array = row["type_chooser"].selected_values()
			raw_value = str(selected_types[0]) if selected_types.size() == 1 else ""
		elif _dropdown_values().has(field_name) and value_dropdown.visible:
			raw_value = str(_dropdown_stored_value(value_dropdown))
		else:
			raw_value = value_edit.text.strip_edges()

		# Skip conditions where "(any)" is selected — matches everything
		if raw_value == "(any)" and op_key not in ["is_empty", "is_not_empty"]:
			continue

		var cond := {"field": field_name, "op": op_key}
		if i > 0:
			cond["conj"] = "or" if conj_option.selected == 1 else "and"

		# Parse value
		if op_key in ["is_empty", "is_not_empty"]:
			pass  # no value needed
		elif field_name == "type" and row["type_chooser"].visible:
			cond["op"] = "catalog_in"
			cond["value"] = row["type_chooser"].selected_values()
		elif field_name == "has_attachment":
			cond["value"] = raw_value.to_lower() == "true"
		elif field_name in ["priority", "severity", "retrieval_count", "research_cost"]:
			cond["value"] = int(raw_value) if raw_value.is_valid_int() else 0
		else:
			cond["value"] = raw_value

		_append_scoped_condition(conditions, cond, row, i)

	if conditions.size() == 0:
		return {}
	if not _user_has_modified:
		# No user interaction yet — show all items
		return {}
	if conditions.size() == 1:
		# Single condition with no conjunction and default eq with empty value → return all
		var only: Dictionary = conditions[0]
		if only["op"] == "eq" and only.get("value", "") == "":
			return {}
	return QueryTypeScope.compile_catalog_conditions(conditions, _type_catalog, _state.get_project_dbs().size() > 1)


func _serialize_all_conditions() -> Dictionary:
	## Like _build_conditions_filter() but preserves "(any)" rows for UI state.
	var conditions: Array = []
	for i in _condition_rows.size():
		var row: Dictionary = _condition_rows[i]
		var field_option: OptionButton = row["field"]
		var op_option: OptionButton = row["op"]
		var value_edit: LineEdit = row["value"]
		var value_dropdown: OptionButton = row["value_dropdown"]
		var conj_option: OptionButton = row["conj"]

		var field_name: String = field_option.get_item_text(field_option.selected)
		var op_label: String = op_option.get_item_text(op_option.selected)
		var op_key: String = _op_label_to_key(op_label)

		var raw_value: String
		if field_name == "type" and row["type_chooser"].visible:
			var chosen: Array = row["type_chooser"].selected_values()
			raw_value = str(chosen[0]) if chosen.size() == 1 else ""
		elif _dropdown_values().has(field_name) and value_dropdown.visible:
			raw_value = str(_dropdown_stored_value(value_dropdown))
		else:
			raw_value = value_edit.text.strip_edges()

		var cond := {"field": field_name, "op": op_key}
		if i > 0:
			cond["conj"] = "or" if conj_option.selected == 1 else "and"

		if op_key in ["is_empty", "is_not_empty"]:
			pass
		elif field_name == "type" and row["type_chooser"].visible:
			cond["op"] = "catalog_in"
			cond["value"] = row["type_chooser"].selected_values()
		elif field_name == "has_attachment":
			cond["value"] = raw_value.to_lower() == "true"
		elif field_name in ["priority", "severity", "retrieval_count", "research_cost"]:
			cond["value"] = int(raw_value) if raw_value.is_valid_int() else 0
		else:
			cond["value"] = raw_value

		_append_scoped_condition(conditions, cond, row, i)

	if conditions.size() == 0:
		return {}
	return {"conditions": conditions}


func _append_scoped_condition(conditions: Array, condition: Dictionary, row: Dictionary, _row_index: int) -> void:
	if condition.field == "status" and row.value_dropdown.visible and row.value_dropdown.item_count > 0:
		var choice = row.catalog_status_choice
		if not choice is Dictionary or choice.is_empty():
			choice = row.value_dropdown.get_item_metadata(row.value_dropdown.selected)
		if choice is Dictionary and not str(choice.get("key", "")).is_empty():
			condition["op"] = "catalog_status"
			condition["value"] = {"key": choice.key, "status":choice.get("value", choice.get("status", ""))}
			conditions.append(condition)
			return
	conditions.append(condition)


## Status → display color mapping.
const _STATUS_COLORS := {
	# Active / in-progress states → green
	"active": Color(0.4, 0.85, 0.45),
	"in_progress": Color(0.4, 0.85, 0.45),
	"implementing": Color(0.4, 0.85, 0.45),
	"remediating": Color(0.4, 0.85, 0.45),
	# Terminal / done states → grey
	"resolved": Color(0.55, 0.55, 0.6),
	"closed": Color(0.55, 0.55, 0.6),
	"shipped": Color(0.55, 0.55, 0.6),
	"done": Color(0.55, 0.55, 0.6),
	"verified": Color(0.55, 0.55, 0.6),
	# Warning / blocked states → yellow
	"blocked": Color(1.0, 0.75, 0.2),
	"failing": Color(1.0, 0.75, 0.2),
}


func _populate_tree() -> void:
	_tree.clear()
	var root := _tree.create_item()

	for item in _current_results:
		var row := _tree.create_item(root)
		var full_id: String = str(item.get("id", ""))
		var item_status: String = str(item.get("status", ""))
		for col_idx in range(_col_fields.size()):
			var column: Variant = _col_fields[col_idx]
			var field: String = str(column.get("field_key", "")) if column is Dictionary else str(column)
			if field == "priority":
				var pri = item.get("priority", 0)
				row.set_text(col_idx, str(int(pri)) if pri else "")
			elif field == "id" and DocketDB._is_uuid7(full_id):
				# Display short ID for UUID7, set tooltip to full ID
				var display_id := full_id.substr(0, 7)
				if _state.db:
					display_id = _state.db.short_id(full_id)
				row.set_text(col_idx, display_id)
				row.set_tooltip_text(col_idx, full_id)
			elif field == "status":
				row.set_text(col_idx, item_status)
				var state_color := _pinned_state_color(item)
				if state_color.a > 0.0:
					row.set_custom_color(col_idx, state_color)
			elif column is Dictionary:
				row.set_text(col_idx, _render_bound_column(item, column))
			else:
				row.set_text(col_idx, str(item.get(field, "")))
		# Metadata always stores full ID for selection signals
		row.set_metadata(0, {"id":full_id,"project":_item_project(item)})

	_count_label.text = "%d items" % _current_results.size()

func _pinned_state_color(item: Dictionary) -> Color:
	var project := _item_project(item)
	var registry := _state.get_type_registry(project)
	if registry == null:
		return Color.TRANSPARENT
	var resolved: Dictionary = registry.resolve_item(item)
	if resolved.has("error"):
		return Color.TRANSPARENT
	match str(resolved.state_category):
		"active":
			return Color(0.4, 0.85, 0.45)
		"waiting":
			return Color(1.0, 0.75, 0.2)
		"terminal":
			return Color(0.55, 0.55, 0.6)
		_:
			return Color(0.65, 0.7, 0.85)

func _render_bound_column(item: Dictionary, binding: Dictionary) -> String:
	var project := _item_project(item)
	if not str(binding.get("project", "")).is_empty() and binding.project != project:
		return ""
	var registry := _state.get_type_registry(project)
	if registry == null:
		return ""
	var resolved: Dictionary = registry.resolve_item(item)
	if resolved.has("error") or str(resolved.revision.type_id) != str(binding.get("type_id", "")):
		return ""
	if binding.field_key == "state_category":
		return str(resolved.state_category)
	if binding.field_key == "state_outcome":
		return str(resolved.state_outcome)
	if binding.field_key == "is_terminal":
		return str(resolved.is_terminal)
	var declared := false
	for descriptor_value in resolved.definition.fields:
		var descriptor: Dictionary = descriptor_value
		if descriptor.key == binding.field_key:
			declared = true
			break
	if not declared:
		return ""
	var fields: Dictionary = item.get("fields", {}) if item.get("fields", {}) is Dictionary else {}
	if bool(resolved.definition.get("protected", false)) or binding.field_key in TypeRegistry.UNIVERSAL_MUTABLE:
		return str(item[binding.field_key]) if item.has(binding.field_key) else ""
	if not fields.has(binding.field_key):
		return ""
	if fields[binding.field_key] is Array or fields[binding.field_key] is Dictionary:
		return JSON.stringify(fields[binding.field_key])
	return str(fields[binding.field_key])

func _item_project(item: Dictionary) -> String:
	var project: String = str(item.get("project", ""))
	if project.is_empty() and _state.get_project_dbs().size() == 1:
		project = str(_state.get_project_dbs().keys()[0])
	return project

func set_result_columns(bindings: Array) -> void:
	_dcq_columns = bindings.duplicate(true)
	_rebuild_columns()
	_populate_tree()

func _show_columns_menu(anchor: Button) -> void:
	_columns_menu.clear()
	_column_candidates.clear()
	var scoped_records: Array = _column_scope_records()
	for record_value in scoped_records:
		var record: Dictionary = record_value
		var registry := _state.get_type_registry(str(record.project))
		if registry == null:
			continue
		var type: Dictionary = registry.resolve_type_ref(str(record.id))
		if type.has("error"):
			continue
		for descriptor_value in type.definition.fields:
			var descriptor: Dictionary = descriptor_value
			if descriptor.key in TypeRegistry.UNIVERSAL_MUTABLE:
				continue
			var owner_label := "%s [%s]" % [record.label, record.project] if _state.get_project_dbs().size() > 1 else str(record.label)
			_column_candidates.append({"project":record.project, "type_id":record.id, "field_key":descriptor.key, "label":"%s — %s" % [owner_label, descriptor.get("label", descriptor.key)], "kind":descriptor.type})
	for derived in ["state_category", "state_outcome", "is_terminal"]:
		for record_value in scoped_records:
			var record: Dictionary = record_value
			var owner_label := "%s [%s]" % [record.label, record.project] if _state.get_project_dbs().size() > 1 else str(record.label)
			_column_candidates.append({"project":record.project, "type_id":record.id, "field_key":derived, "label":"%s — %s" % [owner_label, derived], "kind":"string"})
	for selected_value in _dcq_columns:
		if selected_value is Dictionary and not _candidate_has_binding(selected_value):
			_column_candidates.append((selected_value as Dictionary).duplicate(true))
	for i in _column_candidates.size():
		var binding: Dictionary = _column_candidates[i]
		_columns_menu.add_check_item(str(binding.label), i)
		_columns_menu.set_item_checked(i, _has_result_column(binding))
	_columns_menu.popup(Rect2i(Vector2i(anchor.global_position.x, anchor.global_position.y + anchor.size.y), Vector2i(360, 0)))

func _column_scope_records() -> Array:
	var conditions: Array = _condition_snapshots()
	if conditions.is_empty():
		return _type_catalog.duplicate()
	var branch_scopes: Dictionary = {}
	for i in conditions.size():
		var branch := QueryTypeScope.branch_index(conditions, i)
		branch_scopes[branch] = QueryTypeScope.branch_scope(conditions, i, _type_catalog)
	var allowed: Dictionary = {}
	for scope_value in branch_scopes.values():
		var scope: Dictionary = scope_value
		if not bool(scope.known):
			return _type_catalog.duplicate()
		for record_value in _type_catalog:
			var record: Dictionary = record_value
			if (not scope.identities.is_empty() and scope.identities.has(record.key)) or (scope.identities.is_empty() and scope.types.has(record.slug)):
				allowed[str(record.key)] = true
	var records: Array = []
	for record_value in _type_catalog:
		if allowed.has(str(record_value.key)):
			records.append(record_value)
	return records

func _candidate_has_binding(binding: Dictionary) -> bool:
	for candidate_value in _column_candidates:
		var candidate: Dictionary = candidate_value
		if _same_binding(candidate, binding):
			return true
	return false

func _has_result_column(binding: Dictionary) -> bool:
	for selected_value in _dcq_columns:
		if selected_value is Dictionary:
			var selected: Dictionary = selected_value
			if selected.get("project") == binding.project and selected.get("type_id") == binding.type_id and selected.get("field_key") == binding.field_key:
				return true
	return false

func _toggle_result_column(index: int) -> void:
	var binding: Dictionary = _column_candidates[index]
	for i in range(_dcq_columns.size() - 1, -1, -1):
		var selected: Variant = _dcq_columns[i]
		if selected is Dictionary and selected.get("project") == binding.project and selected.get("type_id") == binding.type_id and selected.get("field_key") == binding.field_key:
			_dcq_columns.remove_at(i)
			_rebuild_columns()
			_populate_tree()
			return
	if _dcq_columns.is_empty():
		_dcq_columns = _col_fields.duplicate(true)
	_dcq_columns.append(binding.duplicate(true))
	_rebuild_columns()
	_populate_tree()


func _on_item_selected() -> void:
	var selected := _tree.get_selected()
	if selected:
		var origin: Dictionary = selected.get_metadata(0)
		item_selected.emit(str(origin.id), str(origin.project))


func _on_item_activated() -> void:
	var selected := _tree.get_selected()
	if selected:
		var origin: Dictionary = selected.get_metadata(0)
		item_activated.emit(str(origin.id), str(origin.project))


func _on_tree_item_mouse_selected(_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index == MOUSE_BUTTON_RIGHT:
		_context_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _on_context_menu_id_pressed(id: int) -> void:
	if id == 0:  # Copy ID
		var selected := _tree.get_selected()
		if selected:
			var origin: Dictionary = selected.get_metadata(0)
			var full_id: String = str(origin.get("id", ""))
			_last_context_copy_id = full_id
			DisplayServer.clipboard_set(full_id)


func get_selected_id() -> String:
	var selected := _tree.get_selected()
	if selected:
		var origin: Dictionary = selected.get_metadata(0)
		return str(origin.get("id", ""))
	return ""

func get_selected_origin() -> Dictionary:
	var selected := _tree.get_selected()
	if selected:
		return (selected.get_metadata(0) as Dictionary).duplicate()
	return {}


func get_filter() -> String:
	## Returns JSON string of {"conditions": [...]} for UI state serialization.
	## Uses _serialize_all_conditions() to preserve "(any)" rows across navigation.
	var filter := _serialize_all_conditions()
	if filter.is_empty():
		return ""
	return JSON.stringify(filter)


func set_filter(text: String) -> void:
	## Accepts JSON conditions format or old "key:value" format.
	if not text.strip_edges().is_empty():
		_user_has_modified = true
	# Clear existing rows
	for row in _condition_rows:
		row["hbox"].queue_free()
	_condition_rows.clear()

	if text.strip_edges().is_empty():
		_add_condition_row(true)
		_run_query()
		return

	# Try JSON parse
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary and parsed.has("conditions"):
		var conditions: Array = parsed["conditions"]
		for i in conditions.size():
			var cond: Dictionary = conditions[i]
			_add_condition_row(i == 0)
			var row: Dictionary = _condition_rows[i]
			# Set conjunction
			if i > 0 and cond.has("conj"):
				var conj_opt: OptionButton = row["conj"]
				conj_opt.selected = 1 if str(cond.conj).to_lower() == "or" else 0
			# Set field
			var field_opt: OptionButton = row["field"]
			var field_name: String = str(cond.get("field", "type"))
			for fi in field_opt.item_count:
				if field_opt.get_item_text(fi) == field_name:
					field_opt.selected = fi
					break
			_update_ops_for_row(i)
			# Set op
			var op_key: String = str(cond.get("op", "eq"))
			var catalog_status_choice: Dictionary = cond.get("value", {}) if op_key == "catalog_status" else {}
			if op_key == "catalog_status":
				op_key = "eq"
			var op_label: String = _OP_LABELS.get(op_key, op_key)
			var op_opt: OptionButton = row["op"]
			for oi in op_opt.item_count:
				if op_opt.get_item_text(oi) == op_label:
					op_opt.selected = oi
					break
			if field_name == "type" and op_key != "catalog_in":
				row["type_chooser"].visible = false
				row["value"].visible = op_key not in ["is_empty", "is_not_empty"]
				row["value_dropdown"].visible = false
			# Set value
			if cond.has("value"):
				var val_str: String = str(catalog_status_choice.get("status", cond["value"]))
				if field_name == "type" and op_key == "catalog_in":
					var values: Array = cond["value"] if cond["value"] is Array else [cond["value"]]
					row["type_chooser"].set_selected_values(values)
					row["type_chooser"].visible = true
					row["value_dropdown"].visible = false
					row["value"].visible = false
				elif field_name == "type":
					row["value"].text = val_str
					row["value"].visible = true
					row["type_chooser"].visible = false
				elif _dropdown_values().has(field_name):
					var dd: OptionButton = row["value_dropdown"]
					if not _select_dropdown_metadata(dd, val_str):
						# Keeping the literal makes legacy saved queries reviewable even
						# when the current registry cannot offer their old value.
						dd.add_item("Unavailable — %s" % val_str)
						dd.set_item_metadata(dd.item_count - 1, val_str)
						dd.selected = dd.item_count - 1
					dd.visible = op_key not in ["is_empty", "is_not_empty"]
					row["value"].visible = false
				else:
					var val_edit: LineEdit = row["value"]
					val_edit.text = val_str
					val_edit.visible = op_key not in ["is_empty", "is_not_empty"]
					row["value_dropdown"].visible = false
	else:
		# Old "key:value" format → convert to condition rows
		var parts := text.split(" ")
		var idx := 0
		for part in parts:
			var kv := part.split(":")
			if kv.size() == 2:
				_add_condition_row(idx == 0)
				var row: Dictionary = _condition_rows[idx]
				if idx > 0:
					row["conj"].selected = 0  # AND
				# Set field
				var field_opt: OptionButton = row["field"]
				for fi in field_opt.item_count:
					if field_opt.get_item_text(fi) == kv[0]:
						field_opt.selected = fi
						break
				_update_ops_for_row(idx)
				# Set value
				var kv_field: String = kv[0]
				if kv_field == "type":
					row["type_chooser"].visible = false
					row["value_dropdown"].visible = false
					row["value"].visible = true
					row["value"].text = kv[1]
				elif _dropdown_values().has(kv_field):
					var dd: OptionButton = row["value_dropdown"]
					for vi in dd.item_count:
						if dd.get_item_text(vi) == kv[1]:
							dd.selected = vi
							break
				else:
					row["value"].text = kv[1]
				idx += 1
		if idx == 0:
			_add_condition_row(true)
	_refresh_scoped_controls()
	if parsed is Dictionary and parsed.has("conditions"):
		for i in parsed.conditions.size():
			var saved: Dictionary = parsed.conditions[i]
			if saved.get("op", "") == "catalog_status" and saved.get("value") is Dictionary:
				var row: Dictionary = _condition_rows[i]
				_select_status_choice(row.value_dropdown, saved.value)
				row.catalog_status_choice = saved.value.duplicate(true)

	_run_query()


func get_filter_summary() -> String:
	## Human-readable summary like "type equals bug, priority > 2"
	var parts := PackedStringArray()
	for i in _condition_rows.size():
		var row: Dictionary = _condition_rows[i]
		var field_opt: OptionButton = row["field"]
		var op_opt: OptionButton = row["op"]
		var value_edit: LineEdit = row["value"]
		var value_dropdown: OptionButton = row["value_dropdown"]
		var conj_opt: OptionButton = row["conj"]

		var field_name: String = field_opt.get_item_text(field_opt.selected)
		var op_label: String = op_opt.get_item_text(op_opt.selected)
		var val: String
		if field_name == "type" and row["type_chooser"].visible:
			val = ", ".join(row["type_chooser"].selected_values())
		elif _dropdown_values().has(field_name) and value_dropdown.visible:
			val = str(_dropdown_stored_value(value_dropdown))
		else:
			val = value_edit.text.strip_edges()

		var part := ""
		if i > 0:
			part += "OR " if conj_opt.selected == 1 else "AND "
		part += "%s %s" % [field_name, op_label]
		if op_label not in ["is empty", "is not empty"] and not val.is_empty():
			part += " %s" % val
		parts.append(part)

	var summary := ", ".join(parts)
	return summary if not summary.is_empty() else "All Items"


func load_dcq(path: String) -> void:
	## Load both filter and sort; identity-bearing dictionaries remain opaque so
	## a missing project/type binding is surfaced during execution.
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		return
	if parsed.has("ui_filter"):
		set_filter(JSON.stringify(parsed.ui_filter))
	elif parsed.has("filter") and parsed.filter is Dictionary and parsed.filter.has("conditions"):
		set_filter(JSON.stringify(parsed.filter))
	_dcq_columns = parsed.get("columns", []).duplicate(true) if parsed.get("columns", []) is Array else []
	if parsed.get("sort") is Array and not parsed.sort.is_empty() and parsed.sort[0] is Dictionary:
		_sort_field = str(parsed.sort[0].get("field_key", parsed.sort[0].get("field", "")))
		_sort_dir = str(parsed.sort[0].get("dir", "asc"))
		_sort_binding = parsed.sort[0].duplicate(true)
		_run_query()
	else:
		_rebuild_columns()


func save_dcq(path: String) -> void:
	## Save current query builder state as a .dcq file.
	# `filter` stays executable for other .dcq consumers while `ui_filter` keeps
	# catalog identities needed to reconstruct the chooser without rebinding.
	var ui_filter := _serialize_all_conditions()
	var filter := _build_conditions_filter()
	var saved_columns: Array = _dcq_columns.duplicate(true) if not _dcq_columns.is_empty() else _col_fields.duplicate()
	var dcq := {"filter": filter, "ui_filter": ui_filter, "columns":saved_columns}
	# Include sort if active
	if not _sort_field.is_empty():
		var sort_value: Dictionary = _sort_binding.duplicate(true)
		sort_value["field"] = _sort_field; sort_value["dir"] = _sort_dir
		dcq["sort"] = [sort_value]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(dcq, "\t"))


func refresh() -> void:
	_run_query()
