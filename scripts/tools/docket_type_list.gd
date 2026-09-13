extends RefCounted
class_name DocketTypeList

func get_definition() -> Dictionary:
	return {"name":"docket_type_list","description":"List project type definitions and their active revisions.","inputSchema":{"type":"object","properties":{"project":{"type":"string"},"search":{"type":"string"},"include_deprecated":{"type":"boolean"}}}}

func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, registry: TypeRegistry) -> Dictionary:
	if registry == null: return {"error":"type registry is unavailable"}
	var search: String = str(args.get("search", "")).strip_edges().to_lower()
	var values: Array = registry.list_types(bool(args.get("include_deprecated", false)))
	if values.size() == 1 and values[0] is Dictionary and values[0].has("error"): return values[0]
	var result: Array = []
	for value in values:
		var descriptor: Dictionary = value
		var haystack: String = "%s\n%s\n%s\n%s" % [descriptor.get("slug", ""), descriptor.get("label", ""), descriptor.get("description", ""), descriptor.get("use_when", "")]
		if search.is_empty() or haystack.to_lower().contains(search):
			result.append({"id":descriptor.id,"slug":descriptor.slug,"label":descriptor.label,"description":descriptor.description,"use_when":descriptor.get("use_when", ""),"project":descriptor.project,"lifecycle":descriptor.lifecycle,"current_revision":descriptor.current_revision})
	return {"types":result,"count":result.size(),"project":registry.get_project_name()}
