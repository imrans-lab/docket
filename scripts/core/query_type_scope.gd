extends RefCounted
class_name QueryTypeScope
## Resolves catalog identities and query choices per OR branch. Project/type
## pairs stay coupled until compilation, preventing duplicate slugs in separate
## projects from collapsing into one predicate.

const UNIVERSAL_FIELDS := ["type", "status", "priority", "severity", "title", "description", "assigned_to", "directed_to", "tags", "has_attachment", "id", "created_at", "updated_at", "project", "blocked_by", "parent"]

static func branch_index(conditions: Array, row_index: int) -> int:
	var branch := 0
	for i in mini(row_index + 1, conditions.size()):
		if i > 0 and str(conditions[i].get("conj", "and")).to_lower() == "or": branch += 1
	return branch

static func branch_scope(conditions: Array, row_index: int, catalog: Array = []) -> Dictionary:
	var wanted := branch_index(conditions, row_index)
	var identity_sets: Array = []
	var slug_sets: Array = []
	for i in conditions.size():
		if branch_index(conditions, i) != wanted: continue
		var cond: Dictionary = conditions[i]
		if cond.get("field", "") != "type": continue
		var raw = cond.get("value", [])
		var values: Array = raw if raw is Array else [raw]
		# A newly inserted chooser has no predicate yet. Treating its empty value
		# as a set made it erase the type scope established by preceding AND rows.
		values = values.filter(func(value): return not str(value).is_empty())
		if values.is_empty(): continue
		if cond.get("op", "") == "catalog_in": identity_sets.append(values)
		elif str(cond.get("op", "eq")) in ["eq", "in"]: slug_sets.append(values)
	var identities := _intersection(identity_sets)
	var slugs := _intersection(slug_sets)
	if not identities.is_empty():
		var identity_slugs: Array = []
		for key in identities:
			var record := TypeCatalog.find_by_key(catalog, str(key))
			if not record.is_empty() and not identity_slugs.has(record.slug): identity_slugs.append(record.slug)
		slugs = identity_slugs if slugs.is_empty() else _intersect_two(slugs, identity_slugs)
	return {"known": not identity_sets.is_empty() or not slug_sets.is_empty(), "identities": identities, "types": slugs}

static func _intersection(sets: Array) -> Array:
	if sets.is_empty(): return []
	var result: Array = []
	for value in sets[0]:
		if not result.has(value): result.append(value)
	for set_value in sets.slice(1): result = _intersect_two(result, set_value)
	return result

static func _intersect_two(left: Array, right: Array) -> Array:
	var result: Array = []
	for value in left:
		if right.has(value): result.append(value)
	return result

static func _record_in_scope(record: Dictionary, scope: Dictionary) -> bool:
	if not scope.known: return true
	if not scope.identities.is_empty(): return scope.identities.has(record.key)
	return scope.types.has(record.slug)

static func statuses(catalog: Array, scope: Dictionary) -> Array:
	var groups: Array = []
	for value in catalog:
		var record: Dictionary = value
		if not _record_in_scope(record, scope): continue
		groups.append({"key": record.key, "type": record.slug, "label": record.label, "project": record.project, "values": record.states.duplicate()})
	return groups

static func fields(catalog: Array, scope: Dictionary) -> Array:
	var available := UNIVERSAL_FIELDS.duplicate()
	for value in catalog:
		var record: Dictionary = value
		if not _record_in_scope(record, scope): continue
		for field_value in record.fields:
			var field := str(field_value)
			if not available.has(field): available.append(field)
	available.sort()
	return available

static func validate_value(field: String, value: String, catalog: Array, scope: Dictionary) -> Dictionary:
	if not scope.known or value.is_empty() or value == "(any)": return {"valid": true, "message": ""}
	if field == "status":
		for group in statuses(catalog, scope):
			if group.values.has(value): return {"valid": true, "message": ""}
		return {"valid": false, "message": "Status '%s' is not available for the selected type scope." % value}
	if not fields(catalog, scope).has(field): return {"valid": false, "message": "Field '%s' is not available for the selected type scope." % field}
	return {"valid": true, "message": ""}

static func compile_catalog_conditions(conditions: Array, catalog: Array, include_project: bool = true) -> Dictionary:
	var groups: Array = []
	var current: Array = []
	for i in conditions.size():
		var cond: Dictionary = conditions[i].duplicate(true)
		if i > 0 and str(cond.get("conj", "and")) == "or": groups.append(current); current = []
		cond.erase("conj")
		current.append(_compile_condition(cond, catalog, include_project))
	groups.append(current)
	var compiled: Array = []
	for group in groups: compiled.append(group[0] if group.size() == 1 else {"$and": group})
	if compiled.size() == 1:
		return compiled[0] if compiled[0] is Dictionary and compiled[0].has("$and") else {"$and": [compiled[0]]}
	return {"$or": compiled}

static func _compile_condition(cond: Dictionary, catalog: Array, include_project: bool) -> Dictionary:
	if cond.get("field", "") == "status" and cond.get("op", "") == "catalog_status":
		var choice: Dictionary = cond.get("value", {})
		var record := TypeCatalog.find_by_key(catalog, str(choice.get("key", "")))
		if record.is_empty(): return {"field": "id", "op": "in", "value": []}
		var predicates: Array = [{"field": "type", "op": "eq", "value": record.slug}, {"field": "status", "op": "eq", "value": choice.get("status", "")}]
		if include_project and not str(record.project).is_empty(): predicates.push_front({"field": "project", "op": "eq", "value": record.project})
		return {"$and": predicates}
	if cond.get("field", "") != "type" or cond.get("op", "") != "catalog_in": return cond
	var alternatives: Array = []
	for key in cond.get("value", []):
		var record := TypeCatalog.find_by_key(catalog, str(key))
		if record.is_empty(): alternatives.append({"field": "id", "op": "eq", "value": "__unknown_type_identity__"})
		else:
			var pair: Array = [{"field": "type", "op": "eq", "value": record.slug}]
			if include_project and not str(record.project).is_empty(): pair.push_front({"field": "project", "op": "eq", "value": record.project})
			alternatives.append(pair[0] if pair.size() == 1 else {"$and": pair})
	if alternatives.is_empty(): return {"field": "id", "op": "eq", "value": "__empty_type_selection__"}
	return alternatives[0] if alternatives.size() == 1 else {"$or": alternatives}
