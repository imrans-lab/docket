extends Node
## Functional tests for cross-project operations, quality scoring lifecycle,
## and project metadata lifecycle through the MCP tool layer.

var A := AssertHelpers
var schema: Dictionary
var db: DocketDB
var db2: DocketDB
var registry: ToolRegistry


func setup() -> void:
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	schema = JSON.parse_string(f.get_as_text())

	var path := "user://test_func_cross_%d.dct" % Time.get_ticks_msec()
	db = DocketDB.create_new(path)
	db.set_project_name("alpha")

	var path2 := "user://test_func_cross2_%d.dct" % Time.get_ticks_msec()
	db2 = DocketDB.create_new(path2)
	db2.set_project_name("beta")

	var project_dbs := {"alpha": db, "beta": db2}
	registry = ToolRegistry.new()
	registry.init(schema, db, project_dbs)
	registry.add_project_fn = Callable()
	registry.remove_project_fn = Callable()


func teardown() -> void:
	for d: DocketDB in [db, db2]:
		if d:
			var p := d.get_path()
			d.close()
			DirAccess.remove_absolute(p)
			for suffix: String in ["-wal", "-shm"]:
				var sp := p + suffix
				if FileAccess.file_exists(sp):
					DirAccess.remove_absolute(sp)


# -- Test 1: Cross-project link -----------------------------------------------

func test_cross_project_link() -> Variant:
	# Create a bug in alpha
	var bug_result = registry.call_tool("docket_create", {
		"type": "bug",
		"title": "Alpha bug",
		"project": "alpha",
	})
	var r = A.eq(bug_result.get("error", ""), "", "bug created without error")
	if r is String: return r
	var bug_id: String = bug_result.id

	# Create a work_item in beta
	var wi_result = registry.call_tool("docket_create", {
		"type": "work_item",
		"title": "Fix for bug",
		"project": "beta",
	})
	r = A.eq(wi_result.get("error", ""), "", "work_item created without error")
	if r is String: return r
	var wi_id: String = wi_result.id

	# Link them cross-project: work_item caused_by alpha:bug
	# Must specify project:"beta" so the link tool resolves "from" in the right DB
	var link_result = registry.call_tool("docket_link", {
		"from": wi_id,
		"to": "alpha:%s" % bug_id,
		"relation": "caused_by",
		"project": "beta",
	})
	r = A.eq(link_result.get("error", ""), "", "cross-project link created without error")
	if r is String: return r

	# Get the work_item and verify the link exists
	var get_result = registry.call_tool("docket_get", {"id": wi_id, "project": "beta"})
	r = A.eq(get_result.get("error", ""), "", "get work_item without error")
	if r is String: return r
	r = A.has_key(get_result, "links", "work_item has links array")
	if r is String: return r
	var links: Array = get_result.links
	r = A.gt(links.size(), 0, "at least one link present")
	if r is String: return r

	var found_link := false
	for link: Dictionary in links:
		if str(link.get("relation", "")) == "caused_by" and str(link.get("to", "")).ends_with(bug_id):
			found_link = true
			break
	r = A.is_true(found_link, "caused_by link to alpha bug found")
	if r is String: return r

	# Query work_items in beta, verify count=1
	var query_result = registry.call_tool("docket_query", {
		"filter": {"type": "work_item"},
		"project": "beta",
	})
	r = A.eq(query_result.get("error", ""), "", "query without error")
	if r is String: return r
	return A.eq(query_result.items.size(), 1, "exactly one work_item in beta")


# -- Test 2: Quality scoring lifecycle ----------------------------------------

