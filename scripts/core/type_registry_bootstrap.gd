extends RefCounted
class_name TypeRegistryBootstrap
## Produces complete, deterministic starter revisions from the shipped schema.
## The resulting snapshots contain their own lifecycle and field meaning; later
## application releases never reinterpret an already persisted revision.

const STARTER_TIME := "2026-09-12T00:00:00Z"
const TEXT_FIELDS := ["title", "description", "created_by", "assigned_to", "directed_to", "resolution", "environment", "repro_steps", "assumed", "corrected", "findings", "answer", "why_chain", "significant_events", "contributing_factors", "value", "component", "key", "topic", "subtopic", "confidence", "surprise", "surfaced_from", "blocked_by", "parent", "test_setup", "test_steps", "expected_result", "command", "usage", "prompt_text", "preconditions", "summary", "article", "parameters", "steps", "outcome", "target", "source", "pristine_hash"]
const INTEGER_FIELDS := ["priority", "severity", "retrieval_count", "research_cost", "quality"]
const BOOLEAN_FIELDS := ["customised", "deprecated", "has_attachment"]
const ARRAY_FIELDS := ["tags", "tool_deps", "unsatisfied_deps"]
const OBJECT_FIELDS := ["optimization", "pristine_content"]
const DATE_FIELDS := ["created_at", "updated_at", "occurred_at", "detected_at", "reported_at", "last_reviewed"]
const COMMON_ITEM_FIELDS := ["title", "description", "created_by", "assigned_to", "directed_to", "priority", "severity", "tags", "parent"]
const COMMON_DEFAULTS := {"title":"", "description":"", "created_by":"", "assigned_to":"", "directed_to":"", "priority":0, "severity":0, "tags":[], "parent":""}
const STATE_CATEGORIES := {
	"bug": {"new":"queued","triaged":"queued","active":"active","resolved":"waiting","verified":"waiting","closed":"terminal"},
	"dcr": {"proposed":"queued","approved":"queued","designing":"active","implementing":"active","reviewing":"active","shipped":"terminal"},
	"rca": {"detected":"queued","investigating":"active","root_caused":"active","remediating":"active","verified":"waiting","closed":"terminal"},
	"chore": {"open":"queued","in_progress":"active","done":"terminal"},
	"hint": {"draft":"queued","validated":"active","promoted":"terminal"},
	"insight": {"draft":"queued","confirmed":"terminal"},
	"question": {"asked":"queued","researching":"active","escalated":"waiting","answered":"terminal"},
	"work_item": {"backlog":"queued","open":"queued","in_progress":"active","blocked":"waiting","done":"terminal"},
	"secret": {"active":"active","rotated":"active","revoked":"terminal"},
	"encrypted_note": {"draft":"queued","sealed":"terminal"},
	"test": {"draft":"queued","ready":"queued","passing":"active","failing":"active","skipped":"waiting","retired":"terminal"},
	"discussion": {"active":"active","resolved":"waiting"},
	"skill": {"draft":"queued","active":"active","archived":"waiting"},
	"prompt": {"draft":"queued","active":"active","archived":"waiting"},
	"kb": {"draft":"queued","active":"active","archived":"waiting"},
	"policy": {"draft":"queued","proposed":"queued","active":"active","suspended":"waiting","archived":"waiting"},
}

# Test seam for proving that a failed seed cannot leave a cache that appears
# complete. Production callers leave this invalid.
static var seed_failure_hook: Callable

static func load_shipped_schema() -> Dictionary:
	var file := FileAccess.open("res://data/schema.json", FileAccess.READ)
	if file == null: return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

static var _declared_schema: Dictionary = {}
static var _declared_version: String = ""
static var projects_opened: bool = false

static func effective_schema() -> Dictionary:
	return load_shipped_schema() if _declared_schema.is_empty() else _declared_schema.duplicate(true)

static func opening_refusal() -> String:
	return "Host schema must be declared before opening projects" if DocketRuntimeState.hosted and _declared_schema.is_empty() else ""

