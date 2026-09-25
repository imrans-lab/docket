extends RefCounted
class_name ProjectQuery
## Queries over a set of open projects, as the Docket grid runs them: a
## query across every project merges the rows, then sorts and limits the
## union; "project" conditions are decided outside each project's database.
## Shared by the standalone app (AppState) and the docket_query_view tool.

var _project_dbs: Dictionary  # selector → DocketDB (ProjectSelectors)
var _registry_for: Callable  # func(project: String) -> TypeRegistry
## Why the last run failed, or "".
var last_error := ""


func _init(project_dbs: Dictionary, registry_for: Callable) -> void:
	_project_dbs = project_dbs
	_registry_for = registry_for


## Run `query` as the grid does: {rows, details} — details[i] for rows[i]
## being {short_id, resolved} (resolved is the row's type resolution, or
## {error}) — or {error}. With one project the query runs on it alone;
## short IDs are those of `primary_db`.
func run_with_details(query: Dictionary, primary_db: DocketDB) -> Dictionary:
	var rows: Array = []
	if _project_dbs.size() > 1:
		rows = run_across(query)
		if not last_error.is_empty():
			return {"error": last_error}
	elif primary_db != null:
		var registry: TypeRegistry = _registry_for.call(_selector_of(primary_db))
		rows = primary_db.execute_registry_query(query, registry) if registry != null else primary_db.execute_query(query)
		if not primary_db.last_query_error.is_empty():
			return {"error": primary_db.last_query_error}
	var details: Array = []
	for item in rows:
		var full_id := str(item.get("id", ""))
		var short := primary_db.short_id(full_id) if primary_db != null else full_id.substr(0, 7)
		var project := _row_project(item)
		if project.is_empty() and primary_db != null:
			project = _selector_of(primary_db)
		var registry: TypeRegistry = _registry_for.call(project)
		details.append({"short_id": short,
			"resolved": registry.resolve_item(item) if registry != null else {"error": "no type registry"}})
	return {"rows": rows, "details": details}


# The selector `db` is open under, or its stored name when it is not in the
# project map (a lone database).
func _selector_of(db: DocketDB) -> String:
	for selector in _project_dbs:
		if _project_dbs[selector] == db:
			return str(selector)
	return db.get_project_name()


func _row_project(item: Dictionary) -> String:
	var project: String = str(item.get("project", ""))
	if project.is_empty() and _project_dbs.size() == 1:
		project = str(_project_dbs.keys()[0])
	return project


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


func run_across(query: Dictionary, detail: String = "full") -> Array:
	## Run a query across all the projects, adding a "project" field to each row.
	# Strip sort/limit from per-DB queries — "project" is a pseudo-field that
	# doesn't exist in SQL, and sort/limit must apply to the merged union.
	var db_query := query.duplicate(true)
	last_error = ""
	db_query.erase("sort")
	db_query.erase("limit")

	var all_results: Array = []
	var sort_spec: Array = query.get("sort", [])
	var query_detail: String = "full" if _sort_requires_registry_values(sort_spec) else detail
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		var project_query := _bind_project_conditions(db_query, proj_name)
		if project_query.has("error"):
			last_error = str(project_query.error)
			push_error(last_error)
			return []
		if bool(project_query.get("excluded", false)):
			continue
		var registry: TypeRegistry = _registry_for.call(str(proj_name))
		if registry == null or not registry.get_diagnostic().is_empty():
			last_error = registry.get_diagnostic() if registry != null else "type registry unavailable for project '%s'" % proj_name
			return []
		var typed: bool = _query_has_typed_binding(project_query.query)
		var results: Array = pdb.execute_registry_query(project_query.query, registry, query_detail) if typed or _sort_requires_registry_values(sort_spec) else pdb.execute_query(project_query.query, query_detail)
		if not pdb.last_query_error.is_empty():
			last_error = "%s: %s" % [proj_name,pdb.last_query_error]
			return []
		if results.size() == 1 and results[0] is Dictionary and results[0].has("_error"):
			last_error = "%s: %s" % [proj_name,results[0]._error]
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
		if value.has("conditions") or value.has("$and") or value.has("$or") or value.has("type_id") or value.has("field_key") or str(value.get("field", "")) in RegistryQuery.DERIVED_FIELDS: return true
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
	if field in RegistryQuery.DERIVED_FIELDS: return item.get(field)
	if spec.has("field_key"):
		var registry: TypeRegistry = _registry_for.call(str(item.get("project", "")))
		if registry == null: return null
		var resolved: Dictionary = registry.resolve_item(item)
		if resolved.has("error"): return null
		var declared: bool = false
		for descriptor in resolved.definition.fields:
			if str(descriptor.key) == field: declared = true
		if not declared: return null
		var typed_fields: Dictionary = item.get("fields", {}) if item.get("fields", {}) is Dictionary else {}
		return typed_fields.get(field)
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
