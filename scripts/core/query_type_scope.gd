extends RefCounted
## Resolves catalog identities and query choices per OR branch. Project/type
## pairs stay coupled until compilation, preventing duplicate slugs in separate
## projects from collapsing into one predicate. A catalog record's project is
## the exact project it came from (its selector), so each pair is guarded by
## a project_selector condition, never by a stored name, which would take in
## copies of it: such a query runs only in this session and is not saved.

const TypeCatalog := preload("type_catalog.gd")

const UNIVERSAL_FIELDS := ["type", "status", "priority", "severity", "title", "description", "assigned_to", "directed_to", "tags", "has_attachment", "id", "created_at", "updated_at", "project", ProjectSelectors.SELECTOR_FIELD, "blocked_by", "parent"]

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
		current.append(cond)
	groups.append(current)
	var compiled: Array = []
	for group in groups:
		var identities: Array = []
		for group_condition in group:
			if group_condition.get("field", "") == "type" and group_condition.get("op", "") == "catalog_in":
				for identity in group_condition.get("value", []):
					var scoped_record := TypeCatalog.find_by_key(catalog, str(identity))
					if not scoped_record.is_empty() and not identities.has(scoped_record.key): identities.append(scoped_record.key)
		var expanded: Array = []
		for group_condition in group:
			var scoped_condition: Dictionary = group_condition.duplicate(true)
			if str(scoped_condition.get("field", "")) not in UNIVERSAL_FIELDS:
				scoped_condition["field_key"] = scoped_condition.field
				if identities.size() == 1:
					var single: Dictionary = TypeCatalog.find_by_key(catalog, str(identities[0]))
					scoped_condition["type_id"] = single.id
					if include_project and not str(single.project).is_empty(): scoped_condition = {"$and":[{"field":ProjectSelectors.SELECTOR_FIELD,"op":"eq","value":single.project},scoped_condition]}
				elif identities.size() > 1:
					var kind: String = ""
					var alternatives: Array = []
					for identity in identities:
						var record: Dictionary = TypeCatalog.find_by_key(catalog, str(identity))
						var record_kind: String = str(record.get("field_kinds", {}).get(scoped_condition.field, ""))
						if record_kind.is_empty() or (not kind.is_empty() and kind != record_kind):
							scoped_condition = {"binding_error":"Field '%s' is not compatible across the selected type identities." % scoped_condition.field}
							alternatives.clear(); break
						kind = record_kind
						var alternative: Dictionary = scoped_condition.duplicate(true); alternative["type_id"] = record.id
						if include_project and not str(record.project).is_empty(): alternative = {"$and":[{"field":ProjectSelectors.SELECTOR_FIELD,"op":"eq","value":record.project},alternative]}
						alternatives.append(alternative)
					if not alternatives.is_empty(): scoped_condition = {"$or":alternatives}
			expanded.append(scoped_condition)
		var compiled_group: Array = []
		for scoped_condition in expanded: compiled_group.append(_compile_condition(scoped_condition, catalog, include_project))
		compiled.append(compiled_group[0] if compiled_group.size() == 1 else {"$and":compiled_group})
	if compiled.size() == 1:
		return compiled[0] if compiled[0] is Dictionary and compiled[0].has("$and") else {"$and": [compiled[0]]}
	return {"$or": compiled}

static func _compile_condition(cond: Dictionary, catalog: Array, include_project: bool) -> Dictionary:
	if cond.get("field", "") == "status" and cond.get("op", "") == "catalog_status":
		var choice: Dictionary = cond.get("value", {})
		var record := TypeCatalog.find_by_key(catalog, str(choice.get("key", "")))
		if record.is_empty(): return {"field":"type","type_id":str(choice.get("key", "")),"op":"eq","value":""}
		var predicates: Array = [{"field":"type","type_id":record.id,"op":"eq","value":record.slug}, {"field":"status","type_id":record.id,"op":"eq","value":choice.get("status", "")}]
		if include_project and not str(record.project).is_empty(): predicates.push_front({"field": ProjectSelectors.SELECTOR_FIELD, "op": "eq", "value": record.project})
		return {"$and": predicates}
	if cond.get("field", "") != "type" or cond.get("op", "") != "catalog_in": return cond
	var alternatives: Array = []
	for key in cond.get("value", []):
		var record := TypeCatalog.find_by_key(catalog, str(key))
		if record.is_empty(): alternatives.append({"field":"type","type_id":str(key),"op":"eq","value":""})
		else:
			var pair: Array = [{"field":"type","type_id":record.id,"op":"eq","value":record.slug}]
			if include_project and not str(record.project).is_empty(): pair.push_front({"field": ProjectSelectors.SELECTOR_FIELD, "op": "eq", "value": record.project})
			alternatives.append(pair[0] if pair.size() == 1 else {"$and": pair})
	if alternatives.is_empty(): return {"field":"id","op":"in","value":[]}
	return alternatives[0] if alternatives.size() == 1 else {"$or": alternatives}
