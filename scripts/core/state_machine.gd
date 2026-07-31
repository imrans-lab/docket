extends RefCounted
class_name StateMachine
## Type-specific state machines. The transition graph is the normal promotion
## flow, not a wall: any state can move to any other state of its type, but
## moves outside the flow require a note explaining why.


## Whether from → to follows the normal promotion flow.
static func can_transition(schema: Dictionary, type: String, from: String, to: String) -> bool:
	if not schema.types.has(type):
		return false
	var transitions: Dictionary = schema.types[type].transitions
	if not transitions.has(from):
		return false
	var valid: Array = transitions[from]
	return valid.has(to)


static func get_valid_transitions(schema: Dictionary, type: String, from: String) -> Array:
	if not schema.types.has(type):
		return []
	var transitions: Dictionary = schema.types[type].transitions
	if not transitions.has(from):
		return []
	return transitions[from].duplicate()


static func get_all_states(schema: Dictionary, type: String) -> Array:
	if not schema.types.has(type):
		return []
	return schema.types[type].get("states", []).duplicate()


static func perform_transition(schema: Dictionary, item: Dictionary, to: String, actor: String, note: String = "", extra: Dictionary = {}) -> Dictionary:
	var type: String = item.type
	var from: String = item.status

	var all_states := get_all_states(schema, type)
	if not all_states.has(to):
		return {"error": "Cannot transition %s from '%s' to '%s'. State '%s' does not exist for type %s. Valid states: %s" % [type, from, to, to, type, str(all_states)]}

	# Off-flow moves are allowed, but require a note explaining why.
	if not can_transition(schema, type, from, to) and note.strip_edges().is_empty():
		var valid := get_valid_transitions(schema, type, from)
		return {"error": "Transition %s from '%s' to '%s' is outside the normal promotion flow (normal next: %s). It is allowed, but requires a note explaining why." % [type, from, to, str(valid)]}

	# Check transition rules (e.g., bug resolved requires resolution)
	var type_def: Dictionary = schema.types[type]
	if type_def.has("transition_rules") and type_def.transition_rules.has(to):
		var rules: Dictionary = type_def.transition_rules[to]
		if rules.has("required_fields"):
			for field in rules.required_fields:
				if not extra.has(field) and not item.get(field, ""):
					return {"error": "Transition to '%s' requires field '%s'" % [to, field]}

	# Apply extra fields (like resolution)
	for key in extra:
		item[key] = extra[key]

	var old_status: String = item.status
	item.status = to
	DataModel.add_event(item, "transition", actor, "%s → %s%s" % [old_status, to, (". " + note if note else "")])

	return {}
