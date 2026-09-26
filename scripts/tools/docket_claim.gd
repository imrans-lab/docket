extends RefCounted
class_name DocketClaim
## docket_claim: take the claim on an item's protected fields (ItemClaim).


func get_definition() -> Dictionary:
	return {
		"name": "docket_claim",
		"description": "Claim an item for a declared holder (a session label). While claimed, changes to protected fields (status, resolution, assigned_to, parent, blocked_by, title, description, and tags in the wr:, role:, base:, head:, result:, requires:, outcome:, deferred: namespaces) through docket_update / docket_transition must pass the same `holder`, or they are refused with \"not the holder: <current>\". Other fields, comments, links and attachments stay open to everyone. Claiming an item someone else holds is refused; re-claiming your own claim changes nothing. The holder is a declaration, not authentication. The claim is recorded as an event in the project file, so it survives a server restart; it is not tied to a connection, so a client disconnect does NOT release it — it lasts until docket_release or docket_reassign. A claim only refuses writes; it never stops another process or undoes its work. Reading an item never creates or refreshes a claim.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"holder": {"type": "string", "description": "Declared holder (session label) taking the claim"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["id", "holder"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = str(args.get("id", ""))
	if not db.has_item(id): return {"error": "Item not found: %s" % id}
	var result: Dictionary = ItemClaim.claim(db, id, str(args.get("holder", "")))
	if not result.has("error"): result["revision"] = ItemRevision.current(db, id)
	return result
