extends RefCounted
class_name DocketTypeOverview
## A project's types as the Project Types panel lists them: every type with
## its definition, how many items each has, and whether the project still
## needs promoting or upgrading. Read-only.

func get_definition() -> Dictionary:
	return {"name":"docket_type_overview","description":"List a project's types with their definitions, item counts per type, and whether the project still needs promoting to JSONL or upgrading to 2.0 (read-only). Errors carry a kind: unavailable (the type registry cannot be read; reason gives why) or list_failed.","inputSchema":{"type":"object","properties":{"project":{"type":"string"},"include_deprecated":{"type":"boolean"}}}}

func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, registry: TypeRegistry) -> Dictionary:
	return overview(registry, db, str(args.get("project", db.get_project_name())), bool(args.get("include_deprecated", false)))


## {types, counts: {slug: item count}, legacy} for `db` (named `project`), or
## {error, kind, reason}. Shared with the standalone app's source.
static func overview(registry: TypeRegistry, db: DocketDB, project: String, include_deprecated: bool) -> Dictionary:
	var diagnostic := registry.get_diagnostic()
	if not diagnostic.is_empty():
		return {"error": "Type registry unavailable for %s: %s" % [project, diagnostic], "kind": "unavailable", "reason": diagnostic}
	var counts: Dictionary = {}
	for row in db._exec_select("SELECT type,COUNT(*) AS count FROM items GROUP BY type;"):
		counts[str(row.type)] = int(row.count)
	var listed: Array = registry.list_types(include_deprecated)
	if not listed.is_empty() and listed[0] is Dictionary and listed[0].has("error"):
		return {"error": "Type registry unavailable for %s: %s" % [project, listed[0].error], "kind": "list_failed", "reason": str(listed[0].error)}
	return {"types": listed, "counts": counts, "legacy": registry.is_legacy() or not db is DocketDBJsonl}
