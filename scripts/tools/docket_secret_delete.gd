extends RefCounted
class_name DocketSecretDelete
## MCP tool: delete a secret from the docket vault.


func get_definition() -> Dictionary:
	return {
		"name": "docket_secret_delete",
		"description": "Delete a secret from the docket vault by handle.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"handle": {"type": "string", "description": "Name of the secret to delete"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["handle"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var handle: String = str(args.get("handle", "")).strip_edges()

	if handle.is_empty():
		return {"error": "'handle' is required"}

	# Same boundary as docket_secret_set. Without this an agent could delete a
	# tracked item's encrypted payload and leave the item behind, pointing at
	# nothing — worse than the overwrite case, because there is no rotation
	# history to recover from.
	var owner := db.get_secret_owner(handle)
	var implied := handle.substr(0, handle.length() - 6) if handle.ends_with(":notes") else handle
	if not owner.is_empty() or db.has_item(implied):
		var item_ref: String = owner if not owner.is_empty() else implied
		return {"error": (
			"Secret '%s' belongs to work item %s. " % [handle, item_ref]
			+ "Delete the item, or clear its value through the item, rather than "
			+ "removing the vault entry directly."
		)}

	if db.delete_secret(handle):
		AuditLog.record(db.get_path(), AuditLog.DELETE, handle, true, "mcp")
		return {"handle": handle, "deleted": true}
	else:
		return {"error": "Secret not found: %s" % handle}
