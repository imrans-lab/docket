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


# --- Incremental reads (docket_read_since, D1 KB s3) ---------------------------
#
# The field is read as segments: an optional `base` (text not covered by the
# trailing chain of live entries, entry_id null) followed by that chain in
# offset order. Consecutive segments are separated by "" or "\n\n", which the
# offsets make explicit. A cursor is an opaque base64 of compact JSON
# {"f": field, "o": offset, "h": sha256[:16] of field[0:o], "s": segment},
# where "s" is "" at a segment boundary, or "base" / an entry id while that
# segment is being read in parts. It holds no revision, so writes to other
# fields, comments and links never invalidate it.

## Text budget per page, in UTF-8 bytes. Keeps a reply well under a 64 KiB
## reply cap measured on the decoded reply.
const PAGE_BYTES := 32768
const DEFAULT_LIMIT := 20
const MAX_LIMIT := 200
const BASE_SEGMENT := "base"
const RESET_ITEM_NOT_FOUND := "item_not_found"
const RESET_REWRITTEN := "rewritten"
const RESET_UNLOGGED_TAIL := "unlogged_tail"
const RESET_MALFORMED := "malformed"


static func encode_cursor(field: String, offset: int, current: String, segment: String) -> String:
	var body: String = JSON.stringify({"f":field, "o":offset, "h":text_hash(current.substr(0, offset)), "s":segment})
	return Marshalls.utf8_to_base64(body)


## {f, o, h, s} or {} when the cursor cannot be decoded.
static func decode_cursor(cursor: String) -> Dictionary:
	var raw_bytes: PackedByteArray = Marshalls.base64_to_raw(cursor)
	if raw_bytes.is_empty(): return {}
	var parsed: Variant = JSON.parse_string(raw_bytes.get_string_from_utf8())
	if not parsed is Dictionary: return {}
	var raw: Dictionary = parsed
	for key in ["f", "h", "s"]:
		if not raw.get(key) is String: return {}
	if not (raw.get("o") is float or raw.get("o") is int) or int(raw.o) < 0: return {}
	return {"f":str(raw.f), "o":int(raw.o), "h":str(raw.h), "s":str(raw.s)}


## Reply without entries that tells the caller to re-read from cursor "".
static func reset_page(reason: String) -> Dictionary:
	return {"entries":[], "next_cursor":"", "reset":true, "reset_reason":reason}


## Segments of `current`: [{key, entry_id, start, end, revision}], base first.
## The chain is built backwards from the end of the field: each step takes the
## latest live entry ending exactly there (or two characters earlier across a
## "\n\n" separator, between entries only).
static func segments(current: String, ledger: Array[Dictionary]) -> Array[Dictionary]:
	var by_end: Dictionary = {}
	for entry in ledger:
		if int(entry.n) > 0 and is_live(entry, current): by_end[int(entry.o) + int(entry.n)] = entry
	var chain: Array[Dictionary] = []
	var pos: int = current.length()
	while true:
		var entry: Dictionary = {}
		if by_end.has(pos): entry = by_end[pos]
		elif not chain.is_empty() and pos >= 2 and current.substr(pos - 2, 2) == "\n\n" and by_end.has(pos - 2): entry = by_end[pos - 2]
		if entry.is_empty(): break
		chain.push_front({"key":str(entry.e), "entry_id":str(entry.e), "start":int(entry.o), "end":int(entry.o) + int(entry.n), "revision":int(entry.r)})
		pos = int(entry.o)
	var base_end: int = pos
	if not chain.is_empty() and base_end >= 2 and current.substr(base_end - 2, 2) == "\n\n": base_end -= 2
	if base_end > 0: chain.push_front({"key":BASE_SEGMENT, "entry_id":null, "start":0, "end":base_end, "revision":null})
	return chain


## One page of `field` after `cursor`: {entries, next_cursor, reset, reset_reason}
## or a reset_page. Each returned entry is {entry_id, offset, length, text,
## revision, continued}; continued=true means the rest of that segment starts
## the next page. A page holds at most `limit` entries and PAGE_BYTES of text;
## a segment larger than the budget is split across pages.
static func read_page(current: String, field: String, ledger: Array[Dictionary], cursor: String, limit: int) -> Dictionary:
	var parts: Array[Dictionary] = segments(current, ledger)
	var index: int = 0
	var pos: int = 0
	if not cursor.is_empty():
		var decoded: Dictionary = decode_cursor(cursor)
		if decoded.is_empty() or decoded.f != field: return reset_page(RESET_MALFORMED)
		var offset: int = int(decoded.o)
		if offset > current.length() or text_hash(current.substr(0, offset)) != decoded.h: return reset_page(RESET_REWRITTEN)
		index = _resume_index(parts, offset, str(decoded.s))
		if index < 0: return reset_page(RESET_UNLOGGED_TAIL)
		pos = offset
	var out: Array[Dictionary] = []
	var budget: int = PAGE_BYTES
	var next_offset: int = pos
	var next_segment: String = ""
	while index < parts.size() and out.size() < limit:
		var part: Dictionary = parts[index]
		var start: int = maxi(pos, int(part.start))
		var text: String = current.substr(start, int(part.end) - start)
		var size: int = text.to_utf8_buffer().size()
		var continued: bool = size > budget
		if continued:
			if not out.is_empty(): break
			text = _prefix_within(text, budget)
		out.append({"entry_id":part.entry_id, "offset":start, "length":text.length(), "text":text, "revision":part.revision, "continued":continued})
		budget -= text.to_utf8_buffer().size()
		next_offset = start + text.length()
		next_segment = str(part.key) if continued else ""
		if continued: break
		index += 1
	return {"entries":out, "next_cursor":encode_cursor(field, next_offset, current, next_segment), "reset":false, "reset_reason":""}


## The longest prefix of `text` whose UTF-8 encoding fits `budget` bytes, and
## at least one character so a page always advances.
static func _prefix_within(text: String, budget: int) -> String:
	var used: int = 0
	var count: int = 0
	while count < text.length():
		var code: int = text.unicode_at(count)
		var width: int = 1 if code < 0x80 else (2 if code < 0x800 else (3 if code < 0x10000 else 4))
		if used + width > budget: break
		used += width
		count += 1
	return text.substr(0, maxi(1, count))


## Index of the segment to read next for a prefix-valid cursor at `offset`, or
## -1 when the text after `offset` is not tiled by segments (unlogged tail).
## A part-way cursor resumes inside its named segment; a boundary cursor must
## sit at the end of a segment, at the end of the field, or at 0 before an entry.
static func _resume_index(parts: Array[Dictionary], offset: int, segment: String) -> int:
	for i in parts.size():
		var part: Dictionary = parts[i]
		if not segment.is_empty() and str(part.key) == segment and int(part.start) < offset and offset < int(part.end): return i
	if offset == 0 and (parts.is_empty() or parts[0].entry_id != null): return 0
	for i in parts.size():
		if int(parts[i].end) == offset: return i + 1
	return -1
