extends RefCounted
class_name ItemRows
## Converts items-table rows into item Dictionaries, completely (DocketDB
## get_item and the "full" query details) or for a chosen set of item keys
## (the "rows" query detail, read by the results grid).
##
## A "rows" item carries only the keys asked for plus ROW_KEYS, which row
## identity, type resolution and storage need. Its values are converted
## exactly as in a complete item. Tags, events and links are each loaded for
## every row in one statement, so the statement count does not grow with rows.

## Keys every "rows" item carries.
const ROW_KEYS := ["id", "type", "status", "type_id", "type_revision", "storage"]
## Related keys loaded from their own tables: key -> [SELECT with a WHERE
## placeholder, owner column]. Each orders an item's entries as a complete item
## does (DocketDB get_events, get_links), grouped by owner.
const _RELATED := {
	"tags": ["SELECT item_id AS owner, tag FROM item_tags%s ORDER BY item_id, tag;", "item_id"],
	"events": ["SELECT item_id AS owner, event_type, actor, timestamp, note FROM item_events%s ORDER BY item_id, timestamp, id;", "item_id"],
	"links": ["SELECT from_id AS owner, to_id, relation FROM item_links%s ORDER BY from_id, id;", "from_id"],
}

enum Kind { TEXT, STORAGE, ENVELOPE, INT, NULLABLE, FLAG, JSON_ARRAY, JSON_DICT }

## Item key → conversion, in the key order of a complete item.
const _KINDS := {
	"id": Kind.TEXT, "type": Kind.TEXT, "status": Kind.TEXT, "title": Kind.TEXT,
	"type_id": Kind.TEXT, "type_revision": Kind.TEXT, "storage": Kind.STORAGE,
	"fields": Kind.ENVELOPE, "extras": Kind.ENVELOPE,
	"description": Kind.TEXT, "created_at": Kind.TEXT, "updated_at": Kind.TEXT,
	"created_by": Kind.TEXT, "assigned_to": Kind.TEXT, "directed_to": Kind.TEXT,
	"priority": Kind.INT, "severity": Kind.INT, "retrieval_count": Kind.INT,
	"research_cost": Kind.INT, "quality": Kind.INT,
	"resolution": Kind.NULLABLE, "environment": Kind.NULLABLE, "repro_steps": Kind.NULLABLE,
	"assumed": Kind.NULLABLE, "corrected": Kind.NULLABLE, "findings": Kind.NULLABLE,
	"answer": Kind.NULLABLE, "occurred_at": Kind.NULLABLE, "detected_at": Kind.NULLABLE,
	"reported_at": Kind.NULLABLE, "why_chain": Kind.NULLABLE, "significant_events": Kind.NULLABLE,
	"contributing_factors": Kind.NULLABLE, "value": Kind.NULLABLE, "component": Kind.NULLABLE,
	"key": Kind.NULLABLE, "topic": Kind.NULLABLE, "subtopic": Kind.NULLABLE,
	"confidence": Kind.NULLABLE, "surprise": Kind.NULLABLE, "surfaced_from": Kind.NULLABLE,
	"blocked_by": Kind.NULLABLE, "parent": Kind.NULLABLE, "test_setup": Kind.NULLABLE,
	"test_steps": Kind.NULLABLE, "expected_result": Kind.NULLABLE, "last_reviewed": Kind.NULLABLE,
	"command": Kind.NULLABLE, "usage": Kind.NULLABLE, "prompt_text": Kind.NULLABLE,
	"preconditions": Kind.NULLABLE, "summary": Kind.NULLABLE, "article": Kind.NULLABLE,
	"parameters": Kind.NULLABLE, "steps": Kind.NULLABLE, "outcome": Kind.NULLABLE,
	"target": Kind.NULLABLE, "source": Kind.NULLABLE, "pristine_hash": Kind.NULLABLE,
	# Plugin-shipped skills metadata: 0/1 flags and JSON-encoded values.
	"customised": Kind.FLAG, "deprecated": Kind.FLAG,
	"tool_deps": Kind.JSON_ARRAY, "optimization": Kind.JSON_DICT,
	"pristine_content": Kind.JSON_DICT, "unsatisfied_deps": Kind.JSON_ARRAY,
}


