extends RefCounted
class_name DocketTypeActivate

func get_definition() -> Dictionary:
	return {"name":"docket_type_activate","description":"Activate or deprecate a custom type with optimistic revision checking.","inputSchema":{"type":"object","properties":{"project":{"type":"string"},"type":{"type":"string"},"action":{"type":"string","enum":["activate","deprecate"]},"expected_revision":{"type":"string"},"author":{"type":"string"},"reason":{"type":"string"}},"required":["type","action","expected_revision","author","reason"]}}

func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, registry: TypeRegistry) -> Dictionary:
	if registry == null: return {"error":"type registry is unavailable"}
	var descriptor: Dictionary = registry.resolve_type_ref(str(args.get("type", "")))
	if descriptor.has("error"): return descriptor
	var action: String = str(args.get("action", ""))
	var error: String
	if action == "activate": error = registry.activate_type(str(descriptor.slug), str(args.get("expected_revision", "")), str(args.get("author", "")), str(args.get("reason", "")))
	elif action == "deprecate": error = registry.deprecate_type(str(descriptor.slug), str(args.get("expected_revision", "")), str(args.get("author", "")), str(args.get("reason", "")))
	else: return {"error":"action must be activate or deprecate"}
	return {"error":error} if not error.is_empty() else {"type":registry.get_type(str(descriptor.slug))}