func test_quality_scoring_lifecycle() -> Variant:
	# Create 3 hints
	var ha_result = registry.call_tool("docket_create", {
		"type": "hint",
		"title": "Hint A",
		"value": "use fast path",
	})
	var r = A.eq(ha_result.get("error", ""), "", "hint_a created")
	if r is String: return r
	var hint_a_id: String = ha_result.id

	var hb_result = registry.call_tool("docket_create", {
		"type": "hint",
		"title": "Hint B",
		"value": "avoid slow loop",
	})
	r = A.eq(hb_result.get("error", ""), "", "hint_b created")
	if r is String: return r
	var hint_b_id: String = hb_result.id

	var hc_result = registry.call_tool("docket_create", {
		"type": "hint",
		"title": "Hint C",
		"value": "check null first",
	})
	r = A.eq(hc_result.get("error", ""), "", "hint_c created")
	if r is String: return r
	# hint_c is left unscored so quality stays 0; its id is not needed further

	# Score hint_a=4, hint_b=-2; leave hint_c unscored (quality stays 0)
	var score_a = registry.call_tool("docket_quality", {"id": hint_a_id, "score": 4, "reason": "very accurate"})
	r = A.eq(score_a.get("error", ""), "", "hint_a scored without error")
	if r is String: return r
	r = A.eq(score_a.quality, 4, "hint_a quality is 4")
	if r is String: return r

	var score_b = registry.call_tool("docket_quality", {"id": hint_b_id, "score": -2, "reason": "stale"})
	r = A.eq(score_b.get("error", ""), "", "hint_b scored without error")
	if r is String: return r
	r = A.eq(score_b.quality, -2, "hint_b quality is -2")
	if r is String: return r

	# Query hints sorted by quality desc
	var q1 = registry.call_tool("docket_query", {
		"filter": {"type": "hint"},
		"sort": [{"field": "quality", "dir": "desc"}],
		"detail": "full",
	})
	r = A.eq(q1.get("error", ""), "", "first quality query without error")
	if r is String: return r
	r = A.eq(q1.items.size(), 3, "three hints returned")
	if r is String: return r
	# hint_a (4) should be first
	var first_id: String = str(q1.items[0].get("id", ""))
	r = A.eq(first_id, hint_a_id, "hint_a (quality 4) is first")
	if r is String: return r
	# hint_b (-2) should be last — hint_c (0) comes before it
	var last_id: String = str(q1.items[2].get("id", ""))
	r = A.eq(last_id, hint_b_id, "hint_b (quality -2) is last")
	if r is String: return r

	# Update hint_b score from -2 to 3
	var rescore_b = registry.call_tool("docket_quality", {"id": hint_b_id, "score": 3, "reason": "revised"})
	r = A.eq(rescore_b.get("error", ""), "", "hint_b rescored without error")
	if r is String: return r
	r = A.eq(rescore_b.quality, 3, "hint_b quality now 3")
	if r is String: return r

	# Get hint_b and verify quality=3 and last_reviewed is set
	var get_b = registry.call_tool("docket_get", {"id": hint_b_id})
	r = A.eq(get_b.get("error", ""), "", "get hint_b without error")
	if r is String: return r
	r = A.eq(int(get_b.get("quality", 0)), 3, "stored quality is 3")
	if r is String: return r
	r = A.is_true(not str(get_b.get("last_reviewed", "")).is_empty(), "last_reviewed is set")
	if r is String: return r

	# Query again sorted by quality desc — hint_a (4) first, hint_b (3) second
	var q2 = registry.call_tool("docket_query", {
		"filter": {"type": "hint"},
		"sort": [{"field": "quality", "dir": "desc"}],
		"detail": "full",
	})
	r = A.eq(q2.get("error", ""), "", "second quality query without error")
	if r is String: return r
	r = A.eq(q2.items.size(), 3, "three hints in second query")
	if r is String: return r
	var first_id2: String = str(q2.items[0].get("id", ""))
	r = A.eq(first_id2, hint_a_id, "hint_a (4) still first after rescore")
	if r is String: return r
	var second_id2: String = str(q2.items[1].get("id", ""))
	return A.eq(second_id2, hint_b_id, "hint_b (3) is now second")


# -- Test 3: Project metadata lifecycle ----------------------------------------

func test_project_metadata_lifecycle() -> Variant:
	# Step 1: get with no metadata set — stage should be empty
	var get1 = registry.call_tool("docket_project_meta", {"action": "get"})
	var r = A.eq(get1.get("error", ""), "", "initial get without error")
	if r is String: return r
	r = A.has_key(get1, "stage", "get result has stage key")
	if r is String: return r
	r = A.eq(get1.stage, "", "fresh project has empty stage")
	if r is String: return r

	# Step 2: set stage=experiment with hypothesis
	var set1 = registry.call_tool("docket_project_meta", {
		"action": "set",
		"stage": "experiment",
		"hypothesis": "Testing cross-project queries",
	})
	r = A.eq(set1.get("error", ""), "", "set experiment without error")
	if r is String: return r
	r = A.eq(set1.stage, "experiment", "stage is experiment after set")
	if r is String: return r

	# Step 3: get and verify stage and hypothesis persisted
	var get2 = registry.call_tool("docket_project_meta", {"action": "get"})
	r = A.eq(get2.get("error", ""), "", "second get without error")
	if r is String: return r
	r = A.eq(get2.stage, "experiment", "stage persisted as experiment")
	if r is String: return r
	r = A.eq(str(get2.get("hypothesis", "")), "Testing cross-project queries", "hypothesis persisted")
	if r is String: return r

	# Step 4: set stage=incubating with note
	var set2 = registry.call_tool("docket_project_meta", {
		"action": "set",
		"stage": "incubating",
		"note": "Proved viable",
	})
	r = A.eq(set2.get("error", ""), "", "set incubating without error")
	if r is String: return r
	r = A.eq(set2.stage, "incubating", "stage is incubating")
	if r is String: return r

	# Step 5: set stage=production
	var set3 = registry.call_tool("docket_project_meta", {"action": "set", "stage": "production"})
	r = A.eq(set3.get("error", ""), "", "set production without error")
	if r is String: return r
	r = A.eq(set3.stage, "production", "stage is production")
	if r is String: return r

	# Step 6: docket_project_list — verify alpha has stage="production"
	var list_result = registry.call_tool("docket_project_list", {})
	r = A.eq(list_result.get("error", ""), "", "project_list without error")
	if r is String: return r
	r = A.has_key(list_result, "projects", "result has projects array")
	if r is String: return r
	var projects: Array = list_result.projects
	var alpha_entry: Dictionary = {}
	for proj: Dictionary in projects:
		if str(proj.get("name", "")) == "alpha":
			alpha_entry = proj
			break
	r = A.is_true(not alpha_entry.is_empty(), "alpha project found in list")
	if r is String: return r
	r = A.eq(str(alpha_entry.get("stage", "")), "production", "alpha entry has stage=production")
	if r is String: return r

	# Step 7: invalid transition — production cannot go to experiment
	var set_invalid = registry.call_tool("docket_project_meta", {
		"action": "set",
		"stage": "experiment",
	})
	return A.has_key(set_invalid, "error", "production -> experiment returns error")
