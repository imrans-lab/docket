extends RefCounted
class_name TypeRegistry
## Project-scoped resolution and validation for immutable type revisions.

const FIELD_TYPES := ["string", "markdown", "integer", "number", "boolean", "enum", "date", "timestamp", "item_ref", "reference_list", "array", "object"]
const UNIVERSAL_MUTABLE := ["title", "description", "assigned_to", "directed_to", "priority", "severity", "tags", "parent", "blocked_by"]
const STATE_CATEGORIES := ["queued", "active", "waiting", "terminal"]
const STATE_OUTCOMES := ["", "success", "action_required", "cancelled", "rejected", "duplicate", "superseded", "obsolete", "failed", "unspecified"]
const RESERVED_FIELD_KEYS := ["id", "type", "type_id", "type_revision", "status", "created_at", "updated_at", "events", "links", "fields", "extras", "fields_json", "extras_json", "unset_fields"]

var _db: DocketDB
var _project: String
var _legacy: bool
var _definitions: Dictionary = {}
var _revisions: Dictionary = {}
var _generation: String = ""

func _init(db: DocketDB, project: String = "") -> void:
	_db = db
	_project = project if not project.is_empty() else db.get_project_name()
	reload()

func reload() -> String:
	_definitions.clear()
	_revisions.clear()
	_legacy = _db.get_meta_value("jsonl_version", "1.0.0") != "2.0.0"
	if _legacy:
		var seeded := TypeRegistryBootstrap.records(TypeRegistryBootstrap.load_shipped_schema())
		for value in seeded.type_defs: _definitions[value.slug] = value
		for value in seeded.type_def_versions: _revisions[value.id] = value
		_generation = "legacy-1.0"
		return ""
	for row in _db._exec_select("SELECT * FROM type_defs ORDER BY slug,id;"):
		var provenance = JSON.parse_string(str(row.provenance_json))
		_definitions[str(row.slug)] = {"id":str(row.id),"slug":str(row.slug),"lifecycle":str(row.lifecycle),"current_revision":str(row.current_revision),"provenance":provenance if provenance is Dictionary else {}}
	for row in _db._exec_select("SELECT * FROM type_def_versions ORDER BY type_id,id;"):
		var definition = JSON.parse_string(str(row.definition_json))
		if not definition is Dictionary: return "malformed stored definition '%s'" % row.id
		_revisions[str(row.id)] = {"id":str(row.id),"type_id":str(row.type_id),"parent_revision":row.get("parent_revision"),"definition":definition,"author":str(row.author),"created_at":str(row.created_at),"reason":str(row.reason)}
	if not _db._last_sql_error.is_empty(): return _db._last_sql_error
	_generation = _db.get_meta_value("jsonl_hash", "")
	return ""

func refresh_if_changed() -> String:
	if _db is DocketDBJsonl:
		var json_db := _db as DocketDBJsonl
		if json_db.ensure_fresh(): return reload()
		if json_db.is_stale(): return json_db.last_write_error if not json_db.last_write_error.is_empty() else "canonical source changed but could not be reloaded"
	var current := _db.get_meta_value("jsonl_hash", "")
	return reload() if current != _generation and not current.is_empty() else ""

func list_types(include_deprecated: bool = false) -> Array:
	var result: Array = []
	for slug in _definitions:
		var record: Dictionary = _definitions[slug]
		if include_deprecated or record.lifecycle != "deprecated": result.append(_descriptor(record))
	result.sort_custom(func(a, b): return str(a.label).naturalnocasecmp_to(str(b.label)) < 0 or (str(a.label).nocasecmp_to(str(b.label)) == 0 and str(a.slug) < str(b.slug)))
	return result

func get_type(slug: String) -> Dictionary:
	if not _definitions.has(slug): return {"error":"unknown type '%s' in project '%s'" % [slug, _project]}
	return _descriptor(_definitions[slug])

func get_revision(revision_id: String) -> Dictionary:
	if not _revisions.has(revision_id): return {"error":"unknown revision '%s' in project '%s'" % [revision_id, _project]}
	return (_revisions[revision_id] as Dictionary).duplicate(true)

func resolve_item(item: Dictionary) -> Dictionary:
	var revision_id := str(item.get("type_revision", ""))
	if revision_id.is_empty() and _legacy:
		var record: Dictionary = _definitions.get(str(item.get("type", "")), {})
		revision_id = str(record.get("current_revision", ""))
	if not _revisions.has(revision_id): return {"error":"missing pinned revision '%s'" % revision_id,"semantics":"unknown","read_only":true}
	var revision: Dictionary = _revisions[revision_id]
	var definition: Dictionary = revision.definition
	if not _legacy and (str(revision.type_id) != str(item.get("type_id", "")) or str(definition.slug) != str(item.get("type", ""))): return {"error":"item type identity conflicts with its pinned revision","semantics":"unknown","read_only":true}
	var state := _state(definition, str(item.get("status", "")))
	if state.is_empty(): return {"error":"historical status '%s' is absent from pinned revision" % item.get("status", ""),"semantics":"unknown","read_only":true,"revision":revision}
	return {"project":_project,"revision":revision,"definition":definition,"state_category":state.state_category,"state_outcome":state.get("state_outcome", ""),"is_terminal":definition.lifecycle.terminal_states.has(item.status),"read_only":false}

