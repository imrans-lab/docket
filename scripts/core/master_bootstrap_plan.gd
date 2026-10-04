extends RefCounted
class_name MasterBootstrapPlan
## Pure proposal over authoritative parser snapshots; acquisition/replay/apply
## belong to the caller. Null current means absent, not an existing empty file.

const SECTIONS := ["items", "events", "comments", "links", "attachments", "secrets", "secret_versions", "saved_queries", "type_defs", "type_def_versions"]

static func plan(current: Variant, shipment: Dictionary, baseline: Variant, ever_shipped: Array, declared_schema: Dictionary) -> Dictionary:
	var error := _validate(shipment)
	if not error.is_empty(): return {"error":"Shipment: " + error}
	if current != null:
		if not current is Dictionary: return {"error":"Current snapshot must be an object or null"}
		error = _validate(current)
		if not error.is_empty(): return {"error":"Current: " + error}
	if current is Dictionary and not JSONLParser._item_registry_diagnostics(current).is_empty():
		return {"error":"Current has unresolved item pins"}
	var seen := {}
	for id in ever_shipped:
		if not id is String or id.is_empty(): return {"error":"Ever-shipped IDs must be nonempty strings"}
		seen[id] = true
	var limitations: Array[String] = []
	var previous := {}
	if baseline is Dictionary:
		error = _validate(baseline)
		if error.is_empty() and JSONLParser._item_registry_diagnostics(baseline).is_empty():
			previous = _items(baseline)
		else: limitations.append("Baseline unavailable: invalid snapshot or pins " + error)
	elif baseline != null: limitations.append("Baseline unavailable: expected parsed object")
	else: limitations.append("Baseline unavailable: no previous shipment")
	for id in previous: seen[id] = true
	var merged: Dictionary = shipment.duplicate(true) if current == null else current.duplicate(true)
	var capabilities := _capabilities(merged, declared_schema)
	if capabilities.has("error"): return {"error":"Capabilities: " + str(capabilities.error)}
	var inserted: Array[String] = []
	var updated: Array[String] = []
	var unchanged: Array[String] = []
	var deleted: Array[String] = []
	var conflicts: Array = []
	if current != null and current.meta.version != shipment.meta.version:
		conflicts.append({"reason":"format_mismatch"})
	var offered := _items(shipment)
	var ids: Array = offered.keys()
	ids.sort()
	if current == null:
		var diagnostics := JSONLParser._item_registry_diagnostics(shipment)
		if not diagnostics.is_empty(): return {"error":"Shipment has unresolved item pins", "diagnostics":diagnostics}
		for id in ids: inserted.append(id)
		if _head(shipment) > int(shipment.meta.get("event_counter", 0)): merged.meta.event_counter = _head(shipment)
	else:
		var existing := _items(current)
		var positions := {}
		for i in merged.items.size(): positions[merged.items[i].id] = i
		for id: String in ids:
			var item: Dictionary = offered[id]
			if existing.has(id) and _equal(existing[id], item):
				unchanged.append(id)
				continue
			if not existing.has(id) and seen.has(id):
				deleted.append(id)
				continue
			var reason := ""
			if current.meta.version != shipment.meta.version: reason = "format_mismatch"
			elif str(current.meta.version) == "2.0.0": reason = _pin_error(item, shipment, current)
			if reason.is_empty() and existing.has(id):
				if not previous.has(id): reason = "baseline_unavailable"
				elif not _equal(existing[id], previous[id]): reason = "customized"
			if not reason.is_empty():
				conflicts.append({"id":id, "reason":reason})
				continue
			var replacement: Dictionary = item.duplicate(true)
			if existing.has(id):
				replacement.erase("retrieval_count")
				if existing[id].has("retrieval_count"): replacement.retrieval_count = existing[id].retrieval_count
				merged.items[positions[id]] = replacement
				updated.append(id)
			else:
				merged.items.append(replacement)
				inserted.append(id)
		# New items in lexical ID order, then source order within each item.
		# Stored history is never sorted or rewritten; the persisted head wins
		# even when the events that consumed earlier IDs have been deleted.
		var head := _head(current)
		for id in inserted:
			for event: Dictionary in shipment.events:
				if event.item_id != id: continue
				var imported: Dictionary = event.duplicate(true)
				if head >= 9223372036854775806: return {"error":"Event ID space exhausted"}
				head += 1
				imported.eid = head
				merged.events.append(imported)
		if head != _head(current): merged.meta.event_counter = head
	for id in ids: seen[id] = true
	var next_ids: Array = seen.keys()
	next_ids.sort()
	return {"merged":merged, "inserted":inserted, "updated":updated, "unchanged":unchanged, "deleted":deleted, "conflicts":conflicts, "capability_gaps":capabilities.gaps, "limitations":limitations, "next_baseline":shipment.duplicate(true), "next_ever_shipped":next_ids}

static func _items(snapshot: Dictionary) -> Dictionary:
	var result := {}
	for item: Dictionary in snapshot.items: result[item.id] = item
	return result

