extends RefCounted
class_name ItemAuthorization
## Standing authorizations (W1 KB docket:01a0dc3549bc, "Standing authorization").
##
## An authorization is an ordinary `policy` item tagged `authorization`:
##   directed_to        grantee: an actor principal or a role string, matched exactly
##   tag action:<class> what is authorized (one or more)
##   tag scope:project:<project name>  every item in that project
##   tag scope:item:<full item id>     that item and every descendant by `parent`
##   tag scope:tag:<tag>               every item carrying that tag
##   tag granted-by:<principal>        who granted it; created_at is when
## Only status `active` is in force. Revocation is a transition to `archived`
## (or `suspended` to pause), so the record and its revoking event stay in the log.
##
## An authorization lives in the same project as the items it covers. It is
## read from tags and directed_to only: assigned_to and claims never create one,
## and holding one never claims an item.

const MARKER := "authorization"
const ACTION_PREFIX := "action:"
const SCOPE_PREFIX := "scope:"
const GRANTED_BY_PREFIX := "granted-by:"


## The scope tags that cover `item_id` in `db`: its project, the item and each
## same-project ancestor, and each of its own tags. [] when the item is missing.
static func covering_scopes(db: DocketDB, item_id: String) -> Array:
	var item: Dictionary = db.get_item(item_id)
	if item.is_empty(): return []
	var project: String = db.get_project_name()
	var scopes: Array = ["scope:project:%s" % project]
	for tag in item.get("tags", []):
		scopes.append("scope:tag:%s" % str(tag))
	var seen: Dictionary = {}
	var current: String = item_id
	# Walks the parent chain; a parent in another project ends the walk, and the
	# seen set stops a hand-edited cycle.
	while not current.is_empty() and not seen.has(current) and db.has_item(current):
		seen[current] = true
		scopes.append("scope:item:%s" % current)
		var ref: Dictionary = DocketDB.parse_qualified_ref(str(db.get_item(current).get("parent", "")))
		var owner: String = str(ref.get("project", ""))
		current = str(ref.get("id", "")) if owner.is_empty() or owner == project else ""
	return scopes


## Active authorizations whose grantee is `actor`, whose actions include
## `action`, and whose scope is one of `scopes`. An empty `actor` or `action`
## matches any. Rows are summaries (see _summary).
static func matching(db: DocketDB, scopes: Array, actor: String = "", action: String = "") -> Array:
	var rows: Array = db.execute_query({"filter":{"conditions":[
		{"field":"type", "op":"eq", "value":"policy"},
		{"conj":"and", "field":"status", "op":"eq", "value":"active"},
		{"conj":"and", "field":"tags", "op":"eq", "value":MARKER},
	]}})
	var found: Array = []
	for row in rows:
		var record: Dictionary = row
		if not actor.is_empty() and str(record.get("directed_to", "")) != actor: continue
		var summary: Dictionary = _summary(record)
		if not action.is_empty() and not (summary.actions as Array).has(action): continue
		var covered: Array = (summary.scopes as Array).filter(func(scope: String) -> bool: return scopes.has(scope))
		if covered.is_empty(): continue
		summary["matched_scopes"] = covered
		found.append(summary)
	return found


## Everything in force on `item_id`, for any grantee and action (the GUI view).
static func for_item(db: DocketDB, item_id: String) -> Array:
	return matching(db, covering_scopes(db, item_id))


static func _summary(record: Dictionary) -> Dictionary:
	var actions: Array = []
	var scopes: Array = []
	var granted_by: String = ""
	for tag_value in record.get("tags", []):
		var tag: String = str(tag_value)
		if tag.begins_with(ACTION_PREFIX): actions.append(tag.substr(ACTION_PREFIX.length()))
		elif tag.begins_with(SCOPE_PREFIX): scopes.append(tag)
		elif tag.begins_with(GRANTED_BY_PREFIX): granted_by = tag.substr(GRANTED_BY_PREFIX.length())
	return {
		"id": str(record.get("id", "")),
		"title": str(record.get("title", "")),
		"grantee": str(record.get("directed_to", "")),
		"actions": actions,
		"scopes": scopes,
		"granted_by": granted_by,
		"granted_at": str(record.get("created_at", "")),
	}
