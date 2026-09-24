extends RefCounted
class_name RegistryQuery
## Compiles project-qualified type bindings against immutable revision snapshots.

const DERIVED_FIELDS := ["state_category", "state_outcome", "is_terminal"]

static func compile(query: Dictionary, registry: TypeRegistry, allowed_fields: Array) -> Dictionary:
	DocketDBFilter.set_allowed_fields(allowed_fields)
	var filter_value = query.get("filter", {})
	var translated: Dictionary
	if filter_value is Dictionary and filter_value.has("conditions"):
		if filter_value.size() != 1: return {"error":"conditions wrapper cannot contain sibling filter keys"}
		if not filter_value.conditions is Array: return {"error":"conditions must be an array"}
		translated = _conditions(filter_value.conditions, registry)
	elif filter_value is Dictionary and (filter_value.has("$or") or filter_value.has("$and") or filter_value.has("field_key") or filter_value.has("op") or filter_value.has("type_id")):
		translated = _tree(filter_value, registry)
	elif filter_value is Dictionary:
		translated = DocketDBFilter.translate_filter(filter_value)
	else:
		return {"error":"filter must be an object"}
	if translated.has("error"): return translated
	var order: Dictionary = _sort(query.get("sort", []), registry)
	if order.has("error"): return order
	return {"where":translated.get("where", translated.get("sql", "")),"bindings":translated.get("bindings", []),"order":order.get("sql", ""),"order_bindings":order.get("bindings", [])}

static func _conditions(conditions: Array, registry: TypeRegistry) -> Dictionary:
	if conditions.is_empty(): return {"where":"","bindings":[]}
	var groups: Array = []
	var group: Array = []
	for index in conditions.size():
		var condition = conditions[index]
		if not condition is Dictionary: return {"error":"query conditions must be objects"}
		var conjunction: String = str(condition.get("conj", "and")).to_lower()
		if conjunction not in ["and", "or"]: return {"error":"unknown query conjunction '%s'" % conjunction}
		if index > 0 and conjunction == "or":
			groups.append(group)
			group = []
		group.append(condition)
	groups.append(group)
	var parts: PackedStringArray = PackedStringArray()
	var bindings: Array = []
	for and_group in groups:
		var scoped: Dictionary = _bind_sibling_scope(and_group)
		if scoped.has("error"): return scoped
		var compiled: Dictionary = _join(scoped.children, "AND", registry)
		if compiled.has("error"): return compiled
		parts.append("(%s)" % compiled.sql)
		bindings.append_array(compiled.bindings)
	return {"where":" OR ".join(parts),"bindings":bindings}

static func _tree(node: Dictionary, registry: TypeRegistry) -> Dictionary:
	if node.has("$and") and node.has("$or"): return {"error":"a boolean query node cannot contain both $and and $or"}
	for operator in ["$and", "$or"]:
		if node.has(operator):
			if node.size() != 1: return {"error":"boolean query nodes cannot mix operators with condition keys"}
			if not node[operator] is Array: return {"error":"%s must contain an array" % operator}
			var children: Array = node[operator].duplicate(true)
			if children.is_empty(): return {"where":"1" if operator == "$and" else "0","bindings":[]}
			if operator == "$and":
				for child in children:
					if _is_false_condition(child): return {"where":"0","bindings":[]}
			if operator == "$and":
				var scoped: Dictionary = _bind_sibling_scope(children)
				if scoped.has("error"): return scoped
				children = scoped.children
			var pieces: Array = []
			for child in children:
				if not child is Dictionary: return {"error":"boolean query children must be objects"}
				pieces.append(_tree(child, registry) if (child.has("$and") or child.has("$or")) else _condition(child, registry))
			return _join_compiled(pieces, "AND" if operator == "$and" else "OR")
	var condition: Dictionary = _condition(node, registry)
	return {"where":condition.get("sql", ""),"bindings":condition.get("bindings", [])} if not condition.has("error") else condition

static func _join(values: Array, separator: String, registry: TypeRegistry) -> Dictionary:
	var compiled: Array = []
	for value in values: compiled.append(_condition(value, registry))
	return _join_compiled(compiled, separator)

static func _join_compiled(values: Array, separator: String) -> Dictionary:
	var parts: PackedStringArray = PackedStringArray()
	var bindings: Array = []
	for value in values:
		var result: Dictionary = value
		if result.has("error"): return result
		var sql: String = str(result.get("sql", result.get("where", "")))
		if sql.is_empty(): return {"error":"query condition compiled to an empty predicate"}
		parts.append("(%s)" % sql)
		bindings.append_array(result.get("bindings", []))
	return {"sql":separator.join(parts),"where":separator.join(parts),"bindings":bindings}