func define_type(slug: String, definition: Dictionary, author: String, reason: String, provenance: Dictionary = {}) -> Dictionary:
	var refresh_error := refresh_if_changed()
	if not refresh_error.is_empty(): return {"error":refresh_error}
	if _legacy: return {"error":"type definitions are read-only until explicit JSONL 2.0 upgrade"}
	if reason.strip_edges().is_empty() or author.strip_edges().is_empty(): return {"error":"author and reason are required"}
	var candidate: Dictionary = definition.duplicate(true)
	candidate.slug = slug
	candidate.protected = false
	candidate.protected_behavior = {"regular_creation_allowed":true}
	if candidate.get("lifecycle") is Dictionary and not candidate.lifecycle.has("enforcement"): candidate.lifecycle.enforcement = "strict"
	var error := validate_definition(candidate)
	if not error.is_empty(): return {"error":error}
	if _definitions.has(slug):
		var existing := get_type(slug)
		if TypeRegistryBootstrap._definition_hash(existing.definition) == TypeRegistryBootstrap._definition_hash(candidate): return {"type":existing,"idempotent":true}
		return {"error":"slug '%s' already has different immutable meaning" % slug,"similar":_similar(candidate)}
	var type_id := "type:%s" % _db.next_uuid7_id()
	var revision_id := "%s@%s" % [type_id, TypeRegistryBootstrap._definition_hash(candidate)]
	var revision := {"id":revision_id,"type_id":type_id,"definition":candidate,"author":author,"created_at":Time.get_datetime_string_from_system(true),"reason":reason}
	var safe_provenance := provenance.duplicate(true)
	safe_provenance["protected"] = false
	var record := {"id":type_id,"slug":slug,"lifecycle":"draft","current_revision":revision_id,"provenance":safe_provenance}
	error = (_db as DocketDBJsonl).apply_registry_change(record, revision, [], [], "")
	if not error.is_empty(): return {"error":error}
	reload()
	return {"type":get_type(slug),"idempotent":false}

func deprecate_type(slug: String, expected_current: String, author: String, reason: String) -> String:
	return _set_type_lifecycle(slug, "deprecated", expected_current, author, reason)

func activate_type(slug: String, expected_current: String, author: String, reason: String) -> String:
	return _set_type_lifecycle(slug, "active", expected_current, author, reason)

func _set_type_lifecycle(slug: String, lifecycle: String, expected_current: String, author: String, reason: String) -> String:
	var refresh_error := refresh_if_changed()
	if not refresh_error.is_empty(): return refresh_error
	if _legacy: return "type definitions are read-only until explicit JSONL 2.0 upgrade"
	if not _definitions.has(slug): return "unknown type '%s'" % slug
	if reason.strip_edges().is_empty() or author.strip_edges().is_empty(): return "author and reason are required"
	var record: Dictionary = _definitions[slug].duplicate(true)
	if bool(record.provenance.get("protected", false)): return "protected built-in type lifecycle cannot be changed"
	if record.current_revision != expected_current: return "stale expected current revision"
	if record.lifecycle == lifecycle: return ""
	record.lifecycle = lifecycle
	var error := (_db as DocketDBJsonl)._begin_canonical_mutation()
	if not error.is_empty(): return error
	var provenance: Dictionary = record.provenance.duplicate(true)
	var history: Array = provenance.get("lifecycle_history", []).duplicate(true)
	history.append({"lifecycle":lifecycle,"author":author,"reason":reason,"timestamp":Time.get_datetime_string_from_system(true)})
	provenance.lifecycle_history = history
	error = _db._exec_checked("UPDATE type_defs SET lifecycle=?,provenance_json=? WHERE id=? AND current_revision=?;", [record.lifecycle,JSON.stringify(provenance,"",true,true),record.id,expected_current])
	error = (_db as DocketDBJsonl)._complete_canonical_mutation(error)
	if error.is_empty(): reload()
	return error

