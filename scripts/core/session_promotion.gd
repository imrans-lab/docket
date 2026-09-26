extends RefCounted
class_name SessionPromotion
## Copies chosen records from a session project (session_file or memory) into a
## durable project. Nothing is automatic and nothing else moves: only the listed
## items are written, and the source keeps its copies.
##
## Each record travels through the move path: DocketDB.export_item_full_checked,
## DocketMove.type_import_plan and DocketMove.import_checked (which writes the
## item, its links and, when asked, its comments and attachments). Unlike a
## move, the copy gets a fresh id, the source is not deleted, and the session's
## event history (claims, heartbeats, edits) stays behind. The copy's only event
## is "promoted", whose note states the provenance for the GUI's event list.
## The same provenance is stored machine-readably in the item's extras under
## PROVENANCE_KEY: origin project name and storage mode, original item id,
## promoted_at, promoted_by (a declared identity, not authenticated), and the
## references it could not resolve.
##
## References (parent, blocked_by, link targets, item_ref and reference_list
## fields) are mapped as follows. A reference to another item in the promoted
## set, bare or qualified with the source project, becomes
## "<target>:<new id>". Any other reference into the source project is kept,
## qualified as "<source>:<id>", and reported as unresolved. References already
## qualified with a different project are left as they are.
##
## Callers: DocketPromote (MCP) and PromoteDialog (GUI). preview() computes the
## same plan as promote() without writing, so the GUI can show the unresolved
## list before the user confirms.

const EVENT_TYPE := "promoted"
const PROVENANCE_KEY := "promoted_from"


## What promote() would do, without writing: {"promote": [{old_id, new_id,
## title}], "unresolved": [...], ...} or {"error"}. The new ids shown here are
## provisional; promote() allocates its own.
static func preview(project_dbs: Dictionary, source: String, ids: Array, target: String, options: Dictionary) -> Dictionary:
	var plan := _plan(project_dbs, source, ids, target, options)
	if plan.has("error"):
		return plan
	return _summary(plan, false)


## Writes the planned copies into the target as one canonical mutation, so
## either every selected record lands or none does.
## `options`: promoted_by (required), include_comments, include_attachments,
## import_definition (bool each).
static func promote(project_dbs: Dictionary, source: String, ids: Array, target: String, options: Dictionary) -> Dictionary:
	var plan := _plan(project_dbs, source, ids, target, options)
	if plan.has("error"):
		return plan
	var target_db := plan.target_db as DocketDBJsonl
	var registry: TypeRegistry = plan.target_registry
	var author: String = plan.promoted_by
	var reason := "promoted from %s" % plan.source_name
	var error := target_db._begin_canonical_mutation()
	if not error.is_empty():
		return {"error": "Target write refused; nothing was copied: %s" % error}
	for entry: Dictionary in plan.entries:
		error = DocketMove.import_checked(target_db, entry.new_id, entry.exported, registry, entry.type_plan.type, entry.type_plan.revisions, author, reason)
		if not error.is_empty():
			error = "%s: %s" % [entry.old_id, error]
			break
	error = target_db._complete_canonical_mutation(error)
	var reload_error := registry.reload()
	if not error.is_empty():
		return {"error": "Target write failed; nothing was copied: %s" % error}
	var result := _summary(plan, true)
	if not reload_error.is_empty():
		result["warning"] = "copied, but the target's type registry did not reload: %s" % reload_error
	return result


# -- Planning -----------------------------------------------------------------

