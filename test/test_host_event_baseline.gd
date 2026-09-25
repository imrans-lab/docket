extends Node
## The descriptor a host's item_changed event carries for an ordinary call of
## a baseline tool, as McpHandler answers a host's tools/call over the real
## tool registry and two JSONL projects, each event built by
## DocketHttpServer.host_event as the stdio server sends it:
## - each successful call of create, transition, update, comment (add, reply,
##   accept), delete, hint set (new and existing) and quality is described by
##   exactly one of its changes, on its item: created (with the item's type,
##   "hint" for a hint set either way), transitioned (with both states),
##   updated (update, delete, and quality's quality_scored, not its
##   typed_update) or comment_added;
## - nothing else is described: a comment listing, a failed call, a mirror, a
##   move (in either project) and a panel's call; every event names the
##   opening it was made in;
## - a listener of a described change that makes changes of its own gets a
##   descriptor for a nested ordinary call (its own) and none for a direct
##   write.

const A = preload("res://test/assert_helpers.gd")
const DIR := "user://fixtures/host_event_baseline"

var _dbs: Array[DocketDB] = []
var _handler: McpHandler
var _events: Array = []
var _next_id := 0


func setup() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	teardown()  # a run that stopped early may have left its fixtures


func teardown() -> void:
	for db in _dbs:
		if db != null and db.is_open():
			db.close()
	_dbs.clear()
	_events.clear()
	for filename in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [DIR, filename]))


# A new JSONL project stored as `name`; its file is new to each test (the
# runner sets the class up once for all of them).
func _project(name: String) -> DocketDB:
	var db := DocketDBJsonl.create_new_jsonl("%s/%s_%d.dct" % [DIR, name, Time.get_ticks_usec()])
	db.set_project_name(name)
	_dbs.append(db)
	db.items_changed.connect(func(changes: Array) -> void:
		for change: Dictionary in changes:
			_events.append(DocketHttpServer.host_event(change, name, _handler, db.get_path(), str(db.get_instance_id()))))
	return db


# `name` with `arguments` as a host's tools/call: the result's JSON, or
# {error} for a failed call.
func _call(name: String, arguments: Dictionary) -> Dictionary:
	_next_id += 1
	var reply: Dictionary = _handler.handle({"jsonrpc": "2.0", "id": _next_id, "method": "tools/call",
		"params": {"name": name, "arguments": arguments}})
	var result: Dictionary = reply.get("result", {})
	var text := str(result.get("content", [{}])[0].get("text", ""))
	if result.get("isError", false) or reply.has("error"):
		return {"error": text if not text.is_empty() else str(reply.get("error", ""))}
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {"error": "unparsed reply: %s" % text}


# The events `work` makes, and the described ones among them.
func _made(work: Callable) -> Array:
	_events.clear()
	var result: Dictionary = work.call()
	var described := _events.filter(func(event: Dictionary) -> bool: return event.has("baseline"))
	return [result, _events.duplicate(), described]


# Whether `made` (of _made) is a successful call described once, by an event
# on `id` (any item when "") of item event `event` carrying `baseline`.
func _described_once(made: Array, id: String, event: String, baseline: Dictionary, what: String) -> Variant:
	var r = A.is_true(not made[0].has("error"), "%s succeeds: %s" % [what, made[0]])
	if r is String: return r
	r = A.eq(made[2].size(), 1, "%s is described by one event: %s" % [what, made[1]])
	if r is String: return r
	var found: Dictionary = made[2][0]
	var item := str(found.id) if id.is_empty() else id
	return A.eq([found.id, found.event, found.baseline], [item, event, baseline],
		"%s is described on its item by its own change: %s" % [what, found])


func _undescribed(made: Array, succeeds: bool, what: String) -> Variant:
	var r = A.eq(not made[0].has("error"), succeeds, "%s %s: %s" % [what, "succeeds" if succeeds else "fails", made[0]])
	if r is String: return r
	return A.eq(made[2], [], "%s is described by nothing: %s" % [what, made[1]])