func validate_definition(definition: Dictionary) -> String:
	for key in ["slug","label","description","fields","lifecycle","protected","protected_behavior"]:
		if not definition.has(key): return "definition missing '%s'" % key
	if not _valid_identifier(str(definition.slug)): return "slug must use lowercase letters, digits, and underscores"
	if not definition.label is String or definition.label.strip_edges().is_empty() or not definition.description is String: return "label and description must be strings and label cannot be blank"
	if definition.has("use_when") and not definition.use_when is String: return "use_when must be a string"
	if not definition.protected is bool or not definition.protected_behavior is Dictionary: return "protected metadata has invalid shape"
	if not definition.fields is Array or not definition.lifecycle is Dictionary: return "fields and lifecycle have invalid shapes"
	var keys := {}
	for value in definition.fields:
		if not value is Dictionary: return "field descriptors must be objects"
		var field: Dictionary = value
		var key := str(field.get("key", ""))
		if not _valid_identifier(key) or keys.has(key): return "field keys must be lowercase identifiers and unique"
		if key in RESERVED_FIELD_KEYS: return "field key '%s' is reserved" % key
		keys[key] = true
		if str(field.get("type", "")) not in FIELD_TYPES: return "field '%s' has unsupported type" % key
		for flag in ["required", "nullable", "mutable"]:
			if field.has(flag) and not field[flag] is bool: return "field '%s' %s must be boolean" % [key, flag]
		if field.get("type") == "enum" and (not field.get("values", []) is Array or field.get("values", []).is_empty()): return "enum field '%s' requires values" % key
		if field.get("type") == "enum":
			var enum_seen := {}
			for option in field.values:
				if not option is String or option.strip_edges().is_empty() or enum_seen.has(option): return "enum field '%s' values must be unique strings" % key
				enum_seen[option] = true
		for constraint in ["minimum","maximum"]:
			if field.has(constraint) and not (field[constraint] is int or field[constraint] is float): return "field '%s' %s must be numeric" % [key,constraint]
			if field.has(constraint) and str(field.type) not in ["integer", "number"]: return "field '%s' numeric constraints require a numeric type" % key
		for constraint in ["min_length","max_length"]:
			if field.has(constraint) and (not field[constraint] is int or int(field[constraint]) < 0): return "field '%s' %s must be a non-negative integer" % [key,constraint]
			if field.has(constraint) and str(field.type) not in ["string", "markdown"]: return "field '%s' length constraints require a text type" % key
		if field.has("minimum") and field.has("maximum") and field.minimum > field.maximum: return "field '%s' minimum exceeds maximum" % key
		if field.has("min_length") and field.has("max_length") and field.min_length > field.max_length: return "field '%s' minimum length exceeds maximum" % key
		if field.has("default"):
			var default_error := _validate_value(field, field.default, true)
			if not default_error.is_empty(): return "field '%s' default: %s" % [key, default_error]
	var lifecycle: Dictionary = definition.lifecycle
	for key in ["initial_state","states","terminal_states","transitions","guards","enforcement"]:
		if not lifecycle.has(key): return "lifecycle missing '%s'" % key
	if not lifecycle.states is Array or not lifecycle.terminal_states is Array or not lifecycle.transitions is Dictionary or not lifecycle.guards is Dictionary: return "lifecycle collections have invalid shapes"
	if str(lifecycle.enforcement) not in ["strict","guided","open"]: return "unsupported lifecycle enforcement"
	var states := {}
	for value in lifecycle.states:
		if not value is Dictionary or not _valid_identifier(str(value.get("key", ""))): return "invalid lifecycle state"
		if states.has(value.key): return "lifecycle state keys must be unique"
		if str(value.get("state_category", "")) not in STATE_CATEGORIES: return "invalid state category"
		if not value.get("state_outcome", "") is String or str(value.get("state_outcome", "")) not in STATE_OUTCOMES: return "invalid state outcome"
		states[value.key] = true
	if not states.has(lifecycle.initial_state): return "initial state is not declared"
	var terminals := {}
	for terminal in lifecycle.terminal_states:
		if not terminal is String or terminals.has(terminal): return "terminal states must be unique strings"
		if not states.has(terminal): return "terminal state '%s' is not declared" % terminal
		terminals[terminal] = true
		var terminal_state := _state(definition, terminal)
		if terminal_state.get("state_category") != "terminal" or str(terminal_state.get("state_outcome", "")).is_empty(): return "terminal state '%s' requires terminal category and state_outcome" % terminal
	for state in lifecycle.states:
		if not terminals.has(state.key) and state.state_category == "terminal": return "nonterminal state '%s' cannot use terminal category" % state.key
	for source in lifecycle.transitions:
		if not states.has(source) or not lifecycle.transitions[source] is Array: return "invalid transition graph"
		var targets := {}
		for target in lifecycle.transitions[source]:
			if not target is String or targets.has(target): return "transition targets must be unique strings"
			if not states.has(target): return "transition target '%s' is not declared" % target
			targets[target] = true
	for state in states:
		if not lifecycle.transitions.has(state): return "transition graph missing state '%s'" % state
	for target in lifecycle.guards:
		if not states.has(target) or not lifecycle.guards[target] is Dictionary: return "guard target '%s' is invalid" % target
		var required_value = lifecycle.guards[target].get("required_fields", [])
		if not required_value is Array: return "guard required_fields must be an array"
		var guarded := {}
		for field in required_value:
			if not field is String or guarded.has(field): return "guard field keys must be unique strings"
			if not keys.has(field): return "guard field '%s' is not declared" % field
			guarded[field] = true
	return ""

func validate_candidate(definition: Dictionary, candidate: Dictionary, creation: bool = false) -> String:
	var descriptors := {}
	for value in definition.fields: descriptors[value.key] = value
	for key in candidate:
		if key not in descriptors and key not in UNIVERSAL_MUTABLE: return "field '%s' is unsupported by pinned revision" % key
		if descriptors.has(key):
			var error := _validate_value(descriptors[key], candidate[key], false)
			if not error.is_empty(): return "field '%s': %s" % [key, error]
		elif key in UNIVERSAL_MUTABLE:
			var universal_error := _validate_value(_universal_descriptor(key), candidate[key], false)
			if not universal_error.is_empty(): return "field '%s': %s" % [key, universal_error]
	for key in descriptors:
		var descriptor: Dictionary = descriptors[key]
		if bool(descriptor.get("required", false)) and (not candidate.has(key) or candidate[key] == null or (candidate[key] is String and candidate[key].strip_edges().is_empty())): return "required field '%s' is missing" % key
	return ""