static func _condition(condition: Dictionary, registry: TypeRegistry) -> Dictionary:
	if condition.has("binding_error"): return {"error":str(condition.binding_error)}
	for key in condition:
		if str(key) not in ["field","field_key","type_id","op","value","conj"]: return {"error":"unknown condition property '%s'" % key}
	for string_key in ["field","field_key","type_id","op","conj"]:
		if condition.has(string_key) and not condition[string_key] is String: return {"error":"condition %s must be a string" % string_key}
	if condition.has("field") and condition.has("field_key") and str(condition.field) != str(condition.field_key): return {"error":"condition has conflicting field and field_key"}
	var field: String = str(condition.get("field_key", condition.get("field", "")))
	var type_id: String = str(condition.get("type_id", ""))
	if type_id.is_empty():
		if field in DERIVED_FIELDS: return _derived(field, condition, registry.all_revisions(), "", registry.is_legacy())
		return DocketDBFilter._condition_to_sql(condition)
	var revisions: Array = registry.revisions_for_type(type_id)
	if revisions.is_empty(): return {"error":"type identity '%s' is not present in project '%s'" % [type_id, registry.get_project_name()]}
	var legacy_slug: String = str(revisions[0].definition.slug)
	if field == "type":
		if str(condition.get("op", "eq")) != "eq": return {"error":"bound type identity supports only equality"}
		var declared_slug: String = str(condition.get("value", ""))
		if str(condition.get("op", "eq")) == "eq" and not declared_slug.is_empty() and declared_slug != legacy_slug: return {"error":"type slug '%s' conflicts with bound identity '%s'" % [declared_slug,type_id]}
		return _scalar("type" if registry.is_legacy() else "type_id", condition.get("op", "eq"), legacy_slug if registry.is_legacy() else type_id)
	if field == "status":
		var status_op: String = str(condition.get("op", "eq"))
		if status_op not in ["eq","neq","in"]: return {"error":"operator '%s' is incompatible with lifecycle state" % status_op}
		var wanted: Array = condition.get("value", []) if status_op == "in" and condition.get("value", []) is Array else [condition.get("value")]
		if status_op == "in" and not condition.get("value") is Array: return {"error":"status 'in' requires an array"}
		for status_value in wanted:
			if not status_value is String: return {"error":"lifecycle state operands must be strings"}
			var declared: bool = false
			for revision in revisions:
				for state in revision.definition.lifecycle.states:
					if str(state.key) == status_value: declared = true
			if not declared: return {"error":"state '%s' is not declared by type identity '%s'" % [status_value,type_id]}
		var status_result: Dictionary = _scalar("status", condition.get("op", "eq"), condition.get("value"))
		if status_result.has("error"): return status_result
		return {"sql":"type=? AND (%s)" % status_result.sql,"bindings":[legacy_slug] + status_result.bindings} if registry.is_legacy() else {"sql":"type_id=? AND (%s)" % status_result.sql,"bindings":[type_id] + status_result.bindings}
	if field in DERIVED_FIELDS: return _derived(field, condition, revisions, type_id, registry.is_legacy())
	if registry.is_legacy():
		var descriptor_found: bool = false
		for descriptor in revisions[0].definition.fields:
			if str(descriptor.key) == field: descriptor_found = true
		if not descriptor_found: return {"error":"field '%s' is absent from type identity '%s'" % [field,type_id]}
		var legacy_condition: Dictionary = condition.duplicate(true); legacy_condition["field"] = field; legacy_condition.erase("field_key"); legacy_condition.erase("type_id")
		var legacy_predicate: Dictionary = DocketDBFilter._condition_to_sql(legacy_condition)
		if legacy_predicate.has("error"): return legacy_predicate
		return {"sql":"type=? AND (%s)" % legacy_predicate.sql,"bindings":[legacy_slug] + legacy_predicate.bindings}
	return _custom(field, condition, revisions, type_id)

