extends RefCounted
class_name DocketTransition

var _schema: Dictionary = {}
var _cached_description: String = ""


func init(schema: Dictionary) -> void:
	_schema = schema
	_cached_description = ""  # Reset cache


func get_definition() -> Dictionary:
	return {
		"name": "docket_transition",
		"description": _build_description(),
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"to": {"type": "string"},
				"resolution": {"type": "string"},
				"note": {"type": "string", "description": "Reason for the change. Required when the transition is outside the normal promotion flow."},
				"blocked_by": {"type": "string"},
				"fields": {"type":"object","description":"Typed field values committed with the transition"},
				"unset_fields": {"type":"array","items":{"type":"string"}},
				"expected_revision": {"type":"string","description":"Expected pinned type revision for stale-form refusal"},
				"expected_item_token": {"type":"string","description":"Expected content token for stale-form refusal"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["id", "to"],
		},
	}


func _build_description() -> String:
	if not _cached_description.is_empty():
		return _cached_description

	var desc := "Transition an item to a new state. Any state of the type is reachable: moves along the normal promotion flow need nothing extra, while any other move (reopening, skipping ahead) requires a 'note' explaining why. When transitioning to 'blocked', supply 'blocked_by' (an item ID, optionally cross-project qualified like 'project:DKT-0042')."

	if _schema.is_empty():
		_cached_description = desc
		return _cached_description

	var state_chains := _build_state_chains(_schema)
	_cached_description = desc + "\n\nState chains — " + state_chains
	return _cached_description


func _build_state_chains(schema: Dictionary) -> String:
	var chains: Array = []
	var types: Dictionary = schema.get("types", {})

	for type_name in types.keys():
		var type_def: Dictionary = types[type_name]
		var states: Array = type_def.get("states", [])
		var transitions: Dictionary = type_def.get("transitions", {})

		if states.is_empty():
			continue

		# Build a readable chain showing transitions from each state
		var chain_parts: PackedStringArray = []
		for state in states:
			if transitions.has(state):
				var valid_next: Array = transitions[state]
				if valid_next.is_empty():
					chain_parts.append("%s (flow end)" % state)
				else:
					chain_parts.append(state)
			else:
				chain_parts.append(state)

		var chain_str := " → ".join(chain_parts)
		chains.append("%s: %s" % [type_name, chain_str])

	return ". ".join(PackedStringArray(chains))


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = args.get("id", "")
	if not db.has_item(id):
		return {"error": "Item not found: %s" % id}

	var to: String = args.get("to", "")
	var note: String = args.get("note", "")
	var extra: Dictionary = {}
	if args.get("fields") is Dictionary: extra["fields"] = args.fields
	if args.get("unset_fields") is Array: extra["unset_fields"] = args.unset_fields
	if args.has("resolution"):
		extra["resolution"] = args.resolution
	if args.has("blocked_by"):
		extra["blocked_by"] = args.blocked_by
	var transition_registry: TypeRegistry = TypeRegistry.for_db(db, db.get_project_name())
	var typed_error: String = transition_registry.transition_item(id, to, "agent", note, extra, str(args.get("expected_revision", "")), str(args.get("expected_item_token", "")))
	if not typed_error.is_empty(): return {"error":typed_error}
	var typed_item: Dictionary = db.get_item(id)
	return {"id":id,"status":typed_item.get("status", ""),"type_revision":typed_item.get("type_revision", ""),"item_token":transition_registry.item_token(typed_item)}
