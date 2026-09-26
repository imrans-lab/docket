extends RefCounted
class_name DocketPromote
## MCP tool: copy selected records from a session project into a durable project
## (SessionPromotion does the work).


func get_definition() -> Dictionary:
	return {
		"name": "docket_promote",
		"description": "Copy the selected records from a session_file or memory project into a durable project. Only the listed items are written; the source keeps them. Each copy gets a new id, a 'promoted' event and extras.promoted_from {project, storage_mode, item_id, promoted_at, promoted_by, unresolved_refs}. The session's event history is not copied. References to other promoted items become '<to_project>:<new id>'; references to items left behind are kept as '<source>:<id>' and listed under 'unresolved'. dry_run=true returns the same plan without writing.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"items": {"type": "array", "items": {"type": "string"}, "description": "IDs (full or short prefix) of the records to promote"},
				"source_project": {"type": "string", "description": "Session project (session_file or memory) holding the items"},
				"to_project": {"type": "string", "description": "Durable project to copy them into"},
				"promoted_by": {"type": "string", "description": "Declared identity recorded as the promoter; not authenticated"},
				"include_comments": {"type": "boolean", "description": "Copy each item's comments (default false)"},
				"include_attachments": {"type": "boolean", "description": "Copy each item's attachments (default false)"},
				"import_definition": {"type": "boolean", "description": "Import a pinned type revision the durable project lacks (default false: refuse)"},
				"dry_run": {"type": "boolean", "description": "Report what would be promoted and what is unresolved; write nothing"},
			},
			"required": ["items", "source_project", "to_project", "promoted_by"],
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
	if bool(args.get("dry_run", false)):
		return SessionPromotion.preview(project_dbs, source, items, target, options)
	return SessionPromotion.promote(project_dbs, source, items, target, options)
