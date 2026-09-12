extends RefCounted
class_name DocketTypeValidate

func get_definition() -> Dictionary:
	return {"name":"docket_type_validate","description":"Validate a custom type definition without writing it.","inputSchema":{"type":"object","properties":{"project":{"type":"string"},"slug":{"type":"string"},"definition":{"type":"object"}},"required":["slug","definition"]}}

func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, registry: TypeRegistry) -> Dictionary:
	if registry == null: return {"error":"type registry is unavailable"}
	if not args.get("definition") is Dictionary: return {"error":"definition must be an object"}
	var candidate: Dictionary = args.definition.duplicate(true)
	candidate["slug"] = str(args.get("slug", ""))
	candidate["protected"] = false
	candidate["protected_behavior"] = {"regular_creation_allowed":true}
	if candidate.get("lifecycle") is Dictionary and not candidate.lifecycle.has("enforcement"): candidate.lifecycle["enforcement"] = "strict"
	var error: String = registry.validate_definition(candidate)
	return {"valid":error.is_empty(),"definition":candidate} if error.is_empty() else {"valid":false,"error":error}
