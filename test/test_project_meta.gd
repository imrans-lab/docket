extends Node
## Unit tests for DocketProjectMeta tool.

var A := AssertHelpers
var db: DocketDB
var tool: RefCounted


func setup() -> void:
	var path := "user://test_project_meta_%d.dct" % Time.get_ticks_msec()
	db = DocketDB.create_new(path)
	db.set_project_name("test-project")
	tool = preload("res://scripts/tools/docket_project_meta.gd").new()


func teardown() -> void:
	if db:
		var path := db.get_path()
		db.close()
		DirAccess.remove_absolute(path)
		for suffix: String in ["-wal", "-shm"]:
			var p := path + suffix
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)


# -- Helpers ------------------------------------------------------------------

func _exec(args: Dictionary) -> Dictionary:
	var project_dbs := {"test-project": db}
	var noop := Callable()
	return tool.execute(args, {}, db, project_dbs, noop, noop)


# -- Tests --------------------------------------------------------------------

func test_get_empty_metadata() -> Variant:
	var result := _exec({"action": "get"})
	var r = A.has_key(result, "stage")
	if r is String: return r
	return A.eq(result.stage, "", "fresh project has empty stage")


func test_set_experiment_stage() -> Variant:
	var result := _exec({"action": "set", "stage": "experiment"})
	var r = A.eq(result.get("error", ""), "", "no error on set")
	if r is String: return r
	r = A.has_key(result, "stage")
	if r is String: return r
	return A.eq(result.stage, "experiment", "stage is experiment")


func test_set_with_hypothesis() -> Variant:
	# Use incubating since previous test left us in experiment
	var set_result := _exec({
		"action": "set",
		"stage": "incubating",
		"hypothesis": "Testing JSONL format",
	})
	var r = A.eq(set_result.get("error", ""), "", "no error on set")
	if r is String: return r

	var get_result := _exec({"action": "get"})
	r = A.has_key(get_result, "hypothesis")
	if r is String: return r
	return A.eq(get_result.hypothesis, "Testing JSONL format", "hypothesis persisted")


func test_transition_experiment_to_incubating() -> Variant:
	_exec({"action": "set", "stage": "experiment"})
	var result := _exec({"action": "set", "stage": "incubating"})
	var r = A.eq(result.get("error", ""), "", "no error transitioning to incubating")
	if r is String: return r
	return A.eq(result.stage, "incubating", "stage is incubating")


func test_transition_experiment_to_production_invalid() -> Variant:
	_exec({"action": "set", "stage": "experiment"})
	var result := _exec({"action": "set", "stage": "production"})
	return A.has_key(result, "error")


func test_transition_production_to_archived() -> Variant:
	_exec({"action": "set", "stage": "experiment"})
	_exec({"action": "set", "stage": "incubating"})
	_exec({"action": "set", "stage": "production"})
	var result := _exec({"action": "set", "stage": "archived"})
	var r = A.eq(result.get("error", ""), "", "no error transitioning to archived")
	if r is String: return r
	return A.eq(result.stage, "archived", "stage is archived")


func test_archived_is_terminal() -> Variant:
	_exec({"action": "set", "stage": "experiment"})
	_exec({"action": "set", "stage": "incubating"})
	_exec({"action": "set", "stage": "production"})
	_exec({"action": "set", "stage": "archived"})
	var result := _exec({"action": "set", "stage": "experiment"})
	return A.has_key(result, "error")


func test_abandoned_can_resurrect() -> Variant:
	# Fresh DB to avoid state from previous tests
	var path2 := "user://test_pm_abandon_%d.dct" % Time.get_ticks_msec()
	var db2 := DocketDB.create_new(path2)
	db2.set_project_name("abandon-test")
	var dbs2 := {"abandon-test": db2}
	var noop := Callable()
	tool.execute({"action": "set", "stage": "experiment"}, {}, db2, dbs2, noop, noop)
	tool.execute({"action": "set", "stage": "abandoned"}, {}, db2, dbs2, noop, noop)
	var result = tool.execute({"action": "set", "stage": "experiment"}, {}, db2, dbs2, noop, noop)
	db2.close()
	DirAccess.remove_absolute(path2)
	var r = A.eq(result.get("error", ""), "", "no error resurrecting abandoned project")
	if r is String: return r
	return A.eq(result.stage, "experiment", "stage is experiment after resurrection")


func test_abandoned_cannot_go_to_production() -> Variant:
	var path2 := "user://test_pm_abandon2_%d.dct" % Time.get_ticks_msec()
	var db2 := DocketDB.create_new(path2)
	db2.set_project_name("abandon-test2")
	var dbs2 := {"abandon-test2": db2}
	var noop := Callable()
	tool.execute({"action": "set", "stage": "experiment"}, {}, db2, dbs2, noop, noop)
	tool.execute({"action": "set", "stage": "abandoned"}, {}, db2, dbs2, noop, noop)
	var result = tool.execute({"action": "set", "stage": "production"}, {}, db2, dbs2, noop, noop)
	db2.close()
	DirAccess.remove_absolute(path2)
	return A.has_key(result, "error")


func test_stalled_can_resume_any() -> Variant:
	var path2 := "user://test_pm_stalled_%d.dct" % Time.get_ticks_msec()
	var db2 := DocketDB.create_new(path2)
	db2.set_project_name("stall-test")
	var dbs2 := {"stall-test": db2}
	var noop := Callable()

	# experiment -> stalled -> experiment
	tool.execute({"action": "set", "stage": "experiment"}, {}, db2, dbs2, noop, noop)
	tool.execute({"action": "set", "stage": "stalled"}, {}, db2, dbs2, noop, noop)
	var r1 = tool.execute({"action": "set", "stage": "experiment"}, {}, db2, dbs2, noop, noop)
	var r = A.eq(r1.get("error", ""), "", "stalled -> experiment ok")
	if r is String: db2.close(); DirAccess.remove_absolute(path2); return r

	# experiment -> incubating -> stalled -> incubating
	tool.execute({"action": "set", "stage": "incubating"}, {}, db2, dbs2, noop, noop)
	tool.execute({"action": "set", "stage": "stalled"}, {}, db2, dbs2, noop, noop)
	var r2 = tool.execute({"action": "set", "stage": "incubating"}, {}, db2, dbs2, noop, noop)
	r = A.eq(r2.get("error", ""), "", "stalled -> incubating ok")
	if r is String: db2.close(); DirAccess.remove_absolute(path2); return r

	# incubating -> production -> stalled -> production
	tool.execute({"action": "set", "stage": "production"}, {}, db2, dbs2, noop, noop)
	tool.execute({"action": "set", "stage": "stalled"}, {}, db2, dbs2, noop, noop)
	var r3 = tool.execute({"action": "set", "stage": "production"}, {}, db2, dbs2, noop, noop)
	r = A.eq(r3.get("error", ""), "", "stalled -> production ok")
	if r is String: db2.close(); DirAccess.remove_absolute(path2); return r

	# production -> stalled -> abandoned
	tool.execute({"action": "set", "stage": "stalled"}, {}, db2, dbs2, noop, noop)
	var r4 = tool.execute({"action": "set", "stage": "abandoned"}, {}, db2, dbs2, noop, noop)
	r = A.eq(r4.get("error", ""), "", "stalled -> abandoned ok")
	db2.close()
	DirAccess.remove_absolute(path2)
	if r is String: return r

	return true


func test_set_requires_stage() -> Variant:
	var result := _exec({"action": "set"})
	return A.has_key(result, "error")


func test_invalid_stage_value() -> Variant:
	var result := _exec({"action": "set", "stage": "flying"})
	return A.has_key(result, "error")
