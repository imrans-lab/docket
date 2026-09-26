extends VBoxContainer
class_name AuthorizationPanel
## Collapsible "Authorizations" section of the item view. Lists the standing
## authorizations in force on the shown item, from the same lookup that answers
## docket_authorized (ItemAuthorization.for_item). Activating a row asks the
## host form to open that policy record.

signal record_opened(id: String)

var _toggle: Button
var _list: ItemList
var _count: int = 0


func _ready() -> void:
	_toggle = Button.new()
	_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_toggle.flat = true
	_toggle.add_theme_font_size_override("font_size", 14)
	_toggle.pressed.connect(_on_toggle)
	add_child(_toggle)
	_list = ItemList.new()
	_list.auto_height = true
	_list.visible = false
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.item_activated.connect(func(idx: int) -> void: record_opened.emit(str(_list.get_item_metadata(idx))))
	add_child(_list)
	_update_toggle()


## Shows the authorizations covering `item_id` in `db`; clears when `db` is null.
func show_for(db: DocketDB, item_id: String) -> void:
	_list.clear()
	var found: Array = [] if db == null or item_id.is_empty() else ItemAuthorization.for_item(db, item_id)
	for entry in found:
		var auth: Dictionary = entry
		_list.add_item("%s may %s via %s (granted by %s, %s)" % [auth.grantee, ", ".join(PackedStringArray(auth.actions)), ", ".join(PackedStringArray(auth.matched_scopes)), auth.granted_by, auth.granted_at])
		_list.set_item_metadata(_list.item_count - 1, auth.id)
		_list.set_item_tooltip(_list.item_count - 1, str(auth.title))
	_count = found.size()
	_update_toggle()


func _on_toggle() -> void:
	_list.visible = not _list.visible
	_update_toggle()


func _update_toggle() -> void:
	var prefix: String = "v" if _list.visible else ">"
	_toggle.text = "%s Authorizations (%d)" % [prefix, _count] if _count > 0 else "%s Authorizations" % prefix
