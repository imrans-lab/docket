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
var _type_registries: Dictionary = {}
var registry_diagnostics: Dictionary = {}
var last_cross_project_query_error: String = ""


func load_dct(path: String) -> void:
	dct_path = path
	if db:
		db.close()
		db = null
	_project_dbs.clear()
	_type_registries.clear()
	registry_diagnostics.clear()

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
	_type_registries[proj_name] = TypeRegistry.for_db(db, proj_name)

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
	_type_registries[proj_name] = TypeRegistry.for_db(new_db, proj_name)

	file_changed.emit()


func get_project_dbs() -> Dictionary:
	return _project_dbs

func get_type_registry(project_name: String = "") -> TypeRegistry:
	var key: String = project_name if not project_name.is_empty() else (db.get_project_name() if db != null else "")
	var registry: TypeRegistry = _type_registries.get(key)
	if registry != null:
		var error: String = registry.refresh_if_changed()
		if error.is_empty(): registry_diagnostics.erase(key)
		else: registry_diagnostics[key] = error
	return registry


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
	_type_registries.erase(project_name)
	registry_diagnostics.erase(project_name)

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
	## The shared transfer path enforces source identity, registry pins and durable write order.
	return DocketMove.new().execute({"id":item_id,"target_project":target_project}, schema, db, _project_dbs)


func create_dct(path: String) -> void:
	dct_path = path
	if db:
		db.close()
		db = null
	_project_dbs.clear()
	_type_registries.clear()
	registry_diagnostics.clear()
	# Default new dockets to JSONL format
	db = DocketDBJsonl.create_new_jsonl(path)
	var proj_name := db.get_project_name()
	_project_dbs[proj_name] = db
	_type_registries[proj_name] = TypeRegistry.for_db(db, proj_name)
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
	_type_registries[proj_name] = TypeRegistry.for_db(new_db, proj_name)
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


func _project_match(proj_name: String, pf: Dictionary) -> Dictionary:
	var op: String = pf.get("op", "eq")
	var raw_value = pf.get("value", "")
	var val: String = str(raw_value)
	match op:
		"eq": return {"matches": proj_name == val}
		"neq": return {"matches": proj_name != val}
		"contains": return {"matches": proj_name.contains(val)}
		"not_contains": return {"matches": not proj_name.contains(val)}
		"like": return {"matches": _project_like(proj_name, val)}
		"is_empty": return {"matches": proj_name.is_empty()}
		"is_not_empty": return {"matches": not proj_name.is_empty()}
		"in":
			if not raw_value is Array: return {"error": "project 'in' requires an array value"}
			return {"matches": raw_value.has(proj_name)}
	return {"error": "unsupported project query operator '%s'" % op}


func _project_like(value: String, pattern: String) -> bool:
	# Query wildcards use '*' for any run and '.' for one character. The small
	# dynamic-programming matcher mirrors SQL LIKE without interpolating text.
	var text := value.to_lower()
	var wildcard := pattern.to_lower()
	var previous: Array[bool] = []
	previous.resize(text.length() + 1)
	previous[0] = true
	for pi in wildcard.length():
		var current: Array[bool] = []
		current.resize(text.length() + 1)
		var token := wildcard[pi]
		if token == "*": current[0] = previous[0]
		for ti in range(1, text.length() + 1):
			if token == "*": current[ti] = previous[ti] or current[ti - 1]
			elif token == "." or token == text[ti - 1]: current[ti] = previous[ti - 1]
		previous = current
	return previous[text.length()]


func execute_cross_project_query(query: Dictionary, detail: String = "full") -> Array:
	## Run a query across all loaded projects, inject "project" field into results.
	# Strip sort/limit from per-DB queries — "project" is a pseudo-field that
	# doesn't exist in SQL, and sort/limit must apply to the merged union.
	var db_query := query.duplicate(true)
	last_cross_project_query_error = ""
	db_query.erase("sort")
	db_query.erase("limit")

	var all_results: Array = []
	var sort_spec: Array = query.get("sort", [])
	var query_detail: String = "full" if _sort_requires_registry_values(sort_spec) else detail
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		var project_query := _bind_project_conditions(db_query, proj_name)
		if project_query.has("error"):
			last_cross_project_query_error = str(project_query.error)
			push_error(last_cross_project_query_error)
			return []
		if bool(project_query.get("excluded", false)):
			continue
		var registry: TypeRegistry = get_type_registry(str(proj_name))
		if registry == null or not registry.get_diagnostic().is_empty():
			last_cross_project_query_error = registry.get_diagnostic() if registry != null else "type registry unavailable for project '%s'" % proj_name
			return []
		var typed: bool = _query_has_typed_binding(project_query.query)
		var results: Array = pdb.execute_registry_query(project_query.query, registry, query_detail) if typed or _sort_requires_registry_values(sort_spec) else pdb.execute_query(project_query.query, query_detail)
		if not pdb.last_query_error.is_empty():
			last_cross_project_query_error = "%s: %s" % [proj_name,pdb.last_query_error]
			return []
		if results.size() == 1 and results[0] is Dictionary and results[0].has("_error"):
			last_cross_project_query_error = "%s: %s" % [proj_name,results[0]._error]
			return []
		for item in results:
			item["project"] = proj_name
		all_results.append_array(results)

	# Apply sort across union
	if sort_spec.size() > 0:
		all_results.sort_custom(func(a, b): return _compare_query_rows(a, b, sort_spec))

	# Apply limit across union
	var limit: int = int(query.get("limit", 0))
	if limit > 0 and all_results.size() > limit:
		all_results.resize(limit)
	if detail == "lean" and query_detail != "lean":
		var lean: Array = []
		for item in all_results: lean.append({"id":item.get("id", ""),"title":item.get("title", ""),"project":item.get("project", "")})
		return lean

	return all_results

