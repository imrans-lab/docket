extends RefCounted
class_name ColumnBinding
## Result columns of the query grid. A column is a field key: an item-level key
## every row carries (ITEM_COLUMNS), or a derived state key or type-declared
## field, which a row shows when its pinned type declares it
## (TypeRegistry.declared_value). Saved queries may hold Dictionary bindings
## from older builds; key() reads the field key they carry.

## Item-level columns, in the order the chooser offers them.
const ITEM_COLUMNS: Array[String] = ["id", "project", "type", "status", "priority", "severity", "storage", "title", "description", "assigned_to", "directed_to", "created_by", "created_at", "updated_at", "tags", "parent", "blocked_by"]


## The field key of a saved column: the String itself, or a Dictionary
## binding's "field_key"; "" for anything else.
static func key(column: Variant) -> String:
	if column is Dictionary:
		return str((column as Dictionary).get("field_key", ""))
	return column if column is String else ""


## Whether a row reads `field_key` through its pinned type, not from the item.
static func is_typed(field_key: String) -> bool:
	return not ITEM_COLUMNS.has(field_key)


static func title(field_key: String) -> String:
	return {"id": "ID", "priority": "Pri"}.get(field_key, field_key.capitalize())


## Chooser entries {key, label} for the item-level and derived columns.
static func item_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for field_key: String in ITEM_COLUMNS + RegistryQuery.DERIVED_FIELDS:
		entries.append({"key": field_key, "label": title(field_key)})
	return entries


## Chooser entries {key, label} for the fields the types of catalog `records`
## declare: each field once, by label, naming the type slugs that declare it.
static func type_entries(records: Array, state: AppState) -> Array[Dictionary]:
	var fields: Dictionary = {}  # field key → {label, types: Array}
	for record_value in records:
		var record: Dictionary = record_value
		var registry := state.get_type_registry(str(record.project))
		var type: Dictionary = registry.resolve_type_ref(str(record.id)) if registry != null else {"error": "no registry"}
		if type.has("error"):
			continue
		for descriptor_value in type.definition.fields:
			var descriptor: Dictionary = descriptor_value
			var field_key := str(descriptor.key)
			if not is_typed(field_key):
				continue
			if not fields.has(field_key):
				var label := str(descriptor.get("label", field_key))
				fields[field_key] = {"label": title(field_key) if label == field_key else label, "types": []}
			var types: Array = fields[field_key].types
			if not types.has(str(record.slug)):
				types.append(str(record.slug))
	var entries: Array[Dictionary] = []
	for field_key: String in fields:
		var types: Array = fields[field_key].types
		var hint := ", ".join(PackedStringArray(types.slice(0, 3)))
		if types.size() > 3:
			hint += " +%d" % (types.size() - 3)
		entries.append({"key": field_key, "label": "%s — %s" % [fields[field_key].label, hint]})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.label).naturalnocasecmp_to(str(b.label)) < 0)
	return entries
