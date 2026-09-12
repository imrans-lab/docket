extends RefCounted
class_name DocketQuery


func get_definition() -> Dictionary:
	return {
		"name": "docket_query",
		"description": "Query work items with filtering, sorting, and limiting. Legacy column filters retain literal meaning. Registry-bound conditions use type_id plus field_key; derived state_category/state_outcome/is_terminal conditions may span types. Nested $and/$or trees preserve branch scope. Operators are validated against each pinned field kind.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"filter": {"type": "object", "description": "Field filters. Supports three formats: flat dict (legacy), {\"$or\":[...]}/{\"$and\":[...]} tree, or {\"conditions\":[...]} list."},
				"sort": {"type": "array", "items": {"type": "object", "properties": {"field": {"type": "string"}, "field_key":{"type":"string"}, "type_id":{"type":"string"}, "dir": {"type": "string", "enum": ["asc", "desc"]}, "nulls":{"type":"string","enum":["first","last"]}}}},
				"limit": {"type": "integer", "minimum": 1},
				"detail": {"type": "string", "enum": ["lean", "full"], "description": "Response detail level. Default: auto (lean when unfiltered or >5 results; full null-stripped when filtered and ≤5 results)."},
				"project": {"type": "string", "description": "Project to query. Omit to use the primary project. An unknown name is an error, not a silent fallback."},
			},
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var query := {}
	if args.has("filter"):
		var filter = args.filter
		# Project belongs to routing. A nested project predicate requires the
		# cross-project coordinator; silently erasing it changes boolean meaning.
		if filter is Dictionary and filter.has("project"):
			return {"error":"filter.project is ambiguous here; use the top-level project argument"}
		query["filter"] = filter
	if args.has("sort"):
		query["sort"] = args.sort
	if args.has("limit"):
		query["limit"] = args.limit

	# Smart default: auto-hydrate only when filter narrows to ≤5 results.
	# >5 results always lean (browse first, hydrate via docket_get).
	# Explicit detail param overrides everything.
	var detail: String
	if args.has("detail"):
		var req: String = str(args.detail)
		detail = "lean" if req == "lean" else "full_stripped"
	else:
		var filter = args.get("filter", {})
		var has_filter: bool = filter is Dictionary and not filter.is_empty()
		if has_filter:
			# Two-pass: count first, hydrate only if small result set
			var lean_results := _execute(query, db, "lean")
			if not db.last_query_error.is_empty():
				return {"error": db.last_query_error}
			if lean_results.size() == 1 and lean_results[0] is Dictionary and lean_results[0].has("_error"):
				return {"error": lean_results[0]["_error"]}
			if lean_results.size() <= 5:
				var full_results := _execute(query, db, "full_stripped")
				if not db.last_query_error.is_empty(): return {"error":db.last_query_error}
				return {"items": full_results, "count": full_results.size()}
			return {"items": lean_results, "count": lean_results.size()}
		else:
			detail = "lean"

	var results = _execute(query, db, detail)
	if not db.last_query_error.is_empty():
		return {"error": db.last_query_error}
	if results.size() == 1 and results[0] is Dictionary and results[0].has("_error"):
		return {"error": results[0]["_error"]}
	return {"items": results, "count": results.size()}

func _execute(query: Dictionary, db: DocketDB, detail: String) -> Array:
	return db.execute_registry_query(query, TypeRegistry.for_db(db, db.get_project_name()), detail) if _has_typed_binding(query) else db.execute_query(query, detail)

func _has_typed_binding(value) -> bool:
	if value is Dictionary:
		if value.has("conditions") or value.has("$and") or value.has("$or") or value.has("type_id") or value.has("field_key") or str(value.get("field", "")) in RegistryQuery.DERIVED_FIELDS: return true
		for child in value.values():
			if _has_typed_binding(child): return true
	elif value is Array:
		for child in value:
			if _has_typed_binding(child): return true
	return false
