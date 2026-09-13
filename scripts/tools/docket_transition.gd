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
				"note": {"type": "string", "description": "Reason for the change when required by the pinned type's lifecycle policy."},
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

	_cached_description = "Transition an item according to its pinned type revision. Strict lifecycles allow only declared edges, guided lifecycles require a note for off-flow moves, and open lifecycles allow any declared state. Required-field and scalar guards always apply. Use docket_get_state_machine or docket_type_get with the item's project to discover its exact states, policy, and guards."
	return _cached_description


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
	if not typed_error.is_empty():
		var failed_item: Dictionary = db.get_item(id)
		db.log_transition(str(failed_item.get("type", "")), str(failed_item.get("status", "")), to, false, [])
		return {"error":typed_error}
	var typed_item: Dictionary = db.get_item(id)
	return {"id":id,"status":typed_item.get("status", ""),"type_revision":typed_item.get("type_revision", ""),"item_token":transition_registry.item_token(typed_item)}
