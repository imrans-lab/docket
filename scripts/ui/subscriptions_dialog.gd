extends AcceptDialog
class_name SubscriptionsDialog
## File > Subscriptions…: read-only view of change-feed subscribers
## (scenes/ui/subscriptions_dialog.tscn). For the selected subscriber it lists
## each delivered event with its ack state from DocketReceipts.status, pending
## first, and a summary of counts and per-project positions.

var _state: AppState
var _ids: PackedStringArray = []


func init(state: AppState) -> void:
	_state = state
	%SubscriberPicker.item_selected.connect(func(_index: int) -> void: _show_selected())
	%RefreshButton.pressed.connect(open)


func open() -> void:
	var picker: OptionButton = %SubscriberPicker
	var previous: String = _ids[picker.selected] if picker.selected >= 0 and picker.selected < _ids.size() else ""
	picker.clear()
	_ids.clear()
	var records: Dictionary = DocketSubscriptions.load_records()
	for id in records:
		_ids.append(str(id))
		picker.add_item("%s (%s)" % [str((records[id] as Dictionary).get("name", "")), str(id)])
	if not _ids.is_empty(): picker.select(maxi(_ids.find(previous), 0))
	_show_selected()
	popup_centered()


func _show_selected() -> void:
	var list: ItemList = %EventList
	var summary: Label = %SummaryLabel
	list.clear()
	var picker: OptionButton = %SubscriberPicker
	if picker.selected < 0 or picker.selected >= _ids.size():
		summary.text = "No subscribers. Agents register one with docket_subscribe."
		return
	var status: Dictionary = DocketReceipts.status(_ids[picker.selected], true, DocketReceipts.MAX_LIMIT, DocketSubscriptions.loaded(_state.db, _state.get_project_dbs()))
	if status.has("error"):
		summary.text = str(status.error)
		return
	var positions: PackedStringArray = []
	for row in status.positions:
		positions.append("%s delivered %d of head %d" % [row.project, int(row.delivered), int(row.head)])
	summary.text = "%d pending, %d acknowledged. %s" % [int(status.pending_count), int(status.acked_count), "; ".join(positions)]
	for event in status.pending: list.add_item(_line("pending", event))
	for event in status.acked_events: list.add_item(_line("acked", event))


func _line(state: String, event: Dictionary) -> String:
	return "%-8s %s #%d  %s  %s  %s" % [state, event.project, int(event.eid), event.kind, event.item_id, event.timestamp]
