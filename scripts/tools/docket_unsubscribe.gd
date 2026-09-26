extends RefCounted
class_name DocketUnsubscribe
## docket_unsubscribe: remove a change-feed subscriber (DocketSubscriptions).


func get_definition() -> Dictionary:
	return {
		"name": "docket_unsubscribe",
		"description": "Remove a subscriber registered with docket_subscribe. Its cursors stop working; the event log itself is unchanged.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"subscriber": {"type": "string", "description": "Subscriber id from docket_subscribe"},
			},
			"required": ["subscriber"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, _project_dbs: Dictionary = {}) -> Dictionary:
	return DocketSubscriptions.unsubscribe(str(args.get("subscriber", "")))
