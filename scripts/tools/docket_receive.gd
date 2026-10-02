extends RefCounted
class_name DocketReceive

func get_definition() -> Dictionary:
	return {
		"name":"docket_receive",
		"description":"Receive compact visible unacknowledged events, including previously delivered events. Returns the docket_changes_since page envelope; events have item title and event payload, received_at and acked_at. Titles and actor/author names are capped at 160 characters, comment/description text at 2048, descriptions at four lines, and a page at 32 KB including receipt fields. Legacy comment events lack an explicit reference: comment.id is null, text is the original 80-character preview, and truncated=true. truncated flags shortened text. First received_at is server UTC and survives repeated receive. Receive never acknowledges; use docket_ack. Visibility and expiry recovery match docket_changes_since; on expired=true call receive again to resume at recovery. Transition payloads contain the stored human-readable note (bounded at 2048 characters), without parsing state names. Current item title/description are read at receive time, not historical snapshots.",
		"inputSchema":{"type":"object", "properties":{
			"subscriber":{"type":"string"},
			"limit":{"type":"integer", "minimum":1, "maximum":DocketSubscriptions.MAX_LIMIT}
		}, "required":["subscriber"]}
	}

func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var raw: Variant = args.get("limit", DocketSubscriptions.DEFAULT_LIMIT)
	if not (raw is int or raw is float) or float(raw) != floorf(float(raw)) or int(raw) < 1: return {"error":"limit must be a positive integer"}
	return DocketMessages.receive(str(args.get("subscriber", "")), mini(int(raw), DocketSubscriptions.MAX_LIMIT), DocketSubscriptions.loaded(db, project_dbs))