static func _custom(field: String, condition: Dictionary, revisions: Array, type_id: String) -> Dictionary:
	var compatible_type: String = ""
	var pins: Array = []
	var enum_values: Array = []
	for revision in revisions:
		for descriptor in revision.definition.fields:
			if str(descriptor.key) == field:
				if compatible_type.is_empty(): compatible_type = str(descriptor.type)
				elif compatible_type != str(descriptor.type): return {"error":"field '%s' has incompatible kinds across pinned revisions" % field}
				pins.append(str(revision.id))
				if compatible_type == "enum" and enum_values.is_empty(): enum_values = descriptor.get("values", []).duplicate()
	if pins.is_empty(): return {"error":"field '%s' is absent from type identity '%s'" % [field,type_id]}
	var op: String = str(condition.get("op", "eq"))
	if not _operator_allowed(compatible_type, op): return {"error":"operator '%s' is incompatible with %s field '%s'" % [op,compatible_type,field]}
	var operand_error: String = _validate_operand(compatible_type, op, condition.get("value"))
	if not operand_error.is_empty(): return {"error":"field '%s': %s" % [field,operand_error]}
	if compatible_type == "enum" and op in ["eq","neq","in"]:
		var enum_value = condition.get("value")
		var enum_operands: Array = enum_value if enum_value is Array else [enum_value]
		for operand in enum_operands:
			if operand != null and not enum_values.has(operand): return {"error":"field '%s': enum value '%s' is not declared" % [field,operand]}
	var path: String = "$.%s" % field
	var pin_sql: Dictionary = _in_sql("type_revision", pins)
	var predicate: Dictionary = _json_predicate(path, op, condition.get("value"))
	if predicate.has("error"): return predicate
	return {"sql":"type_id=? AND %s AND (%s)" % [pin_sql.sql,predicate.sql],"bindings":[type_id] + pin_sql.bindings + predicate.bindings}

static func _derived(field: String, condition: Dictionary, revisions: Array, type_id: String, legacy: bool = false) -> Dictionary:
	var op: String = str(condition.get("op", "eq"))
	if op not in ["eq","neq","in"]: return {"error":"operator '%s' is incompatible with derived state field '%s'" % [op,field]}
	var operands: Array = condition.get("value", []) if op == "in" and condition.get("value", []) is Array else [condition.get("value")]
	if op == "in" and not condition.get("value") is Array: return {"error":"derived state 'in' requires an array"}
	for operand in operands:
		if field == "is_terminal" and not operand is bool: return {"error":"is_terminal requires boolean operands"}
		if field != "is_terminal" and not operand is String: return {"error":"derived state fields require string operands"}
	var branches: PackedStringArray = PackedStringArray()
	var bindings: Array = []
	for revision in revisions:
		var statuses: Array = []
		for state in revision.definition.lifecycle.states:
			var derived_value = state.get("state_category", "") if field == "state_category" else (state.get("state_outcome", "") if field == "state_outcome" else revision.definition.lifecycle.terminal_states.has(state.key))
			if _matches(derived_value, op, condition.get("value")): statuses.append(str(state.key))
		if not statuses.is_empty():
			var status_sql: Dictionary = _in_sql("status", statuses)
			if legacy:
				branches.append("(type=? AND %s)" % status_sql.sql)
				bindings.append(str(revision.definition.slug)); bindings.append_array(status_sql.bindings)
			else:
				branches.append("(type_revision=? AND %s)" % status_sql.sql)
				bindings.append(str(revision.id)); bindings.append_array(status_sql.bindings)
	if branches.is_empty(): return {"sql":"0","bindings":[]}
	if legacy: return {"sql":"(%s)" % " OR ".join(branches),"bindings":bindings}
	if type_id.is_empty(): return {"sql":"(%s)" % " OR ".join(branches),"bindings":bindings}
	bindings.push_front(type_id)
	return {"sql":"type_id=? AND (%s)" % " OR ".join(branches),"bindings":bindings}

static func _json_predicate(path: String, op: String, value) -> Dictionary:
	if op == "is_missing": return {"sql":"json_type(fields_json,?) IS NULL","bindings":[path]}
	if op == "is_null": return {"sql":"json_type(fields_json,?)='null'","bindings":[path]}
	if op == "is_empty": return {"sql":"(json_type(fields_json,?) IS NULL OR json_type(fields_json,?)='null' OR json_extract(fields_json,?)='')","bindings":[path,path,path]}
	if op == "is_not_empty": return {"sql":"(json_type(fields_json,?) IS NOT NULL AND json_type(fields_json,?)!='null' AND json_extract(fields_json,?)!='')","bindings":[path,path,path]}
	var scalar: Dictionary = _scalar("json_extract(fields_json,?)", op, value)
	if scalar.has("error"): return scalar
	# An empty `in` compiles to a bare 0, which has no path placeholder.
	if scalar.sql == "0": return {"sql":"0","bindings":[]}
	return {"sql":scalar.sql,"bindings":[path] + scalar.bindings}

