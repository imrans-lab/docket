extends RefCounted
class_name DocketMove


func get_definition() -> Dictionary:
	return {
		"name": "docket_move",
		"description": "Move an item from one project to another. Transfers all data (tags, events, comments, attachments) and updates cross-project parent/blocked_by references.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"target_project": {"type": "string", "description": "Name of the target project"},
				"source_project": {"type":"string","description":"Source project when the ID is not globally unique"},
				"import_definition": {"type":"boolean","description":"Import the exact pinned revision when absent"},
				"author": {"type":"string"},
				"reason": {"type":"string"},
			},
			"required": ["id", "target_project"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _primary_db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var item_id: String = str(args.get("id", ""))
	var target_project: String = str(args.get("target_project", ""))

	if item_id.is_empty() or target_project.is_empty():
		return {"error": "Missing 'id' or 'target_project'"}

	# If no multi-project context, can't move
	if project_dbs.is_empty():
		return {"error": "No projects loaded — cannot move items"}

	# Find the source without iteration-order ambiguity.
	var source_db: DocketDB = null
	var source_name: String = ""
	var requested_source: String = str(args.get("source_project", ""))
	if not requested_source.is_empty():
		var source_known: bool = false
		for project_name in project_dbs:
			if str(project_name).to_lower() == requested_source.to_lower(): source_known = true
		if not source_known: return {"error":"Source project not found: %s" % requested_source}
	for proj_name in project_dbs:
		var pdb: DocketDB = project_dbs[proj_name]
		if pdb.has_item(item_id) and (requested_source.is_empty() or str(proj_name).to_lower() == requested_source.to_lower()):
			if source_db != null: return {"error":"Item ID is ambiguous across projects; specify source_project"}
			source_db = pdb
			source_name = proj_name
	if source_db == null:
		return {"error": "Item not found: %s" % item_id}

	# Find target DB (case-insensitive match)
	var target_db: DocketDB = null
	var canonical_target: String = target_project
	for proj_name in project_dbs:
		if proj_name.to_lower() == target_project.to_lower():
			target_db = project_dbs[proj_name]
			canonical_target = proj_name
			break
	if target_db == null:
		return {"error": "Target project not found: %s" % target_project}
	if source_db == target_db:
		return {"error": "Item is already in project '%s'" % canonical_target}

	# Refuse to move anything holding vault content.
	#
	# export_item_full carries the item, tags, events, links, comments and
	# attachments — but NOT vault entries. delete_item then explicitly removes
	# the source's secret, its ":notes" companion, and their version history. So
	# a move would destroy the ciphertext with nothing written to the target.
	#
	# Copying the bytes would not help either: they are encrypted under the
	# source project's vault key, which the target does not have. A correct move
	# needs decrypt-then-re-encrypt with both passwords, so refusing is the
	# honest behaviour until that exists.
	var vault_handles: Array = source_db.list_secrets_owned_by(item_id)
	for conventional_handle in [item_id,item_id + ":notes"]:
		var has_current: bool = not source_db.get_secret_raw(conventional_handle).is_empty()
		var history: Array = source_db._exec_select("SELECT 1 FROM docket_secret_versions WHERE handle=? LIMIT 1;", [conventional_handle])
		if (has_current or not history.is_empty()) and not vault_handles.has(conventional_handle): vault_handles.append(conventional_handle)
	if not source_db._last_sql_error.is_empty(): return {"error":"Source vault read failed; nothing was copied: %s" % source_db._last_sql_error}
	if not vault_handles.is_empty():
		return {"error": (
			"Cannot move '%s': it holds encrypted vault content (%s). " % [item_id, ", ".join(PackedStringArray(vault_handles))]
			+ "The ciphertext is encrypted with '%s' vault key and cannot be re-keyed automatically. " % source_name
			+ "Read the secret, delete it from this item, move the item, then re-create the secret in '%s'." % canonical_target
		)}

	# Export full item (data + events + comments + attachments)
	var export_result: Dictionary = source_db.export_item_full_checked(item_id)
	if export_result.has("error"): return {"error":"Source export failed; nothing was copied: %s" % export_result.error}
	var exported: Dictionary = export_result.export

	var new_id: String
	var refs_updated: int = 0
	var source_item: Dictionary = exported.get("item", {})
	var pending_type: Dictionary = {}
	var pending_revisions: Array = []
	var target_registry: TypeRegistry = TypeRegistry.for_db(target_db, canonical_target)
	var source_registry: TypeRegistry = TypeRegistry.for_db(source_db, source_name)
	if not str(source_item.get("type_revision", "")).is_empty():
		if target_registry.is_legacy(): return {"error":"Target must be explicitly upgraded before moving a pinned v2 item"}
		var revision: Dictionary = source_registry.get_revision(str(source_item.type_revision))
		if revision.has("error"): return revision
		if target_registry.get_revision(str(source_item.type_revision)).has("error"):
			if not bool(args.get("import_definition", false)): return {"error":"Target lacks exact pinned revision '%s'; explicit definition import is required" % source_item.type_revision}
			pending_type = source_registry.resolve_type_ref(str(source_item.get("type_id", "")))
			var ancestry: Dictionary = source_registry.revision_ancestry(str(source_item.type_revision))
			if ancestry.has("error"): return ancestry
			for ancestor in ancestry.revisions:
				if target_registry.get_revision(str(ancestor.id)).has("error"): pending_revisions.append(ancestor)
	elif target_db is DocketDBJsonl and target_db.get_meta_value("jsonl_version", "1.0.0") == "2.0.0":
		# A legacy builtin gains the target project's explicit compatible pin before
		# import; leaving it unbound would make an otherwise valid v2 file read-only.
		var legacy_target_registry: TypeRegistry = TypeRegistry.for_db(target_db, canonical_target)
		var builtin: Dictionary = legacy_target_registry.get_type(str(source_item.get("type", "")))
		if builtin.has("error") or not bool(builtin.definition.get("protected", false)): return {"error":"Legacy item type has no compatible protected builtin in target"}
		source_item["type_id"] = builtin.id
		source_item["type_revision"] = builtin.current_revision
	new_id = item_id if DocketDB._is_uuid7(item_id) else target_db.next_uuid7_id()
	var reference_prepare_error: String = _prepare_export_refs(exported, source_registry, source_name, canonical_target, item_id, new_id)
	if not reference_prepare_error.is_empty(): return {"error":"Source reference semantics are unresolved; nothing was copied: %s" % reference_prepare_error}
	var target_error: String = _import_checked(target_db, new_id, exported, target_registry, pending_type, pending_revisions, args)
	if not target_error.is_empty(): return {"error":"Target write failed; source preserved: %s" % target_error}
	var old_qualified: String = "%s:%s" % [source_name,item_id]
	var new_qualified: String = "%s:%s" % [canonical_target,new_id]
	for proj_name in project_dbs:
		var pdb: DocketDB = project_dbs[proj_name]
		# Bare IDs are local. Only the source project's bare reference identifies
		# the moved item; another project may own an unrelated item with that ID.
		var bare_target: String = new_qualified if str(proj_name) == source_name else item_id
		var project_registry: TypeRegistry = TypeRegistry.for_db(pdb, str(proj_name))
		var rewrite: Dictionary = project_registry.rewrite_move_references(old_qualified,new_qualified,item_id,bare_target,str(proj_name) == source_name)
		if not str(rewrite.get("error", "")).is_empty(): return {"error":"Target copy is durable, but reference rewrite failed in '%s': %s" % [proj_name,rewrite.error],"partial_copy":true,"new_id":new_id,"new_project":canonical_target}
		refs_updated += int(rewrite.count)
	var source_error: String = _delete_checked(source_db,item_id)
	if not source_error.is_empty(): return {"error":"Target copy is durable but source deletion failed: %s" % source_error,"partial_copy":true,"new_id":new_id,"new_project":canonical_target}

	return {
		"old_id": item_id,
		"new_id": new_id,
		"old_project": source_name,
		"new_project": canonical_target,
		"refs_updated": refs_updated,
	}

func _prepare_export_refs(exported: Dictionary, registry: TypeRegistry, source_project: String, target_project: String, old_id: String, new_id: String) -> String:
	var item: Dictionary = exported.item
	for key in ["parent","blocked_by"]:
		if item.has(key): item[key] = _transfer_ref(str(item[key]),source_project,target_project,old_id,new_id)
	for link in exported.get("links", []): link["to"] = _transfer_ref(str(link.get("to", "")),source_project,target_project,old_id,new_id)
	if registry == null: return "source registry is unavailable"
	var resolved: Dictionary = registry.resolve_item(item)
	if resolved.has("error"): return str(resolved.error)
	var custom: Dictionary = item.get("fields", {})
	for descriptor in resolved.definition.fields:
		var key: String = str(descriptor.key)
		if not custom.has(key): continue
		if descriptor.type == "item_ref": custom[key] = _transfer_ref(str(custom[key]),source_project,target_project,old_id,new_id)
		elif descriptor.type == "reference_list" and custom[key] is Array:
			var refs: Array = []
			for reference in custom[key]: refs.append(_transfer_ref(str(reference),source_project,target_project,old_id,new_id))
			custom[key] = refs
	return ""

func _transfer_ref(reference: String, source_project: String, target_project: String, old_id: String, new_id: String) -> String:
	if reference == old_id or reference == "%s:%s" % [source_project,old_id]: return "%s:%s" % [target_project,new_id]
	return reference if reference.contains(":") or reference.is_empty() else "%s:%s" % [source_project,reference]

func _import_checked(db: DocketDB, id: String, exported: Dictionary, registry: TypeRegistry, type_record: Dictionary, revisions: Array, args: Dictionary) -> String:
	if db is DocketDBJsonl: return registry.import_revisions_and_item(type_record, revisions, id, exported, str(args.get("author", "")), str(args.get("reason", "")))
	db._last_sql_error = ""
	db._exec_checked("BEGIN TRANSACTION;")
	db.import_item_full(id, exported)
	var error: String = db._last_sql_error
	if error.is_empty(): error = db._exec_checked("COMMIT;")
	else: db._rollback()
	return error

func _delete_checked(db: DocketDB, id: String) -> String:
	if db is DocketDBJsonl: return (db as DocketDBJsonl).delete_item_checked(id)
	db._last_sql_error = ""
	db._exec_checked("BEGIN TRANSACTION;")
	db.delete_item(id)
	var error: String = db._last_sql_error
	if error.is_empty(): error = db._exec_checked("COMMIT;")
	else: db._rollback()
	return error
