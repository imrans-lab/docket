extends RefCounted
## Builds presentation records from the current schema-shaped registry adapter.
## Records carry stable identity separately from labels so sorting and saved
## preferences remain deterministic when labels collide or change.


static func from_schema(schema: Dictionary, project: String = "", counts: Dictionary = {}) -> Array:
	var result: Array = []
	var types: Dictionary = schema.get("types", {})
	for slug_value in types:
		var slug := str(slug_value)
		var definition: Dictionary = types[slug_value]
		var lifecycle := str(definition.get("lifecycle", "active"))
		var schema_fields: Array = _fields_for_definition(definition)
		var schema_kinds: Dictionary = {}
		for schema_field in schema_fields: schema_kinds[str(schema_field)] = "legacy"
		result.append({
			"id": str(definition.get("id", slug)),
			"key": identity(project, str(definition.get("id", slug))),
			"slug": slug,
			"label": str(definition.get("label", slug.capitalize())),
			"description": str(definition.get("description", "")),
			"use_when": str(definition.get("use_when", "")),
			"aliases": definition.get("aliases", []).duplicate(),
			"project": project,
			"item_count": int(counts.get(slug, 0)),
			"deprecated": lifecycle == "deprecated" or bool(definition.get("deprecated", false)),
			"states": definition.get("states", []).duplicate(),
			"fields": schema_fields,
			"field_kinds": schema_kinds,
		})
	return sorted(result)

# `registry` is a TypeRegistry, left untyped so the UI can use this file
# without loading the storage classes.
static func from_registry(registry, counts: Dictionary = {}) -> Array:
	var checked: Dictionary = from_registry_checked(registry, counts)
	return checked.records

static func from_registry_checked(registry, counts: Dictionary = {}) -> Dictionary:
	return from_descriptors(registry.get_project_name(), registry.list_types(true), counts)

## Catalog records of `project`'s type descriptors (as TypeRegistry.list_types
## gives them, with definitions): {records, error}.
static func from_descriptors(project: String, values: Array, counts: Dictionary = {}) -> Dictionary:
	var result: Array = []
	if values.size() == 1 and values[0] is Dictionary and values[0].has("error"): return {"records":[],"error":str(values[0].error)}
	for value in values:
		if not value is Dictionary: return {"records":[],"error":"type registry returned a malformed catalog entry"}
		if value.has("error"): return {"records":[],"error":str(value.error)}
		var descriptor: Dictionary = value
		var definition: Dictionary = descriptor.definition
		var states: Array = []
		for state in definition.lifecycle.states: states.append(str(state.key))
		var fields: Array = []
		var field_kinds: Dictionary = {}
		for field in definition.fields:
			fields.append(str(field.key)); field_kinds[str(field.key)] = str(field.type)
		result.append({"id":descriptor.id,"key":identity(project,str(descriptor.id)),"slug":descriptor.slug,"label":definition.label,"description":definition.description,"use_when":definition.get("use_when", ""),"aliases":definition.get("aliases", []),"project":project,"item_count":int(counts.get(descriptor.slug, 0)),"deprecated":descriptor.lifecycle == "deprecated","states":states,"fields":fields,"field_kinds":field_kinds,"revision":descriptor.current_revision})
	return {"records":sorted(result),"error":""}


static func identity(project: String, type_id: String) -> String:
	# JSON encoding avoids delimiter ambiguity while remaining stable in prefs.
	return JSON.stringify([project, type_id])


static func find_by_key(records: Array, key: String) -> Dictionary:
	for record_value in records:
		var record: Dictionary = record_value
		if str(record.get("key", "")) == key:
			return record
	return {}


static func sorted(records: Array) -> Array:
	var copy := records.duplicate(true)
	copy.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_keys := [str(a.get("label", "")).to_lower(), str(a.get("project", "")).to_lower(), str(a.get("slug", "")).to_lower(), str(a.get("id", ""))]
		var b_keys := [str(b.get("label", "")).to_lower(), str(b.get("project", "")).to_lower(), str(b.get("slug", "")).to_lower(), str(b.get("id", ""))]
		for i in a_keys.size():
			if a_keys[i] != b_keys[i]:
				return a_keys[i] < b_keys[i]
		return false
	)
	return copy


static func filter(records: Array, search: String, include_deprecated: bool = false) -> Array:
	var needle := search.strip_edges().to_lower()
	var matches: Array = []
	for record_value in sorted(records):
		var record: Dictionary = record_value
		if bool(record.get("deprecated", false)) and not include_deprecated:
			continue
		var searchable := PackedStringArray([
			str(record.get("label", "")), str(record.get("slug", "")),
			str(record.get("description", "")), str(record.get("use_when", "")),
		])
		for alias in record.get("aliases", []):
			searchable.append(str(alias))
		if needle.is_empty() or " ".join(searchable).to_lower().contains(needle):
			matches.append(record)
	return matches


static func _fields_for_definition(definition: Dictionary) -> Array:
	var seen := {}
	var fields: Array = []
	for key in definition.get("required_fields", []):
		if not seen.has(str(key)):
			seen[str(key)] = true
			fields.append(str(key))
	for key in definition.get("optional_fields", []):
		if not seen.has(str(key)):
			seen[str(key)] = true
			fields.append(str(key))
	fields.sort()
	return fields
