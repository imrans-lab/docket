extends RefCounted
class_name DocketSubscriptionStatus
## docket_subscription_status: inspect receipt state by subscriber or by event
## (DocketReceipts.status / event_status).


func get_definition() -> Dictionary:
	return {
		"name": "docket_subscription_status",
		"description": "Inspect acknowledgement state. With `subscriber`: {subscriber, name, filters, pending, pending_count, acked_count, positions, cursor, acked_events (when include_acked)}. pending lists delivered-but-unacknowledged events the subscriber can still see ({project, eid, item_id, kind, actor, timestamp}, at most `limit`, eid order per project); positions has one row per project {project, start, delivered, head, retention_floor, acked}, where delivered is the largest eid ever sent to it; cursor is a docket_changes_since cursor just after everything delivered. With `event` instead: {project, eid, acked_by, pending_for}, each a list of {subscriber, name}.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"subscriber": {"type": "string", "description": "Subscriber id from docket_subscribe"},
				"event": {"type": "object", "description": "{project, eid}: report which subscribers acknowledged it or have it pending", "properties": {"project": {"type": "string"}, "eid": {"type": "integer", "minimum": 1}}, "required": ["project", "eid"]},
				"include_acked": {"type": "boolean", "description": "Also list acknowledged events (subscriber mode; default false)"},
				"limit": {"type": "integer", "minimum": 1, "maximum": DocketReceipts.MAX_LIMIT, "description": "Maximum events per list (default %d)" % DocketReceipts.DEFAULT_LIMIT},
			},
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var projects: Dictionary = DocketSubscriptions.loaded(db, project_dbs)
	var subscriber: String = str(args.get("subscriber", ""))
	var event: Variant = args.get("event")
	if subscriber.is_empty() == (event == null): return {"error":"pass exactly one of subscriber or event"}
	if event != null:
		if not event is Dictionary: return {"error":"event must be {project, eid}"}
		var eid: Variant = (event as Dictionary).get("eid")
		if not (eid is int or eid is float) or float(eid) != floorf(float(eid)) or int(eid) < 1: return {"error":"event.eid must be a positive integer"}
		return DocketReceipts.event_status(str((event as Dictionary).get("project", "")), int(eid), projects)
	var raw_limit: Variant = args.get("limit", DocketReceipts.DEFAULT_LIMIT)
	if not (raw_limit is int or raw_limit is float) or float(raw_limit) != floorf(float(raw_limit)) or int(raw_limit) < 1: return {"error":"limit must be a positive integer"}
	return DocketReceipts.status(subscriber, bool(args.get("include_acked", false)), mini(int(raw_limit), DocketReceipts.MAX_LIMIT), projects)
