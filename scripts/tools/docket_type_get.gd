extends RefCounted
class_name DocketTypeGet

func get_definition() -> Dictionary:
	return {"name":"docket_type_get","description":"Get one complete type definition by slug, stable type ID, or revision ID.","inputSchema":{"type":"object","properties":{"project":{"type":"string"},"type":{"type":"string"},"revision":{"type":"string"}},"anyOf":[{"required":["type"]},{"required":["revision"]}]}}

func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, registry: TypeRegistry) -> Dictionary:
	if registry == null: return {"error":"type registry is unavailable"}
	var revision: String = str(args.get("revision", ""))
	if not revision.is_empty():
		var found: Dictionary = registry.get_revision(revision)
		if found.has("error"): return found
		var requested: String = str(args.get("type", "")).strip_edges()
		if not requested.is_empty():
			var descriptor: Dictionary = registry.resolve_type_ref(requested)
			if descriptor.has("error"): return descriptor
			if str(found.type_id) != str(descriptor.id): return {"error":"revision does not belong to requested type identity"}
		return found
	if str(args.get("type", "")).is_empty(): return {"error":"type or revision is required"}
	return registry.resolve_type_ref(str(args.get("type", "")))
