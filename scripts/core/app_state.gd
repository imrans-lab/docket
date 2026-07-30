extends RefCounted
class_name AppState
## Centralized state container for the Docket GUI.
## Holds schema, db(s), dct_path. Emits signals on file/data changes.
## Supports multiple loaded .dct projects simultaneously.

signal file_changed
signal data_changed
## Emitted when a .dct could not be opened (e.g. unresolved conflict markers).
## Carries the path and a human-readable reason.
signal load_failed(path: String, reason: String)
@warning_ignore("unused_signal")
signal open_item_requested(id: String)
@warning_ignore("unused_signal")
signal open_query_requested(filter: String, label: String)

var schema: Dictionary
var db: DocketDB  # Primary DB (first loaded)
var dct_path: String
var prefs: UserPrefs

# Multi-project support: project_name → DocketDB
var _project_dbs: Dictionary = {}


func load_dct(path: String) -> void:
	dct_path = path
	if db:
		db.close()
		db = null
	_project_dbs.clear()

	if FileAccess.file_exists(path):
		match JSONLMigration.detect_format(path):
			"jsonl":
				db = DocketDBJsonl.open_jsonl(path)
			"sqlite":
				db = DocketDB.new()
				db.open(path)
			"json_v1":
				db = DocketMigration.migrate(path)
			_:
				push_error("AppState: unknown file format for %s" % path)
				load_failed.emit(path, "Unknown file format.")
				return
	else:
		# Default new files to JSONL format
		db = DocketDBJsonl.create_new_jsonl(path)

	# A refused open (conflict markers, corrupt file) must not fall through:
	# registering a null db crashes downstream, and creating a fresh one here
	# would overwrite the file the user still needs to repair.
	if db == null:
		var reason := DocketDBJsonl.last_open_error
		if reason.is_empty():
			reason = "Could not open %s." % path
		push_error("AppState: %s" % reason)
		dct_path = ""
		load_failed.emit(path, reason)
		return

	# Register in multi-project map
	var proj_name := db.get_project_name()
	if proj_name.is_empty():
		proj_name = path.get_file().get_basename()
		db.set_project_name(proj_name)
	_project_dbs[proj_name] = db

	file_changed.emit()


func add_project(path: String) -> void:
	## Load an additional .dct project without closing the primary.
	var new_db: DocketDB
	if FileAccess.file_exists(path):
		match JSONLMigration.detect_format(path):
			"jsonl":
				new_db = DocketDBJsonl.open_jsonl(path)
			"sqlite":
				new_db = DocketDB.new()
				new_db.open(path)
			"json_v1":
				new_db = DocketMigration.migrate(path)
			_:
				push_error("AppState: unknown file format for %s" % path)
				load_failed.emit(path, "Unknown file format.")
				return
	else:
		# Default new files to JSONL format
		new_db = DocketDBJsonl.create_new_jsonl(path)

	if new_db == null:
		var reason := DocketDBJsonl.last_open_error
		if reason.is_empty():
			reason = "Could not open %s." % path
		push_error("AppState: %s" % reason)
		load_failed.emit(path, reason)
		return

	var proj_name := new_db.get_project_name()
	if proj_name.is_empty():
		proj_name = path.get_file().get_basename()
		new_db.set_project_name(proj_name)

	# Resolve ID prefix collisions by appending chars from project name
	var new_prefix := new_db.get_id_prefix()
	var collides := func() -> bool:
		for existing_name in _project_dbs:
			var existing_db: DocketDB = _project_dbs[existing_name]
			if existing_db.get_id_prefix() == new_prefix and existing_name != proj_name:
				return true
		return false
	if collides.call():
		# Try alternative prefixes using more of the project name
		var upper := proj_name.to_upper().replace("-", "").replace("_", "").replace(" ", "")
		var resolved := false
		for i in range(3, upper.length()):
			new_prefix = upper.substr(0, i).right(3)
			var still_collides := false
			for existing_name in _project_dbs:
				var existing_db: DocketDB = _project_dbs[existing_name]
				if existing_db.get_id_prefix() == new_prefix and existing_name != proj_name:
					still_collides = true
					break
			if not still_collides:
				resolved = true
				break
		if not resolved:
			# Last resort: append digit
			for digit in range(2, 10):
				new_prefix = new_db.get_id_prefix().left(2) + str(digit)
				var still_collides := false
				for existing_name in _project_dbs:
					var existing_db: DocketDB = _project_dbs[existing_name]
					if existing_db.get_id_prefix() == new_prefix and existing_name != proj_name:
						still_collides = true
						break
				if not still_collides:
					resolved = true
					break
		if new_prefix != new_db.get_id_prefix():
			new_db.set_id_prefix(new_prefix)

	_project_dbs[proj_name] = new_db

	file_changed.emit()


func get_project_dbs() -> Dictionary:
	return _project_dbs