static func _scalar(expression: String, op_value, value) -> Dictionary:
	var op: String = str(op_value)
	match op:
		"eq": return {"sql":"%s IS ?" % expression,"bindings":[value]}
		"neq": return {"sql":"%s IS NOT ?" % expression,"bindings":[value]}
		"gt", "after": return {"sql":"%s>?" % expression,"bindings":[value]}
		"gte": return {"sql":"%s>=?" % expression,"bindings":[value]}
		"lt", "before": return {"sql":"%s<?" % expression,"bindings":[value]}
		"lte": return {"sql":"%s<=?" % expression,"bindings":[value]}
		"contains": return {"sql":"%s LIKE '%%' || ? || '%%'" % expression,"bindings":[value]}
		"not_contains": return {"sql":"%s NOT LIKE '%%' || ? || '%%'" % expression,"bindings":[value]}
		"like": return {"sql":"%s LIKE ? ESCAPE '\\'" % expression,"bindings":[str(value).replace("%", "\\%").replace("_", "\\_").replace("*", "%").replace(".", "_")]}
		"in":
			if not value is Array: return {"error":"operator 'in' requires an array"}
			return _in_sql(expression, value)
		"is_empty": return {"sql":"(%s IS NULL OR %s='')" % [expression,expression],"bindings":[]}
		"is_not_empty": return {"sql":"(%s IS NOT NULL AND %s!='')" % [expression,expression],"bindings":[]}
	return {"error":"unsupported query operator '%s'" % op}

static func _bind_sibling_scope(children: Array) -> Dictionary:
	var ids: Array = []
	for child in children:
		_collect_type_ids(child, ids)
	if ids.size() > 1:
		for child in children:
			if child is Dictionary and (child.has("field_key") or str(child.get("field", "")) in DERIVED_FIELDS): return {"error":"typed field binding is ambiguous across multiple type identities in one AND branch"}
	if ids.size() == 1:
		for child in children:
			if child is Dictionary and not child.has("type_id") and (child.has("field_key") or str(child.get("field", "")) == "status"): child["type_id"] = ids[0]
	return {"children":children}

static func _is_false_condition(value) -> bool:
	return value is Dictionary and str(value.get("field", "")) == "id" and str(value.get("op", "")) == "in" and value.get("value") is Array and value.value.is_empty()

static func _collect_type_ids(value, ids: Array) -> void:
	if value is Dictionary:
		if str(value.get("field", "")) == "type" and not str(value.get("type_id", "")).is_empty() and not ids.has(str(value.type_id)): ids.append(str(value.type_id))
		for child in value.values(): _collect_type_ids(child, ids)
	elif value is Array:
		for child in value: _collect_type_ids(child, ids)

static func _in_sql(expression: String, values: Array) -> Dictionary:
	if values.is_empty(): return {"sql":"0","bindings":[]}
	var placeholders: PackedStringArray = PackedStringArray()
	for _value in values: placeholders.append("?")
	return {"sql":"%s IN (%s)" % [expression,",".join(placeholders)],"bindings":values.duplicate()}

static func _operator_allowed(kind: String, op: String) -> bool:
	if op in ["is_empty","is_not_empty","is_missing","is_null"]: return true
	if op in ["eq","neq","in"]: return kind not in ["array","object","reference_list"]
	if op in ["gt","gte","lt","lte"]: return kind in ["integer","number","date","timestamp"]
	if op in ["before","after"]: return kind in ["date","timestamp"]
	if op in ["contains","not_contains","like"]: return kind in ["string","markdown","enum","item_ref"]
	return false

static func _validate_operand(kind: String, op: String, value) -> String:
	if op in ["is_empty","is_not_empty","is_missing","is_null"]: return ""
	if op == "in":
		if not value is Array: return "operator 'in' requires an array"
		for entry in value:
			var element_error: String = _validate_operand(kind, "eq", entry)
			if not element_error.is_empty(): return element_error
		return ""
	if value == null and op in ["eq","neq"]: return "null comparison must use is_null or is_missing"
	if kind == "boolean" and not value is bool: return "boolean comparison requires a boolean operand"
	if kind in ["integer","number"] and not (value is int or value is float): return "numeric comparison requires a numeric operand"
	if kind == "integer" and value is float and value != floor(value): return "integer comparison requires an integral operand"
	if kind in ["integer","number"] and not is_finite(float(value)): return "numeric comparison requires a finite operand"
	if kind in ["string","markdown","enum","date","timestamp","item_ref"] and not value is String: return "text comparison requires a string operand"
	return ""

static func _matches(actual, op: String, expected) -> bool:
	match op:
		"eq": return actual == expected
		"neq": return actual != expected
		"in": return expected is Array and expected.has(actual)
	return false

