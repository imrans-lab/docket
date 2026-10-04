extends Node
## Literal parser fixtures, including in-memory WAL replay. No DB or files.
var A := AssertHelpers
const SCHEMA := {"types":{"hint":{"states":["draft", "active"], "initial_state":"draft", "transitions":{"draft":["active"], "active":[]}, "optional_fields":["value"]}}}
const META := '{"_type":"meta","version":"1.0.0","counter":4,"id_prefix":"T","event_counter":90,"project":"personal","custom":{"null":null,"false":false,"zero":0,"empty":[]}}\n'
const CURRENT := """{"_type":"item","id":"A","type":"hint","status":"draft","title":"old","created_at":"t","updated_at":"t","retrieval_count":12,"tags":["z","a"],"fields":{"literal":"C:\\\\new\\\\tab","null":null,"false":false,"zero":0,"list":[2,1],"empty":{}},"extras":{"unicode":"雪","empty_text":""}}
{"_type":"item","id":"B","type":"hint","status":"draft","title":"old B","created_at":"t","updated_at":"t"}
{"_type":"item","id":"C","type":"hint","status":"draft","title":"deleted","created_at":"t","updated_at":"t"}
{"_type":"item","id":"U","type":"hint","status":"draft","title":"personal","created_at":"t","updated_at":"t"}
{"_type":"event","item_id":"U","seq":1,"eid":7,"event_type":"noted","timestamp":"t","opaque":{"zero":0}}
{"_type":"comment","id":1,"item_id":"U","created_at":"t","text":"mine"}
{"_type":"link","from_id":"U","to_id":"A","relation":"related"}
{"_type":"attachment","id":1,"item_id":"U","filename":"a","data":"YQ==","created_at":"t"}
{"_type":"secret","handle":"h","ciphertext":"YQ==","iv":"Yg==","mac":"Yw==","created_at":"t","updated_at":"t","opaque":false}
{"_type":"secret_version","handle":"h","version":1,"ciphertext":"YQ==","iv":"Yg==","mac":"Yw==","created_at":"t"}
{"_type":"saved_query","name":"mine","query":{"zero":0,"false":false,"null":null}}
"""
const SHIPMENT := """{"_type":"item","id":"A","type":"hint","status":"draft","title":"new","created_at":"t","updated_at":"t","retrieval_count":99,"tags":["a","z"],"fields":{"literal":"C:\\\\new\\\\tab","null":null,"false":false,"zero":0,"list":[2,1],"empty":{}},"extras":{"unicode":"雪","empty_text":""}}
{"_type":"item","id":"B","type":"hint","status":"draft","title":"new B","created_at":"t","updated_at":"t"}
{"_type":"item","id":"C","type":"hint","status":"draft","title":"resurrect","created_at":"t","updated_at":"t"}
{"_type":"item","id":"Z","type":"hint","status":"draft","title":"new Z","created_at":"t","updated_at":"t"}
{"_type":"item","id":"D","type":"hint","status":"draft","title":"new D","created_at":"t","updated_at":"t"}
{"_type":"event","item_id":"Z","seq":1,"eid":7,"event_type":"created","timestamp":"t","opaque":{"literal":"\\\\n","null":null}}
{"_type":"event","item_id":"D","seq":2,"eid":8,"event_type":"noted","timestamp":"t","opaque":false}
{"_type":"event","item_id":"D","seq":1,"eid":9,"event_type":"created","timestamp":"t"}
{"_type":"comment","id":2,"item_id":"D","created_at":"t","text":"shipment only"}
{"_type":"link","from_id":"D","to_id":"Z","relation":"related"}
{"_type":"attachment","id":2,"item_id":"D","filename":"ship","data":"ZA==","created_at":"t"}
{"_type":"secret","handle":"ship","ciphertext":"ZA==","iv":"Yg==","mac":"Yw==","created_at":"t","updated_at":"t"}
{"_type":"secret_version","handle":"ship","version":1,"ciphertext":"ZA==","iv":"Yg==","mac":"Yw==","created_at":"t"}
{"_type":"saved_query","name":"ship","query":{}}
"""
const WAL := """{"_type":"wal","base":"canonical","replace":[["B","item"],["C","item"]],"records":[{"_type":"item","id":"B","type":"hint","status":"draft","title":"WAL customization","created_at":"t","updated_at":"t"}]}
"""

func _parse(body: String, version: String = "1.0.0") -> Dictionary:
	return JSONLParser.parse_bytes((META.replace("1.0.0", version) + body).to_utf8_buffer(), "literal")

func _find(snapshot: Dictionary, id: String) -> Dictionary:
	for item: Dictionary in snapshot.items:
		if item.id == id: return item
	return {}

