extends RefCounted
class_name DocketItemView
## One item as the item form shows it: the item with its events and links,
## its type resolution (state, pinned revision and definition), its revision
## token and its short ID. Read-only; it serves any project format, as
## docket_get does, but resolves the type for legacy projects too.

func get_definition() -> Dictionary:
	return {"name":"docket_item_view","description":"Get one item with its full type resolution, revision token and short ID (read-only). Its own errors carry a kind: registry (no type registry), refresh (its type definitions could not be reloaded; only with refresh), missing (no such item). An unknown project or ambiguous ID prefix is an error without a kind.","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"project":{"type":"string"},"refresh":{"type":"boolean","description":"Reload the project's type definitions first"}},"required":["id"]}}

func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, registry: TypeRegistry) -> Dictionary:
	var id := str(args.get("id", ""))
	if registry == null:
		return {"error":"type registry unavailable", "kind":"registry"}
	if bool(args.get("refresh", false)):
		var refresh_error := registry.refresh_if_changed()
		if not refresh_error.is_empty():
			return {"error":refresh_error, "kind":"refresh"}
	var item: Dictionary = db.get_item(id) if not id.is_empty() else {}
	if item.is_empty():
		return {"error":"item no longer exists in %s" % str(args.get("project", db.get_project_name())), "kind":"missing"}
	return {"item":item, "resolved":registry.resolve_item(item), "token":registry.item_token(item),
		"short_id":db.short_id(id) if DocketFields.is_uuid7(id) else id}
