extends RefCounted
class_name DocketSavedQuery


func get_definition() -> Dictionary:
	return {
		"name": "docket_saved_query",
		"description": "Save, load, or list saved queries within the .dct file.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"action": {"type": "string", "enum": ["save", "load", "list"]},
				"name": {"type": "string"},
				"filter": {"type": "object"},
				"sort": {"type": "array"},
				"columns": {"type": "array", "items": {"type": "string"}},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["action"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, registry: TypeRegistry = null) -> Dictionary:
	var action: String = args.get("action", "")

	match action:
		"save":
			var name: String = args.get("name", "")
			if name.is_empty():
				return {"error": "Query name required for save"}
			var query := {}
			if args.has("filter"):
				query["filter"] = args.filter
			if args.has("sort"):
				query["sort"] = args.sort
			if args.has("columns"):
				if not args.columns is Array: return {"error":"columns must be an array"}
				for column in args.columns:
					if not column is String or str(column).strip_edges().is_empty(): return {"error":"saved query columns must be non-empty strings"}
				query["columns"] = args.columns
			if ProjectSelectors.has_selector_condition(query):
				return {"error": "A saved query cannot name a project by project_selector, which lasts only this session; name it by `project` (its stored name)"}
			if registry == null: registry = TypeRegistry.for_db(db, db.get_project_name())
			# `project` conditions are evaluated outside the database
			# (ProjectQuery), so the query is checked with them bound as for this
			# project, and saved as given.
			var checked: Dictionary = ProjectQuery.new({db.get_project_name(): db}, Callable()).bind(query, db.get_project_name())
			if checked.has("error"): return {"error":"saved query is invalid: %s" % checked.error}
			var validation: Dictionary = RegistryQuery.compile(checked.query, registry, db.item_columns())
			if validation.has("error"): return {"error":"saved query is invalid: %s" % validation.error}
			var error: String = db.save_query_checked(name, query)
			return {"error":error} if not error.is_empty() else {"saved": name}
		"load":
			var name: String = args.get("name", "")
			var query := db.load_query(name)
			if query.is_empty():
				return {"error": "Query not found: %s" % name}
			return query
		"list":
			var queries := db.list_queries()
			var names: Array = []
			for q in queries:
				names.append(q.name)
			return {"queries": names}
		_:
			return {"error": "Invalid action: %s. Use save, load, or list." % action}