func test_replayed_merge_preserves_personal_payloads_sections_and_converges() -> Variant:
	var current := _parse(CURRENT)
	var baseline := _parse(CURRENT)
	var shipment := _parse(SHIPMENT)
	for snapshot in [current, baseline, shipment]:
		if not str(snapshot.get("error", "")).is_empty(): return snapshot.error
	var replay := JSONLSidecar.replay_into(current, "memory.dct", "canonical", WAL.to_utf8_buffer())
	if not replay.is_empty(): return replay
	var inputs := [current.duplicate(true), shipment.duplicate(true), baseline.duplicate(true)]
	var ever: Array = ["C", "R"]
	var result := MasterBootstrapPlan.plan(current, shipment, baseline, ever, SCHEMA)
	if result.has("error"): return result.error
	var r = A.eq([result.inserted, result.updated, result.deleted, result.conflicts], [["D", "Z"], ["A"], ["C"], [{"id":"B", "reason":"customized"}]], "literal merge decisions after WAL customization/deletion")
	if r is String: return r
	var merged: Dictionary = result.merged
	r = A.eq(_find(merged, "A"), {"_type":"item", "id":"A", "type":"hint", "status":"draft", "title":"new", "created_at":"t", "updated_at":"t", "retrieval_count":12, "tags":["a", "z"], "fields":{"literal":"C:\\new\\tab", "null":null, "false":false, "zero":0.0, "list":[2.0,1.0], "empty":{}}, "extras":{"unicode":"雪", "empty_text":""}}, "independent complete replacement payload, literal escapes and envelopes")
	if r is String: return r
	r = A.eq([_find(merged, "B").title, _find(merged, "U").title, _find(merged, "C")], ["WAL customization", "personal", {}], "personal and deleted IDs")
	if r is String: return r
	for section in ["comments", "links", "attachments", "secrets", "secret_versions", "saved_queries", "type_defs", "type_def_versions"]:
		r = A.eq(merged[section], current[section], "current " + section + " retained exactly")
		if r is String: return r
	var expected_meta: Dictionary = current.meta.duplicate(true)
	expected_meta.event_counter = 93
	r = A.eq(merged.meta, expected_meta, "only proposed event head changes")
	if r is String: return r
	r = A.eq(merged.events, [{"_type":"event", "item_id":"U", "seq":1, "eid":7, "event_type":"noted", "timestamp":"t", "extras":{"opaque":{"zero":0.0}}}, {"_type":"event", "item_id":"D", "seq":2, "eid":91, "event_type":"noted", "timestamp":"t", "extras":{"opaque":false}}, {"_type":"event", "item_id":"D", "seq":1, "eid":92, "event_type":"created", "timestamp":"t"}, {"_type":"event", "item_id":"Z", "seq":1, "eid":93, "event_type":"created", "timestamp":"t", "extras":{"opaque":{"literal":"\\n", "null":null}}}], "independent remapped history, lexical new IDs/source per-item order")
	if r is String: return r
	for previous in [baseline, result.next_baseline]:
		var repeated := MasterBootstrapPlan.plan(merged, shipment, previous, result.next_ever_shipped, SCHEMA)
		r = A.eq([repeated.inserted, repeated.updated, repeated.merged], [[], [], merged], "interrupted baseline advancement and rerun do not duplicate history")
		if r is String: return r
	r = A.eq([current, shipment, baseline, ever], [inputs[0], inputs[1], inputs[2], ["C", "R"]], "no caller input mutation")
	if r is String: return r
	var later := _parse('{"_type":"item","id":"R","type":"hint","status":"draft","title":"return","created_at":"t","updated_at":"t"}\n')
	var returned := MasterBootstrapPlan.plan(merged, later, result.next_baseline, result.next_ever_shipped, SCHEMA)
	return A.eq([returned.deleted, returned.inserted], [["R"], []], "ever-shipped deletion survives removed/reintroduced shipment")