static func _equal(left: Dictionary, right: Dictionary) -> bool:
	var a := left.duplicate(true)
	var b := right.duplicate(true)
	for value in [a, b]:
		value.erase("retrieval_count")
		if value.has("tags"):
			var tags := {}
			for tag in value.tags: tags[tag] = true
			var ordered: Array = tags.keys()
			ordered.sort()
			value.tags = ordered
	return a == b

static func _head(snapshot: Dictionary) -> int:
	var head := int(snapshot.meta.get("event_counter", 0))
	for event: Dictionary in snapshot.events: head = maxi(head, int(event.get("eid", 0)))
	return head

static func _validate(snapshot: Dictionary) -> String:
	if not str(snapshot.get("error", "")).is_empty(): return str(snapshot.error)
	if not str(snapshot.get("read_only_reason", "")).is_empty(): return str(snapshot.read_only_reason)
	if not snapshot.get("meta") is Dictionary or not JSONLParser.validate_meta(snapshot.meta): return "Invalid parsed metadata"
	if str(snapshot.meta.version) not in JSONLParser.SUPPORTED_VERSIONS: return "Unsupported format"
	for section in SECTIONS:
		if not snapshot.get(section) is Array: return "Missing parsed section: " + section
		for record in snapshot[section]:
			if not record is Dictionary: return "Non-object in " + section
	if not snapshot.get("issues", []).is_empty(): return "Snapshot has parse issues"
	var ids := {}
	for item: Dictionary in snapshot.items:
		if not item.get("id") is String or item.id.is_empty() or ids.has(item.id): return "Invalid or duplicate item identity"
		ids[item.id] = true
	# Reject ambiguous identities in every retained record family, not only items.
	var identity_fields := {"comments":["id"], "attachments":["id"], "links":["from_id", "to_id", "relation"], "secrets":["handle"], "secret_versions":["handle", "version"], "saved_queries":["name"]}
	for section in identity_fields:
		var identities := {}
		for record: Dictionary in snapshot[section]:
			var parts: Array = []
			for field in identity_fields[section]:
				if not record.has(field): return "Missing identity in " + section
				parts.append(record[field])
			var identity := JSONLSerializer._json_value(parts)
			if identities.has(identity): return "Duplicate identity in " + section
			identities[identity] = true
	var counter: Variant = snapshot.meta.get("event_counter", 0)
	if not _natural(counter): return "Invalid event counter"
	var eids := {}
	var sequences := {}
	for event: Dictionary in snapshot.events:
		if not event.get("item_id") is String or not ids.has(event.item_id): return "Invalid event owner"
		if not _natural(event.get("seq")): return "Invalid event sequence"
		var key := "%s:%s" % [event.item_id, event.seq]
		if sequences.has(key): return "Duplicate per-item event sequence"
		sequences[key] = true
		if event.has("eid"):
			if not _natural(event.eid) or event.eid == 0 or eids.has(event.eid): return "Invalid or duplicate event ID"
			eids[event.eid] = true
	if str(snapshot.meta.version) == "2.0.0":
		var error := JSONLParser._validate_registry_records(snapshot)
		if not error.is_empty(): return error
		for revision: Dictionary in snapshot.type_def_versions:
			error = TypeRegistry.validate_definition(revision.definition)
			if not error.is_empty(): return error
	return JSONLParser._validate_record_dependencies(snapshot)

static func _natural(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value >= 0 and value == floor(value) and value < 9223372036854775807

static func _pin_error(item: Dictionary, shipment: Dictionary, current: Dictionary) -> String:
	var type_id := str(item.get("type_id", ""))
	var revision_id := str(item.get("type_revision", ""))
	var shipped_revision := {}
	var stored_revision := {}
	var stored_type := {}
	for record: Dictionary in shipment.type_def_versions:
		if record.id == revision_id: shipped_revision = record
	for record: Dictionary in current.type_def_versions:
		if record.id == revision_id: stored_revision = record
	for record: Dictionary in current.type_defs:
		if record.id == type_id: stored_type = record
	if stored_type.is_empty() or shipped_revision.is_empty() or stored_revision.is_empty(): return "missing_pin"
	if stored_revision.type_id != type_id or shipped_revision.type_id != type_id or stored_type.slug != item.type or stored_revision.definition != shipped_revision.definition: return "incompatible_pin"
	var states: Array = []
	for state in stored_revision.definition.lifecycle.states: states.append(state.key)
	return "" if states.has(item.status) else "incompatible_pin"

static func _capabilities(snapshot: Dictionary, schema: Dictionary) -> Dictionary:
	var error := TypeRegistryBootstrap.validate_schema(schema)
	if not error.is_empty(): return {"error":error}
	var descriptors: Array = []
	if str(snapshot.meta.version) == "1.0.0":
		for revision in TypeRegistryBootstrap.records(schema).type_def_versions:
			descriptors.append({"slug":revision.definition.slug, "definition":revision.definition})
	else:
		for record: Dictionary in snapshot.type_defs:
			for revision: Dictionary in snapshot.type_def_versions:
				if revision.id == record.current_revision:
					descriptors.append({"slug":record.slug, "definition":revision.definition})
	return SchemaCapabilityGaps.compare_definitions(schema, descriptors)
