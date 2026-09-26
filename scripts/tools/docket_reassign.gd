extends RefCounted
class_name DocketReassign
## docket_reassign: move a claim to a new holder, or override it (ItemClaim).


func get_definition() -> Dictionary:
	return {
		"name": "docket_reassign",
		"description": "Move an item's claim to holder `to`. The current holder (or anyone, when the item is unclaimed) may hand it over. Anyone else is overriding the claim and must pass override=true; this is the human override path. A reason is always required. The prior holder's claim ends immediately: its next protected write is refused with \"not the holder: <new holder>\". The reassignment is recorded in the item's event log (docket_get events) as `claim_reassigned` with the actor, the previous holder, the new holder, the reason and whether it was an override. It does not edit assigned_to or any other field, and it does not stop the prior holder's process; the new holder reconciles whatever that process already did.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"to": {"type": "string", "description": "Declared holder receiving the claim"},
				"reason": {"type": "string", "description": "Why the claim moves (required)"},
				"actor": {"type": "string", "description": "Who is reassigning (declared principal); recorded as the event actor"},
				"override": {"type": "boolean", "description": "Required when `actor` is not the current holder of a claimed item"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["id", "to", "reason", "actor"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = str(args.get("id", ""))
	if not db.has_item(id): return {"error": "Item not found: %s" % id}
	var result: Dictionary = ItemClaim.reassign(db, id, str(args.get("actor", "")), str(args.get("to", "")), str(args.get("reason", "")), bool(args.get("override", false)))
	if not result.has("error"): result["revision"] = ItemRevision.current(db, id)
	return result
