class_name CoordRecord
extends RefCounted
## The vault password as the system credential store holds it, tagged with
## the coordination epoch and administration tag it was stored under, in an
## account named by both (account()). A reader reads only the account the
## committed state names (active_account()) and accepts the record only when
## both match that state (CoordState), so a value written by an administration
## that never committed, or before a Forget, is never used.
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


## The credential store account for `tag` in `epoch`.
static func account(epoch: String, tag: int) -> String:
	return "vault-password/%s/%d" % [epoch, tag]


## {epoch, tag} when `text` is an account() name, else {}.
static func parse_account(text: String) -> Dictionary:
	var parts := text.split("/")
	if parts.size() != 3 or parts[0] != "vault-password" or not CoordState.is_epoch(parts[1]) or parse_tag(parts[2]) < 1:
		return {}
	return {"epoch": parts[1], "tag": parse_tag(parts[2])}


## The account holding the credential committed in `state` (CoordState.read),
## or "" when it names none: not ready, or an administration is unfinished.
static func active_account(state: Dictionary) -> String:
	if state.get("ok") != true or str(state.get("state", "")) != CoordState.READY \
			or not (state.get("intent", {}) as Dictionary).is_empty():
		return ""
	return account(state.epoch, state.generation)


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
## (CoordState.read): one active_account() names, with the same epoch and a
## tag equal to its generation.
static func accepts(record: Dictionary, state: Dictionary) -> bool:
	return not active_account(state).is_empty() and not record.has("error") \
		and record.get("epoch") == state.get("epoch") and record.get("tag") == state.get("generation")