func create_item(fields: Dictionary, actor: String = "") -> Dictionary:
	var refresh_error := refresh_if_changed()
	if not refresh_error.is_empty(): return {"error":refresh_error}
	var slug: String = str(fields.get("type", ""))
	var resolved: Dictionary = get_type(slug)
	if resolved.has("error"): return resolved
	if resolved.lifecycle != "active": return {"error":"type '%s' is %s and cannot create items" % [slug,resolved.lifecycle]}
	var definition: Dictionary = resolved.definition
	if not bool(definition.protected_behavior.get("regular_creation_allowed", true)): return {"error":"type '%s' requires its protected creation path" % slug}
	var normalized := _normalize_input(fields, true)
	if normalized.has("error"): return normalized
	var candidate: Dictionary = normalized.values
	for descriptor in definition.fields:
		if not candidate.has(descriptor.key) and descriptor.has("default"): candidate[descriptor.key] = descriptor.default
	var error := validate_candidate(definition, candidate, true)
	if not error.is_empty(): return {"error":error}
	var item := {"type":slug,"type_id":resolved.id,"type_revision":resolved.current_revision,"status":definition.lifecycle.initial_state,"title":candidate.get("title", ""),"created_at":Time.get_datetime_string_from_system(true),"updated_at":Time.get_datetime_string_from_system(true),"created_by":actor,"fields":{}}
	if _legacy:
		item.erase("type_id")
		item.erase("type_revision")
	for key in candidate:
		if key in DocketDB._ITEM_COLS or key == "tags": item[key] = candidate[key]
		elif key != "type": item.fields[key] = candidate[key]
	var id := _db.next_uuid7_id()
	error = _db.insert_item(id, item)
	return {"error":error} if not error.is_empty() else {"id":id,"item":_db.get_item(id)}

func update_item(id: String, changes: Dictionary, actor: String = "") -> String:
	var refresh_error := refresh_if_changed()
	if not refresh_error.is_empty(): return refresh_error
	var item := _db.get_item(id)
	if item.is_empty(): return "item not found"
	var resolved := resolve_item(item)
	if resolved.has("error"): return resolved.error
	if changes.has("type") or changes.has("type_id") or changes.has("type_revision") or changes.has("status"): return "registry-backed retype/status update is not allowed"
	var normalized := _normalize_input(changes)
	if normalized.has("error"): return normalized.error
	var mutable_error := _validate_mutable_patch(resolved.definition, normalized.values, normalized.unset)
	if not mutable_error.is_empty(): return mutable_error
	# Validate one complete clone before staging either the item patch or its audit.
	var candidate := _candidate_values(item, resolved.definition)
	for key in normalized.unset: candidate.erase(key)
	for key in normalized.values: candidate[key] = normalized.values[key]
	var error := validate_candidate(resolved.definition, candidate)
	if not error.is_empty(): return error
	var patch := _storage_patch(normalized.values, normalized.unset)
	if not _db is DocketDBJsonl:
		_db._last_sql_error = ""
		error = _db._exec_checked("BEGIN TRANSACTION;")
		if error.is_empty(): error = _db.update_item_fields_checked(id, patch)
		if error.is_empty():
			_db.add_event(id, "typed_update", actor)
			error = _db._last_sql_error
		if error.is_empty(): error = _db._exec_checked("COMMIT;")
		else: _db._rollback()
		return error
	error = (_db as DocketDBJsonl)._begin_canonical_mutation()
	if not error.is_empty(): return error
	error = (_db as DocketDBJsonl).update_item_fields_checked(id, patch)
	if error.is_empty(): error = (_db as DocketDBJsonl).add_event_checked(id, "typed_update", actor)
	return (_db as DocketDBJsonl)._complete_canonical_mutation(error)

