extends VBoxContainer
class_name WorkRecordPanel
## Work-record section of the item view (scenes/ui/work_record_panel.tscn).
## Shows, each from its own field and never merged into one status:
##   - the claim holder (ItemClaim.holder, the same lookup docket_get reports);
##   - for a `wr:task`, its outcome tag and each child attempt's state and result;
##   - for a `wr:attempt`, its own state and result.
## Override reassigns the claim to the GUI principal with a required reason
## through ItemClaim.reassign, which writes the audited claim_reassigned event.
## Release gives up a claim the GUI principal holds. The section is hidden for
## items that are neither claimed nor tagged `wr:`.

signal record_opened(id: String)
signal claim_changed

@onready var _holder_label: Label = %HolderLabel
@onready var _override_button: Button = %OverrideButton
@onready var _release_button: Button = %ReleaseButton
@onready var _state_label: Label = %StateLabel
@onready var _attempts_label: Label = %AttemptsLabel
@onready var _attempts_list: ItemList = %AttemptsList
@onready var _error_label: Label = %ErrorLabel
@onready var _override_dialog: ConfirmationDialog = %OverrideDialog
@onready var _reason_edit: LineEdit = %ReasonEdit

var _db: DocketDB
var _item_id: String = ""


func _ready() -> void:
	_override_button.pressed.connect(_on_override_pressed)
	_release_button.pressed.connect(_on_release_pressed)
	_attempts_list.item_activated.connect(func(idx: int) -> void: record_opened.emit(str(_attempts_list.get_item_metadata(idx))))
	_reason_edit.text_changed.connect(func(text: String) -> void: _override_dialog.get_ok_button().disabled = text.strip_edges().is_empty())
	_override_dialog.register_text_enter(_reason_edit)
	_override_dialog.confirmed.connect(_on_override_confirmed)
	visible = false


## Shows the work-record state of `item` (as returned by db.get_item) in `db`.
## A null `db` or empty `item_id` hides the section (drafts, missing items).
func show_for(db: DocketDB, item_id: String, item: Dictionary) -> void:
	_db = db
	_item_id = item_id
	_error_label.visible = false
	if db == null or item_id.is_empty():
		visible = false
		return
	var tags: Array = item.get("tags", []) if item.get("tags", []) is Array else []
	var kind: String = _tag_value(tags, "wr:")
	var holder: String = ItemClaim.holder(db, item_id)
	visible = not kind.is_empty() or not holder.is_empty()
	if not visible: return
	var me: String = GuiPrincipal.id()
	_holder_label.text = "Claim holder: %s" % (holder if not holder.is_empty() else "(unclaimed)")
	_override_button.visible = not holder.is_empty() and holder != me
	_release_button.visible = holder == me
	_state_label.text = _state_text(kind, item, tags)
	_state_label.visible = not _state_label.text.is_empty()
	_attempts_list.clear()
	var show_attempts: bool = kind == "task"
	_attempts_label.visible = show_attempts
	_attempts_list.visible = show_attempts
	if show_attempts: _fill_attempts(db, item_id)


## Task outcome for a task, attempt state and result for an attempt.
func _state_text(kind: String, item: Dictionary, tags: Array) -> String:
	var status: String = str(item.get("status", ""))
	match kind:
		"task":
			var outcome: String = _tag_value(tags, "outcome:")
			return "Task outcome: %s (status %s)" % [outcome if not outcome.is_empty() else "not decided", status]
		"attempt":
			var result: String = _tag_value(tags, "result:")
			return "Attempt state: %s; result: %s" % [status, result if not result.is_empty() else "none yet"]
	return ""


func _fill_attempts(db: DocketDB, task_id: String) -> void:
	var rows: Array = db.execute_query({"filter":{"conditions":[
		{"field":"parent", "op":"eq", "value":task_id},
		{"conj":"and", "field":"tags", "op":"eq", "value":"wr:attempt"},
	]}, "sort":[{"field":"created_at", "dir":"asc"}]})
	for row in rows:
		var attempt: Dictionary = row
		var tags: Array = attempt.get("tags", []) if attempt.get("tags", []) is Array else []
		var role: String = _tag_value(tags, "role:")
		var result: String = _tag_value(tags, "result:")
		_attempts_list.add_item("%s  %s; result: %s  %s" % [role if not role.is_empty() else "(no role)", str(attempt.get("status", "")), result if not result.is_empty() else "none yet", str(attempt.get("title", ""))])
		_attempts_list.set_item_metadata(_attempts_list.item_count - 1, str(attempt.get("id", "")))
	_attempts_label.text = "Attempts (%d)" % rows.size() if not rows.is_empty() else "Attempts: none recorded"


func _on_override_pressed() -> void:
	_reason_edit.text = ""
	_override_dialog.get_ok_button().disabled = true
	_override_dialog.popup_centered()
	_reason_edit.grab_focus()


func _on_override_confirmed() -> void:
	var reason: String = _reason_edit.text.strip_edges()
	if reason.is_empty() or _db == null: return
	var me: String = GuiPrincipal.id()
	_report(ItemClaim.reassign(_db, _item_id, me, me, reason, true))


func _on_release_pressed() -> void:
	if _db == null: return
	_report(ItemClaim.release(_db, _item_id, GuiPrincipal.id()))


## Shows a refusal inline; on success asks the host form to reload the item.
func _report(result: Dictionary) -> void:
	if result.has("error"):
		_error_label.text = str(result.error)
		_error_label.visible = true
		return
	claim_changed.emit()


## The rest of the first tag starting with `prefix`, or "".
static func _tag_value(tags: Array, prefix: String) -> String:
	for tag in tags:
		if str(tag).begins_with(prefix): return str(tag).substr(prefix.length())
	return ""
