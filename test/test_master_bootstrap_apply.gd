extends Node
## Real disk oracles; fixture wire text and expected decisions are independent
## of the parsed formatter. No owner profile, crypto setup, or network.
var A := AssertHelpers
const DIR := "user://test_master_bootstrap_apply"
const SCHEMA := {"types":{"hint":{"states":["draft", "active"], "initial_state":"draft", "transitions":{"draft":["active"], "active":[]}, "optional_fields":["value"]}}}
const META := '{"_type":"meta","version":"1.0.0","counter":4,"id_prefix":"T","event_counter":90,"vault_salt":"YQ==","vault_verify":"Yg==","vault_kdf_iterations":12000}\n'
const ITEMS := """{"_type":"item","id":"A","type":"hint","status":"draft","title":"old","created_at":"t","updated_at":"t","retrieval_count":12,"fields":{"null":null,"false":false,"zero":0,"empty":[],"text":"","object":{},"literal":"C:\\\\new\\\\tab"},"extras":{"unicode":"雪"}}
{"_type":"item","id":"B","type":"hint","status":"draft","title":"old B","created_at":"t","updated_at":"t"}
{"_type":"item","id":"C","type":"hint","status":"draft","title":"deleted","created_at":"t","updated_at":"t"}
"""
const FAMILIES := """{"_type":"event","item_id":"A","seq":1,"eid":7,"event_type":"noted","timestamp":"t","opaque":{"null":null,"false":false,"zero":0}}
{"_type":"comment","id":1,"item_id":"A","created_at":"t","text":"mine","parent_id":0,"status":"resolved","resolved_at":"later","resolved_by":"me"}
{"_type":"link","from_id":"A","to_id":"B","relation":"related"}
{"_type":"attachment","id":1,"item_id":"A","filename":"a","data":"AAEC/w==","created_at":"t","mime_type":"application/octet-stream","size_bytes":4,"description":"binary","encoding":"base64"}
{"_type":"secret","handle":"h","ciphertext":"AAEC/w==","iv":"Yg==","mac":"Yw==","created_at":"t","updated_at":"t","requires_2fa":false,"opaque":{"null":null,"false":false,"zero":0}}
{"_type":"secret_version","handle":"h","version":1,"ciphertext":"YQ==","iv":"Yg==","mac":"Yw==","created_at":"t","rotated_by":"me"}
{"_type":"secret_version","handle":"h","version":2,"ciphertext":"AAEC/w==","iv":"Yg==","mac":"Yw==","created_at":"later"}
{"_type":"saved_query","name":"mine","query":{"zero":0,"false":false,"null":null,"empty":{}}}
"""

func setup() -> void: DirAccess.make_dir_recursive_absolute(DIR)
func teardown() -> void:
	MasterBootstrapApply.acquired_hook = Callable()
	MasterBootstrapApply.lock_timeout_ms = 5000
	JSONLCheckedCommit.stage_hook = Callable()
	JSONLReplace.stage_hook = Callable()
	JSONLReplace.force_windows = false
	var dir := DirAccess.open(DIR)
	if dir != null:
		for name in dir.get_files(): dir.remove(name)
		for name in dir.get_directories(): DirAccess.remove_absolute(DIR + "/" + name)
	DirAccess.remove_absolute(DIR)

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text); f.flush(); f.close()

func _apply(path: String, text: String) -> Dictionary:
	return MasterBootstrapApply.apply(path, text, SCHEMA)

func _disk(path: String) -> Dictionary:
	return JSONLCache.read_source(path).parsed

func _find(snapshot: Dictionary, id: String) -> Dictionary:
	for item in snapshot.items:
		if item.id == id: return item
	return {}

