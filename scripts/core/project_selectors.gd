class_name ProjectSelectors
extends RefCounted
## How open projects are named and found within one session.
##
## Each open project is known by a selector: the key of the project map
## (selector → DocketDB) every registry shares. The first project open under a
## stored name gets that name; another with the same stored name (a copy, say)
## gets "name~2", "name~3", …, unique case-insensitively. Selectors live only
## for the session: they are never written into a project, and a project's
## references to another ("name:id") keep naming it by its stored name.
##
## A project is opened from its file's resolved path (ProjectFile.locate), and
## its identity within the session is that path plus its open generation (the
## DocketDB's instance id), which a reopen changes.


## The selector of the project open at `located` (from ProjectFile.locate)
## in `dbs`, or "". Open projects are identified afresh, since saving one
## replaces its file.
static func selector_for(dbs: Dictionary, located: Dictionary) -> String:
	for selector in dbs:
		var open_path := (dbs[selector] as DocketDB).get_path()
		if open_path == located.path or (located.has("id") and ProjectFile.identity(open_path) == located.id):
			return str(selector)
	return ""


## Why a stored project name cannot name an open project, or "": it must not
## be empty, and it must not contain ":", which separates a reference's
## project from its item.
static func stored_name_problem(stored_name: String) -> String:
	if stored_name.is_empty():
		return "the project has no name"
	if ":" in stored_name:
		return "the project name '%s' contains ':', which references cannot name" % stored_name
	return ""


## Puts `db`, opened from `path`, into `dbs` under a new selector:
## {selector}, or {error} (and then `db` is closed); `db` is bound to its file
## as its owner (DocketDBConnection.bind_file). A project with no stored
## name is given its file's name, as it always was, since references need one.
static func register(dbs: Dictionary, db: DocketDB, path: String) -> Dictionary:
	var unnamed := db.get_project_name().is_empty()
	var problem := stored_name_problem(path.get_file().get_basename() if unnamed else db.get_project_name())
	if not problem.is_empty():
		db.close()
		return {"error": problem}
	var unbound := db.bind_file(db.get_path())
	if not unbound.is_empty():
		db.close()
		return {"error": unbound}
	if unnamed:
		db.set_project_name(path.get_file().get_basename())
	var selector := allocate(dbs, db.get_project_name())
	dbs[selector] = db
	return {"selector": selector}


## A selector for a project stored as `stored_name`, unique in `dbs`
## case-insensitively: the name itself when free, else "name~2", "name~3", ….
static func allocate(dbs: Dictionary, stored_name: String) -> String:
	var taken := {}
	for selector in dbs:
		taken[str(selector).to_lower()] = true
	if not taken.has(stored_name.to_lower()):
		return stored_name
	var n := 2
	while taken.has(("%s~%d" % [stored_name, n]).to_lower()):
		n += 1
	return "%s~%d" % [stored_name, n]


## The project `name` asks for: {selector} or {error}. An exact selector wins;
## otherwise a selector or stored name matching case-insensitively, only when
## exactly one project does.
static func resolve(dbs: Dictionary, name: String) -> Dictionary:
	if dbs.has(name):
		return {"selector": name}
	var found: Array = []
	for selector in dbs:
		if str(selector).nocasecmp_to(name) == 0 or (dbs[selector] as DocketDB).get_project_name().nocasecmp_to(name) == 0:
			found.append(str(selector))
	if found.size() == 1:
		return {"selector": found[0]}
	if found.is_empty():
		return {"error": "Unknown project '%s'. Loaded projects: %s" % [name, _listed(dbs.keys())]}
	return {"error": "Project '%s' is ambiguous: use one of %s" % [name, _listed(found)]}


## The project a stored reference "`stored_name`:id" names, read from the
## project `from` (a selector, or "" for none): {selector} or {error}. A
## reference naming its own project's stored name is to that project (a
## copy's references stay within the copy); another stored name names a
## project only when exactly one open project has it.
static func resolve_reference(dbs: Dictionary, stored_name: String, from: String = "") -> Dictionary:
	if dbs.has(from) and (dbs[from] as DocketDB).get_project_name() == stored_name:
		return {"selector": from}
	var found: Array = []
	for selector in dbs:
		if (dbs[selector] as DocketDB).get_project_name() == stored_name:
			found.append(str(selector))
	if found.size() == 1:
		return {"selector": found[0]}
	if found.is_empty():
		return {"error": "No open project is named '%s'" % stored_name}
	return {"error": "More than one open project is named '%s' (%s): the reference is ambiguous" % [stored_name, _listed(found)]}


## A check for the stored references a project writes, for
## TypeRegistry.references: given a reference's project name and the project
## writing it, "" or why the reference cannot be written: it names a project
## by a name only this session gives (a selector such as "name~2", never
## stored), or by a stored name more than one open project has. A project not
## open, or the writer's own name, is no concern of it.
static func reference_checker(dbs: Dictionary) -> Callable:
	return func(stored_name: String, writer: DocketDB) -> String:
		if writer != null and writer.get_project_name() == stored_name:
			return ""
		var resolved := resolve_reference(dbs, stored_name)
		if not resolved.has("error"):
			return ""
		if resolved.error.begins_with("More than one"):
			return str(resolved.error)
		for selector in dbs:
			if str(selector).nocasecmp_to(stored_name) == 0:
				return "'%s' is a name only this session gives; a reference names that project by its stored name, '%s'" % [
					stored_name, (dbs[selector] as DocketDB).get_project_name()]
		return ""


## How project `selector` of `dbs` is described to clients.
static func describe(dbs: Dictionary, selector: String, primary: DocketDB = null) -> Dictionary:
	var db: DocketDB = dbs[selector]
	return {"name": selector, "display_name": db.get_project_name(), "path": db.get_path(), "prefix": db.get_id_prefix(), "primary": db == primary,
		"open_generation": str(db.get_instance_id())}


static func _listed(names: Array) -> String:
	var sorted := PackedStringArray(names.map(func(n) -> String: return str(n)))
	sorted.sort()
	return ", ".join(sorted) if not sorted.is_empty() else "(none)"
