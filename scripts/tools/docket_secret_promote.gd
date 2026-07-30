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

	# Move the ciphertext to the handle every consumer already looks for. An item
	# payload lives under handle == item_id: the GUI loads it that way, and
	# delete/move clean up that way. Setting ownership while leaving the value
	# under its original handle produced an item that pointed at a secret nothing
	# could read, and that a later GUI save would duplicate.
	#
	# Safe without the vault password: the handle is never part of the
	# encryption, so this is a rename, not a re-encrypt.
	var rekey_err := db.rekey_secret(handle, item_id)
	if not rekey_err.is_empty():
		db.delete_item(item_id)   # roll back the item we just created
		return {"error": "Could not attach secret to the new item: %s" % rekey_err}

	db.set_secret_owner(item_id, item_id)
	db.add_event(item_id, "created", "mcp",
		"Promoted vault entry '%s' to a tracked item" % handle)

	return {
		"id": item_id,
		"handle": item_id,
		"previous_handle": handle,
		"type": "secret",
		"status": str(item.get("status", "")),
		"title": str(item.get("title", "")),
		"promoted": true,
	}