func get_db_for_project(project_name: String) -> DocketDB:
	return _project_dbs.get(project_name)


func find_item_db(id: String) -> DocketDB:
	## Search all loaded project DBs for an item by ID.
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb.has_item(id):
			return pdb
	return null


func get_project_name_for_item(id: String) -> String:
	## Return the project name that owns this item ID.
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb.has_item(id):
			return proj_name
	return ""


func remove_project(project_name: String) -> Dictionary:
	## Close and remove a project. Zero open projects is allowed.
	if not _project_dbs.has(project_name):
		return {"error": "Project not found: %s" % project_name}

	var closing_db: DocketDB = _project_dbs[project_name]
	closing_db.close()
	_project_dbs.erase(project_name)

	# If we just closed the primary, promote the next one or clear
	if closing_db == db:
		if _project_dbs.size() > 0:
			var first_name: String = _project_dbs.keys()[0]
			db = _project_dbs[first_name]
			dct_path = db.get_path()
		else:
			db = null
			dct_path = ""

	file_changed.emit()
	return {"closed": project_name, "remaining": _project_dbs.keys()}


func find_children_across_projects(qualified_id: String) -> Array:
	## Search ALL loaded projects for items whose parent matches the given qualified ref.
	## Also matches bare ID form for backwards compatibility.
	var parsed := DocketDB.parse_qualified_ref(qualified_id)
	var bare_id: String = parsed.id
	var results: Array = []
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		# Match qualified form (project:ID) and bare ID
		var rows := pdb.execute_query({"filter": {"$or": [
			{"field": "parent", "op": "eq", "value": qualified_id},
			{"field": "parent", "op": "eq", "value": bare_id},
		]}})
		for item in rows:
			item["project"] = proj_name
		results.append_array(rows)
	return results


func move_item(item_id: String, target_project: String) -> Dictionary:
	## Move an item between projects. Auto-updates all references.
	# Find source
	var source_db: DocketDB = null
	var source_name: String = ""
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb.has_item(item_id):
			source_db = pdb
			source_name = proj_name
			break
	if source_db == null:
		return {"error": "Item not found: %s" % item_id}

	# Find target
	var target_db: DocketDB = null
	var canonical_target := target_project
	for proj_name in _project_dbs:
		if proj_name.to_lower() == target_project.to_lower():
			target_db = _project_dbs[proj_name]
			canonical_target = proj_name
			break
	if target_db == null:
		return {"error": "Target project not found: %s" % target_project}
	if source_db == target_db:
		return {"error": "Item is already in project '%s'" % canonical_target}

	# Export item data
	var exported := source_db.export_item_full(item_id)
	if exported.is_empty():
		return {"error": "Failed to export item %s" % item_id}

	var new_id: String
	var refs_updated := 0

	if DocketDB._is_uuid7(item_id):
		# UUID7 items keep their ID — globally unique, no rewrite needed
		new_id = item_id
		target_db.import_item_full(new_id, exported)
		source_db.delete_item(item_id)
	else:
		# Legacy items get upgraded to UUID7 on move
		new_id = target_db.next_uuid7_id()
		target_db.import_item_full(new_id, exported)
		source_db.delete_item(item_id)
		# Rewrite references across ALL projects (legacy-only)
		var old_qualified := "%s:%s" % [source_name, item_id]
		var new_qualified := "%s:%s" % [canonical_target, new_id]
		for proj_name in _project_dbs:
			var pdb: DocketDB = _project_dbs[proj_name]
			refs_updated += pdb.rewrite_refs(old_qualified, new_qualified, item_id, new_qualified)

	data_changed.emit()
	return {
		"old_id": item_id,
		"new_id": new_id,
		"old_project": source_name,
		"new_project": canonical_target,
		"refs_updated": refs_updated,
	}


func create_dct(path: String) -> void:
	dct_path = path
	if db:
		db.close()
		db = null
	_project_dbs.clear()
	# Default new dockets to JSONL format
	db = DocketDBJsonl.create_new_jsonl(path)
	var proj_name := db.get_project_name()
	_project_dbs[proj_name] = db
	file_changed.emit()


func create_and_add_project(path: String) -> void:
	## Create a new .dct and add it alongside existing projects (does NOT replace).
	# Default new dockets to JSONL format
	var new_db := DocketDBJsonl.create_new_jsonl(path)
	if new_db == null:
		return
	var proj_name := new_db.get_project_name()
	if proj_name.is_empty():
		proj_name = path.get_file().get_basename()
		new_db.set_project_name(proj_name)

	# Warn on prefix collision
	var new_prefix := new_db.get_id_prefix()
	for existing_name in _project_dbs:
		var existing_db: DocketDB = _project_dbs[existing_name]
		if existing_db.get_id_prefix() == new_prefix and existing_name != proj_name:
			push_warning("DocketDB: ID prefix '%s' in project '%s' collides with '%s'" % [new_prefix, proj_name, existing_name])

	_project_dbs[proj_name] = new_db
	file_changed.emit()