func test_baseline_calls_are_described_once_and_nothing_else_is() -> Variant:
	var base := _project("base")
	var other := _project("other")
	var registry := ToolRegistry.new()
	registry.init(TypeRegistryBootstrap.load_shipped_schema(), base, {"base": base, "other": other})
	var secret := Crypto.new().generate_random_bytes(32).hex_encode()
	OS.set_environment(McpHandler.PanelAuthority.SECRET_VARIABLE, secret)
	_handler = McpHandler.new()
	_handler.init_with_registry(registry)
	_handler.panel_authority = McpHandler.PanelAuthority.from_environment(registry)

	var made := _made(func() -> Dictionary: return _call("docket_create", {"type": "bug", "title": "A", "project": "base"}))
	var r = _described_once(made, "", "created", {"kind": "created", "item_type": "bug"}, "a create")
	if r is String: return r
	var item := str(made[0].id)
	r = A.eq([made[2][0].id, made[2][0].project, made[2][0].project_path, made[2][0].open_generation],
		[item, "base", base.get_path(), str(base.get_instance_id())], "the created event names the new item and the opening it was made in")
	if r is String: return r
	var target := str(_call("docket_create", {"type": "bug", "title": "B", "project": "base"}).get("id", ""))
	var doomed := str(_call("docket_create", {"type": "bug", "title": "D", "project": "base"}).get("id", ""))
	var moving := str(_call("docket_create", {"type": "bug", "title": "M", "project": "base"}).get("id", ""))
	r = A.is_true(not target.is_empty() and not doomed.is_empty() and not moving.is_empty(), "the other items were created")
	if r is String: return r

	var hint_args := {"component": "c", "key": "k", "value": "v1", "project": "base"}
	made = _made(func() -> Dictionary: return _call("docket_hint_set", hint_args))
	r = _described_once(made, "", "created", {"kind": "created", "item_type": "hint"}, "a new hint")
	if r is String: return r
	var hint := str(made[2][0].id)
	hint_args.value = "v2"
	made = _made(func() -> Dictionary: return _call("docket_hint_set", hint_args))
	r = _described_once(made, hint, "typed_update", {"kind": "created", "item_type": "hint"}, "an existing hint set again")
	if r is String: return r

	made = _made(func() -> Dictionary: return _call("docket_transition", {"id": item, "to": "triaged", "project": "base"}))
	r = _described_once(made, item, "transition", {"kind": "transitioned", "from_status": "new", "to_status": "triaged"}, "a transition")
	if r is String: return r
	made = _made(func() -> Dictionary: return _call("docket_update", {"id": item, "title": "A2", "project": "base"}))
	r = _described_once(made, item, "typed_update", {"kind": "updated"}, "an update")
	if r is String: return r

	made = _made(func() -> Dictionary: return _call("docket_comment", {"action": "add", "item_id": item, "text": "first", "project": "base"}))
	r = _described_once(made, item, "comment_added", {"kind": "comment_added"}, "a comment")
	if r is String: return r
	var comment := int(made[0].get("id", 0))
	made = _made(func() -> Dictionary: return _call("docket_comment", {"action": "reply", "comment_id": comment, "text": "second", "project": "base"}))
	r = _described_once(made, item, "comment_reply", {"kind": "comment_added"}, "a reply")
	if r is String: return r
	made = _made(func() -> Dictionary: return _call("docket_comment", {"action": "accept", "comment_id": comment, "project": "base"}))
	r = _described_once(made, item, "comment_accepted", {"kind": "comment_added"}, "an accepted comment")
	if r is String: return r
	made = _made(func() -> Dictionary: return _call("docket_comment", {"action": "list", "item_id": item, "project": "base"}))
	r = _undescribed(made, true, "a comment listing")
	if r is String: return r

	made = _made(func() -> Dictionary: return _call("docket_quality", {"id": hint, "score": 3, "project": "base"}))
	r = _described_once(made, hint, "quality_scored", {"kind": "updated"}, "a quality score")
	if r is String: return r
	r = A.eq(made[1].map(func(event: Dictionary) -> Array: return [event.id, event.event, event.has("baseline")]),
		[[hint, "typed_update", false], [hint, "quality_scored", true]], "a quality score's typed_update is not described")
	if r is String: return r

	made = _made(func() -> Dictionary: return _call("docket_delete", {"id": doomed, "project": "base"}))
	r = _described_once(made, doomed, "deleted", {"kind": "updated"}, "a delete")
	if r is String: return r

	made = _made(func() -> Dictionary: return _call("docket_update", {"id": "0190a0a0-0000-7000-8000-000000000000", "title": "X", "project": "base"}))
	r = _undescribed(made, false, "an update of a missing item")
	if r is String: return r
	made = _made(func() -> Dictionary: return _call("docket_transition", {"id": item, "to": "nowhere", "project": "base"}))
	r = _undescribed(made, false, "a transition to an undeclared state")
	if r is String: return r
	r = A.eq(made[1], [], "a failed call makes no change")
	if r is String: return r

	made = _made(func() -> Dictionary: return _call("docket_mirror", {"source_id": item, "target_id": target, "fields": {"title": "Mirrored"}, "project": "base"}))
	r = _undescribed(made, true, "a mirror")
	if r is String: return r
	r = A.is_true(not made[1].is_empty(), "a mirror changes its target: %s" % [made[1]])
	if r is String: return r
	made = _made(func() -> Dictionary: return _call("docket_move", {"id": moving, "target_project": "other", "source_project": "base"}))
	r = _undescribed(made, true, "a move")
	if r is String: return r
	r = A.eq([made[1].any(func(e: Dictionary) -> bool: return e.project == "other" and e.event == "created"),
		made[1].any(func(e: Dictionary) -> bool: return e.project == "base" and e.event == "deleted")], [true, true],
		"a move creates in the target project and deletes in the source: %s" % [made[1]])
	if r is String: return r

	var opened: Dictionary = _handler.handle({"jsonrpc": "2.0", "id": 900, "method": "docket/panel/open_session",
		"params": {"panel_secret": secret, "panel": "test-panel"}})
	var session := str(opened.get("result", {}).get("panel_session", ""))
	made = _made(func() -> Dictionary:
		var reply: Dictionary = _handler.handle({"jsonrpc": "2.0", "id": 901, "method": "docket/panel/call",
			"params": {"panel_session": session, "name": "docket_update", "arguments": {"id": item, "title": "Panel", "project": "base"}}})
		return {} if reply.has("result") and not reply.result.get("isError", false) else {"error": str(reply)})
	r = _undescribed(made, true, "a panel's update")
	if r is String: return r
	return A.eq(made[1].size(), 1, "a panel's update is reported: %s" % [made[1]])