func test_literal_formatter_all_families_binary_pins_presence_and_metadata() -> Variant:
	var literal := META.trim_suffix("\n").trim_suffix("}") + ',"custom":{"null":null,"false":false,"zero":0,"empty":[],"text":"","object":{}}}\n' + ITEMS + FAMILIES
	var v2 := FileAccess.get_file_as_string("res://test/fixtures/dynamic_types_record_order_v2.jsonl")
	for text in [literal, v2]:
		var parsed := JSONLParser.parse_bytes(text.to_utf8_buffer(), "literal")
		var formatted := JSONLSerializer.format_parsed(parsed)
		var reparsed := JSONLParser.parse_bytes(formatted.to_utf8_buffer(), "reparse")
		var r = A.is_true(reparsed == parsed, "every parser section and metadata round trips")
		if r is String: return r
	var parsed := JSONLParser.parse_bytes(literal.to_utf8_buffer(), "literal")
	var r = A.is_true(parsed.attachments[0].data == PackedByteArray([0,1,2,255]) and parsed.secrets[0].ciphertext == PackedByteArray([0,1,2,255]) and parsed.secret_versions[1].ciphertext == PackedByteArray([0,1,2,255]), "independent binary bytes")
	if r is String: return r
	r = A.eq(parsed.items[0].fields, {"null":null,"false":false,"zero":0.0,"empty":[],"text":"","object":{},"literal":"C:\\new\\tab"}, "independent presence/escaping oracle")
	if r is String: return r
	return A.eq([parsed.comments[0].parent_id, parsed.events[0].extras, parsed.secret_versions.size()], [0, {"opaque":{"null":null,"false":false,"zero":0.0}}, 2], "optional presence, unknown payload, full history")

func test_install_repeat_upgrade_wal_cache_settle_restart_no_resurrection() -> Variant:
	var path := DIR + "/install.dct"
	var shipment := META + ITEMS + FAMILIES
	var result := _apply(path, shipment)
	if result.has("error"): return result.error
	var r = A.eq([result.status, result.inserted], ["installed", ["A","B","C"]], "absent legacy installation")
	if r is String: return r
	var installed := FileAccess.get_file_as_bytes(path)
	result = _apply(path, shipment)
	r = A.is_true(not result.has("error") and FileAccess.get_file_as_bytes(path) == installed, "repeat converges byte for byte")
	if r is String: return r
	var db := DocketDBJsonl.open_jsonl(path)
	if db == null: return "installed cache open failed"
	var stored := db.get_meta_value(MasterBootstrapApply.STATE_KEY)
	var errors := [db.update_item_fields_checked("B", {"title":"personal"}), db.delete_item_checked("C"), db.add_event_checked("B", "created", "me", "acknowledged")]
	db._jsonl_path = ""; db.close() # actual acknowledged WAL survives unclean settlement
	r = A.eq(errors, ["", "", ""], "ordinary WAL mutations acknowledged")
	if r is String: return r
	var upgrade := shipment.replace('"old"', '"updated"').replace('"old B"', '"updated B"') + '{"_type":"item","id":"D","type":"hint","status":"draft","title":"new","created_at":"t","updated_at":"t"}\n{"_type":"event","item_id":"D","seq":1,"eid":8,"event_type":"created","timestamp":"t"}\n'
	result = _apply(path, upgrade)
	if result.has("error"): return result.error
	var merged := _disk(path)
	r = A.eq([result.inserted, merged.events[-1].eid, merged.events[-1].item_id], [["D"], 92, "D"], "persisted WAL head remaps imported event IDs")
	if r is String: return r
	r = A.eq([result.updated, result.deleted, result.conflicts, _find(merged,"A").title, _find(merged,"A").retrieval_count, _find(merged,"B").title, _find(merged,"C"), merged.meta.event_counter], [["A"], ["C"], [{"id":"B","reason":"customized"}], "updated", 12, "personal", {}, 92.0], "WAL precedes planning; customization/deletion/counter retained")
	if r is String: return r
	db = DocketDBJsonl.open_jsonl(path)
	if db == null: return "upgrade cache open failed"
	var state := MasterBootstrapApply.read_state({"version":"1.0.0", MasterBootstrapApply.STATE_KEY:db.get_meta_value(MasterBootstrapApply.STATE_KEY)})
	errors = [db.update_item_fields_checked("A", {"description":"personal after upgrade"}), db.flush_checked()]
	db.close()
	r = A.is_true(not stored.is_empty() and not state.has("error") and state.ever_shipped == ["A","B","C","D"] and errors == ["", ""], "state survives actual metadata import, mutation, synchronous settle")
	if r is String: return r
	JSONLCache.delete_cache_family(path)
	db = DocketDBJsonl.open_jsonl(path)
	if db == null: return "restart failed"
	var restarted_state := db.get_meta_value(MasterBootstrapApply.STATE_KEY)
	db.close()
	result = _apply(path, upgrade)
	if result.has("error"): return result.error
	merged = _disk(path)
	r = A.is_true(not restarted_state.is_empty() and _find(merged,"C").is_empty() and _find(merged,"A").description == "personal after upgrade", "restart/bootstrap cannot resurrect or overwrite customization")
	if r is String: return r
	r = A.is_true([merged.secrets[0].ciphertext, merged.secrets[0].opaque, merged.secret_versions.size(), merged.secret_versions[0].ciphertext, merged.secret_versions[1].ciphertext, merged.meta.vault_kdf_iterations] == [PackedByteArray([0,1,2,255]), {"null":null,"false":false,"zero":0.0}, 2, PackedByteArray([97]), PackedByteArray([0,1,2,255]), 12000.0], "ordinary settle/restart preserves ciphertext, unknown secret payload, history and vault metadata")
	if r is String: return r
	var v2path := DIR + "/v2.dct"
	var v2 := FileAccess.get_file_as_string("res://test/fixtures/dynamic_types_record_order_v2.jsonl")
	result = _apply(v2path, v2)
	if result.has("error"): return result.error
	var pins := [_disk(v2path).type_defs, _disk(v2path).type_def_versions]
	var v2bytes := FileAccess.get_file_as_bytes(v2path)
	result = _apply(v2path, v2)
	r = A.is_true(not result.has("error") and v2bytes == FileAccess.get_file_as_bytes(v2path), "absent v2 install and repeat")
	if r is String: return r
	result = _apply(v2path, v2.replace("Before definition", "Updated definition"))
	if result.has("error"): return result.error
	return A.eq([result.updated, _disk(v2path).type_defs, _disk(v2path).type_def_versions], [["ORD-0001"], pins[0], pins[1]], "v2 update preserves immutable pins")

