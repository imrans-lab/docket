class_name CoordRecord
extends RefCounted
## The vault password as the system credential store holds it, tagged with
## the coordination epoch and administration tag it was stored under. A reader
## accepts it only when both match the committed state (CoordState), so a
## value written by an administration that never committed, or before a
## Forget, is never used.
##
## Stored as JSON with every field a string: tags are decimal strings, which
## GDScript, SQLite and Rust all read back exactly.

const VERSION := "1"
const _KEYS := ["v", "epoch", "tag", "password"]


## A tag's value, or -1 when `text` is not a tag: a canonical decimal (no
## sign, no leading zeros) of at most 18 digits, which fits every int it
## passes through.
static func parse_tag(text: String) -> int:
	if RegEx.create_from_string("^(0|[1-9][0-9]{0,17})\\z").search(text) == null:
		return -1
	return text.to_int()


static func encode(epoch: String, tag: int, password: String) -> String:
	return JSON.stringify({"v": VERSION, "epoch": epoch, "tag": str(tag), "password": password})


## {epoch, tag, password} or {error}; an error never quotes the record.
static func decode(text: String) -> Dictionary:
	# JSON.parse() keeps its errors to itself; parse_string() prints them,
	# and nothing about a stored credential belongs in a log.
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {"error": "the stored credential is not a Docket record"}
	var record: Dictionary = json.data
	var keys := record.keys()
	keys.sort()
	var expected := _KEYS.duplicate()
	expected.sort()
	if keys != expected or record.values().any(func(value: Variant) -> bool: return not value is String):
		return {"error": "the stored credential is not a Docket record"}
	if record.v != VERSION:
		return {"error": "the stored credential is from another Docket record version"}
	var tag := parse_tag(record.tag)
	if not CoordState.is_epoch(record.epoch) or tag < 1 or str(record.password).is_empty():
		return {"error": "the stored credential is not a valid Docket record"}
	return {"epoch": record.epoch, "tag": tag, "password": record.password}


## Whether decoded `record` is the credential committed in `state`
## (CoordState.read): state ready with no rotation left unfinished, same
## epoch, tag equal to its generation.
static func accepts(record: Dictionary, state: Dictionary) -> bool:
	return state.get("ok") == true and str(state.get("state", "")) == CoordState.READY \
		and str(state.get("rotation_intent", "")).is_empty() and not record.has("error") \
		and record.get("epoch") == state.get("epoch") and record.get("tag") == state.get("generation")
