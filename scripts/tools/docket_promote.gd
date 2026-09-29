extends RefCounted
class_name DocketPromote
## MCP tool: copy selected records from a session project into a durable project
## (SessionPromotion does the work), or, with no to_project, keep ephemeral
## items of a file-backed project in place (ItemStorage.keep).


func get_definition() -> Dictionary:
	return {
		"name": "docket_promote",
		"description": "With to_project omitted (or equal to source_project): keep the listed ephemeral items of a file-backed project in place — each becomes durable with the same id and a 'promoted' event, and is written on the next settle. Otherwise: copy the selected records from a session_file or memory project into a durable project. Only the listed items are written; the source keeps them. Each copy gets a new id, a 'promoted' event and extras.promoted_from {project, storage_mode, item_id, promoted_at, promoted_by, unresolved_refs}. The session's event history is not copied. References to other promoted items become '<to_project>:<new id>'; references to items left behind are kept as '<source>:<id>' and listed under 'unresolved'. dry_run=true returns the same plan without writing.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"items": {"type": "array", "items": {"type": "string"}, "description": "IDs (full or short prefix) of the records to promote"},
				"source_project": {"type": "string", "description": "Session project (session_file or memory) holding the items, or the file-backed project holding ephemeral items to keep"},
				"to_project": {"type": "string", "description": "Durable project to copy them into; omit to keep ephemeral items in place"},
				"promoted_by": {"type": "string", "description": "Declared identity recorded as the promoter; not authenticated"},
				"include_comments": {"type": "boolean", "description": "Copy each item's comments (default false)"},
				"include_attachments": {"type": "boolean", "description": "Copy each item's attachments (default false)"},
				"import_definition": {"type": "boolean", "description": "Import a pinned type revision the durable project lacks (default false: refuse)"},
				"dry_run": {"type": "boolean", "description": "Report what would be promoted and what is unresolved; write nothing"},
			},
			"required": ["items", "source_project", "promoted_by"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var items: Variant = args.get("items", [])
	if not items is Array:
		return {"error": "items must be an array of item IDs"}
	var options := {
		"promoted_by": str(args.get("promoted_by", "")),
		"include_comments": bool(args.get("include_comments", false)),
		"include_attachments": bool(args.get("include_attachments", false)),
		"import_definition": bool(args.get("import_definition", false)),
	}
	var source := str(args.get("source_project", ""))
	var target := str(args.get("to_project", ""))
	if target.is_empty() or target == source:
		return _keep_in_place(project_dbs, source, items, options.promoted_by, bool(args.get("dry_run", false)))
	if bool(args.get("dry_run", false)):
		return SessionPromotion.preview(project_dbs, source, items, target, options)
	return SessionPromotion.promote(project_dbs, source, items, target, options)


func _keep_in_place(project_dbs: Dictionary, source: String, items: Array, promoted_by: String, dry_run: bool) -> Dictionary:
	## Every listed item must be ephemeral, and the batch must pass
	## ItemStorage.batch_refusal against project_dbs; otherwise nothing is kept.
	## The batch is kept in one mutation (ItemStorage.keep), so all or none;
	## keep runs batch_refusal itself inside it. dry_run only reports it.
	if not project_dbs.has(source): return {"error": "Unknown project: %s" % source}
	var db: DocketDB = project_dbs[source]
	if not ItemStorage.supports_ephemeral(db): return {"error": "project '%s' has no ephemeral items; name a durable to_project to promote session records" % source}
	var ids: Array = []
	for value in items:
		var id := db.resolve_short_id(str(value))
		if id.is_empty(): return {"error": "Item not found: %s" % value}
		if not ItemStorage.is_ephemeral(db, id): return {"error": "item %s is already durable" % id}
		ids.append(id)
	if dry_run:
		var refusal := ItemStorage.batch_refusal(db, ids, project_dbs)
		return {"error": refusal} if not refusal.is_empty() else {"project": source, "would_keep": ids}
	var error := ItemStorage.keep(db, ids, promoted_by, project_dbs)
	if not error.is_empty(): return {"error": error}
	return {"project": source, "kept": ids}
