extends RefCounted
class_name DocketRelease
## docket_release: give up a claim (ItemClaim).


func get_definition() -> Dictionary:
	return {
		"name": "docket_release",
		"description": "Release your claim on an item. Only the current holder may release; anyone else is refused with \"not the holder: <current>\". Releasing an unclaimed item changes nothing. A disconnecting client never releases its claims; call this when done, or have someone docket_reassign.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"holder": {"type": "string", "description": "Declared holder releasing the claim"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["id", "holder"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = str(args.get("id", ""))
	if not db.has_item(id): return {"error": "Item not found: %s" % id}
	var result: Dictionary = ItemClaim.release(db, id, str(args.get("holder", "")))
	if not result.has("error"): result["revision"] = ItemRevision.current(db, id)
	return result