func _sort_requires_registry_values(specs: Array) -> bool:
	for value in specs:
		if value is Dictionary and (value.has("field_key") or str(value.get("field", "")) in RegistryQuery.DERIVED_FIELDS): return true
	return false

func _query_has_typed_binding(value) -> bool:
	if value is Dictionary:
		if value.has("type_id") or value.has("field_key") or str(value.get("field", "")) in RegistryQuery.DERIVED_FIELDS: return true
		for child in value.values():
			if _query_has_typed_binding(child): return true
	elif value is Array:
		for child in value:
			if _query_has_typed_binding(child): return true
	return false

func _compare_query_rows(a: Dictionary, b: Dictionary, specs: Array) -> bool:
	for value in specs:
		if not value is Dictionary: continue
		var spec: Dictionary = value
		var av = _query_sort_value(a, spec)
		var bv = _query_sort_value(b, spec)
		var a_null: bool = av == null
		var b_null: bool = bv == null
		if a_null != b_null: return b_null if str(spec.get("nulls", "last")) == "last" else a_null
		if a_null: continue
		if av == bv: continue
		var less: bool = str(av) < str(bv) if typeof(av) != typeof(0) and typeof(av) != typeof(0.0) else float(av) < float(bv)
		return not less if str(spec.get("dir", "asc")) == "desc" else less
	var project_compare: int = str(a.get("project", "")).casecmp_to(str(b.get("project", "")))
	if project_compare != 0: return project_compare < 0
	return str(a.get("id", "")) < str(b.get("id", ""))

func _query_sort_value(item: Dictionary, spec: Dictionary):
	var type_id: String = str(spec.get("type_id", ""))
	if not type_id.is_empty() and str(item.get("type_id", "")) != type_id: return null
	var field: String = str(spec.get("field_key", spec.get("field", "")))
	if item.has(field): return item[field]
	var custom: Dictionary = item.get("fields", {}) if item.get("fields", {}) is Dictionary else {}
	return custom.get(field)


func _bind_project_conditions(query: Dictionary, project_name: String) -> Dictionary:
	## Project is evaluated outside each project's SQLite database. Replacing a
	## project predicate with a per-database Boolean preserves AND/OR grouping;
	## removing it would change sibling branches and could widen the query.
	var bound := query.duplicate(true)
	var filter = bound.get("filter")
	if not filter is Dictionary:
		return {"query": bound, "excluded": false}
	if filter.has("conditions") or filter.has("$and") or filter.has("$or"):
		var replaced := _replace_project_predicates(filter, project_name)
		if replaced.has("error"): return replaced
		bound["filter"] = replaced.value
		return {"query": bound, "excluded": false}
	var flat_filter: Dictionary = filter.duplicate(true)
	var flat_query := {"filter": flat_filter}
	var project_filter := _extract_project_filter(flat_query)
	if not project_filter.is_empty():
		var project_match := _project_match(project_name, project_filter)
		if project_match.has("error"): return project_match
		if not project_match.matches: return {"query": bound, "excluded": true}
	bound["filter"] = flat_query.get("filter", {})
	return {"query": bound, "excluded": false}


func _replace_project_predicates(node: Variant, project_name: String) -> Dictionary:
	if node is Array:
		var replaced_array: Array = []
		for child in node:
			var replaced_child := _replace_project_predicates(child, project_name)
			if replaced_child.has("error"): return replaced_child
			replaced_array.append(replaced_child.value)
		return {"value": replaced_array}
	if not node is Dictionary: return {"value": node}
	if str(node.get("field", "")) == "project":
		var match_result := _project_match(project_name, node)
		if match_result.has("error"): return match_result
		var replacement := {"field": "id", "op": "is_not_empty", "value": ""} if match_result.matches else {"field": "id", "op": "in", "value": []}
		if node.has("conj"): replacement["conj"] = node.conj
		return {"value": replacement}
	var replaced_dict: Dictionary = node.duplicate(true)
	for key in ["conditions", "$and", "$or"]:
		if replaced_dict.has(key):
			var children := _replace_project_predicates(replaced_dict[key], project_name)
			if children.has("error"): return children
			replaced_dict[key] = children.value
	return {"value": replaced_dict}


func reload_stale() -> Array:
	## Reload any JSONL-backed project whose file changed on disk (git pull,
	## another Docket instance, the MCP server). Returns names reloaded.
	var reloaded: Array = []
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb is DocketDBJsonl:
			var db_reloaded: bool = (pdb as DocketDBJsonl).ensure_fresh()
			var registry: TypeRegistry = _type_registries[proj_name]
			var previous_generation: String = registry.get_generation_token()
			var error: String = registry.reload() if db_reloaded else registry.refresh_if_changed()
			if not error.is_empty(): registry_diagnostics[proj_name] = error
			else:
				registry_diagnostics.erase(proj_name)
				if db_reloaded or registry.get_generation_token() != previous_generation: reloaded.append(proj_name)
	return reloaded


func reload_all() -> Array:
	## Unconditionally re-read every JSONL project from disk, discarding cache.
	## Backs File > Reload from Disk and the docket_reload MCP tool.
	var reloaded: Array = []
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb is DocketDBJsonl:
			var loaded: bool = (pdb as DocketDBJsonl).reload()
			var registry: TypeRegistry = _type_registries[proj_name]
			var error: String = registry.reload() if loaded else registry.refresh_if_changed()
			if not loaded and error.is_empty():
				error = (pdb as DocketDBJsonl).last_write_error
				if error.is_empty(): error = "canonical project could not be reloaded"
			if error.is_empty():
				registry_diagnostics.erase(proj_name)
				reloaded.append(proj_name)
			else: registry_diagnostics[proj_name] = error
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