func test_observed_disk_drift_at_acquisition_and_last_commit_boundary_refuses() -> Variant:
	for boundary in ["acquired", "before_verify"]:
		for family in ["canonical", "sidecar"]:
			var path: String = DIR + "/drift-" + boundary + "-" + family + ".dct"
			var shipment := META + ITEMS
			var initial := _apply(path, shipment)
			if initial.has("error"): return initial.error
			var old := FileAccess.get_file_as_string(path)
			var edit := func(target: String) -> void:
				if family == "canonical": _write(target, old.replace('"old"', '"external"'))
				else: JSONLSidecar.append(target + ".log", '{"_type":"wal","base":"%s","replace":[["B","item"]],"records":[]}' % FileAccess.get_sha256(target))
			if boundary == "acquired": MasterBootstrapApply.acquired_hook = edit
			else:
				JSONLCheckedCommit.stage_hook = func(stage: String, target: String, _temp: String) -> String:
					if stage == "before_verify": edit.call(target)
					return ""
			var result := _apply(path, shipment.replace('"old"', '"updated"'))
			MasterBootstrapApply.acquired_hook = Callable(); JSONLCheckedCommit.stage_hook = Callable()
			var r = A.eq(result.status, "refused", "observed actual disk drift refuses")
			if r is String: return r
			var current := _disk(path)
			r = A.eq(_find(current,"A").title if family == "canonical" else _find(current,"B"), "external" if family == "canonical" else {}, "external canonical/WAL edit remains authoritative")
			if r is String: return r
			r = A.is_true(not FileAccess.file_exists(path + ".tmp.%d" % OS.get_process_id()), "refused temp cleaned")
			if r is String: return r
	return true

