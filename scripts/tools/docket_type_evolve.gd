extends RefCounted
class_name DocketTypeEvolve

func get_definition() -> Dictionary:
	return {"name":"docket_type_evolve","description":"Preview or apply an additive type evolution and optional selected item repins.","inputSchema":{"type":"object","properties":{"project":{"type":"string"},"type":{"type":"string"},"definition":{"type":"object"},"expected_revision":{"type":"string"},"item_ids":{"type":"array","items":{"type":"string"}},"apply":{"type":"boolean"},"author":{"type":"string"},"reason":{"type":"string"}},"required":["type","definition","expected_revision"]}}

## Within `op` when given (the operation of the request it serves).
func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, registry: TypeRegistry, op: RefCounted = null) -> Dictionary:
	if registry == null: return {"error":"type registry is unavailable"}
	if not args.get("definition") is Dictionary: return {"error":"definition must be an object"}
	var descriptor: Dictionary = registry.resolve_type_ref(str(args.get("type", "")))
	if descriptor.has("error"): return descriptor
	var ids: Array = args.get("item_ids", []) if args.get("item_ids", []) is Array else []
	var preview: Dictionary = registry.preview_evolution(str(descriptor.slug), args.definition, str(args.get("expected_revision", "")), ids)
	if preview.has("error") or not bool(args.get("apply", false)): return preview
	var error: String = registry.apply_evolution(preview, str(args.get("author", "")), str(args.get("reason", "")), op)
	return {"error":error} if not error.is_empty() else {"type":registry.get_type(str(descriptor.slug)),"repinned_items":ids}