func transition_item(id: String, target: String, actor: String, note: String = "", extra: Dictionary = {}) -> String:
	var refresh_error := refresh_if_changed()
	if not refresh_error.is_empty(): return refresh_error
	var item: Dictionary = _db.get_item(id)
	if item.is_empty(): return "item not found"
	var resolved: Dictionary = resolve_item(item)
	if resolved.has("error"): return resolved.error
	var definition: Dictionary = resolved.definition
	var lifecycle: Dictionary = definition.lifecycle
	if _state(definition, target).is_empty(): return "target state '%s' is not declared" % target
	var normal: bool = lifecycle.transitions.get(item.status, []).has(target)
	if lifecycle.enforcement == "strict" and not normal: return "strict lifecycle rejects off-flow transition"
	if lifecycle.enforcement == "guided" and not normal and note.strip_edges().is_empty(): return "off-flow transition requires a note"
	var normalized := _normalize_input(extra)
	if normalized.has("error"): return normalized.error
	var mutable_error := _validate_mutable_patch(definition, normalized.values, normalized.unset)
	if not mutable_error.is_empty(): return mutable_error
	var candidate: Dictionary = _candidate_values(item, definition)
	for key in normalized.unset: candidate.erase(key)
	for key in normalized.values: candidate[key] = normalized.values[key]
	var guard: Dictionary = lifecycle.guards.get(target, {})
	for field in guard.get("required_fields", []):
		if not candidate.has(field) or candidate[field] == null or (candidate[field] is String and candidate[field].strip_edges().is_empty()): return "transition to '%s' requires field '%s'" % [target, field]
	var error := validate_candidate(definition, candidate)
	if not error.is_empty(): return error
	var patch := _storage_patch(normalized.values, normalized.unset)
	patch.status = target
	if not _db is DocketDBJsonl:
		_db._last_sql_error = ""
		var legacy_error := _db._exec_checked("BEGIN TRANSACTION;")
		if legacy_error.is_empty(): legacy_error = _db.update_item_fields_checked(id, patch)
		if legacy_error.is_empty():
			_db.add_event(id, "transition", actor, "%s → %s%s" % [item.status,target,". "+note if not note.is_empty() else ""])
			legacy_error = _db._last_sql_error
		if legacy_error.is_empty(): legacy_error = _db._exec_checked("COMMIT;")
		else: _db._rollback()
		return legacy_error
	error = (_db as DocketDBJsonl)._begin_canonical_mutation()
	if not error.is_empty(): return error
	error = (_db as DocketDBJsonl).update_item_fields_checked(id, patch)
	if error.is_empty(): error = (_db as DocketDBJsonl).add_event_checked(id, "transition", actor, "%s → %s%s" % [item.status,target,". "+note if not note.is_empty() else ""])
	var blocking: Dictionary = definition.protected_behavior.get("blocking", {})
	if error.is_empty() and bool(blocking.get("enabled", false)) and target == str(blocking.get("state", "")) and normalized.values.has("blocked_by"):
		var blocker := str(normalized.values.blocked_by)
		if ":" in blocker: blocker = blocker.split(":", false, 1)[1]
		if _db.has_item(blocker): error = (_db as DocketDBJsonl).add_link_checked(blocker, id, "blocks")
	return (_db as DocketDBJsonl)._complete_canonical_mutation(error)

func repair_item_status(id: String, target: String, actor: String, reason: String, fields: Dictionary = {}) -> String:
	var refresh_error := refresh_if_changed()
	if not refresh_error.is_empty(): return refresh_error
	if actor.strip_edges().is_empty() or reason.strip_edges().is_empty(): return "actor and repair reason are required"
	var item: Dictionary = _db.get_item(id)
	if item.is_empty(): return "item not found"
	var revision_id := str(item.get("type_revision", ""))
	if revision_id.is_empty() and _legacy:
		var legacy_type: Dictionary = get_type(str(item.get("type", "")))
		if legacy_type.has("error"): return legacy_type.error
		revision_id = legacy_type.current_revision
	if not _revisions.has(revision_id): return "missing pinned revision '%s'" % revision_id
	var revision: Dictionary = _revisions[revision_id]
	var definition: Dictionary = revision.definition
	if not _legacy and (str(revision.type_id) != str(item.get("type_id", "")) or str(definition.slug) != str(item.get("type", ""))): return "item type identity conflicts with its pinned revision"
	if _state(definition, target).is_empty(): return "repair target state '%s' is not declared" % target
	var normalized := _normalize_input(fields)
	if normalized.has("error"): return normalized.error
	var mutable_error := _validate_mutable_patch(definition, normalized.values, normalized.unset)
	if not mutable_error.is_empty(): return mutable_error
	var candidate := _candidate_values(item, definition)
	for key in normalized.unset: candidate.erase(key)
	for key in normalized.values: candidate[key] = normalized.values[key]
	var guard: Dictionary = definition.lifecycle.guards.get(target, {})
	for key in guard.get("required_fields", []):
		if not candidate.has(key) or candidate[key] == null or (candidate[key] is String and candidate[key].strip_edges().is_empty()): return "repair to '%s' requires field '%s'" % [target, key]
	var error := validate_candidate(definition, candidate)
	if not error.is_empty(): return error
	var patch := _storage_patch(normalized.values, normalized.unset); patch.status = target
	if not _db is DocketDBJsonl:
		_db._last_sql_error = ""
		error = _db._exec_checked("BEGIN TRANSACTION;")
		if error.is_empty(): error = _db.update_item_fields_checked(id, patch)
		if error.is_empty():
			_db.add_event(id, "status_repaired", actor, reason)
			error = _db._last_sql_error
		if error.is_empty(): error = _db._exec_checked("COMMIT;")
		else: _db._rollback()
		return error
	error = (_db as DocketDBJsonl)._begin_canonical_mutation()
	if not error.is_empty(): return error
	error = (_db as DocketDBJsonl).update_item_fields_checked(id, patch)
	if error.is_empty(): error = (_db as DocketDBJsonl).add_event_checked(id, "status_repaired", actor, reason)
	return (_db as DocketDBJsonl)._complete_canonical_mutation(error)

func preview_evolution(slug: String, definition: Dictionary, expected_current: String, item_ids: Array = []) -> Dictionary:
	var refresh_error := refresh_if_changed()
	if not refresh_error.is_empty(): return {"error":refresh_error}
	var current := get_type(slug)
	if current.has("error"): return current
	if current.current_revision != expected_current: return {"error":"stale expected current revision"}
	if bool(current.provenance.get("protected", false)): return {"error":"protected built-in definitions cannot be overridden"}
	var candidate: Dictionary = definition.duplicate(true)
	candidate.slug = slug
	var error := validate_definition(candidate)
	if not error.is_empty(): return {"error":error}
	error = _compatible(current.definition, candidate)
	if not error.is_empty(): return {"error":error}
	var impacts: Array = []
	for id in item_ids:
		var item: Dictionary = _db.get_item(str(id))
		if item.is_empty(): return {"error":"selected item '%s' is missing" % id}
		if str(item.type_id) != str(current.id): return {"error":"selected item '%s' belongs to another type" % id}
		error = validate_candidate(candidate, _candidate_values(item, current.definition))
		if not error.is_empty(): return {"error":"item '%s': %s" % [id,error]}
		impacts.append(str(id))
	return {"slug":slug,"expected_current":expected_current,"definition":candidate,"items":impacts,"saved_query_impact":_saved_query_impact(slug, candidate)}

