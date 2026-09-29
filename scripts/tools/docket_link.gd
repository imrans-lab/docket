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
	if not from_db.has_item(from_id):
		return {"error": "Item not found: %s" % from_id}

	# Parse cross-project qualifier on "to" (e.g. "otherproject:DKT-0002")
	var to_id := to_id_raw
	var to_project := ""
	if ":" in to_id_raw:
		var parts := to_id_raw.split(":", true, 1)
		to_project = parts[0]
		to_id = parts[1]

	# Validate the "to" item exists
	if not to_project.is_empty():
		if not project_dbs.has(to_project):
			return {"error": "Unknown project: %s" % to_project}
		var to_db: DocketDB = project_dbs[to_project]
		if not to_db.has_item(to_id):
			return {"error": "Item not found in project '%s': %s" % [to_project, to_id]}
		var refusal := ItemStorage.link_refusal(from_db, from_id, to_db, to_id)
		if not refusal.is_empty():
			return {"error": refusal}
	else:
		if not from_db.has_item(to_id):
			return {"error": "Item not found: %s" % to_id}

	var valid_relations: Array = schema.get("link_relations", [])
	if not valid_relations.has(relation):
		return {"error": "Invalid relation '%s'. Valid: %s" % [relation, str(valid_relations)]}

	# Store the link — use qualified ID for cross-project refs
	var stored_to := to_id_raw if not to_project.is_empty() else to_id
	# A link with an ephemeral end is ephemeral (ItemStorage); so is its history
	# entry, which names both ends: it goes on the source when that is ephemeral,
	# else on an ephemeral target of the source's own project, else the source.
	# A link across projects with an ephemeral end was refused (link_refusal).
	# The local ends are rechecked, the link written and the entry placed under
	# the cache's write lock (ItemStorage.write_locked), so a drop or keep by
	# another process lands wholly before or after them.
	var local_to := to_id if to_project.is_empty() or to_project == from_db.get_project_name() else ""
	var error := ItemStorage.write_locked(from_db, func() -> String:
		for item_id: String in [from_id, local_to]:
			if not item_id.is_empty() and not from_db.has_item(item_id): return "Item not found: %s" % item_id
		from_db.add_link(from_id, stored_to, relation)
		var history_id := from_id
		if not ItemStorage.is_ephemeral(from_db, from_id) and not local_to.is_empty() and ItemStorage.is_ephemeral(from_db, local_to): history_id = local_to
		from_db.add_event(history_id, "linked", "agent",
			"Linked %s → %s (%s)" % [from_id, stored_to, relation])
		return "")
	if not error.is_empty():
		return {"error": error}

	return {"from": from_id, "to": stored_to, "relation": relation}


func _resolve_db(args: Dictionary, default_db: DocketDB, project_dbs: Dictionary) -> DocketDB:
	var proj_name: String = str(args.get("project", ""))
	if not proj_name.is_empty() and project_dbs.has(proj_name):
		return project_dbs[proj_name]
	return default_db
