extends RefCounted
class_name DocketGet


func get_definition() -> Dictionary:
	return {
		"name": "docket_get",
		"description": "Get a single work item by ID with full detail and event history.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"include": {"type": "array", "items": {"type": "string", "enum": ["events", "links"]}, "description": "Sections to include. Default: [\"events\", \"links\"]. Pass [] to omit both."},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["id"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = args.get("id", "")
	if not db.has_item(id):
		return {"error": "Item not found: %s" % id}

	var item := db.get_item(id)
	if db is DocketDBJsonl and db.get_meta_value("jsonl_version", "1.0.0") == "2.0.0":
		var registry := TypeRegistry.for_db(db, db.get_project_name())
		var semantics: Dictionary = registry.resolve_item(item)
		item["item_token"] = registry.item_token(item)
		if semantics.has("error"): item["type_diagnostic"] = semantics.error
		else:
			item["state_category"] = semantics.state_category
			item["state_outcome"] = semantics.state_outcome
			item["is_terminal"] = semantics.is_terminal

	# Strip excluded sections
	var include: Array = args.get("include", ["events", "links"])
	if not ("events" in include):
		item.erase("events")
	if not ("links" in include):
		item.erase("links")

	return DocketDB._strip_empty(item)
