extends RefCounted
class_name DocketLink


func get_definition() -> Dictionary:
	return {
		"name": "docket_link",
		"description": "Link two work items with a typed relationship.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"from": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"to": {"type": "string", "description": "Full ID or short prefix (min 4 chars), optionally cross-project qualified like 'project:DKT-0042'"},
				"relation": {"type": "string", "enum": ["caused_by", "blocks", "duplicates", "follow_up", "surfaced"]},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["from", "to", "relation"],
		},
	}


func execute(args: Dictionary, schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var from_id: String = args.get("from", "")
	var to_id_raw: String = args.get("to", "")
	var relation: String = args.get("relation", "")

	# Resolve the "from" item in the specified project DB
	var from_db := _resolve_db(args, db, project_dbs)
	if from_db == null or not from_db.has_item(from_id):
		return {"error": "Item not found: %s" % from_id}

	# Parse cross-project qualifier on "to" (e.g. "otherproject:DKT-0002"):
	# a project the caller names as other tools take it; the link stores that
	# project's stored name, which must name it again when read back from
	# here (two open projects of that name cannot be told apart).
	var to_id := to_id_raw
	var stored_to := to_id_raw
	if ":" in to_id_raw:
		var parts := to_id_raw.split(":", true, 1)
		to_id = parts[1]
		var named := ProjectSelectors.resolve(project_dbs, parts[0])
		if named.has("error"):
			return {"error": named.error}
		var to_db: DocketDB = project_dbs[named.selector]
		if not to_db.has_item(to_id):
			return {"error": "Item not found in project '%s': %s" % [named.selector, to_id]}
		var from_selector := ""
		for selector in project_dbs:
			if project_dbs[selector] == from_db:
				from_selector = str(selector)
		var read_back := ProjectSelectors.resolve_reference(project_dbs, to_db.get_project_name(), from_selector)
		if read_back.has("error") or read_back.selector != named.selector:
			return {"error": "A link to %s:%s could not be read back as that project: %s" % [named.selector, to_id,
				read_back.get("error", "its stored name names %s from here" % read_back.get("selector", ""))]}
		stored_to = "%s:%s" % [to_db.get_project_name(), to_id]
	elif not from_db.has_item(to_id):
		return {"error": "Item not found: %s" % to_id}

	var valid_relations: Array = schema.get("link_relations", [])
	if not valid_relations.has(relation):
		return {"error": "Invalid relation '%s'. Valid: %s" % [relation, str(valid_relations)]}

	from_db.add_link(from_id, stored_to, relation)
	from_db.add_event(from_id, "linked", "agent",
		"Linked %s → %s (%s)" % [from_id, stored_to, relation])

	return {"from": from_id, "to": stored_to, "relation": relation}


# The project `args` names (ToolRegistry has made it a selector), or the
# primary when it names none.
func _resolve_db(args: Dictionary, default_db: DocketDB, project_dbs: Dictionary) -> DocketDB:
	var proj_name: String = str(args.get("project", ""))
	return default_db if proj_name.is_empty() else project_dbs.get(proj_name)
