extends RefCounted
class_name DocketProjectBootstrap
## Public loopback tool; the disk/apply owners retain canonical-data checks.

func get_definition() -> Dictionary:
	return {
		"name":"docket_project_bootstrap",
		"description":"Install or update a shipped project at an absolute path, then open or refresh it. content is canonical base64 of UTF-8 .dct content. Preserves customised items and existing project metadata; validates canonical data and opening identity before committing. Returns the bootstrap report and project descriptor. A committed-but-unavailable error includes disk_committed and failure_stage in its data. Uses the same loopback trust as other tools; no token is required.",
		"inputSchema":{
			"type":"object", "additionalProperties":false,
			"properties":{
				"path":{"type":"string", "description":"Absolute canonical .dct file path"},
				"content":{"type":"string", "description":"Canonical base64 of the UTF-8 shipped .dct content"},
			},
			"required":["path", "content"],
		},
	}

func execute(args: Dictionary, bootstrap_project: Callable) -> Dictionary:
	if args.size() != 2 or not args.get("path") is String or not args.get("content") is String:
		return _error(-32602, "Invalid bootstrap parameters")
	var path: String = args.path
	if path.is_empty() or not path.is_absolute_path() or path.contains("://") or path.get_file().is_empty():
		return _error(-32602, "Bootstrap requires an absolute file path")
	var refusal := TypeRegistryBootstrap.opening_refusal()
	if not refusal.is_empty(): return _error(-32602, refusal)
	var encoded: String = args.content
	if encoded.is_empty() or encoded.length() % 4 != 0:
		return _error(-32602, "Invalid bootstrap encoding")
	var bytes := Marshalls.base64_to_raw(encoded)
	if bytes.is_empty() or Marshalls.raw_to_base64(bytes) != encoded:
		return _error(-32602, "Invalid bootstrap encoding")
	var shipment := bytes.get_string_from_utf8()
	if shipment.to_utf8_buffer() != bytes:
		return _error(-32602, "Bootstrap content must be UTF-8")
	if not bootstrap_project.is_valid(): return _error(-32603, "Bootstrap unavailable")
	var reply: Dictionary = bootstrap_project.call(ProjectOpenings.normalized_path(path), shipment)
	return reply.get("result", reply)

static func _error(code: int, message: String) -> Dictionary:
	return {"error":{"code":code, "message":message}}