## The scalar keys of an item built from `row`: every key when `keys` is
## empty, else ROW_KEYS and those of `keys` that are items-table values.
static func scalars(row: Dictionary, keys: Dictionary = {}) -> Dictionary:
	var item := {}
	var id: String = str(row.get("id", ""))
	for key: String in _KINDS:
		if not keys.is_empty() and not keys.has(key): continue
		match _KINDS[key]:
			Kind.TEXT:
				item[key] = str(row.get(key, ""))
			Kind.STORAGE:
				item[key] = str(row.get(key, ItemStorage.DURABLE))
			Kind.ENVELOPE:
				var decoded = JSON.parse_string(str(row.get("%s_json" % key, "{}")))
				if decoded is Dictionary:
					item[key] = decoded
				else:
					item[key] = {}
					item["_storage_error"] = "malformed %s_json for item %s" % [key, id]
			Kind.INT:
				item[key] = int(row.get(key, 0))
			Kind.NULLABLE:
				var val = row.get(key)
				item[key] = str(val) if val != null else ""
			Kind.FLAG:
				item[key] = int(row.get(key, 0)) != 0
			Kind.JSON_ARRAY, Kind.JSON_DICT:
				var want_array: bool = _KINDS[key] == Kind.JSON_ARRAY
				var raw = row.get(key)
				var parsed = JSON.parse_string(str(raw)) if raw != null and not str(raw).is_empty() else null
				if want_array: item[key] = parsed if parsed is Array else []
				else: item[key] = parsed if parsed is Dictionary else {}
	return item


## The wanted-key set for scalars(): ROW_KEYS plus `keys`.
static func key_set(keys: PackedStringArray) -> Dictionary:
	var wanted := {}
	for key in ROW_KEYS: wanted[key] = true
	for key in keys: wanted[key] = true
	return wanted


## Items-table columns to select for `wanted`, limited to `existing` columns.
static func select_list(wanted: Dictionary, existing: Array) -> String:
	var columns := PackedStringArray()
	for key: String in _KINDS:
		if not wanted.has(key): continue
		var column: String = "%s_json" % key if _KINDS[key] == Kind.ENVELOPE else key
		if existing.has(column): columns.append(column)
	return ",".join(columns)


## "rows" items for query `rows` selected with select_list(), plus each
## related key asked for, loaded for every item matching `where` in one
## statement per related table.
static func items(db: DocketDB, rows: Array, wanted: Dictionary, where: String, bindings: Array) -> Array:
	var result: Array = []
	for row in rows: result.append(scalars(row, wanted))
	for key: String in _RELATED:
		if not wanted.has(key): continue
		var owner_column: String = _RELATED[key][1]
		var filter := "" if where.is_empty() else " WHERE %s IN (SELECT id FROM items WHERE %s)" % [owner_column, where]
		var by_owner := {}
		for related_row: Dictionary in db._exec_select(str(_RELATED[key][0]) % filter, bindings):
			var owner := str(related_row.owner)
			if not by_owner.has(owner): by_owner[owner] = []
			(by_owner[owner] as Array).append(_related_entry(key, related_row))
		for item: Dictionary in result:
			item[key] = by_owner.get(item.id, [])
	return result


## One entry of related key `key`, converted as a complete item converts it.
static func _related_entry(key: String, row: Dictionary) -> Variant:
	match key:
		"tags":
			return str(row.tag)
		"events":
			return {
				"event_type": str(row.get("event_type", "")),
				"actor": str(row.get("actor", "")),
				"timestamp": str(row.get("timestamp", "")),
				"note": str(row.get("note", "")),
			}
	return {"to": str(row.get("to_id", "")), "relation": str(row.get("relation", ""))}


## Shortest unique display prefix (at least 7 characters) of each UUID7 id in
## `wanted`, among `all_ids`; other ids map to themselves. Prefixes compare
## case-insensitively, as SQL LIKE does.
static func shortest_prefixes(all_ids: Array, wanted: Array) -> Dictionary:
	var sorted := PackedStringArray()
	for id in all_ids: sorted.append(str(id).to_lower())
	sorted.sort()
	var result := {}
	for id_value in wanted:
		var full_id := str(id_value)
		if not DocketDB._is_uuid7(full_id):
			result[full_id] = full_id
			continue
		var lower := full_id.to_lower()
		var at := sorted.bsearch(lower)
		var shared := 0
		if at > 0: shared = maxi(shared, _common_prefix(lower, sorted[at - 1]))
		var next := at + 1 if at < sorted.size() and sorted[at] == lower else at
		if next < sorted.size(): shared = maxi(shared, _common_prefix(lower, sorted[next]))
		result[full_id] = full_id.substr(0, clampi(shared + 1, 7, full_id.length()))
	return result


static func _common_prefix(a: String, b: String) -> int:
	var n := mini(a.length(), b.length())
	for i in n:
		if a[i] != b[i]: return i
	return n