func test_absent_empty_baseline_uncertainty_and_semantic_comparison() -> Variant:
	var shipment := _parse(SHIPMENT)
	var initial := MasterBootstrapPlan.plan(null, shipment, null, [], SCHEMA)
	if initial.has("error"): return initial.error
	var r = A.eq([initial.merged, initial.inserted], [shipment, ["A", "B", "C", "D", "Z"]], "absent install preserves whole shipment and valid head")
	if r is String: return r
	var empty := _parse("")
	var installed := MasterBootstrapPlan.plan(empty, shipment, null, [], SCHEMA)
	r = A.eq([installed.merged.comments, installed.merged.secrets, installed.merged.saved_queries, installed.merged.meta.project, installed.merged.meta.event_counter], [[], [], [], "personal", 93], "existing empty project imports only items/history")
	if r is String: return r
	var current := _parse(CURRENT)
	var uncertain := MasterBootstrapPlan.plan(current, shipment, null, [], SCHEMA)
	r = A.eq(uncertain.conflicts, [{"id":"A", "reason":"baseline_unavailable"}, {"id":"B", "reason":"baseline_unavailable"}, {"id":"C", "reason":"baseline_unavailable"}], "missing baseline cannot prove pristine")
	if r is String: return r
	var corrupt := JSONLParser.parse_bytes("broken".to_utf8_buffer(), "malformed literal")
	var invalid_baseline := MasterBootstrapPlan.plan(current, shipment, corrupt, [], SCHEMA)
	r = A.is_true(invalid_baseline.conflicts == uncertain.conflicts and not invalid_baseline.limitations.is_empty(), "corrupt baseline is visible uncertainty")
	if r is String: return r
	# Explicit zero may be present in an authoritative in-memory/replayed snapshot;
	# canonical parser omits top-level zero, so do not confuse it with absence.
	current.items[0].retrieval_count = 0
	var replacement := MasterBootstrapPlan.plan(current, shipment, _parse(CURRENT), [], SCHEMA)
	r = A.eq(_find(replacement.merged, "A").retrieval_count, 0, "explicit read-count zero survives replacement")
	if r is String: return r
	var same := current.duplicate(true)
	same.items[0].tags = ["a", "z", "a"]
	same.items[0].retrieval_count = 77
	var equal := MasterBootstrapPlan.plan(current, same, null, [], SCHEMA)
	r = A.eq([equal.updated, equal.conflicts, equal.merged], [[], [], current], "only read count and tag set representation ignored")
	if r is String: return r
	same.items[0].fields.list = [1,2]
	var reordered := MasterBootstrapPlan.plan(current, same, null, [], SCHEMA)
	return A.eq(reordered.conflicts, [{"id":"A", "reason":"baseline_unavailable"}], "other arrays retain semantic order")

func _v2(body: String, schema: Dictionary = SCHEMA) -> Dictionary:
	var records := TypeRegistryBootstrap.records(schema)
	var text := body
	for section in ["type_defs", "type_def_versions"]:
		for record in records[section]: text += JSON.stringify(record) + "\n"
	return _parse(text, "2.0.0")

func test_v2_immutable_pins_and_pure_capability_report() -> Variant:
	var current := _v2("")
	var registry_before := [current.type_defs.duplicate(true), current.type_def_versions.duplicate(true)]
	var revision: String = current.type_defs[0].current_revision
	var literal := '{"_type":"item","id":"V","type":"hint","type_id":"builtin:hint","type_revision":"%s","status":"draft","title":"v2","created_at":"t","updated_at":"t","fields":{"null":null,"false":false,"zero":0,"empty":[]}}\n' % revision
	var shipment := _v2(literal)
	var result := MasterBootstrapPlan.plan(current, shipment, null, [], SCHEMA)
	if result.has("error"): return result.error
	var r = A.eq([result.inserted, result.merged.type_defs, result.merged.type_def_versions, _find(result.merged, "V").fields], [["V"], registry_before[0], registry_before[1], {"null":null, "false":false, "zero":0.0, "empty":[]}], "compatible pins and immutable registry")
	if r is String: return r
	var changed := SCHEMA.duplicate(true)
	changed.types.hint.optional_fields = ["value", "source"]
	changed.types.hint["field_definitions"] = {"value":{"type":"integer"}}
	changed.types.hint.states.append("pending")
	changed.types.hint.transitions["pending"] = []
	changed.types["widget"] = SCHEMA.types.hint.duplicate(true)
	var descriptors: Array = [{"slug":"hint", "definition":current.type_def_versions[0].definition}]
	var before := [changed.duplicate(true), descriptors.duplicate(true)]
	var gaps := SchemaCapabilityGaps.compare_definitions(changed, descriptors)
	r = A.eq(gaps, {"gaps":["field_kind:hint.value:string!=integer", "missing_field:hint.source", "missing_state:hint.pending", "missing_type:widget"]}, "literal structural gaps from pure core")
	if r is String: return r
	r = A.eq([changed, descriptors], before, "pure capability comparison does not mutate inputs")
	if r is String: return r
	var offered_update := _v2(literal.replace('"v2"', '"updated v2"'))
	result.merged.items[0].retrieval_count = 0
	var update := MasterBootstrapPlan.plan(result.merged, offered_update, shipment, result.next_ever_shipped, SCHEMA)
	r = A.eq([update.updated, _find(update.merged, "V").title, _find(update.merged, "V").retrieval_count, update.merged.type_def_versions], [["V"], "updated v2", 0, registry_before[1]], "v2 pristine update retains counter and immutable revisions")
	if r is String: return r
	var reported := MasterBootstrapPlan.plan(current, shipment, null, [], changed)
	r = A.eq(reported.capability_gaps, ["field_kind:hint.value:string!=integer", "missing_field:hint.source", "missing_state:hint.pending", "missing_type:widget"], "planner uses supplied declared schema and current revisions")
	if r is String: return r
	var new_registry := _v2("", changed)
	var different_revision: String = new_registry.type_defs[0].current_revision
	var incompatible := _v2(literal.replace(revision, different_revision), changed)
	var refused := MasterBootstrapPlan.plan(current, incompatible, null, [], SCHEMA)
	r = A.eq(refused.conflicts, [{"id":"V", "reason":"missing_pin"}], "shipped revision unavailable in current registry")
	if r is String: return r
	var missing := _v2(literal.replace(revision, "unknown"))
	r = A.eq(MasterBootstrapPlan.plan(current, missing, null, [], SCHEMA).conflicts, [{"id":"V", "reason":"missing_pin"}], "unresolved shipped pin reported")
	if r is String: return r
	var wrong_state := _v2(literal.replace('"draft"', '"not-a-state"'))
	r = A.eq(MasterBootstrapPlan.plan(current, wrong_state, null, [], SCHEMA).conflicts, [{"id":"V", "reason":"incompatible_pin"}], "stored pin cannot reinterpret absent status")
	if r is String: return r
	for invalid in [missing, wrong_state]:
		r = A.is_true(MasterBootstrapPlan.plan(null, invalid, null, [], SCHEMA).has("error"), "absent installation refuses unresolved semantics")
		if r is String: return r
	var legacy := _parse("")
	return A.eq(MasterBootstrapPlan.plan(legacy, shipment, null, [], SCHEMA).conflicts, [{"id":"V", "reason":"format_mismatch"}], "no implicit format upgrade")

