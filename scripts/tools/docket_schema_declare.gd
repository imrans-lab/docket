extends RefCounted
class_name DocketSchemaDeclare
## Public loopback declaration; TypeRegistryBootstrap owns schema semantics.

func get_definition() -> Dictionary:
	return {
		"name":"docket_schema_declare",
		"description":"Declare the starter schema and its nonempty version before opening projects. Exact retries are idempotent; a changed schema after a project has opened is refused. Preserves persisted type revisions and protected-slug rules. Returns {version, idempotent}. Uses the same loopback trust as other tools; no token is required.",
		"inputSchema":{
			"type":"object", "additionalProperties":false,
			"properties":{
				"schema":{"type":"object", "description":"Complete starter schema, including nonempty types"},
				"version":{"type":"string", "description":"Nonempty schema version"},
			},
			"required":["schema", "version"],
		},
	}

func execute(args: Dictionary, schema_adopted: Callable) -> Dictionary:
	if args.size() != 2 or not args.has("schema") or not args.has("version"):
		return _error(-32602, "Invalid schema parameters")
	var declaration := TypeRegistryBootstrap.declare_schema(args.schema, args.version)
	if declaration.has("error"): return _error(-32602, declaration.error)
	if not declaration.idempotent and schema_adopted.is_valid(): schema_adopted.call()
	return declaration

static func _error(code: int, message: String) -> Dictionary:
	return {"error":{"code":code, "message":message}}
