extends RefCounted
class_name DocketAppend
## docket_append: append text to a markdown field as one ledger entry
## (TypeRegistry.append_field, ContentLedger).


func get_definition() -> Dictionary:
	return {
		"name": "docket_append",
		"description": "Append text to a markdown field (description, article, steps, prompt_text, or a custom markdown field) without resending the whole body. The server joins it to the end of the field, separated by a blank line, and returns {entry_id, revision, offset, length, deduplicated}. docket_get still returns the whole field. Appends are applied one at a time, so concurrent appenders never lose an entry; entries keep the order the server received them. `request_id` makes retries safe: repeating a request_id that already succeeded returns the original entry with deduplicated=true and writes nothing (even if if_revision is now stale); reusing it with different text is refused. Dedup is per (item, field, request_id) for the item's lifetime. A new append honours the claim on a protected field (description) and `if_revision`.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"field": {"type": "string", "description": "Markdown field to append to"},
				"text": {"type": "string", "description": "Text to append; only this is sent and stored"},
				"request_id": {"type": "string", "description": "Caller-chosen unique id for this append (a uuid); retry with the same id and text"},
				"if_revision": {"type":"integer","minimum":0,"description":"Item revision you read (docket_get `revision`). A stale value refuses a new append and nothing is written."},
				"holder": {"type": "string", "description": "Your declared claim holder; required to append to a protected field of a claimed item. Recorded as the event actor."},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["id", "field", "text", "request_id"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = str(args.get("id", ""))
	if not db.has_item(id): return {"error": "Item not found: %s" % id}
	var if_revision: Dictionary = ItemRevision.parse_arg(args)
	if if_revision.has("error"): return {"error":if_revision.error}
	var holder: String = str(args.get("holder", ""))
	var registry: TypeRegistry = TypeRegistry.for_db(db, db.get_project_name())
	var result: Dictionary = registry.append_field(id, str(args.get("field", "")), str(args.get("text", "")), str(args.get("request_id", "")), holder if not holder.is_empty() else "agent", int(if_revision.value), holder)
	# Every refusal reports the current revision so the caller can re-read and retry.
	if result.has("error"): return {"error":result.error, "revision":ItemRevision.current(db, id)}
	result["id"] = id
	return result