func test_real_temp_rename_failures_and_postrename_marker_restart() -> Variant:
	for failure in ["temp", "rename", "cleanup"]:
		var path: String = DIR + "/failure-" + failure + ".dct"
		var shipment := META + ITEMS
		var result := _apply(path, shipment)
		if result.has("error"): return result.error
		var before := FileAccess.get_file_as_bytes(path)
		JSONLSidecar.append(path + ".log", '{"_type":"wal","base":"%s","replace":[["B","item"]],"records":[]}' % FileAccess.get_sha256(path))
		_write(path + ".log", FileAccess.get_file_as_string(path + ".log") + "{torn") # actual unacknowledged tail
		var temp := path + ".tmp.%d" % OS.get_process_id()
		if failure == "temp": DirAccess.make_dir_absolute(temp)
		JSONLCheckedCommit.stage_hook = func(stage: String, _target: String, temp_path: String) -> String:
			if failure == "rename" and stage == "before_rename": DirAccess.remove_absolute(temp_path)
			return "test interrupted cleanup" if failure == "cleanup" and stage == "after_rename" else ""
		result = _apply(path, shipment.replace('"old"', '"updated"'))
		JSONLCheckedCommit.stage_hook = Callable()
		if failure == "temp": DirAccess.remove_absolute(temp)
		var r = A.eq(result.status, "applied" if failure == "cleanup" else "refused", "actual failure disposition")
		if r is String: return r
		var replayed := _disk(path)
		r = A.eq([_find(replayed,"A").title, _find(replayed,"B")], ["updated" if failure == "cleanup" else "old", {}], "failure preserves authority and acknowledged WAL; target marker skips old prefix")
		if r is String: return r
		if failure != "cleanup":
			r = A.eq(FileAccess.get_file_as_bytes(path), before, "failed replacement leaves canonical bytes unchanged")
			if r is String: return r
		else:
			var state := MasterBootstrapApply.read_state(replayed.meta)
			r = A.eq([state.baseline.items[0].title, state.ever_shipped], ["updated", ["A","B","C"]], "baseline and records commit together before cleanup")
			if r is String: return r
		var db := DocketDBJsonl.open_jsonl(path)
		if db == null: return "marker restart failed"
		db.close()
		r = A.eq([_find(_disk(path),"A").title, _find(_disk(path),"B")], ["updated" if failure == "cleanup" else "old", {}], "actual cache restart retains replay/marker result")
		if r is String: return r
	return true

func test_safe_refusals_missing_corrupt_unreadable_formats_lock_and_state() -> Variant:
	var shipment := META + ITEMS
	var path := DIR + "/refused.dct"
	for text in ["", "broken", META.replace("1.0.0", "3.0.0") + ITEMS]:
		_write(path, text)
		var result := _apply(path, shipment)
		var r = A.is_true(result.status == "refused" and FileAccess.get_file_as_string(path) == text, "empty/malformed/newer authority preserved")
		if r is String: return r
	_write(path, shipment)
	var held := FileLock.acquire(path)
	MasterBootstrapApply.lock_timeout_ms = 0
	var result := _apply(path, shipment)
	held.release(); MasterBootstrapApply.lock_timeout_ms = 5000
	var r = A.eq(result.status, "refused", "lock timeout fails closed")
	if r is String: return r
	_write(path + ".log", '{"_type":"wal","base":"wrong","replace":[],"records":"invalid"}\n')
	result = _apply(path, shipment)
	r = A.eq(result.status, "refused", "corrupt WAL refused")
	if r is String: return r
	DirAccess.remove_absolute(path + ".log"); DirAccess.make_dir_absolute(path + ".log")
	result = _apply(path, shipment)
	r = A.eq(result.status, "refused", "unreadable WAL refused")
	if r is String: return r
	DirAccess.remove_absolute(path + ".log"); DirAccess.remove_absolute(path); DirAccess.make_dir_absolute(path)
	result = _apply(path, shipment)
	r = A.eq(result.status, "refused", "unreadable canonical refused")
	if r is String: return r
	DirAccess.remove_absolute(path); _write(path + ".log", "")
	result = _apply(path, shipment)
	r = A.eq(result.status, "refused", "absent canonical with even empty orphan WAL refused")
	if r is String: return r
	DirAccess.remove_absolute(path + ".log")
	var v2 := FileAccess.get_file_as_string("res://test/fixtures/dynamic_types_record_order_v2.jsonl")
	_write(path, v2)
	result = _apply(path, shipment)
	r = A.is_true(result.status == "refused" and FileAccess.get_file_as_string(path) == v2, "supported format mismatch refused")
	if r is String: return r
	for state in [null, {}, "{}", '{"version":99,"baseline_b64":"YQ==","ever_shipped":[]}']:
		var parsed := JSONLParser.parse_bytes(shipment.to_utf8_buffer(), "fixture")
		parsed.meta[MasterBootstrapApply.STATE_KEY] = state
		var text := JSONLSerializer.format_parsed(parsed)
		_write(path, text)
		result = _apply(path, shipment)
		r = A.is_true(result.status == "refused" and FileAccess.get_file_as_string(path) == text and _apply(DIR + "/seed.dct", text).status == "refused", "resident state validates and caller cannot seed it")
		if r is String: return r
	return true