func test_a_listeners_own_changes_do_not_take_the_calls_descriptor() -> Variant:
	var base := _project("base")
	var registry := ToolRegistry.new()
	registry.init(TypeRegistryBootstrap.load_shipped_schema(), base, {"base": base})
	_handler = McpHandler.new()
	_handler.init_with_registry(registry)
	var nested := str(_call("docket_create", {"type": "bug", "title": "Nested", "project": "base"}).get("id", ""))
	var direct := str(_call("docket_create", {"type": "bug", "title": "Direct", "project": "base"}).get("id", ""))
	var r = A.is_true(not nested.is_empty() and not direct.is_empty(), "the listener's items were created")
	if r is String: return r
	# Once, on the change describing the next create: an ordinary call through
	# the handler, and a write straight to the registry.
	var listened := [false]
	base.items_changed.connect(func(changes: Array) -> void:
		if listened[0] or not changes.any(func(c: Dictionary) -> bool: return c.has("baseline")):
			return
		listened[0] = true
		_call("docket_update", {"id": nested, "title": "Nested2", "project": "base"})
		registry.call_tool("docket_update", {"id": direct, "title": "Direct2", "project": "base"}))
	var made := _made(func() -> Dictionary: return _call("docket_create", {"type": "bug", "title": "Outer", "project": "base"}))
	r = A.is_true(listened[0] and not made[0].has("error"), "the listener ran within the create: %s" % [made[0]])
	if r is String: return r
	var outer := str(made[0].get("id", ""))
	return A.eq(made[1].map(func(e: Dictionary) -> Array: return [e.id, e.event, e.get("baseline", {})]),
		[[outer, "created", {"kind": "created", "item_type": "bug"}],
		[nested, "typed_update", {"kind": "updated"}],
		[direct, "typed_update", {}]],
		"the create, the nested call and the direct write are each described as their own, or not at all: %s" % [made[1]])
