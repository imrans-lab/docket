extends RefCounted
class_name DocketChangesSince
## docket_changes_since: page a subscriber's visible events by cursor
## (DocketSubscriptions.changes_since).


func get_definition() -> Dictionary:
	return {
		"name": "docket_changes_since",
		"description": "Read the events a subscriber (docket_subscribe) may see after `cursor`. Returns {events, next_cursor, more, expired, expired_projects, unavailable_projects}. Each event is {project, eid, item_id, kind, actor, timestamp, fields, possible_duplicate}; eids are per project and strictly increasing, each project's events come in eid order, and projects are merged by timestamp. Cursor \"\" is the subscription start; pass next_cursor to read on, and keep reading while more=true. A page holds at most `limit` events and about 32 KB. A reconnecting subscriber passes its last cursor and receives every visible event it missed. possible_duplicate=true marks an event this subscriber has been sent before (for instance after re-reading from an older cursor); being sent is not an acknowledgement. Expired cursor: when a project's position is older than the retained log (event_retention) or newer than its head (the file was rewound), the reply has expired=true, no events, expired_projects [{project, cursor_eid, recovery_eid, reason: retention | ahead_of_log}], and a next_cursor positioned at the earliest available event (retention) or the head (ahead_of_log); events between the old cursor and recovery_eid are not recoverable. An empty page with expired=false and more=false means nothing new. A cursor for another subscriber, or an undecodable one, is an error.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"subscriber": {"type": "string", "description": "Subscriber id from docket_subscribe"},
				"cursor": {"type": "string", "description": "next_cursor from the previous page, or \"\" for the subscription start"},
				"limit": {"type": "integer", "minimum": 1, "maximum": DocketSubscriptions.MAX_LIMIT, "description": "Maximum events per page (default %d)" % DocketSubscriptions.DEFAULT_LIMIT},
			},
			"required": ["subscriber"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var raw_limit: Variant = args.get("limit", DocketSubscriptions.DEFAULT_LIMIT)
	if not (raw_limit is int or raw_limit is float) or float(raw_limit) != floorf(float(raw_limit)) or int(raw_limit) < 1: return {"error":"limit must be a positive integer"}
	var limit: int = mini(int(raw_limit), DocketSubscriptions.MAX_LIMIT)
	return DocketSubscriptions.changes_since(str(args.get("subscriber", "")), str(args.get("cursor", "")), limit, DocketSubscriptions.loaded(db, project_dbs))