func test_preservation_matches_actual_ordinary_settle_in_every_family() -> Variant:
	var path := DIR + "/parity.dct"
	var text := META + ITEMS + FAMILIES
	_write(path, text)
	var db := DocketDBJsonl.open_jsonl(path)
	if db == null: return "parity fixture open failed"
	var error := db.flush_checked()
	db.close()
	if not error.is_empty(): return error
	var ordinary := _disk(path)
	var result := _apply(path, text)
	if result.has("error"): return result.error
	var bootstrapped := _disk(path)
	for section in MasterBootstrapPlan.SECTIONS:
		var r = A.is_true(bootstrapped[section] == ordinary[section], "no additional loss beyond actual ordinary settle: " + section)
		if r is String: return r
	var missing := DIR + "/missing-loaded.dct"
	_write(missing, text)
	MasterBootstrapApply.acquired_hook = func(target: String) -> void: DirAccess.remove_absolute(target)
	result = _apply(missing, text)
	MasterBootstrapApply.acquired_hook = Callable()
	return A.is_true(result.status == "refused" and not FileAccess.file_exists(missing), "missing acquired project is never silently recreated")

# Restart-state simulations at the real protocol boundaries, not killed-child proof.
func test_windows_replacement_boundaries_replay_markers_and_recover_idempotently() -> Variant:
	JSONLReplace.force_windows = true
	for boundary in ["after_backup", "after_install"]:
		var path: String = DIR + "/windows-" + boundary + ".dct"
		var result := _apply(path, META + ITEMS)
		if result.has("error"): return result.error
		var old := FileAccess.get_file_as_bytes(path)
		JSONLSidecar.append(path + ".log", '{"_type":"wal","base":"%s","replace":[["B","item"]],"records":[]}' % FileAccess.get_sha256(path))
		var observed: Array = []
		JSONLReplace.stage_hook = func(stage: String, target: String, temp: String) -> String:
			if target != path: return ""
			if stage == boundary:
				observed.append([FileAccess.file_exists(target), FileAccess.get_file_as_bytes(target + ".docket-replace-backup") == old])
				if boundary == "after_backup": DirAccess.remove_absolute(temp)
				return "simulated interrupted process" if boundary == "after_install" else ""
			return "simulated unavailable restore" if boundary == "after_backup" and stage == "before_restore" else ""
		result = _apply(path, (META + ITEMS).replace('"old"', '"updated"'))
		JSONLReplace.stage_hook = Callable()
		var r = A.eq(observed, [[boundary == "after_install", true]], "actual staged disk boundary observed")
		if r is String: return r
		r = A.eq(result.status, "refused" if boundary == "after_backup" else "applied", "restore failure versus committed cleanup failure")
		if r is String: return r
		if boundary == "after_backup":
			r = A.is_true(str(result.error).contains(path + ".docket-replace-backup") and FileAccess.get_file_as_bytes(path + ".docket-replace-backup") == old, "restore failure names preserved bytes")
			if r is String: return r
		var source := JSONLCache.read_source(path)
		if source.is_empty(): return JSONLCache.last_error
		r = A.eq([_find(source.parsed,"A").title, _find(source.parsed,"B")], ["old" if boundary == "after_backup" else "updated", {}], "old target ignores new marker; valid new target skips prefix")
		if r is String: return r
		var recovered := FileAccess.get_file_as_bytes(path)
		r = A.is_true(not FileAccess.file_exists(path + ".docket-replace-backup") and JSONLReplace.recover(path).is_empty() and FileAccess.get_file_as_bytes(path) == recovered, "recovery is byte-idempotent")
		if r is String: return r
		var db := DocketDBJsonl.open_jsonl(path)
		if db == null: return DocketDBJsonl.last_open_error
		db.close()
		r = A.eq([_find(_disk(path),"A").title, _find(_disk(path),"B")], ["old" if boundary == "after_backup" else "updated", {}], "cold cache restart preserves acknowledged deletion")
		if r is String: return r
	return true

