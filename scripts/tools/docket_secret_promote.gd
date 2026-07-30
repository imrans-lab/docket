extends RefCounted
class_name DocketSecretPromote


func get_definition() -> Dictionary:
	return {
		"name": "docket_secret_promote",
		"description": (
			"Wrap an existing standalone vault entry in a tracked Secret work item, "
			+ "so it gains a title, status, comments, links and a GUI record. The "
			+ "value is never decrypted or re-entered, so no vault password is needed."
		),
		"inputSchema": {
			"type": "object",
			"properties": {
				"handle": {
					"type": "string",
					"description": "Handle of the standalone secret to promote.",
				},
				"title": {
					"type": "string",
					"description": "Title for the new Secret item. Defaults to the handle.",
				},
				"description": {"type": "string"},
				"tags": {"type": "array", "items": {"type": "string"}},
			},
			"required": ["handle"],
		},
	}


func execute(args: Dictionary, schema: Dictionary, db: DocketDB) -> Dictionary:
	var handle: String = str(args.get("handle", "")).strip_edges()
	if handle.is_empty():
		return {"error": "'handle' is required"}

	if db.get_secret_raw(handle).is_empty():
		return {"error": "No secret found with handle '%s'" % handle}

	var existing_owner := db.get_secret_owner(handle)
	if not existing_owner.is_empty():
		return {"error": (
			"Secret '%s' already belongs to item %s." % [handle, existing_owner]
		)}

	# Create the tracked item. Note this deliberately bypasses docket_create,
	# which refuses type=secret — that guard exists to stop an agent creating a
	# Secret item with no vault entry behind it. Here the ciphertext already
	# exists, so the item is the part that is missing.
	var item := DataModel.create_item(schema, "secret", {
		"title": str(args.get("title", handle)),
		"description": str(args.get("description", "")),
		"tags": args.get("tags", []),
	})
	if item.has("error"):
		return item

	var item_id := db.next_uuid7_id()
	item["id"] = item_id
	var err := db.insert_item(item_id, item)
	if not err.is_empty():
		return {"error": "Failed to create item: %s" % err}

	# Attach by ownership rather than by renaming the handle. Re-keying would
	# mean moving ciphertext, and a mistake there is unrecoverable — the mapping
	# between a value and its handle cannot be re-derived.
	db.set_secret_owner(handle, item_id)
	db.add_event(item_id, "created", "mcp", "Promoted vault entry '%s' to a tracked item" % handle)

	return {
		"id": item_id,
		"handle": handle,
		"type": "secret",
		"status": str(item.get("status", "")),
		"title": str(item.get("title", "")),
		"promoted": true,
	}
