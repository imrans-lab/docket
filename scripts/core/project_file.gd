class_name ProjectFile
extends RefCounted
## Where a project file really is, and which file it is, through the native
## DocketFileIdentity; there is no fallback without it.
##
## Before a project is opened, locate resolves its path (links and parent
## directories), so every spelling of one file reaches one opening, and
## everything that opens it (cache, lock, watch, audit) works from that one
## path.
##
## The open project's owner is then bound to its file
## (DocketDBConnection.bind_file): the entry at that path, never followed if
## it is a link, and the file's identity. Before each change the owner checks
## the entry (check): still that file; or another regular file with no other
## names at the same path, as another writer's save or a git checkout leaves
## it, which an owner may reconcile with; or anything else (a link, a moved
## directory, a hard link, no file), which it refuses until the project is
## opened again. After replacing the file itself it takes the identity of the
## file it wrote, and no other. This notices a replacement that has happened;
## it cannot stop one racing a write.


# The native helper, or null when the extension is absent.
static var _identity: Object = ClassDB.instantiate("DocketFileIdentity") if ClassDB.class_exists("DocketFileIdentity") else null


## Where the project file `path` really is, before anything opens it: {path,
## id} for an existing file (`id` the operating system's identity of it),
## {path} for one still to be created (its existing directory resolved), or
## {error}. A file with more than one hard link is refused: an update replaces
## the file, which would part it from its other names.
static func locate(path: String) -> Dictionary:
	if _identity == null:
		return {"error": _unavailable(path)}
	var absolute := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(absolute):
		return _identity.of_new(absolute)
	var found: Dictionary = _identity.of(absolute)
	if found.has("error"):
		return found
	if int(found.links) != 1:
		return {"error": "%s has %d hard links; open it by a path that is its only name" % [path, int(found.links)]}
	return {"path": found.path, "id": found.id}


## Where a file not yet at `path` would be: {path}, its directory resolved,
## or {error} when any entry is there (a link, dangling or not, a directory)
## or none can be ruled out.
static func vacant(path: String) -> Dictionary:
	if _identity == null:
		return {"error": _unavailable(path)}
	return _identity.of_new(ProjectSettings.globalize_path(path))


## The identity of the file `path` leads to, or "".
static func identity(path: String) -> String:
	return "" if _identity == null else str(_identity.of(ProjectSettings.globalize_path(path)).get("id", ""))


## The regular file whose entry is `path`, not followed if it is a link:
## {path, id, links} or {error}.
static func entry(path: String) -> Dictionary:
	if _identity == null:
		return {"error": _unavailable(path)}
	return _identity.of_leaf(ProjectSettings.globalize_path(path))


## What the entry at `binding.path` is now, against the file `binding.id`
## an owner is bound to: {} when it is that file; {replaced} (its entry) when
## it is another regular file with no other names at the same path; else
## {error}, why it cannot be written as the project.
static func check(binding: Dictionary) -> Dictionary:
	var now := entry(str(binding.path))
	if now.has("error"):
		return {"error": "external replacement: %s (%s); open the project again to continue" % [binding.path, now.error]}
	if now.path != binding.path or int(now.links) != 1:
		return {"error": "external replacement: %s is no longer the file this project opened; open the project again to continue" % binding.path}
	return {"replaced": now} if now.id != binding.id else {}


static func _unavailable(path: String) -> String:
	return "Docket's native extension is not loaded, so %s cannot be identified" % path