static func _sort(specs_value, registry: TypeRegistry) -> Dictionary:
	if not specs_value is Array: return {"error":"sort must be an array"}
	var parts: PackedStringArray = PackedStringArray()
	var bindings: Array = []
	for value in specs_value:
		if not value is Dictionary: return {"error":"sort entries must be objects"}
		var spec: Dictionary = value
		for key in spec:
			if str(key) not in ["field","field_key","type_id","dir","nulls"]: return {"error":"unknown sort property '%s'" % key}
		for string_key in ["field","field_key","type_id","dir","nulls"]:
			if spec.has(string_key) and not spec[string_key] is String: return {"error":"sort %s must be a string" % string_key}
		if spec.has("field") and spec.has("field_key") and str(spec.field) != str(spec.field_key): return {"error":"sort has conflicting field and field_key"}
		var requested_direction: String = str(spec.get("dir", "asc")).to_lower()
		if requested_direction not in ["asc","desc"]: return {"error":"sort direction must be asc or desc"}
		var direction: String = "DESC" if requested_direction == "desc" else "ASC"
		var nulls: String = str(spec.get("nulls", "last")).to_lower()
		if nulls not in ["first","last"]: return {"error":"sort nulls must be first or last"}
		var field: String = str(spec.get("field_key", spec.get("field", "")))
		var type_id: String = str(spec.get("type_id", ""))
		var expression: String
		var local_bindings: Array = []
		if field in DERIVED_FIELDS:
			var cases: Array = _derived_cases(field, registry.all_revisions() if type_id.is_empty() else registry.revisions_for_type(type_id), registry.is_legacy())
			if cases.is_empty(): return {"error":"derived sort has no pinned semantics"}
			expression = "CASE " + " ".join(PackedStringArray(cases)) + " END"
		elif type_id.is_empty():
			var why: String = DocketDBFilter.reject_reason(field)
			if not why.is_empty(): return {"error":why}
			expression = field
		elif field in ["type","status"]:
			var scoped_revisions: Array = registry.revisions_for_type(type_id)
			if scoped_revisions.is_empty(): return {"error":"sort type identity '%s' is not present in this project" % type_id}
			if registry.is_legacy():
				expression = "CASE WHEN type=? THEN %s END" % field
				local_bindings = [str(scoped_revisions[0].definition.slug)]
			else:
				expression = "CASE WHEN type_id=? THEN %s END" % ("type_id" if field == "type" else "status")
				local_bindings = [type_id]
		else:
			var revisions: Array = registry.revisions_for_type(type_id)
			if registry.is_legacy():
				var legacy_why: String = DocketDBFilter.reject_reason(field)
				if not legacy_why.is_empty(): return {"error":legacy_why}
				expression = "CASE WHEN type=? THEN %s END" % field
				local_bindings = [str(revisions[0].definition.slug)]
				parts.append("(%s IS NULL) %s" % [expression,"ASC" if nulls == "last" else "DESC"])
				parts.append("%s %s" % [expression,direction])
				bindings.append_array(local_bindings); bindings.append_array(local_bindings)
				continue
			var check: Dictionary = _custom(field, {"op":"is_not_empty"}, revisions, type_id)
			if check.has("error"): return check
			var pins: Array = []
			for revision in revisions:
				for descriptor in revision.definition.fields:
					if str(descriptor.key) == field: pins.append(str(revision.id))
			var pin_sql: Dictionary = _in_sql("type_revision", pins)
			expression = "CASE WHEN type_id=? AND %s THEN json_extract(fields_json,?) END" % pin_sql.sql
			local_bindings = [type_id] + pin_sql.bindings + ["$.%s" % field]
		parts.append("(%s IS NULL) %s" % [expression,"ASC" if nulls == "last" else "DESC"])
		parts.append("%s %s" % [expression,direction])
		bindings.append_array(local_bindings); bindings.append_array(local_bindings)
	parts.append("id ASC")
	return {"sql":",".join(parts),"bindings":bindings}

static func _derived_cases(field: String, revisions: Array, legacy: bool = false) -> Array:
	var cases: Array = []
	for revision in revisions:
		for state in revision.definition.lifecycle.states:
			var value = state.get("state_category", "") if field == "state_category" else (state.get("state_outcome", "") if field == "state_outcome" else revision.definition.lifecycle.terminal_states.has(state.key))
			cases.append("WHEN %s=%s AND status=%s THEN %s" % ["type" if legacy else "type_revision",_quote(revision.definition.slug if legacy else revision.id),_quote(state.key),_quote(value)])
	return cases

static func _quote(value) -> String:
	# Values originate in validated immutable definitions, but quoting still keeps
	# the generated CASE expression structurally separate from their content.
	return "'%s'" % str(value).replace("'", "''")
