extends RefCounted
class_name DocketMirror
## MCP tool: mirror fields (and optionally state) from one item to another across projects.
## Pull mode (fields is Array): read named fields from source, copy to target.
## Push mode (fields is Dict): write provided values directly to target.


func get_definition() -> Dictionary:
	return {
		"name": "docket_mirror",
		"description": "Mirror fields from a source item to a target item across projects. Pull mode (fields=Array) copies field values from source; push mode (fields=Dict) writes values directly. Optionally transitions the target and adds an audit comment.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"source_id": {"type": "string", "description": "Source item ID (full or short prefix)"},
				"source_project": {"type": "string", "description": "Source project name (optional, defaults to primary)"},
				"target_id": {"type": "string", "description": "Target item ID (full or short prefix)"},
				"target_project": {"type": "string", "description": "Target project name (optional, defaults to primary)"},
				"fields": {"description": "Array of field names to pull from source, or Dict of field:value pairs to push"},
				"transition_to": {"type": "string", "description": "Optional state to transition the target to"},
				"note": {"type": "string", "description": "Optional audit note"},
				"expected_revision": {"type":"string","description":"Expected pinned target type revision"},
				"expected_item_token": {"type":"string","description":"Expected target content token"},
			},
			"required": ["source_id", "target_id", "fields"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, primary_db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var source_id: String = str(args.get("source_id", ""))
	var target_id: String = str(args.get("target_id", ""))
	if source_id.is_empty() or target_id.is_empty():
		return {"error": "Missing 'source_id' or 'target_id'"}

	var fields = args.get("fields", null)
	if fields == null:
		return {"error": "Missing 'fields' parameter"}

	var source_project: String = str(args.get("source_project", ""))
	var target_project: String = str(args.get("target_project", ""))
	var transition_to: String = str(args.get("transition_to", ""))
	var note: String = str(args.get("note", ""))

	# Resolve DBs
	var source_db: DocketDB = _resolve_project_db(source_project, primary_db, project_dbs)
	var target_db: DocketDB = _resolve_project_db(target_project, primary_db, project_dbs)
	if source_db == null: return {"error":"Unknown source project '%s'" % source_project}
	if target_db == null: return {"error":"Unknown target project '%s'" % target_project}

	# Build payload from pull or push mode
	var payload: Dictionary = {}
	var field_list: PackedStringArray = []
	var source_proj_label: String = source_project if not source_project.is_empty() else _primary_name(primary_db, project_dbs)

	if fields is Array:
		# Pull mode: read from source
		if not source_db.has_item(source_id):
			return {"error": "Source item not found: %s" % source_id}
		var source_item: Dictionary = source_db.get_item(source_id)
		var source_semantics: Dictionary = TypeRegistry.for_db(source_db, source_db.get_project_name()).resolve_item(source_item)
		if source_semantics.has("error"): return {"error":"Source item semantics are unresolved: %s" % source_semantics.error}
		for field_name in fields:
			var fname: String = str(field_name)
			var custom: Dictionary = source_item.get("fields", {}) if source_item.get("fields", {}) is Dictionary else {}
			var custom_declared: bool = false
			for descriptor in source_semantics.definition.fields:
				if str(descriptor.key) == fname and not bool(source_semantics.definition.get("protected", false)): custom_declared = true
			if custom_declared and custom.has(fname):
				payload[fname] = custom[fname]
				field_list.append(fname)
			elif source_item.has(fname):
				payload[fname] = source_item[fname]
				field_list.append(fname)
		if payload.is_empty(): return {"error":"No selected fields exist on the source item"}
	elif fields is Dictionary:
		# Push mode: use provided values directly
		for key in fields:
			payload[str(key)] = fields[key]
			field_list.append(str(key))
		if payload.is_empty():
			return {"error": "Fields dictionary is empty"}
	else:
		return {"error": "'fields' must be an Array (pull mode) or Dictionary (push mode)"}

	if not target_db.has_item(target_id): return {"error":"Target item not found: %s" % target_id}
	var target_registry: TypeRegistry = TypeRegistry.for_db(target_db, target_db.get_project_name())
	var audit: String = "Mirrored from %s:%s [%s]" % [source_proj_label,source_id,", ".join(field_list)]
	if not note.is_empty(): audit += ": %s" % note
	var mirror_result: Dictionary = target_registry.mirror_item(target_id, {"fields":payload}, transition_to, "agent", note, audit, str(args.get("expected_revision", "")), str(args.get("expected_item_token", "")))
	if mirror_result.has("error"): return mirror_result
	return {"target_id":target_id,"target_project":target_db.get_project_name(),"pushed_fields":Array(field_list),"transitioned_to":transition_to,"comment_id":mirror_result.get("comment_id", 0)}


func _resolve_project_db(name: String, primary_db: DocketDB, project_dbs: Dictionary) -> DocketDB:
	if name.is_empty():
		return primary_db
	# Case-insensitive lookup
	for proj_name in project_dbs:
		if proj_name.to_lower() == name.to_lower():
			return project_dbs[proj_name]
	return null


func _primary_name(primary_db: DocketDB, project_dbs: Dictionary) -> String:
	# Find the project name that maps to the primary DB
	for proj_name in project_dbs:
		if project_dbs[proj_name] == primary_db:
			return proj_name
	return "primary"
