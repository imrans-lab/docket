extends RefCounted
class_name MasterBootstrapApply
## Explicit disk-only apply; never opens a cache or initializes a loaded file.
## Same advisory multi-owner contract as ordinary writers: observed drift
## refuses, but an uncooperative writer can race the final check and rename.

const STATE_KEY := "master_bootstrap_state"
const STATE_VERSION := 1
static var lock_timeout_ms := 5000
## Called after authoritative acquisition, before planning, for real drift tests.
static var acquired_hook: Callable

static func apply(path: String, shipment_jsonl: String, declared_schema: Dictionary) -> Dictionary:
	if path.is_empty(): return _refuse("Canonical path is empty")
	var shipment := JSONLParser.parse_bytes(shipment_jsonl.to_utf8_buffer(), "shipment")
	var error := MasterBootstrapPlan._validate(shipment)
	if not error.is_empty(): return _refuse("Shipment: " + error)
	if shipment.meta.has(STATE_KEY): return _refuse("Shipment may not seed reserved bootstrap state")
	var lock := FileLock.acquire(path, lock_timeout_ms)
	if lock == null: return _refuse("Could not acquire advisory lock")
	var result := _apply_locked(path, shipment, declared_schema)
	lock.release()
	return result

static func _apply_locked(path: String, shipment: Dictionary, schema: Dictionary) -> Dictionary:
	var exists := FileAccess.file_exists(path)
	if not exists and DirAccess.dir_exists_absolute(path): return _refuse("Canonical path is unreadable")
	var source := {}
	var current: Variant = null
	var state := {"baseline":null, "ever_shipped":[]}
	if exists:
		if DirAccess.dir_exists_absolute(JSONLSidecar.path_for(path)): return _refuse("Sidecar path is unreadable")
		source = JSONLCache.read_source(path)
		if source.is_empty(): return _refuse(JSONLCache.last_error)
		current = source.parsed
		var error := MasterBootstrapPlan._validate(current)
		if not error.is_empty(): return _refuse("Current: " + error)
		if current.meta.version != shipment.meta.version: return _refuse("Supported formats differ; no automatic upgrade")
		state = read_state(current.meta)
		if state.has("error"): return _refuse(state.error)
	else:
		if FileAccess.file_exists(JSONLSidecar.path_for(path)) or DirAccess.dir_exists_absolute(JSONLSidecar.path_for(path)):
			return _refuse("Missing canonical with orphan sidecar")
	if acquired_hook.is_valid(): acquired_hook.call(path)
	var proposal := MasterBootstrapPlan.plan(current, shipment, state.baseline, state.ever_shipped, schema)
	if proposal.has("error"): return _refuse(proposal.error)
	var merged: Dictionary = proposal.merged
	merged.meta[STATE_KEY] = JSONLSerializer._json_value({"version":STATE_VERSION, "baseline_b64":Marshalls.raw_to_base64(JSONLSerializer.format_parsed(proposal.next_baseline).to_utf8_buffer()), "ever_shipped":proposal.next_ever_shipped})
	var text := JSONLSerializer.format_parsed(merged)
	var reparsed := JSONLParser.parse_bytes(text.to_utf8_buffer(), "bootstrap output")
	var validation := MasterBootstrapPlan._validate(reparsed)
	if not validation.is_empty(): return _refuse("Output: " + validation)
	var persisted := read_state(reparsed.meta)
	if persisted.has("error"): return _refuse(persisted.error)
	# Detect any formatter loss or normalization before replacing authority.
	for section in MasterBootstrapPlan.SECTIONS:
		if reparsed[section] != merged[section]: return _refuse("Output changed parsed section: " + section)
	# Generic metadata numbers parse as floats; compare canonical JSON values,
	# so advancing an integer event head is not mistaken for formatter loss.
	if JSONLSerializer._json_value(reparsed.meta) != JSONLSerializer._json_value(merged.meta): return _refuse("Output changed parsed metadata")
	var verify := func() -> String: return _verify_source(path, exists, source)
	var committed := JSONLCheckedCommit.replace(path, text, verify)
	if not str(committed.error).is_empty(): return _refuse(committed.error)
	var response := {"status":"installed" if not exists else "applied", "warning":committed.warning}
	for key in ["inserted", "updated", "unchanged", "deleted", "conflicts", "capability_gaps", "limitations"]: response[key] = proposal[key]
	return response

static func _verify_source(path: String, existed: bool, source: Dictionary) -> String:
	var sidecar_path := JSONLSidecar.path_for(path)
	if not existed:
		return "Source changed before install" if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(sidecar_path) or DirAccess.dir_exists_absolute(sidecar_path) else ""
	if not FileAccess.file_exists(path): return "Canonical disappeared before commit"
	var bytes := FileAccess.get_file_as_bytes(path)
	if FileAccess.get_open_error() != OK or bytes != source.canonical: return "Canonical changed before commit"
	if DirAccess.dir_exists_absolute(sidecar_path): return "Sidecar changed before commit"
	var sidecar := JSONLSidecar.read_bytes(sidecar_path)
	if not str(sidecar.error).is_empty() or sidecar.bytes != source.sidecar or FileAccess.file_exists(sidecar_path) != source.sidecar_exists:
		return "Sidecar changed before commit"
	return ""

static func read_state(meta: Dictionary) -> Dictionary:
	if not meta.has(STATE_KEY): return {"baseline":null, "ever_shipped":[]}
	if not meta[STATE_KEY] is String: return {"error":"Reserved bootstrap state must be a JSON string"}
	var state: Variant = JSON.parse_string(meta[STATE_KEY])
	if not state is Dictionary or state.size() != 3 or state.get("version") != STATE_VERSION or not state.get("baseline_b64") is String or not state.get("ever_shipped") is Array:
		return {"error":"Invalid versioned bootstrap state"}
	var bytes := Marshalls.base64_to_raw(state.baseline_b64)
	if bytes.is_empty() or Marshalls.raw_to_base64(bytes) != state.baseline_b64: return {"error":"Invalid bootstrap baseline encoding"}
	var baseline := JSONLParser.parse_bytes(bytes, "bootstrap baseline")
	var error := MasterBootstrapPlan._validate(baseline)
	if not error.is_empty() or baseline.meta.has(STATE_KEY) or baseline.meta.version != meta.version or not JSONLParser._item_registry_diagnostics(baseline).is_empty():
		return {"error":"Invalid bootstrap baseline"}
	var previous := ""
	for id in state.ever_shipped:
		if not id is String or id.is_empty() or id <= previous: return {"error":"Invalid sorted ever-shipped IDs"}
		previous = id
	for item in baseline.items:
		if item.id not in state.ever_shipped: return {"error":"Baseline ID missing from ever-shipped IDs"}
	return {"baseline":baseline, "ever_shipped":state.ever_shipped}

static func _refuse(error: String) -> Dictionary:
	return {"status":"refused", "error":error}
