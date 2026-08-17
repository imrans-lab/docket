extends RefCounted
class_name DocketHintQuery
## Query hints (and optionally insights) with component/key/tag filtering.
## Auto-increments retrieval_count on each returned item.


func get_definition() -> Dictionary:
	return {
		"name": "docket_hint_query",
		"description": "Query hints by component, key pattern, or tags. Auto-increments retrieval_count on returned items. Set include_insights=true to also search insights.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"component": {"type": "string", "description": "Filter by component (exact match)"},
				"key": {"type": "string", "description": "Filter by key (exact match)"},
				"tags": {"type": "array", "items": {"type": "string"}, "description": "Filter: item must have all these tags"},
				"include_insights": {"type": "boolean", "description": "Also return matching insights (default false)"},
				"promoted_only": {"type": "boolean", "description": "Only return promoted hints (for CLAUDE.md graduation)"},
				"min_retrievals": {"type": "integer", "description": "Only return items retrieved at least this many times"},
				"min_research_cost": {"type": "integer", "description": "Only return items with research cost >= this value"},
				"limit": {"type": "integer", "minimum": 1},
				"detail": {"type": "string", "enum": ["lean", "full"], "description": "Response detail level. Default: lean."},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
		},
	}


## Every argument query_hints() actually filters on, plus the response-shaping
## ones. Anything outside this set is a caller mistake, and silence is the
## dangerous answer: query_hints() ignores what it does not recognise, so a
## single unrecognised key (e.g. a free-text `query`) turns an intended narrow
## lookup into "every hint in the project" — which is how the 2026-08-16
## full-store rewrite started.
const ACCEPTED_ARGS := [
	"component", "key", "tags", "include_insights", "promoted_only",
	"min_retrievals", "min_research_cost", "limit", "detail", "project",
]


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var unknown: Array = []
	for k in args.keys():
		if not ACCEPTED_ARGS.has(str(k)):
			unknown.append(str(k))
	if not unknown.is_empty():
		unknown.sort()
		return {"error": "Unknown argument(s): %s. docket_hint_query filters on: %s. (There is no free-text search here — narrow with component/key/tags.)" % [
			", ".join(unknown), ", ".join(ACCEPTED_ARGS)]}

	var query_args := args.duplicate()

	# If not including insights, restrict to hints only at SQL level
	var hints_only: bool = not args.get("include_insights", false)
	if hints_only:
		query_args["_hints_only"] = true

	var detail: String
	if args.has("detail") and str(args.detail) == "full":
		detail = "full_stripped"
	else:
		detail = "lean"

	var results := db.query_hints(query_args, detail)

	# Auto-bump retrieval count on the returned set — as ONE batch. A loop of
	# per-item bumps costs one full-database rewrite per item on the JSONL
	# backend (see DocketDBJsonl.bump_retrieval_many).
	var ids: Array = []
	for item in results:
		var id: String = str(item.get("id", ""))
		if not id.is_empty():
			ids.append(id)
	db.bump_retrieval_many(ids)

	return {"items": results, "count": results.size()}
