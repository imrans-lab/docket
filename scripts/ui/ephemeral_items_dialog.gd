extends ConfirmationDialog
class_name EphemeralItemsDialog
## Quit and project close with ephemeral items outstanding
## (scenes/ui/ephemeral_items_dialog.tscn): Save writes them to their project
## files (ItemStorage.keep, then the normal settle), Delete deletes them
## (ItemStorage.drop), Cancel returns and the quit or close does not happen.
## After Save or Delete the caller's continuation runs; when any item fails, the
## dialog asks again for what is left.

const PREFERRED_SIZE := Vector2i(560, 380)
const USABLE_RATIO := 0.9
## Largest share of min_size's height the message area takes before it scrolls.
const MESSAGE_SHARE := 1.0 / 3.0

var _state: AppState
var _pending: Dictionary = {}
var _after: Callable


func init(state: AppState) -> void:
	_state = state
	add_button("Delete", false, "drop")
	(%Message as Label).resized.connect(_fit_message, CONNECT_DEFERRED)
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
	var failure_label: Label = %Failure
	failure_label.text = "Not done:\n%s" % failure
	(%FailureScroll as ScrollContainer).visible = not failure.is_empty()
	var host := get_parent().get_viewport()
	if is_embedded() and not host.size_changed.is_connected(_on_host_resized):
		host.size_changed.connect(_on_host_resized)
	_fit_to_area()
	popup_centered(min_size)


## A dialog opens at the larger of min_size and its content minimum. The
## message, item list and failure report each scroll, so the content minimum is
## the button row, fixed margins and the message area (_fit_message), whatever
## the text length or item count. min_size is the preferred size cut down to the
## usable area, so the dialog and its buttons stay inside it whenever that area
## is at least the content minimum.
func _fit_to_area() -> void:
	min_size = PREFERRED_SIZE.min(Vector2i(Vector2(_usable_size()) * USABLE_RATIO))
	_fit_message()


## The embedding viewport changed size while the dialog may be open: the bound
## is recomputed and an open dialog is resized to it and centred again.
func _on_host_resized() -> void:
	if not visible: return
	_fit_to_area()
	size = min_size
	move_to_center()


## Sizes the message area to the wrapped message at the label's current width,
## up to MESSAGE_SHARE of min_size's height; a longer message scrolls. The item
## list takes the rest. The label reports its new wrapping only after its
## resized signal has been emitted, so the call on resize is deferred: it runs
## in the same flush of deferred calls as the container layout, before the
## frame is drawn. Before the first layout the label has no width, and ask()'s
## call sets the cap.
func _fit_message() -> void:
	var needed := (%Message as Label).get_minimum_size().y
	(%MessageScroll as ScrollContainer).custom_minimum_size.y = minf(needed, min_size.y * MESSAGE_SHARE)


## The area the dialog's content may use: the embedding viewport, or the
## screen's usable rect for a native window, less the title bar.
func _usable_size() -> Vector2i:
	var area: Vector2i
	if is_embedded(): area = Vector2i(get_parent().get_viewport().get_visible_rect().size)
	else: area = DisplayServer.screen_get_usable_rect(current_screen).size
	return area - Vector2i(0, get_theme_constant(&"title_height"))


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
