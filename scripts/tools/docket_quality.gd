extends RefCounted
class_name DocketQuality

const ELIGIBLE_TYPES := ["hint", "insight", "kb", "skill", "prompt"]


func get_definition() -> Dictionary:
	return {
		"name": "docket_quality",
		"description": "Score a knowledge item's quality (-5 to +5). Only for knowledge types: hint, insight, kb, skill, prompt. Sets quality score and last_reviewed timestamp.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"score": {"type": "integer", "minimum": -5, "maximum": 5},
				"reason": {"type": "string", "description": "Why this score (recorded in event log)"},
				"project": {"type": "string", "description": "Target project name"},
			},
			"required": ["id", "score"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = args.get("id", "")
	var item = db.get_item(id)
	if item == null:
		return {"error": "Item not found: %s" % id}

	var item_type: String = str(item.get("type", ""))
	if item_type not in ELIGIBLE_TYPES:
		return {"error": "Quality scoring only applies to knowledge types (hint, insight, kb, skill, prompt), not '%s'" % item_type}

	var score = args.get("score", 0)
	if typeof(score) != TYPE_INT and typeof(score) != TYPE_FLOAT:
		return {"error": "Score must be between -5 and +5, got %s" % str(score)}
	var score_int := int(score)
	if score_int < -5 or score_int > 5:
		return {"error": "Score must be between -5 and +5, got %s" % str(score_int)}

	var now: String = Time.get_datetime_string_from_system(true)
	if not now.ends_with("Z"): now += "Z"
	var old_quality := int(item.get("quality", 0))

	var reason: String = args.get("reason", "")
	var event_note := "Quality: %d -> %d" % [old_quality, score_int]
	if not reason.is_empty():
		event_note += " (%s)" % reason
	var registry: TypeRegistry = TypeRegistry.for_db(db, db.get_project_name())
	var error: String = registry._begin_item_mutation()
	if not error.is_empty(): return {"error":error}
	error = registry.update_item(id, {"quality":score_int,"last_reviewed":now}, "")
	if error.is_empty():
		if db is DocketDBJsonl: error = (db as DocketDBJsonl).add_event_checked(id, "quality_scored", "", event_note)
		else:
			db.add_event(id, "quality_scored", "", event_note)
			error = db._last_sql_error
	error = registry._complete_item_mutation(error)
	if not error.is_empty(): return {"error":error}

	return {"id": id, "quality": score_int, "last_reviewed": now, "previous_quality": old_quality}
