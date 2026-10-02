extends RefCounted
class_name DocketRespond
## Validation precedes the reply; project and receipt saves remain independent.

func get_definition() -> Dictionary:
	return {
		"name":"docket_respond",
		"description":"Optionally reply, then acknowledge delivered events. All ids are validated by docket_ack before writing: a refused id writes no reply and acknowledges nothing. With text, the first event anchors the reply in its project; comment_added/comment_reply events with an explicit reference produce a threaded reply. Legacy unresolved comments produce a top-level comment. item_id overrides the target within that project; a threaded reply requires the originating item. Author defaults to agent. Returns {comment_id?, acked, already_acked, pending_count}. Without text only acknowledges. Project comments and subscriber receipts save independently: a save failure after a reply returns error, comment_id, acks_recorded=false; recover with docket_ack, not another text response. No crash-atomic or exactly-once guarantee. Each successful call with text adds a reply, including re-acks. The reply event follows normal visibility and is returned by receive if visible until explicitly acknowledged; authors are not filtered out.",
		"inputSchema":{"type":"object", "properties":{
			"subscriber":{"type":"string"},
			"event_ids":{"type":"array", "minItems":1, "items":{}},
			"text":{"type":"string"},
			"item_id":{"type":"string"},
			"author":{"type":"string"}
		}, "required":["subscriber", "event_ids"]}
	}

func execute(args: Dictionary, schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var projects: Dictionary = DocketSubscriptions.loaded(db, project_dbs)
	var subscriber: String = str(args.get("subscriber", ""))
	var raw_events: Variant = args.get("event_ids")
	var checked: Dictionary = DocketReceipts.ack(subscriber, raw_events, projects, true)
	if checked.has("error"): return checked
	if not args.has("text"): return _compact(DocketReceipts.ack(subscriber, raw_events, projects))
	if not args.text is String or str(args.text).is_empty(): return {"error":"Reply text is required when text is supplied"}
	var records: Dictionary = DocketSubscriptions.load_records()
	if not records.has(subscriber): return {"error":"Unknown subscriber: %s" % subscriber}
	var view: Dictionary = DocketSubscriptions.visibility(records[subscriber].get("filters", {}), projects)
	var anchor: Dictionary = DocketReceipts.parse_event((raw_events as Array)[0], view.projects)
	if anchor.has("error"): return anchor
	var target: DocketDB = projects[anchor.project]
	var found: Dictionary = DocketSubscriptions.collect(str(anchor.project), target, int(anchor.eid) - 1, 1, view.kinds, view.chain, int(anchor.eid))
	if found.events.is_empty(): return {"error":"Reply event is no longer visible or retained"}
	var event: Dictionary = found.events[0]
	var item_id: String = str(args.get("item_id", event.item_id))
	if not target.has_item(item_id): return {"error":"Item not found in event project: %s" % item_id}
	var comment: Dictionary = DocketMessages.originating_comment(event, target) if ProjectEvents.COMMENTS.has(str(event.kind)) else {}
	if not comment.is_empty() and item_id != str(comment.item_id): return {"error":"A threaded reply must target the originating comment's item"}
	var comment_args: Dictionary = {"action":"add", "item_id":item_id, "text":args.text, "author":args.get("author", "agent")}
	if not comment.is_empty():
		comment_args.action = "reply"
		comment_args["comment_id"] = int(comment.id)
	var replied: Dictionary = DocketComment.new().execute(comment_args, schema, target)
	if replied.has("error"): return replied
	var ack: Dictionary = DocketReceipts.ack(subscriber, raw_events, projects)
	if ack.has("error"):
		ack["comment_id"] = int(replied.id)
		ack["acks_recorded"] = false
		ack["error"] = "%s; reply %d was saved, acknowledgements were not recorded; recover with docket_ack" % [ack.error, int(replied.id)]
		return ack
	var out: Dictionary = _compact(ack)
	out["comment_id"] = int(replied.id)
	return out

func _compact(ack: Dictionary) -> Dictionary:
	if ack.has("error"): return ack
	return {"acked":ack.acked, "already_acked":ack.already_acked, "pending_count":ack.pending_count}
