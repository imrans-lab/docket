extends RefCounted
class_name DocketGetStateMachine


func get_definition() -> Dictionary:
	return {
		"name": "docket_get_state_machine",
		"description": "Return the project registry's full pinned lifecycle definition. Enforcement may be strict, guided, or open; callers must follow the returned transitions and guards.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"project": {"type":"string", "description":"Project whose pinned type semantics should be returned."},
				"type": {"type": "string", "description": "Item type (e.g. 'bug', 'work_item'). Omit to get all types."},
			},
			"required": [],
		},
	}


func execute(args: Dictionary, schema: Dictionary, db: DocketDB) -> Dictionary:
	if db is DocketDBJsonl and db.get_meta_value("jsonl_version", "1.0.0") == "2.0.0":
		var registry := TypeRegistry.for_db(db, db.get_project_name())
		if args.has("type") and not str(args.type).is_empty():
			var descriptor: Dictionary = registry.resolve_type_ref(str(args.type))
			if descriptor.has("error"): return descriptor
			return {"type":descriptor.slug,"type_id":descriptor.id,"revision":descriptor.current_revision,"lifecycle":descriptor.definition.lifecycle}
		var definitions: Array = registry.list_types(true)
		if definitions.size() == 1 and definitions[0] is Dictionary and definitions[0].has("error"): return definitions[0]
		return {"state_machines":definitions}
	var types: Dictionary = schema.get("types", {})

	if args.has("type") and not str(args.get("type", "")).is_empty():
		var type_name: String = str(args["type"])
		if not types.has(type_name):
			return {"error": "Unknown type: %s. Valid types: %s" % [type_name, ", ".join(PackedStringArray(types.keys()))]}
		return _build_state_machine(type_name, types[type_name])

	# Return all types
	var result: Array = []
	for type_name in types.keys():
		result.append(_build_state_machine(type_name, types[type_name]))
	return {"state_machines": result}


func _build_state_machine(type_name: String, type_def: Dictionary) -> Dictionary:
	return {
		"type": type_name,
		"states": type_def.get("states", []),
		"initial_state": type_def.get("initial_state", ""),
		"transitions": type_def.get("transitions", {}),
	}