static func declare_schema(schema: Variant, version: Variant) -> Dictionary:
	if not version is String or version.strip_edges().is_empty(): return {"error":"Schema version must be a nonempty string"}
	if not schema is Dictionary: return {"error":"Schema must be an object"}
	if version == _declared_version and schema == _declared_schema: return {"version":version,"idempotent":true}
	if projects_opened: return {"error":"Cannot change schema after projects have opened"}
	var error := validate_schema(schema)
	if not error.is_empty(): return {"error":error}
	_declared_schema = schema.duplicate(true)
	_declared_version = version
	return {"version":version,"idempotent":false}

static func validate_schema(schema: Dictionary) -> String:
	if not schema.get("types") is Dictionary or schema.types.is_empty(): return "Schema types must be a nonempty object"
	for property in ["version", "id_prefix", "id_format"]:
		if schema.has(property) and not schema[property] is String: return "Schema %s must be a string" % property
	for property in ["common_fields", "link_relations", "priority_values", "severity_values"]:
		if schema.has(property) and not schema[property] is Array: return "Schema %s must be an array" % property
		for value in schema.get(property, []):
			if property in ["common_fields", "link_relations"] and not value is String: return "Schema %s must contain strings" % property
			if property in ["priority_values", "severity_values"] and not (value is int or value is float): return "Schema %s must contain numbers" % property
	for slug in schema.types:
		if not slug is String or not schema.types[slug] is Dictionary: return "Type names and definitions have invalid shapes"
		var source: Dictionary = schema.types[slug]
		for property in ["label", "description", "use_when", "initial_state"]:
			if source.has(property) and not source[property] is String: return "Type %s must be a string" % property
		for property in ["states", "terminal_states", "required_fields", "optional_fields", "resolutions"]:
			if not source.get(property, []) is Array: return "Type %s must be an array" % property
			var seen := {}
			for value in source.get(property, []):
				if not value is String or seen.has(value): return "Type %s must contain unique strings" % property
				seen[value] = true
		for property in ["transitions", "transition_rules", "field_definitions"]:
			if not source.get(property, {}) is Dictionary: return "Type %s must be an object" % property
		for key in source.get("field_definitions", {}):
			var descriptor: Variant = source.field_definitions[key]
			if not key is String or not descriptor is Dictionary: return "Field descriptors must be objects with string keys"
			if key not in source.get("required_fields", []) and key not in source.get("optional_fields", []) and key not in COMMON_ITEM_FIELDS: return "Field descriptor is not declared"
			for property in ["type", "key", "label", "description", "help"]:
				if descriptor.has(property) and not descriptor[property] is String: return "Field %s must be a string" % property
			for flag in ["required", "nullable", "mutable"]:
				if descriptor.has(flag) and not descriptor[flag] is bool: return "Field flags must be boolean"
			if descriptor.has("key") and descriptor.key != key: return "Conflicting field key"
	for revision in records(schema).type_def_versions:
		var error := TypeRegistry.validate_definition(revision.definition)
		if not error.is_empty(): return error
	return ""

static func records(schema: Dictionary) -> Dictionary:
	var definitions: Array = []
	var revisions: Array = []
	var slugs: Array = schema.get("types", {}).keys()
	slugs.sort()
	for slug_value in slugs:
		var slug := str(slug_value)
		var source: Dictionary = schema.types[slug]
		var type_id := "builtin:%s" % slug
		var complete := _complete_definition(slug, source)
		var revision_id := "%s@%s" % [type_id, _definition_hash(complete)]
		definitions.append({"_type": "type_def", "id": type_id, "slug": slug, "lifecycle": "active", "current_revision": revision_id, "provenance": {"kind": "starter", "protected": true}})
		revisions.append({"_type": "type_def_version", "id": revision_id, "type_id": type_id, "definition": complete, "author": "docket", "created_at": STARTER_TIME, "reason": "starter definition"})
	return {"type_defs": definitions, "type_def_versions": revisions}

