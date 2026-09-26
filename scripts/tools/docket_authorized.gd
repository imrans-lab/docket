extends RefCounted
class_name DocketAuthorized
## docket_authorized: is an actor authorized for an action on an item or project
## (ItemAuthorization).


func get_definition() -> Dictionary:
	return {
		"name": "docket_authorized",
		"description": "Answer \"is `actor` authorized for `action` on this scope\" from standing authorization records: `policy` items tagged `authorization`, status active, grantee in directed_to, and tags action:<class>, scope:project:<name> | scope:item:<full id> (that item and its descendants by parent) | scope:tag:<tag>, granted-by:<principal>. With `id`, the scopes checked are the item's project, the item and its same-project ancestors, and the item's own tags; without `id`, only the project scope. Returns authorized=false and no records when no active authorization covers the scope. A revoked (archived) or suspended record never matches. Read-only: assignment does not create an authorization, and an authorization does not claim the item.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"actor": {"type": "string", "description": "Grantee to check, matched exactly against directed_to (a principal or a role string)"},
				"action": {"type": "string", "description": "Action class, matched exactly against action:<class> tags"},
				"id": {"type": "string", "description": "Item the action targets: full ID or short prefix (min 4 chars). Omit to check the project scope only."},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["actor", "action"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var actor: String = str(args.get("actor", ""))
	var action: String = str(args.get("action", ""))
	if actor.strip_edges().is_empty() or action.strip_edges().is_empty(): return {"error": "actor and action are required"}
	var id: String = str(args.get("id", ""))
	var scopes: Array = ["scope:project:%s" % db.get_project_name()]
	if not id.is_empty():
		if not db.has_item(id): return {"error": "Item not found: %s" % id}
		scopes = ItemAuthorization.covering_scopes(db, id)
	var found: Array = ItemAuthorization.matching(db, scopes, actor, action)
	return {"authorized": not found.is_empty(), "authorizations": found, "scopes_checked": scopes}
