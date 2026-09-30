extends RefCounted
class_name ColumnBinding
## Typed result columns of the query grid. Two binding forms exist:
##   type binding    {"type": slug, "field_key", "label", "kind"} — what the
##                   Columns chooser offers; it shows the field for every loaded
##                   project whose item type has that slug and declares the field.
##   project binding {"project", "type_id", "field_key", "label", "kind"} — bound
##                   to one type identity (and one project unless "project" is
##                   empty); saved queries and Work entries may still hold these.

const DERIVED := ["state_category", "state_outcome", "is_terminal"]


## Chooser entries for catalog `records`: each type slug once, its fields once
## (first declaring project's label), then its derived state columns, however
## many projects carry the type.
static func candidates(records: Array, state: AppState) -> Array:
	var order: Array[String] = []
	var groups: Dictionary = {}  # slug → {label, fields: Array, seen: {field_key: true}}
	for record_value in records:
		var record: Dictionary = record_value
		var registry := state.get_type_registry(str(record.project))
		if registry == null:
			continue
		var type: Dictionary = registry.resolve_type_ref(str(record.id))
		if type.has("error"):
			continue
		var slug := str(record.slug)
		if not groups.has(slug):
			order.append(slug)
			groups[slug] = {"label": str(record.label), "fields": [], "seen": {}}
		var group: Dictionary = groups[slug]
		for descriptor_value in type.definition.fields:
			var descriptor: Dictionary = descriptor_value
			if descriptor.key in TypeRegistry.UNIVERSAL_MUTABLE or group.seen.has(descriptor.key):
				continue
			group.seen[descriptor.key] = true
			(group.fields as Array).append({"type": slug, "field_key": descriptor.key, "label": "%s — %s" % [group.label, descriptor.get("label", descriptor.key)], "kind": descriptor.type})
	var result: Array = []
	for slug in order:
		var group: Dictionary = groups[slug]
		result.append_array(group.fields)
		for derived: String in DERIVED:
			result.append({"type": slug, "field_key": derived, "label": "%s — %s" % [group.label, derived], "kind": "string"})
	return result


## Identity of a binding: equal keys name the same column.
static func key(binding: Dictionary) -> String:
	return JSON.stringify([str(binding.get("type", "")), str(binding.get("project", "")), str(binding.get("type_id", "")), str(binding.get("field_key", ""))])


static func same(left: Dictionary, right: Dictionary) -> bool:
	return key(left) == key(right)


## Whether the column applies to a row of `project` whose pinned semantics are
## `resolved` (TypeRegistry.resolve_item, without error).
static func applies(binding: Dictionary, project: String, resolved: Dictionary) -> bool:
	var type_id := str(binding.get("type_id", ""))
	if type_id.is_empty():
		return str(binding.get("type", "")) == str(resolved.definition.slug)
	var bound_project := str(binding.get("project", ""))
	return (bound_project.is_empty() or bound_project == project) and str(resolved.revision.type_id) == type_id
