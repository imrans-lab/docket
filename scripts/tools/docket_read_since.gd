extends RefCounted
class_name DocketReadSince
## docket_read_since: page a markdown field's appended entries by cursor
## (ContentLedger.read_page over TypeRegistry.appendable_target).


func get_definition() -> Dictionary:
	return {
		"name": "docket_read_since",
		"description": "Read a markdown field (description, article, steps, prompt_text, or a custom markdown field) incrementally, so a reader that already has the body fetches only what was appended since. Returns {entries, next_cursor, reset, reset_reason, revision}. Start with cursor \"\": the first entry is the `base` (entry_id null: text not written by docket_append), then appended entries in order. Each entry is {entry_id, offset, length, text, revision, continued}; offsets are characters in the stored field, and entries are separated by nothing or one blank line (\"\\n\\n\"), as the offsets show. A page holds at most `limit` entries and about 32 KB of text; an entry larger than that is split, continued=true marking that its rest starts the next page. Pass next_cursor to read on; when nothing is new the page is empty and next_cursor is unchanged (not an error). An empty field returns an empty page with a valid cursor. Cursor lifetime: a cursor stays valid across appends, other fields, comments and links, and across restarts; it is invalidated only by a change to this field's text other than an append. Then reset=true, entries is empty, next_cursor is \"\", and reset_reason is: rewritten (text before the cursor changed: replace, clear, GUI or hand edit, merge; `revision` is the item's current revision, the one that holds the replacement), unlogged_tail (text after the cursor was not written by docket_append, e.g. a docket_update that extended the field), malformed (undecodable, or a cursor for another field), or item_not_found (deleted or moved). Recovery is one call: read_since with cursor \"\", which returns the whole current field and a fresh cursor.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"field": {"type": "string", "description": "Markdown field to read"},
				"cursor": {"type": "string", "description": "next_cursor from the previous page, or \"\" to read from the start"},
				"limit": {"type": "integer", "minimum": 1, "maximum": ContentLedger.MAX_LIMIT, "description": "Maximum entries per page (default %d)" % ContentLedger.DEFAULT_LIMIT},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["id", "field"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = str(args.get("id", ""))
	var field: String = str(args.get("field", ""))
	var raw_limit: Variant = args.get("limit", ContentLedger.DEFAULT_LIMIT)
	if not (raw_limit is int or raw_limit is float) or float(raw_limit) != floorf(float(raw_limit)) or int(raw_limit) < 1: return {"error":"limit must be a positive integer"}
	var limit: int = mini(int(raw_limit), ContentLedger.MAX_LIMIT)
	if not db.has_item(id): return ContentLedger.reset_page(ContentLedger.RESET_ITEM_NOT_FOUND)
	var registry: TypeRegistry = TypeRegistry.for_db(db, db.get_project_name())
	var target: Dictionary = registry.appendable_target(id, field)
	if target.has("error"):
		if str(target.error) == "item not found": return ContentLedger.reset_page(ContentLedger.RESET_ITEM_NOT_FOUND)
		return {"error":target.error}
	var page: Dictionary = ContentLedger.read_page(str(target.text), field, ContentLedger.entries(db, id, field), str(args.get("cursor", "")), limit)
	page["revision"] = ItemRevision.current(db, id)
	return page
