extends RefCounted
class_name DocketReceive

func get_definition() -> Dictionary:
	return {
		"name":"docket_receive",
		"description":"Receive visible unacknowledged messages, oldest first, without acknowledging. Returns the docket_changes_since page envelope. Messages contain {project, eid, item_id, title, kind, actor, timestamp, possible_duplicate, received_at, acked_at, truncated}; created adds {created:{title,description}}, comment_added/comment_reply adds {comment:{id,author,text}}, transition/status_repaired adds {transition:{note}}. Other kinds carry the common keys only. Titles/names are capped at 160 characters, payload text at 2048, descriptions at four lines, and pages at 32 KB. A page may stop below limit because of its byte budget. Legacy comments have null id and an 80-character stored preview; truncated=true when the preview reaches 80 characters or other text was shortened. Repeated receive preserves first server UTC received_at. Default limit is 50, maximum 200; older unacknowledged messages can fill the limit and hide newer ones until ACK. Visibility/expiry match changes_since; on expired=true call receive again to recover. Current item title/description are read at receive time. Use docket_ack to consume, or docket_respond to reply and acknowledge.",
		"inputSchema":{"type":"object", "properties":{
			"subscriber":{"type":"string", "description":"Subscriber id returned by docket_subscribe"},
			"limit":{"type":"integer", "minimum":1, "maximum":DocketSubscriptions.MAX_LIMIT, "description":"Maximum messages per call (default %d, maximum %d); byte budget can stop the page sooner" % [DocketSubscriptions.DEFAULT_LIMIT, DocketSubscriptions.MAX_LIMIT]}
		}, "required":["subscriber"]}
	}

func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var raw: Variant = args.get("limit", DocketSubscriptions.DEFAULT_LIMIT)
	if not (raw is int or raw is float) or float(raw) != floorf(float(raw)) or int(raw) < 1: return {"error":"limit must be a positive integer"}
	return DocketMessages.receive(str(args.get("subscriber", "")), mini(int(raw), DocketSubscriptions.MAX_LIMIT), DocketSubscriptions.loaded(db, project_dbs))