func apply_evolution(preview: Dictionary, author: String, reason: String) -> String:
	if preview.has("error") or author.strip_edges().is_empty() or reason.strip_edges().is_empty(): return str(preview.get("error", "author and reason are required"))
	var reload_error := refresh_if_changed()
	if reload_error.is_empty(): reload_error = reload()
	if not reload_error.is_empty(): return reload_error
	var begin_error := (_db as DocketDBJsonl)._begin_canonical_mutation()
	if not begin_error.is_empty(): return begin_error
	# Preview dictionaries are untrusted and can outlive their source snapshot.
	var checked := preview_evolution(str(preview.get("slug", "")), preview.get("definition", {}), str(preview.get("expected_current", "")), preview.get("items", []))
	if checked.has("error"): return (_db as DocketDBJsonl)._complete_canonical_mutation(str(checked.error))
	var current: Dictionary = get_type(checked.slug)
	var revision_id := "%s@%s" % [current.id, TypeRegistryBootstrap._definition_hash(checked.definition)]
	if revision_id == current.current_revision:
		var bind_error := ""
		for id in checked.items:
			if not bind_error.is_empty(): break
			var item: Dictionary = _db.get_item(id)
			var defaults := {}
			for descriptor in checked.definition.fields:
				if descriptor.has("default") and not item.has(descriptor.key) and not item.get("fields", {}).has(descriptor.key): defaults[descriptor.key] = descriptor.default
			if not defaults.is_empty(): bind_error = (_db as DocketDBJsonl).update_item_fields_checked(id, _storage_patch(defaults, []))
			if not bind_error.is_empty(): break
			bind_error = _db._exec_checked("UPDATE items SET type_id=?,type_revision=? WHERE id=?;", [current.id, revision_id, id])
			if bind_error.is_empty(): bind_error = _db._exec_checked("INSERT INTO item_events (item_id,event_type,actor,timestamp,note) VALUES (?,?,?,?,?);", [id,"type_revision_changed",author,Time.get_datetime_string_from_system(true),reason])
		return (_db as DocketDBJsonl)._complete_canonical_mutation(bind_error)
	var revision := {"id":revision_id,"type_id":current.id,"parent_revision":current.current_revision,"definition":checked.definition,"author":author,"created_at":Time.get_datetime_string_from_system(true),"reason":reason}
	var record: Dictionary = _definitions[checked.slug].duplicate(true)
	record.current_revision = revision_id
	var bindings: Array = []
	var events: Array = []
	for id in checked.items:
		var item: Dictionary = _db.get_item(id)
		var defaults := {}
		for descriptor in checked.definition.fields:
			if descriptor.has("default") and not item.has(descriptor.key) and not item.get("fields", {}).has(descriptor.key): defaults[descriptor.key] = descriptor.default
		bindings.append({"item_id":id,"type_id":current.id,"type_revision":revision_id,"changes":_storage_patch(defaults, [])})
		events.append({"item_id":id,"event_type":"type_revision_changed","actor":author,"timestamp":Time.get_datetime_string_from_system(true),"note":reason})
	var error := (_db as DocketDBJsonl).apply_registry_change(record, revision, bindings, events, current.current_revision)
	error = (_db as DocketDBJsonl)._complete_canonical_mutation(error)
	if error.is_empty(): reload()
	return error

func _descriptor(record: Dictionary) -> Dictionary:
	var revision: Dictionary = _revisions.get(record.current_revision, {})
	return {"project":_project,"id":record.id,"slug":record.slug,"lifecycle":record.lifecycle,"current_revision":record.current_revision,"provenance":record.provenance.duplicate(true),"definition":revision.get("definition", {}).duplicate(true),"label":revision.get("definition", {}).get("label", record.slug),"description":revision.get("definition", {}).get("description", ""),"use_when":revision.get("definition", {}).get("use_when", "")}

func _state(definition: Dictionary, key: String) -> Dictionary:
	for value in definition.lifecycle.states:
		if str(value.key) == key: return value
	return {}

