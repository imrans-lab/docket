class_name NewFile
extends RefCounted
## A new file written whole and flushed, then given its name only if nothing
## has that name, through the native DocketFileIO; there is no fallback
## without it. stage() writes a private file beside where it will live;
## publish() moves it to its name without ever replacing an entry there. A
## publication that stops part-way says how far it got, and a name it took is
## kept.

const NOT_PUBLISHED := "not_published"
const UNCERTAIN := "published_durability_uncertain"
const DURABLE := "published_durable"

# The native helper, or null when the extension is absent.
static var _io: Object = ClassDB.instantiate("DocketFileIO") if ClassDB.class_exists("DocketFileIO") else null


## A private file in the existing directory `parent` holding `bytes`, on the
## device: {stage, identity, bytes, hash} (`hash` the SHA-256 of `bytes`), or
## {error}, with `stage` when a file was created and left for its owner to
## remove.
static func stage(parent: String, bytes: PackedByteArray) -> Dictionary:
	if _io == null:
		return {"error": _unavailable()}
	# Its own copy, written, hashed and kept: a caller changing its array
	# later changes none of them.
	var own := bytes.duplicate()
	var staged: Dictionary = _io.stage_new(ProjectSettings.globalize_path(parent), own)
	if staged.has("error"):
		return staged
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(own)
	staged["bytes"] = own
	staged["hash"] = hashing.finish().hex_encode()
	return staged


## `staged` (from stage()) published as `dest`, in the directory it was staged
## in, if it still holds exactly its bytes: {status, phase, error}, plus
## {identity, path} when DURABLE. `status` is NOT_PUBLISHED (nothing changed;
## the staged file stays for its owner to remove), UNCERTAIN (dest is taken
## and kept; its flush failed, or it is not the file or bytes staged) or
## DURABLE.
static func publish(staged: Dictionary, dest: String) -> Dictionary:
	if _io == null:
		return {"status": NOT_PUBLISHED, "phase": "native", "error": _unavailable()}
	return _io.publish_new(staged.stage, staged.identity, staged.bytes, ProjectSettings.globalize_path(dest))


## Flushes the existing file `path` to the device: {} or {error}.
static func sync(path: String) -> Dictionary:
	if _io == null:
		return {"error": _unavailable()}
	return _io.sync_existing(ProjectSettings.globalize_path(path))


static func _unavailable() -> String:
	return "Docket's native extension is not loaded, so it cannot write new files safely."