static func _plan(project_dbs: Dictionary, source: String, ids: Array, target: String, options: Dictionary) -> Dictionary:
	var source_name := _canonical_name(project_dbs, source)
	var target_name := _canonical_name(project_dbs, target)
	if source_name.is_empty():
		return {"error": "Unknown source project '%s'" % source}
	if target_name.is_empty():
		return {"error": "Unknown target project '%s'" % target}
	var source_db: DocketDB = project_dbs[source_name]
	var target_db: DocketDB = project_dbs[target_name]
	var source_mode := SessionProject.mode_of(source_db)
	if source_mode == SessionProject.MODE_DURABLE:
		return {"error": "%s is a durable project; promotion copies from session_file or memory projects" % source_name}
	if SessionProject.mode_of(target_db) != SessionProject.MODE_DURABLE or target_db is DocketDBMemory:
		return {"error": "%s is a %s project; promotion writes into a durable project" % [target_name, SessionProject.mode_of(target_db)]}
	if not target_db is DocketDBJsonl:
		return {"error": "%s is not a .dct project" % target_name}
	var promoted_by := str(options.get("promoted_by", "")).strip_edges()
	if promoted_by.is_empty():
		return {"error": "promoted_by is required: the identity recorded as having promoted these records"}
	if ids.is_empty():
		return {"error": "items is empty; name the records to promote"}

	# Resolve every requested id before exporting anything.
	var id_map: Dictionary = {}  # source id -> new target id
	var order: PackedStringArray = []
	for raw: Variant in ids:
		var requested := str(raw)
		var full := source_db.resolve_short_id(requested) if requested.length() >= 4 else ""
		if full.is_empty() and source_db.has_item(requested):
			full = requested
		if full.is_empty():
			return {"error": "Item not found in %s: %s" % [source_name, requested]}
		if id_map.has(full):
			continue
		id_map[full] = target_db.next_uuid7_id()
		order.append(full)

	var source_registry := TypeRegistry.for_db(source_db, source_name)
	var target_registry := TypeRegistry.for_db(target_db, target_name)
	var promoted_at := Time.get_datetime_string_from_system(true)
	var entries: Array[Dictionary] = []
	var unresolved: Array[Dictionary] = []
	for old_id in order:
		var export_result := source_db.export_item_full_checked(old_id)
		if export_result.has("error"):
			return {"error": "Could not read %s; nothing was copied: %s" % [old_id, export_result.error]}
		var exported: Dictionary = export_result.export
		var item: Dictionary = exported.item
		var misses: Array[Dictionary] = []
		var ref_error := _map_references(exported, source_registry, source_name, target_name, id_map, misses)
		if not ref_error.is_empty():
			return {"error": "%s: reference semantics are unresolved; nothing was copied: %s" % [old_id, ref_error]}
		var type_plan := DocketMove.type_import_plan(item, source_registry, target_registry, target_db, bool(options.get("import_definition", false)))
		if type_plan.has("error"):
			return {"error": "%s: %s" % [old_id, type_plan.error]}
		for miss in misses:
			miss["item"] = old_id
		unresolved.append_array(misses)
		exported["events"] = []
		exported.erase("incoming_links")
		if not bool(options.get("include_comments", false)):
			exported["comments"] = []
		if not bool(options.get("include_attachments", false)):
			exported["attachments"] = []
		var provenance := {
			"project": source_name,
			"storage_mode": source_mode,
			"item_id": old_id,
			"promoted_at": promoted_at,
			"promoted_by": promoted_by,
		}
		var missed_refs: Array = []
		for miss in misses:
			missed_refs.append(miss.reference)
		if not missed_refs.is_empty():
			provenance["unresolved_refs"] = missed_refs
		var extras: Dictionary = item.get("extras", {}) if item.get("extras", {}) is Dictionary else {}
		extras[PROVENANCE_KEY] = provenance
		item["extras"] = extras
		var note := "Promoted from %s:%s (%s) by %s" % [source_name, old_id, source_mode, promoted_by]
		if not missed_refs.is_empty():
			note += "; unresolved references: %s" % ", ".join(PackedStringArray(missed_refs))
		exported["arrival_event"] = {"event_type": EVENT_TYPE, "actor": promoted_by, "note": note}
		entries.append({"old_id": old_id, "new_id": id_map[old_id], "title": str(item.get("title", "")), "exported": exported, "type_plan": type_plan})
	return {
		"source_name": source_name, "target_name": target_name, "source_mode": source_mode,
		"target_db": target_db, "target_registry": target_registry, "promoted_by": promoted_by,
		"promoted_at": promoted_at, "entries": entries, "unresolved": unresolved,
		"include_comments": bool(options.get("include_comments", false)),
		"include_attachments": bool(options.get("include_attachments", false)),
	}


## Rewrites every reference in `exported` in place and appends each unresolved
## one to `misses` as {field, reference}. Returns "" or why the item's typed
## fields could not be read.
static func _map_references(exported: Dictionary, registry: TypeRegistry, source: String, target: String, id_map: Dictionary, misses: Array[Dictionary]) -> String:
	var item: Dictionary = exported.item
	for key in ["parent", "blocked_by"]:
		if not str(item.get(key, "")).is_empty():
			item[key] = _map_reference(str(item[key]), key, source, target, id_map, misses)
	for link: Dictionary in exported.get("links", []):
		link["to"] = _map_reference(str(link.get("to", "")), "link:%s" % link.get("relation", ""), source, target, id_map, misses)
	var resolved := registry.resolve_item(item)
	if resolved.has("error"):
		return str(resolved.error)
	var custom: Dictionary = item.get("fields", {}) if item.get("fields", {}) is Dictionary else {}
	for descriptor: Dictionary in resolved.definition.fields:
		var key := str(descriptor.key)
		if not custom.has(key):
			continue
		if str(descriptor.type) == "item_ref" and not str(custom[key]).is_empty():
			custom[key] = _map_reference(str(custom[key]), key, source, target, id_map, misses)
		elif str(descriptor.type) == "reference_list" and custom[key] is Array:
			var mapped: Array = []
			for reference: Variant in custom[key]:
				mapped.append(_map_reference(str(reference), key, source, target, id_map, misses))
			custom[key] = mapped
	return ""


static func _map_reference(reference: String, field: String, source: String, target: String, id_map: Dictionary, misses: Array[Dictionary]) -> String:
	if reference.is_empty():
		return reference
	var local := reference
	if reference.contains(":"):
		var parts := reference.split(":", true, 1)
		if parts[0].to_lower() != source.to_lower():
			return reference
		local = parts[1]
	if id_map.has(local):
		return "%s:%s" % [target, id_map[local]]
	var kept := "%s:%s" % [source, local]
	misses.append({"field": field, "reference": kept})
	return kept


# -- Helpers ------------------------------------------------------------------

static func _summary(plan: Dictionary, written: bool) -> Dictionary:
	var items: Array = []
	for entry: Dictionary in plan.entries:
		items.append({"old_id": entry.old_id, "new_id": entry.new_id, "title": entry.title})
	return {
		"promoted" if written else "would_promote": items,
		"unresolved": plan.unresolved,
		"source_project": plan.source_name,
		"source_storage_mode": plan.source_mode,
		"target_project": plan.target_name,
		"promoted_by": plan.promoted_by,
		"promoted_at": plan.promoted_at,
		"include_comments": plan.include_comments,
		"include_attachments": plan.include_attachments,
	}


static func _canonical_name(project_dbs: Dictionary, requested: String) -> String:
	for proj_name in project_dbs:
		if str(proj_name).to_lower() == requested.to_lower():
			return str(proj_name)
	return ""
