extends RefCounted
class_name QueryTypeScope
## Computes query-builder choices one OR branch at a time. An OR starts a new
## branch, so a type constraint can never narrow controls in its sibling.

const UNIVERSAL_FIELDS := [
	"type", "status", "priority", "severity", "title", "description",
	"assigned_to", "directed_to", "tags", "has_attachment", "id", "created_at",
	"updated_at", "project", "blocked_by", "parent",
]


static func branch_index(conditions: Array, row_index: int) -> int:
	var branch := 0
	for i in mini(row_index + 1, conditions.size()):
		if i > 0 and str(conditions[i].get("conj", "and")).to_lower() == "or":
			branch += 1
	return branch


static func selected_types(conditions: Array, row_index: int) -> Array:
	return branch_scope(conditions, row_index).types


static func branch_scope(conditions: Array, row_index: int) -> Dictionary:
	var wanted_branch := branch_index(conditions, row_index)
	var selected: Array = []
	var constrained := false
	var first_predicate := true
	for i in conditions.size():
		if branch_index(conditions, i) != wanted_branch:
			continue
		var condition: Dictionary = conditions[i]
		if str(condition.get("field", "")) != "type" or str(condition.get("op", "eq")) not in ["eq", "in"]:
			continue
		constrained = true
		var value = condition.get("value", "")
		var values: Array = value if value is Array else [value]
		var predicate_types: Array = []
		for type_value in values:
			var slug := str(type_value)
			if not slug.is_empty() and not predicate_types.has(slug):
				predicate_types.append(slug)
		if first_predicate:
			selected = predicate_types
			first_predicate = false
		else:
			for existing in selected.duplicate():
				if not predicate_types.has(existing):
					selected.erase(existing)
	return {"known": constrained, "types": selected}


static func statuses(catalog: Array, selected: Array, constrained: bool = true) -> Array:
	var groups: Array = []
	for record_value in catalog:
		var record: Dictionary = record_value
		if constrained and not selected.has(str(record.get("slug", ""))):
			continue
		groups.append({
			"type": str(record.get("slug", "")),
			"label": str(record.get("label", "")),
			"project": str(record.get("project", "")),
			"values": record.get("states", []).duplicate(),
		})
	return groups


static func fields(catalog: Array, selected: Array, constrained: bool = true) -> Array:
	var available := UNIVERSAL_FIELDS.duplicate()
	for record_value in catalog:
		var record: Dictionary = record_value
		if not constrained or selected.has(str(record.get("slug", ""))):
			for field_value in record.get("fields", []):
				var field := str(field_value)
				if not available.has(field):
					available.append(field)
	available.sort()
	return available


static func validate_value(field: String, value: String, catalog: Array, selected: Array, constrained: bool = true) -> Dictionary:
	if not constrained or value.is_empty() or value == "(any)":
		return {"valid": true, "message": ""}
	if field == "status":
		for group in statuses(catalog, selected, constrained):
			if group.values.has(value):
				return {"valid": true, "message": ""}
		return {"valid": false, "message": "Status '%s' is not available for the selected type scope." % value}
	if not fields(catalog, selected, constrained).has(field):
		return {"valid": false, "message": "Field '%s' is not available for the selected type scope." % field}
	return {"valid": true, "message": ""}


static func expand_grouped_status(condition: Dictionary, choice: Dictionary, include_project: bool) -> Array:
	## A status label is only meaningful inside its catalog group. Materialize
	## that group as ordinary predicates so saved queries keep their meaning.
	var result: Array = []
	var incoming_conj := str(condition.get("conj", "and"))
	if include_project and not str(choice.get("project", "")).is_empty():
		result.append({"field": "project", "op": "eq", "value": choice.project, "conj": incoming_conj})
		incoming_conj = "and"
	result.append({"field": "type", "op": "eq", "value": choice.type, "conj": incoming_conj})
	var status_condition := condition.duplicate(true)
	status_condition["value"] = choice.value
	status_condition["conj"] = "and"
	result.append(status_condition)
	return result