func test_invalid_snapshots_identities_heads_and_capability_inputs_refuse() -> Variant:
	var valid := _parse(CURRENT)
	if not str(valid.get("error", "")).is_empty(): return valid.error
	var parsed = A.eq([valid.items.size(), valid.events.size(), valid.comments.size()], [4, 1, 1], "literal refusal fixture parsed before indexing")
	if parsed is String: return parsed
	var bad_counter := valid.duplicate(true)
	bad_counter.meta.event_counter = -1
	var fractional := valid.duplicate(true)
	fractional.meta.event_counter = 1.5
	var duplicate := valid.duplicate(true)
	duplicate.items.append(duplicate.items[0].duplicate(true))
	var duplicate_event := valid.duplicate(true)
	duplicate_event.events.append(duplicate_event.events[0].duplicate(true))
	var invalid_eid := valid.duplicate(true)
	invalid_eid.events[0].eid = 0
	var duplicate_comment := valid.duplicate(true)
	duplicate_comment.comments.append(duplicate_comment.comments[0].duplicate(true))
	var invalid_sequence := valid.duplicate(true)
	invalid_sequence.events[0].seq = 0.5
	var unsupported := _parse(CURRENT, "3.0.0")
	for invalid in [bad_counter, fractional, duplicate, duplicate_event, duplicate_comment, invalid_sequence, invalid_eid, unsupported, JSONLParser.parse_bytes("broken".to_utf8_buffer(), "malformed literal")]:
		var before: Dictionary = invalid.duplicate(true)
		var r = A.is_true(MasterBootstrapPlan.plan(invalid, valid, null, [], SCHEMA).has("error") and MasterBootstrapPlan.plan(null, invalid, null, [], SCHEMA).has("error") and invalid == before, "invalid input refuses without mutation")
		if r is String: return r
	for descriptors in [[{"error":"unavailable"}], [{}], [null]]:
		var r = A.is_true(SchemaCapabilityGaps.compare_definitions(SCHEMA, descriptors).has("error"), "invalid/unavailable descriptors visibly refuse")
		if r is String: return r
	var low_head := valid.duplicate(true)
	low_head.meta.event_counter = 2
	var initial := MasterBootstrapPlan.plan(null, low_head, null, [], SCHEMA)
	var r = A.eq(initial.merged.meta.event_counter, 7, "initial proposal preserves a counter above all retained event IDs")
	if r is String: return r
	return A.is_true(SchemaCapabilityGaps.compare_definitions({}, []).has("error"), "invalid declared schema visibly refuses")
