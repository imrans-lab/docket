extends RefCounted
class_name DocketSubscribe
## docket_subscribe: register a change-feed subscriber (DocketSubscriptions).


func get_definition() -> Dictionary:
	return {
		"name": "docket_subscribe",
		"description": "Register a subscriber to the project event log and get its id and initial cursor. The record is stored by this Docket server outside every project file, so it survives restart; read it with docket_changes_since and remove it with docket_unsubscribe. The subscription starts at each project's current head: only changes after this call are returned. filters (all optional): projects (names; default every loaded project, including session_file and memory projects), kinds (event kinds such as typed_update, transition, comment_added, claimed, created; default all), identity and role (declared principals). With identity or role the feed is scoped: only events on items whose assigned_to or directed_to equals the identity or role, plus those items' parents up to the first wr:objective item, evaluated from the current records at read time. Without them the feed holds every event in its projects.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Label for the subscriber (for humans; not unique)"},
				"filters": {
					"type": "object",
					"properties": {
						"projects": {"type": "array", "items": {"type": "string"}},
						"kinds": {"type": "array", "items": {"type": "string"}},
						"identity": {"type": "string"},
						"role": {"type": "string"},
					},
				},
			},
			"required": ["name"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	return DocketSubscriptions.subscribe(str(args.get("name", "")), args.get("filters", {}), DocketSubscriptions.loaded(db, project_dbs))
