extends RefCounted
class_name DocketUpdate


func get_definition() -> Dictionary:
	return {
		"name": "docket_update",
		"description": "Update fields on an existing item. Not for state transitions — use docket_transition.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"fields": {"type":"object","description":"Typed custom field values"},
				"unset_fields": {"type":"array","items":{"type":"string"}},
				"expected_revision": {"type":"string","description":"Expected pinned type revision for stale-form refusal"},
				"expected_item_token": {"type":"string","description":"Expected content token for stale-form refusal"},
				"title": {"type": "string"},
				"description": {"type": "string"},
				"priority": {"type": "integer"},
				"severity": {"type": "integer"},
				"tags": {"type": "array", "items": {"type": "string"}},
				"assigned_to": {"type": "string"},
				"directed_to": {"type": "string"},
				"parent": {"type": "string", "description": "Parent item ID (e.g. DKT-0009)"},
				# Bug fields
				"environment": {"type": "string"},
				"repro_steps": {"type": "string"},
				# RCA fields
				"occurred_at": {"type": "string"},
				"detected_at": {"type": "string"},
				"reported_at": {"type": "string"},
				"why_chain": {"type": "string"},
				"significant_events": {"type": "string"},
				"contributing_factors": {"type": "string"},
				# Hint fields
				"value": {"type": "string"},
				"component": {"type": "string"},
				"key": {"type": "string"},
				"confidence": {"type": "string"},
				"research_cost": {"type": "integer", "minimum": 0},
				# Insight fields
				"assumed": {"type": "string"},
				"corrected": {"type": "string"},
				"surprise": {"type": "string"},
				"surfaced_from": {"type": "string"},
				# Question fields
				"findings": {"type": "string"},
				"answer": {"type": "string"},
				# Test fields
				"test_setup": {"type": "string", "description": "Setup instructions (conda envs, libs, resources)"},
				"test_steps": {"type": "string", "description": "Execution steps"},
				"expected_result": {"type": "string", "description": "Expected outcome"},
				# Skill fields
				"steps": {"type": "string", "description": "The executable pipeline — ordered commands/actions for an LLM to follow"},
				"preconditions": {"type": "string", "description": "What must be true before using this skill"},
				"outcome": {"type": "string", "description": "What success looks like when the skill completes"},
				"tool_deps": {"type": "array", "items": {"type": "string"}, "description": "Tool names this skill requires"},
				"optimization": {"type": "object", "description": "Runtime optimization profile: {context_window, summary_mode, tool_idle_turns, tool_budget}"},
				# Plugin-shipped skills metadata (Minerva DCR 019df57b)
				"source": {"type": "string", "description": "Origin marker: 'user', 'master', or 'plugin:<plugin_id>'."},
				"customised": {"type": "boolean", "description": "True once user has edited a plugin-seeded skill."},
				"pristine_hash": {"type": "string", "description": "SHA-256 of canonical-JSON pristine content."},
				"pristine_content": {"type": "object", "description": "Original plugin-shipped record, preserved for update-time diff."},
				"unsatisfied_deps": {"type": "array", "items": {"type": "string"}, "description": "tool_deps not resolvable in current registry."},
				"deprecated": {"type": "boolean", "description": "True if upstream removed this skill in a later plugin version."},
				# Prompt fields
				"parameters": {"type": "string", "description": "Variables or placeholders in the prompt"},
				# KB fields
				"article": {"type": "string", "description": "The full article body (long-form content)"},
				"summary": {"type": "string", "description": "Short preview (1-2 sentences) for search results"},
				# Knowledge quality fields
				"quality": {"type": "integer", "minimum": -5, "maximum": 5, "description": "Quality score (-5 to +5, knowledge types only)"},
				"last_reviewed": {"type": "string", "description": "ISO 8601 timestamp of last quality review"},
				# Work item fields
				"blocked_by": {"type": "string"},
				# Model targeting
				"target": {"type": "string", "description": "Model targeting expression. Grammar: family[:version][@provider]. Examples: 'all', 'sonnet', 'sonnet:<=4.6', 'sonnet:<=4.6@openrouter'. Comma-separated for OR."},
				# Multi-project
				"project": {"type": "string", "description": "Target project name (optional, defaults to primary)"},
			},
			"required": ["id"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = args.get("id", "")
	if not db.has_item(id):
		return {"error": "Item not found: %s" % id}

	# Auto-qualify parent if bare ID
	if args.has("parent") and not str(args.parent).is_empty():
		var parent_str: String = str(args.parent)
		if not parent_str.contains(":"):
			var proj_name := db.get_project_name()
			if not proj_name.is_empty():
				args["parent"] = "%s:%s" % [proj_name, parent_str]

	var changes: Dictionary = args.duplicate()
	changes.erase("id")
	changes.erase("project")
	var expected_revision: String = str(changes.get("expected_revision", ""))
	changes.erase("expected_revision")
	var expected_item_token: String = str(changes.get("expected_item_token", ""))
	changes.erase("expected_item_token")
	changes = _without_no_ops(changes, db.get_item(id))
	# A write that changes nothing still appends an update event, so a caller
	# that re-applies the same values on a loop (a reconcile pass, a scheduler)
	# grows the file by one event per call forever. Nothing left to apply means
	# there is nothing to record either. Staleness checks still have to run, so
	# the early return only applies when the caller asked for none.
	if changes.is_empty() and expected_revision.is_empty() and expected_item_token.is_empty():
		return {"id":id,"status":"unchanged"}
	var update_registry: TypeRegistry = TypeRegistry.for_db(db, db.get_project_name())
	var typed_error: String = update_registry.update_item(id, changes, "agent", expected_revision, expected_item_token)
	return {"error":typed_error} if not typed_error.is_empty() else {"id":id,"status":"updated","type_revision":db.get_item(id).get("type_revision", ""),"item_token":update_registry.item_token(id)}


static func _without_no_ops(changes: Dictionary, item: Dictionary) -> Dictionary:
	## Drop the entries whose value the item already holds. Unset requests are
	## left alone: absence is not a value this can compare against.
	var effective: Dictionary = {}
	var stored_fields: Dictionary = item.get("fields", {}) if item.get("fields", {}) is Dictionary else {}
	for key in changes:
		if key in ["unset_fields", "unset_extras"]:
			effective[key] = changes[key]
		elif key == "fields" and changes[key] is Dictionary:
			var effective_fields: Dictionary = {}
			for field_key in changes[key]:
				if not _values_equal(changes[key][field_key], stored_fields.get(field_key)):
					effective_fields[field_key] = changes[key][field_key]
			if not effective_fields.is_empty():
				effective[key] = effective_fields
		elif not _values_equal(changes[key], item.get(key)):
			effective[key] = changes[key]
	return effective


static func _values_equal(a, b) -> bool:
	## JSON-shaped equality. MCP arguments arrive parsed, so a count the caller
	## sent as 4 reaches here as 4.0 and has to compare equal to a stored 4.
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	return JSON.stringify(a) == JSON.stringify(b)
