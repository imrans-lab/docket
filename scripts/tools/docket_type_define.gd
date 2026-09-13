extends RefCounted
class_name DocketTypeDefine

func get_definition() -> Dictionary:
	return {"name":"docket_type_define","description":"Define a draft custom type. Activation is a separate explicit operation.","inputSchema":{"type":"object","properties":{"project":{"type":"string"},"slug":{"type":"string"},"definition":{"type":"object"},"author":{"type":"string"},"reason":{"type":"string"},"provenance":{"type":"object"}},"required":["slug","definition","author","reason"]}}

func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, registry: TypeRegistry) -> Dictionary:
	if registry == null: return {"error":"type registry is unavailable"}
	if not args.get("definition") is Dictionary: return {"error":"definition must be an object"}
	var provenance: Dictionary = args.get("provenance", {}) if args.get("provenance", {}) is Dictionary else {}
	return registry.define_type(str(args.get("slug", "")), args.definition, str(args.get("author", "")), str(args.get("reason", "")), provenance)
