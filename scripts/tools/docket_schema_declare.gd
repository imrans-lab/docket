extends RefCounted
class_name DocketSchemaDeclare
## Public loopback declaration; TypeRegistryBootstrap owns schema semantics.

func get_definition() -> Dictionary:
	return {
		"name":"docket_schema_declare",
		"description":"Declare the starter schema and its nonempty version at any time. Exact retries are idempotent. For open projects, installs missing starter types and preserves existing immutable meanings and item pins; conflicts are reported per project and slug, without refusing the declaration. Legacy views reload the starter schema. Returns {version, idempotent, projects:[{name, activated:[slugs], conflicts:[{slug, reason}]}]}. Uses the same loopback trust as other tools; no token is required.",
		"inputSchema":{
			"type":"object", "additionalProperties":false,
			"properties":{
				"schema":{"type":"object", "description":"Complete starter schema, including nonempty types"},
				"version":{"type":"string", "description":"Nonempty schema version"},
			},
			"required":["schema", "version"],
		},
	}

func execute(args: Dictionary, schema_adopted: Callable, project_dbs: Dictionary = {}) -> Dictionary:
	if args.size() != 2 or not args.has("schema") or not args.has("version"):
		return _error(-32602, "Invalid schema parameters")
	var declaration := TypeRegistryBootstrap.declare_schema(args.schema, args.version)
	if declaration.has("error"): return _error(-32602, declaration.error)
	declaration["projects"] = TypeRegistryBootstrap.apply_to_open_projects(project_dbs)
	if schema_adopted.is_valid(): schema_adopted.call()
	return declaration

static func _error(code: int, message: String) -> Dictionary:
	return {"error":{"code":code, "message":message}}
