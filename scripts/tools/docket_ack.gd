extends RefCounted
class_name DocketAck
## docket_ack: record that a subscriber consumed events (DocketReceipts.ack).


func get_definition() -> Dictionary:
	return {
		"name": "docket_ack",
		"description": "Acknowledge that a subscriber (docket_subscribe) has consumed events it was sent by docket_changes_since. This is the only way an event becomes consumed: being sent is not consumption, and neither is a delivery receipt from any client. Acking is idempotent (an event acked again is listed in already_acked and nothing changes) and all or nothing (if any entry is refused, the reply is {error, rejected: [{event, reason}]} and nothing is recorded). An event can be acked once it has been delivered to this subscriber and is still visible to it and still in the retained log. Acks never change a comment's open/accepted/rejected status or an item's status, and comment or item changes never change acks. Returns {subscriber, acked, already_acked, pending_count}; see docket_subscription_status for what is still pending.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"subscriber": {"type": "string", "description": "Subscriber id from docket_subscribe"},
				"event_ids": {"type": "array", "minItems": 1, "description": "Events to acknowledge: {project, eid} objects (as docket_changes_since returns them), \"project:eid\" strings, or bare eids when the subscription covers one project", "items": {}},
			},
			"required": ["subscriber", "event_ids"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	return DocketReceipts.ack(str(args.get("subscriber", "")), args.get("event_ids"), DocketSubscriptions.loaded(db, project_dbs))