func _extract_project_filter(query: Dictionary) -> Dictionary:
	## Extract and remove "project" conditions from a query filter.
	## Returns {op, value} if found, or {} if no project filter.
	var filter = query.get("filter")
	if not filter is Dictionary:
		return {}

	# Conditions-list format: {"conditions": [{field, op, value}, ...]}
	if filter.has("conditions") and filter.conditions is Array:
		var kept: Array = []
		var result := {}
		for cond in filter.conditions:
			if cond is Dictionary and str(cond.get("field", "")) == "project":
				result = {"op": str(cond.get("op", "eq")), "value": cond.get("value", "")}
			else:
				kept.append(cond)
		filter["conditions"] = kept
		if kept.is_empty():
			query.erase("filter")
		return result

	# Flat dict format: {"project": "x"} or {"project__ne": "x"}
	if filter.has("project"):
		var val = filter["project"]
		filter.erase("project")
		if filter.is_empty():
			query.erase("filter")
		return {"op": "eq", "value": val}
	if filter.has("project__ne"):
		var val = filter["project__ne"]
		filter.erase("project__ne")
		if filter.is_empty():
			query.erase("filter")
		return {"op": "neq", "value": val}

	return {}


func _project_matches(proj_name: String, pf: Dictionary) -> bool:
	var op: String = pf.get("op", "eq")
	var val: String = str(pf.get("value", ""))
	match op:
		"eq": return proj_name == val
		"neq": return proj_name != val
		"contains": return proj_name.contains(val)
		"not_contains": return not proj_name.contains(val)
		"like": return proj_name.matchn(val)
	return true


func execute_cross_project_query(query: Dictionary, detail: String = "full") -> Array:
	## Run a query across all loaded projects, inject "project" field into results.
	# Strip sort/limit from per-DB queries — "project" is a pseudo-field that
	# doesn't exist in SQL, and sort/limit must apply to the merged union.
	var db_query := query.duplicate(true)
	db_query.erase("sort")
	db_query.erase("limit")

	# Extract project filter from conditions — "project" is a pseudo-field
	var project_filter := _extract_project_filter(db_query)

	var all_results: Array = []
	for proj_name in _project_dbs:
		# Apply project filter: skip DBs that don't match
		if not project_filter.is_empty() and not _project_matches(proj_name, project_filter):
			continue
		var pdb: DocketDB = _project_dbs[proj_name]
		var results := pdb.execute_query(db_query, detail)
		for item in results:
			item["project"] = proj_name
		all_results.append_array(results)

	# Apply sort across union
	var sort_spec: Array = query.get("sort", [])
	if sort_spec.size() > 0:
		var field: String = str(sort_spec[0].get("field", ""))
		var dir: String = str(sort_spec[0].get("dir", "asc")).to_lower()
		if not field.is_empty():
			all_results.sort_custom(func(a, b):
				var va = a.get(field, "")
				var vb = b.get(field, "")
				if dir == "desc":
					return va > vb
				return va < vb
			)

	# Apply limit across union
	var limit: int = int(query.get("limit", 0))
	if limit > 0 and all_results.size() > limit:
		all_results.resize(limit)

	return all_results


func reload_stale() -> Array:
	## Reload any JSONL-backed project whose file changed on disk (git pull,
	## another Docket instance, the MCP server). Returns names reloaded.
	var reloaded: Array = []
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb is DocketDBJsonl and (pdb as DocketDBJsonl).ensure_fresh():
			reloaded.append(proj_name)
	return reloaded


func reload_all() -> Array:
	## Unconditionally re-read every JSONL project from disk, discarding cache.
	## Backs File > Reload from Disk and the docket_reload MCP tool.
	var reloaded: Array = []
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb is DocketDBJsonl and (pdb as DocketDBJsonl).reload():
			reloaded.append(proj_name)
	if not reloaded.is_empty():
		data_changed.emit()
	return reloaded


func flush_all() -> Array:
	## Force every JSONL project to serialize to disk. Writes are already
	## immediate, so this is a no-op in practice — it exists as an explicit
	## "settle the file before I commit" step.
	var flushed: Array = []
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb is DocketDBJsonl:
			(pdb as DocketDBJsonl).flush()
			flushed.append(proj_name)
	return flushed


func save() -> void:
	# JSONL writes happen on every mutation, so this is belt-and-braces — but
	# it does now actually write, rather than only emitting a signal.
	flush_all()
	data_changed.emit()


func load_schema() -> void:
	var sf := FileAccess.open("res://data/schema.json", FileAccess.READ)
	schema = JSON.parse_string(sf.get_as_text())
	prefs = UserPrefs.load_prefs()