func _candidate_values(item: Dictionary, definition: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var custom: Dictionary = item.get("fields", {})
	for descriptor in definition.fields:
		if item.has(descriptor.key): result[descriptor.key] = item[descriptor.key]
		elif custom.has(descriptor.key): result[descriptor.key] = custom[descriptor.key]
	for key in UNIVERSAL_MUTABLE:
		if item.has(key): result[key] = item[key]
	return result

func _normalize_input(input: Dictionary, allow_type: bool = false) -> Dictionary:
	for key in input:
		if key in RESERVED_FIELD_KEYS and key not in ["fields", "unset_fields"] and not (allow_type and key == "type"): return {"error":"reserved field '%s' cannot be written" % key}
	if input.has("fields") and not input.fields is Dictionary: return {"error":"fields must be an object"}
	if input.has("extras"): return {"error":"unknown stored extras are preserved but cannot be edited through typed operations"}
	var values: Dictionary = input.get("fields", {}).duplicate(true)
	for key in values:
		if key in RESERVED_FIELD_KEYS: return {"error":"reserved field '%s' cannot be written" % key}
	for key in input:
		if key not in ["fields","unset_fields","type"]:
			if values.has(key): return {"error":"ambiguous field authority for '%s'" % key}
			values[key] = input[key]
	var unset_value = input.get("unset_fields", [])
	if not unset_value is Array: return {"error":"unset_fields must be an array"}
	var unset: Array = []
	for key in unset_value:
		if not key is String: return {"error":"unset field keys must be strings"}
		if key in RESERVED_FIELD_KEYS: return {"error":"reserved field '%s' cannot be unset" % key}
		if values.has(key): return {"error":"field '%s' cannot be set and unset" % key}
		unset.append(key)
	return {"values":values,"unset":unset}

func _validate_mutable_patch(definition: Dictionary, values: Dictionary, unset: Array) -> String:
	var descriptors := {}
	for descriptor in definition.fields: descriptors[descriptor.key] = descriptor
	for key in values.keys() + unset:
		if descriptors.has(key) and not bool(descriptors[key].get("mutable", true)): return "field '%s' is immutable" % key
	return ""

func _universal_descriptor(key: String) -> Dictionary:
	if key in ["priority", "severity"]: return {"key":key,"type":"integer","nullable":true}
	if key == "tags": return {"key":key,"type":"array","nullable":true}
	return {"key":key,"type":"string","nullable":true}

func _storage_patch(values: Dictionary, unset: Array) -> Dictionary:
	var patch := {"fields":{},"unset_fields":[]}
	for key in values:
		if key in DocketDB._ITEM_COLS or key == "tags": patch[key] = values[key]
		else: patch.fields[key] = values[key]
	for key in unset:
		if key in DocketDB._ITEM_COLS or key == "tags": patch[key] = null
		else: patch.unset_fields.append(key)
	if patch.fields.is_empty(): patch.erase("fields")
	if patch.unset_fields.is_empty(): patch.erase("unset_fields")
	return patch

func _validate_value(field: Dictionary, value, default_value: bool) -> String:
	if value == null: return "null is not allowed" if not bool(field.get("nullable", false)) else ""
	var kind: String = str(field.type)
	var valid: bool = false
	match kind:
		"string", "markdown", "enum", "date", "timestamp", "item_ref": valid = value is String
		"integer": valid = value is int or (value is float and value == floor(value))
		"number": valid = value is int or value is float
		"boolean": valid = value is bool
		"reference_list":
			valid = value is Array
			if valid:
				for entry in value:
					if not entry is String: valid = false; break
		"array": valid = value is Array
		"object": valid = value is Dictionary
	if not valid: return "expected %s" % kind
	if kind == "enum" and value not in field.values: return "value is not in enum"
	if kind == "date" and not _looks_like_date(value): return "expected ISO date YYYY-MM-DD"
	if kind == "timestamp" and not _looks_like_timestamp(value): return "expected ISO timestamp"
	if kind == "item_ref" and value.strip_edges().is_empty(): return "item reference cannot be blank"
	if value is String:
		if field.has("min_length") and value.length() < int(field.min_length): return "shorter than minimum length"
		if field.has("max_length") and value.length() > int(field.max_length): return "longer than maximum length"
	if value is int or value is float:
		if field.has("minimum") and value < field.minimum: return "below minimum"
		if field.has("maximum") and value > field.maximum: return "above maximum"
	return ""

func _looks_like_date(value: String) -> bool:
	if value.length() != 10 or value[4] != "-" or value[7] != "-": return false
	var year := value.substr(0,4); var month := value.substr(5,2); var day := value.substr(8,2)
	if not _all_digits(year) or not _all_digits(month) or not _all_digits(day): return false
	var year_number := int(year); var month_number := int(month); var day_number := int(day)
	if month_number < 1 or month_number > 12: return false
	var days := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if year_number % 400 == 0 or (year_number % 4 == 0 and year_number % 100 != 0): days[1] = 29
	return day_number >= 1 and day_number <= days[month_number - 1]

func _valid_identifier(value: String) -> bool:
	if value.is_empty() or not "abcdefghijklmnopqrstuvwxyz".contains(value[0]): return false
	for character in value:
		if not "abcdefghijklmnopqrstuvwxyz0123456789_".contains(character): return false
	return true

func _all_digits(value: String) -> bool:
	if value.is_empty(): return false
	for character in value:
		if not "0123456789".contains(character): return false
	return true

func _looks_like_timestamp(value: String) -> bool:
	# Validate the RFC 3339 date/time core before accepting UTC or a numeric offset.
	if value.length() < 20 or value[10] != "T" or not _looks_like_date(value.left(10)): return false
	var hour := value.substr(11, 2); var minute := value.substr(14, 2); var second := value.substr(17, 2)
	if value[13] != ":" or value[16] != ":" or not _all_digits(hour) or not _all_digits(minute) or not _all_digits(second): return false
	if int(hour) > 23 or int(minute) > 59 or int(second) > 59: return false
	var suffix := value.substr(19)
	if suffix == "Z": return true
	if suffix.begins_with("."):
		var zone_at := suffix.find("Z")
		if zone_at > 1 and _all_digits(suffix.substr(1, zone_at - 1)) and zone_at == suffix.length() - 1: return true
		var plus_at := suffix.find("+"); var minus_at := suffix.find("-")
		var offset_at := plus_at if plus_at >= 0 else minus_at
		if offset_at <= 1 or not _all_digits(suffix.substr(1, offset_at - 1)): return false
		suffix = suffix.substr(offset_at)
	if suffix.length() != 6 or suffix[0] not in ["+", "-"] or suffix[3] != ":": return false
	var zone_hour := suffix.substr(1, 2); var zone_minute := suffix.substr(4, 2)
	if not _all_digits(zone_hour) or not _all_digits(zone_minute): return false
	return int(zone_hour) < 14 and int(zone_minute) <= 59 or (int(zone_hour) == 14 and int(zone_minute) == 0)

func _compatible(old: Dictionary, candidate: Dictionary) -> String:
	var old_fields := {}
	for field in old.fields: old_fields[field.key] = field
	var new_fields := {}
	for field in candidate.fields: new_fields[field.key] = field
	for key in old_fields:
		if not new_fields.has(key) or new_fields[key].type != old_fields[key].type: return "evolution cannot remove or change existing field '%s'" % key
		for invariant in ["required","nullable","default","values","minimum","maximum","min_length","max_length","mutable"]:
			if old_fields[key].get(invariant) != new_fields[key].get(invariant): return "existing field '%s' constraint '%s' cannot change" % [key,invariant]
	for key in new_fields:
		if not old_fields.has(key) and bool(new_fields[key].get("required", false)): return "new fields must be optional"
	var old_states := {}
	for state in old.lifecycle.states: old_states[state.key] = state
	var new_states := {}
	for state in candidate.lifecycle.states: new_states[state.key] = state
	for key in old_states:
		if not new_states.has(key): return "existing state '%s' cannot be removed" % key
		for invariant in ["state_category","state_outcome"]:
			if old_states[key].get(invariant) != new_states[key].get(invariant): return "existing state '%s' meaning cannot change" % key
	if old.lifecycle.initial_state != candidate.lifecycle.initial_state or old.lifecycle.enforcement != candidate.lifecycle.enforcement: return "existing lifecycle defaults and enforcement cannot change"
	if old.protected != candidate.protected or old.protected_behavior != candidate.protected_behavior: return "protected behavior cannot change"
	for key in old_states:
		if old.lifecycle.terminal_states.has(key) != candidate.lifecycle.terminal_states.has(key): return "existing state '%s' terminal membership cannot change" % key
	# Added states may connect freely; the graph induced by old states is immutable.
	for source in old_states:
		for target in old_states:
			if old.lifecycle.transitions.get(source, []).has(target) != candidate.lifecycle.transitions.get(source, []).has(target): return "transition graph among existing states cannot change"
	for target in old_states:
		if old.lifecycle.guards.get(target, {}) != candidate.lifecycle.guards.get(target, {}): return "guard for existing state '%s' cannot change" % target
	return ""

func _similar(candidate: Dictionary) -> Array:
	var result: Array = []
	for descriptor in list_types(true):
		if str(descriptor.label).nocasecmp_to(str(candidate.label)) == 0 or str(descriptor.slug).similarity(str(candidate.slug)) >= 0.6: result.append({"slug":descriptor.slug,"label":descriptor.label})
	return result

func _saved_query_impact(slug: String, definition: Dictionary) -> Array:
	var impacts: Array = []
	var fields := {}
	for descriptor in definition.fields: fields[descriptor.key] = true
	var states := {}
	for state in definition.lifecycle.states: states[state.key] = true
	for query in _db.list_queries():
		var references: Array = []
		_collect_query_references(query.get("query", query), slug, fields, states, references)
		if not references.is_empty(): impacts.append({"name":query.get("name", ""),"references":references})
	return impacts

func _collect_query_references(value, slug: String, fields: Dictionary, states: Dictionary, references: Array) -> void:
	if value is Array:
		for child in value: _collect_query_references(child, slug, fields, states, references)
		return
	if not value is Dictionary: return
	var node: Dictionary = value
	var field := str(node.get("field", ""))
	if field == "type" and _query_value_contains(node.get("value"), slug): _append_unique(references, "type")
	elif field == "status":
		for state in states:
			if _query_value_contains(node.get("value"), state): _append_unique(references, "status:%s" % state)
	elif fields.has(field): _append_unique(references, "field:%s" % field)
	for key in node:
		var base_key := str(key).split("__", false, 1)[0]
		if base_key == "type" and _query_value_contains(node[key], slug): _append_unique(references, "type")
		elif base_key == "status":
			for state in states:
				if _query_value_contains(node[key], state): _append_unique(references, "status:%s" % state)
		elif fields.has(base_key): _append_unique(references, "field:%s" % base_key)
		_collect_query_references(node[key], slug, fields, states, references)

func _query_value_contains(value, expected: String) -> bool:
	if value is Array: return value.has(expected)
	return value is String and value == expected

func _append_unique(values: Array, value: String) -> void:
	if not values.has(value): values.append(value)
