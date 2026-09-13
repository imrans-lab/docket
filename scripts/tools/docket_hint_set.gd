extends RefCounted
class_name DocketHintSet
## Create or update a hint by component+key. If a hint with matching
## component and key exists, updates its value; otherwise creates a new one.


func get_definition() -> Dictionary:
	return {
		"name": "docket_hint_set",
		"description": "Set a hint (create or update). If a hint with the same component+key exists, updates it; otherwise creates a new one.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"component": {"type": "string", "description": "Logical component, e.g. 'godot', 'build', 'docket'"},
				"key": {"type": "string", "description": "Hint key, e.g. 'test', 'run', 'path'"},
				"value": {"type": "string", "description": "The actionable fact or command"},
				"title": {"type": "string", "description": "Short summary (defaults to component/key if omitted)"},
				"tags": {"type": "array", "items": {"type": "string"}},
				"confidence": {"type": "string"},
				"research_cost": {"type": "integer", "minimum": 0, "description": "How many turns/steps it took to discover this"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["component", "key", "value"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var comp: String = args.get("component", "")
	var key: String = args.get("key", "")
	var value: String = args.get("value", "")

	# Search for existing hint with same component+key
	var existing := db.find_hint(comp, key)

	if not existing.is_empty():
		# Update existing hint
		var existing_id: String = str(existing.get("id", ""))
		var changes := {"value": value}
		if args.has("title"):
			changes["title"] = args.title
		if args.has("tags"):
			changes["tags"] = args.tags
		if args.has("confidence"):
			changes["confidence"] = args.confidence
		if args.has("research_cost"):
			changes["research_cost"] = int(args.research_cost)
		var update_error: String = TypeRegistry.for_db(db, db.get_project_name()).update_item(existing_id, changes, "agent")
		return {"error":update_error} if not update_error.is_empty() else db.get_item(existing_id)
	else:
		# Create new hint
		var title: String = args.get("title", "%s/%s" % [comp, key])
		var fields := {
			"title": title,
			"value": value,
			"component": comp,
			"key": key,
		}
		if args.has("tags"):
			fields["tags"] = args.tags
		if args.has("confidence"):
			fields["confidence"] = args.confidence
		if args.has("research_cost"):
			fields["research_cost"] = int(args.research_cost)
		fields["type"] = "hint"
		var created: Dictionary = TypeRegistry.for_db(db, db.get_project_name()).create_item(fields, "agent")
		return created if created.has("error") else db.get_item(str(created.id))
