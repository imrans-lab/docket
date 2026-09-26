extends RefCounted
class_name ContentLedger
## Entry ledger for appendable fields (D1 KB docket:01a0dc398e6c s1-2).
##
## The field string stays the only content authority. Each docket_append adds
## one `content_appended` item event whose note is compact JSON:
##   {"e": entry id (uuid7), "f": field, "o": offset, "n": length,
##    "h": sha256[:16] of the appended text, "q": request_id, "r": revision after the write}
## Offsets and lengths are in String characters of the STORED text, excluding
## the separator. An entry is live while field[o:o+n] still hashes to h.
##
## request_id dedup reads these same events, keyed (item, field, request_id).
## Events live as long as the item and move with it, so dedup has no TTL.

const EVENT := "content_appended"
const HASH_CHARS := 16


## Hash stored in an entry's "h" and compared on dedup and liveness.
static func text_hash(text: String) -> String:
	return text.sha256_text().substr(0, HASH_CHARS)


## Separator placed before appended text: none for an empty field or one that
## already ends in a blank line, else one blank line.
static func separator(current: String) -> String:
	if current.is_empty() or current.ends_with("\n\n"): return ""
	return "\n\n"


static func encode(entry_id: String, field: String, offset: int, length: int, digest: String, request_id: String, revision: int) -> String:
	return JSON.stringify({"e":entry_id, "f":field, "o":offset, "n":length, "h":digest, "q":request_id, "r":revision})


## Decoded note, or {} when the note is not a well-formed ledger record.
## JSON numbers arrive as floats; o, n and r are returned as ints.
static func decode(note: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(note)
	if not parsed is Dictionary: return {}
	var raw: Dictionary = parsed
	for key in ["e", "f", "h", "q"]:
		if not raw.get(key) is String: return {}
	for key in ["o", "n", "r"]:
		if not (raw.get(key) is float or raw.get(key) is int): return {}
	return {"e":str(raw.e), "f":str(raw.f), "o":int(raw.o), "n":int(raw.n), "h":str(raw.h), "q":str(raw.q), "r":int(raw.r)}


## Ledger entries of one field of `id`, in canonical event order
## (timestamp, then insertion), which is also append order.
static func entries(db: DocketDB, id: String, field: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var rows: Array = db._exec_select("SELECT note FROM item_events WHERE item_id=? AND event_type=? ORDER BY timestamp ASC, id ASC;", [id, EVENT])
	for row in rows:
		var entry: Dictionary = decode(str(row.get("note", "")))
		if not entry.is_empty() and entry.f == field: result.append(entry)
	return result


## The earlier entry written for (id, field, request_id), or {}.
static func find_request(db: DocketDB, id: String, field: String, request_id: String) -> Dictionary:
	for entry in entries(db, id, field):
		if entry.q == request_id: return entry
	return {}


## Whether `entry` still covers its original text in `current`.
static func is_live(entry: Dictionary, current: String) -> bool:
	var offset: int = int(entry.o)
	var length: int = int(entry.n)
	if offset < 0 or offset + length > current.length(): return false
	return text_hash(current.substr(offset, length)) == str(entry.h)