func test_windows_replacement_failure_restores_and_reserved_invalid_files_refuse() -> Variant:
	JSONLReplace.force_windows = true
	var path := DIR + "/windows-restore.dct"
	_write(path, META + ITEMS)
	var old := FileAccess.get_file_as_bytes(path)
	var temp := path + ".test-temp"
	_write(temp, (META + ITEMS).replace('"old"', '"updated"'))
	JSONLReplace.stage_hook = func(stage: String, _target: String, source: String) -> String:
		if stage == "after_backup": DirAccess.remove_absolute(source)
		return ""
	var error := DocketDBJsonl._rename_over(temp, path)
	JSONLReplace.stage_hook = Callable()
	var r = A.is_true(not error.is_empty() and FileAccess.get_file_as_bytes(path) == old and not FileAccess.file_exists(path + ".docket-replace-backup"), "real install failure restores exact old bytes")
	if r is String: return r
	# Each invalid role/state must preserve every fixture, including WAL backup.
	for invalid in ["corrupt", "future", "wal", "target", "directory"]:
		var backup := path + ".docket-replace-backup"
		_write(path, META + ITEMS)
		_write(backup, META + ITEMS)
		_write(path + ".log.docket-replace-backup", '{"_type":"wal","base":"old","replace":[["B","item"]],"records":[]}\n{torn')
		if invalid == "corrupt": _write(backup, "not canonical")
		if invalid == "future": _write(backup, META.replace("1.0.0", "9.0.0") + ITEMS)
		if invalid == "wal": _write(path + ".log.docket-replace-backup", '{"_type":"unknown"}\n')
		if invalid == "target": _write(path, "not canonical")
		if invalid == "directory":
			DirAccess.remove_absolute(backup); DirAccess.make_dir_absolute(backup)
		var before := FileAccess.get_file_as_bytes(path)
		var wal_before := FileAccess.get_file_as_bytes(path + ".log.docket-replace-backup")
		var backup_before := FileAccess.get_file_as_bytes(backup) if invalid != "directory" else PackedByteArray()
		var refused := _apply(path, META + ITEMS)
		r = A.is_true(refused.status == "refused" and FileAccess.get_file_as_bytes(path) == before and FileAccess.get_file_as_bytes(path + ".log.docket-replace-backup") == wal_before, "invalid reserved evidence refuses without touching authority or WAL")
		if r is String: return r
		r = A.is_true(DirAccess.dir_exists_absolute(backup) if invalid == "directory" else FileAccess.get_file_as_bytes(backup) == backup_before, "invalid backup retained")
		if r is String: return r
		DirAccess.remove_absolute(backup); DirAccess.remove_absolute(path + ".log.docket-replace-backup")
	return true

func test_windows_missing_target_bootstrap_and_live_freshness_recover_before_classification() -> Variant:
	JSONLReplace.force_windows = true
	var path := DIR + "/windows-live.dct"
	_write(path, META + ITEMS)
	var db := DocketDBJsonl.open_jsonl(path)
	if db == null: return DocketDBJsonl.last_open_error
	var old := FileAccess.get_file_as_bytes(path)
	DirAccess.rename_absolute(path, path + ".docket-replace-backup")
	var stale := db.is_stale() # Recovers before fingerprint/missing classification.
	var r = A.is_true(not stale and FileAccess.get_file_as_bytes(path) == old, "live freshness restores unchanged authority")
	if r is String: db.close(); return r
	DirAccess.rename_absolute(path, path + ".docket-replace-backup")
	r = A.is_true(db.reload() and FileAccess.get_file_as_bytes(path) == old, "live reload restores before cache-path classification")
	db.close()
	if r is String: return r
	DirAccess.rename_absolute(path, path + ".docket-replace-backup")
	var result := _apply(path, (META + ITEMS).replace('"old"', '"updated"'))
	r = A.eq(result.status, "applied", "missing-target recovery is existing bootstrap, not new installation")
	if r is String: return r
	DirAccess.rename_absolute(path, path + ".docket-replace-backup")
	db = DocketDBJsonl.create_new_jsonl(path)
	if db == null: return DocketDBJsonl.last_open_error
	r = A.eq(db.get_item("A").title, "updated", "create path recovers existing content before seeding")
	db.close()
	return r