static func _complete_definition(slug: String, source: Dictionary) -> Dictionary:
	var terminal: Array = source.get("terminal_states", []).duplicate()
	var states: Array = []
	for state_value in source.get("states", []):
		var state := str(state_value)
		states.append({"key": state, "state_category": _state_category(slug, state, terminal), "state_outcome": "unspecified" if terminal.has(state) else ""})
	var fields: Array = []
	var required: Array = source.get("required_fields", [])
	var field_keys: Array = COMMON_ITEM_FIELDS.duplicate()
	for value in required:
		if not field_keys.has(value): field_keys.append(value)
	for value in source.get("optional_fields", []):
		if not field_keys.has(value): field_keys.append(value)
	for key_value in field_keys:
		var key := str(key_value)
		var descriptor: Dictionary = source.get("field_definitions", {}).get(key, {}).duplicate(true)
		descriptor["key"] = key
		descriptor["type"] = descriptor.get("type", _field_type(key))
		descriptor["required"] = required.has(key)
		descriptor["nullable"] = not required.has(key)
		if not descriptor.has("default") and COMMON_DEFAULTS.has(key): descriptor["default"] = COMMON_DEFAULTS[key]
		descriptor["mutable"] = key != "created_by"
		fields.append(descriptor)
	var behavior := {"regular_creation_allowed": slug not in ["secret", "encrypted_note"]}
	if slug == "work_item": behavior["blocking"] = {"enabled": true, "state": "blocked"}
	return {"slug": slug, "label": source.get("label", slug), "description": source.get("description", ""), "use_when": source.get("use_when", source.get("description", "")), "fields": fields, "lifecycle": {"initial_state": source.get("initial_state", ""), "states": states, "terminal_states": terminal, "transitions": source.get("transitions", {}).duplicate(true), "guards": source.get("transition_rules", {}).duplicate(true), "enforcement": "guided"}, "protected": true, "protected_behavior": behavior}

static func _field_type(key: String) -> String:
	if key in INTEGER_FIELDS: return "integer"
	if key in BOOLEAN_FIELDS: return "boolean"
	if key in ARRAY_FIELDS: return "reference_list" if key == "tool_deps" else "array"
	if key in OBJECT_FIELDS: return "object"
	if key in DATE_FIELDS: return "timestamp"
	return "markdown" if key in ["description", "article", "steps", "prompt_text"] else "string"

static func _state_category(slug: String, state: String, terminal: Array) -> String:
	var mapped: String = str(STATE_CATEGORIES.get(slug, {}).get(state, ""))
	if not mapped.is_empty(): return mapped
	return "terminal" if terminal.has(state) else "active"

static func _definition_hash(definition: Dictionary) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSONLSerializer._json_value(definition).to_utf8_buffer())
	return context.finish().hex_encode()

static func seed_cache(db: DocketDB, schema: Dictionary = {}) -> String:
	var effective := schema if not schema.is_empty() else effective_schema()
	if effective.is_empty(): return "shipped schema is unavailable"
	var bootstrap := records(effective)
	db._last_sql_error = ""
	var error := db._exec_checked("BEGIN TRANSACTION;")
	if not error.is_empty(): return error
	JSONLCache._insert_type_registry(db, bootstrap.type_defs, bootstrap.type_def_versions)
	if seed_failure_hook.is_valid():
		var injected_error := str(seed_failure_hook.call())
		if not injected_error.is_empty() and db._last_sql_error.is_empty(): db._last_sql_error = injected_error
	if db._last_sql_error.is_empty():
		error = db._exec_checked("INSERT OR REPLACE INTO docket_meta (key,value) VALUES ('jsonl_version','2.0.0');")
	else:
		error = db._last_sql_error
	if not error.is_empty():
		db._rollback()
		return error
	error = db._exec_checked("COMMIT;")
	if not error.is_empty():
		db._rollback()
		return error
	return ""
