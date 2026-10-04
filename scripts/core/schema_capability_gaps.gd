extends RefCounted
class_name SchemaCapabilityGaps
## Read-only comparison of required effective-schema semantics to stored types.

static func compare(registry: TypeRegistry) -> Dictionary:
	if registry == null: return {"error":"Type registry is unavailable"}
	var error := registry.refresh_if_changed()
	if not error.is_empty(): return {"error":error}
	return compare_definitions(TypeRegistryBootstrap.effective_schema(), registry.list_types(true))

static func compare_definitions(declared_schema: Dictionary, persisted_definitions: Array) -> Dictionary:
	var error := TypeRegistryBootstrap.validate_schema(declared_schema)
	if not error.is_empty(): return {"error":error}
	var expected := TypeRegistryBootstrap.records(declared_schema)
	var available := {}
	for descriptor in persisted_definitions:
		if not descriptor is Dictionary: return {"error":"Invalid persisted type descriptor"}
		if descriptor.has("error"): return {"error":descriptor.error}
		if not descriptor.get("slug") is String or not descriptor.get("definition") is Dictionary: return {"error":"Invalid persisted type descriptor"}
		error = TypeRegistry.validate_definition(descriptor.definition)
		if not error.is_empty(): return {"error":error}
		if available.has(descriptor.slug): return {"error":"Duplicate persisted type slug"}
		available[descriptor.slug] = descriptor.definition
	var gaps: Array[String] = []
	for revision in expected.type_def_versions:
		var definition: Dictionary = revision.definition
		var slug: String = definition.slug
		if not available.has(slug):
			gaps.append("missing_type:%s" % slug)
			continue
		var fields := {}
		for field in available[slug].fields: fields[field.key] = field.type
		for field in definition.fields:
			if not fields.has(field.key): gaps.append("missing_field:%s.%s" % [slug,field.key])
			elif fields[field.key] != field.type: gaps.append("field_kind:%s.%s:%s!=%s" % [slug,field.key,fields[field.key],field.type])
		var states: Array = []
		for state in available[slug].lifecycle.states: states.append(state.key)
		for state in definition.lifecycle.states:
			if not states.has(state.key): gaps.append("missing_state:%s.%s" % [slug,state.key])
	gaps.sort()
	return {"gaps":gaps}
