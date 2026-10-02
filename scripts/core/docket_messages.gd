extends RefCounted
class_name DocketMessages
## Receive reuses the cursor feed, skipping acknowledged events during collection.
## Its private cursor stays before the first returned event until it is acked.

const TEXT_CHARS := 2048
const TITLE_CHARS := 160
const DESCRIPTION_LINES := 4
const PAGE_BYTES := 32768

static func receive(id: String, limit: int, project_dbs: Dictionary) -> Dictionary:
	var records: Dictionary = DocketSubscriptions.load_records()
	if not records.has(id): return {"error":"Unknown subscriber: %s" % id}
	var record: Dictionary = records[id]
	var cursor: String = str(record.get("receive_cursor", ""))
	var page: Dictionary = DocketSubscriptions.changes_since(id, cursor, limit, project_dbs, true)
	if page.has("error"): return page
	records = DocketSubscriptions.load_records()
	record = records[id]
	if bool(page.expired):
		record["receive_cursor"] = page.next_cursor
		var error: String = DocketSubscriptions.save_records(records)
		return {"error":error} if not error.is_empty() else page
	var positions: Dictionary = DocketSubscriptions.decode_cursor(str(page.next_cursor)).p
	var messages: Array[Dictionary] = []
	var delivered: Array[Dictionary] = []
	var budget: int = PAGE_BYTES
	var first: Dictionary = {}
	for event: Dictionary in page.events:
		var project: String = str(event.project)
		if not first.has(project):
			positions[project] = int(event.eid) - 1
			first[project] = true
	for event: Dictionary in page.events:
		var project: String = str(event.project)
		var message: Dictionary = resolve(event, project_dbs[project])
		var size: int = JSON.stringify(message).to_utf8_buffer().size() + 256
		if size > budget:
			page.more = true
			break
		budget -= size
		messages.append(message)
		delivered.append(event)
	DocketReceipts.stamp(record, delivered, "received_at")
	for message: Dictionary in messages:
		message.merge(DocketReceipts.times(record, str(message.project), int(message.eid)))
	record["receive_cursor"] = DocketSubscriptions.encode_cursor(id, positions)
	var error: String = DocketSubscriptions.save_records(records)
	if not error.is_empty(): return {"error":error}
	page["events"] = messages
	return page


## Compact current item detail and event-specific payload, without referenced items.
static func resolve(event: Dictionary, db: DocketDB) -> Dictionary:
	var item: Dictionary = db.get_item(str(event.item_id))
	var title: String = str(item.get("title", ""))
	var out: Dictionary = {}
	for key: String in ["project", "eid", "item_id", "kind", "actor", "timestamp", "possible_duplicate"]:
		out[key] = event.get(key)
	out["actor"] = str(out.actor).left(TITLE_CHARS)
	out["title"] = title.left(TITLE_CHARS)
	out["truncated"] = title.length() > TITLE_CHARS or str(event.actor).length() > TITLE_CHARS
	if str(event.kind) == "created":
		var text: String = str(item.get("description", ""))
		var lines: PackedStringArray = text.split("\n")
		var excerpt: String = "\n".join(lines.slice(0, DESCRIPTION_LINES)).left(TEXT_CHARS)
		out["created"] = {"title":title.left(TITLE_CHARS), "description":excerpt}
		out.truncated = bool(out.truncated) or excerpt != text
	if ProjectEvents.TRANSITIONS.has(str(event.kind)):
		var rows: Array = db._exec_select("SELECT note FROM item_events WHERE eid=?;", [int(event.eid)])
		var note: String = str(rows[0].get("note", "")) if not rows.is_empty() else ""
		out["transition"] = {"note":note.left(TEXT_CHARS)}
		out.truncated = bool(out.truncated) or note.length() > TEXT_CHARS
	if ProjectEvents.COMMENTS.has(str(event.kind)):
		var comment: Dictionary = originating_comment(event, db)
		if not comment.is_empty():
			var text: String = str(comment.text)
			var author: String = str(comment.author)
			out["comment"] = {"id":int(comment.id), "author":author.left(TITLE_CHARS), "text":text.left(TEXT_CHARS)}
			out.truncated = bool(out.truncated) or text.length() > TEXT_CHARS or author.length() > TITLE_CHARS
		else:
			var rows: Array = db._exec_select("SELECT note FROM item_events WHERE eid=?;", [int(event.eid)])
			out["comment"] = {"id":null, "author":str(event.actor).left(TITLE_CHARS), "text":str(rows[0].get("note", "")).left(80) if not rows.is_empty() else ""}
			out.truncated = true
	return out


## Only an explicit event field can identify a comment; legacy previews are ambiguous.
static func originating_comment(event: Dictionary, db: DocketDB) -> Dictionary:
	for field: String in event.get("fields", []):
		if not field.begins_with("comment:"): continue
		var digits: String = field.trim_prefix("comment:")
		if not digits.is_valid_int() or int(digits) <= 0: continue
		var comment: Dictionary = db.get_comment(int(digits))
		if str(comment.get("item_id", "")) == str(event.item_id): return comment
	return {}
