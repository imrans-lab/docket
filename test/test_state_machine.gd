extends Node

var A := AssertHelpers
var schema: Dictionary


func setup() -> void:
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	schema = JSON.parse_string(f.get_as_text())


func test_bug_valid_transition() -> Variant:
	return A.is_true(StateMachine.can_transition(schema, "bug", "new", "triaged"))


func test_bug_invalid_transition() -> Variant:
	return A.is_false(StateMachine.can_transition(schema, "bug", "new", "resolved"))


func test_bug_valid_transitions_list() -> Variant:
	var valid = StateMachine.get_valid_transitions(schema, "bug", "new")
	var r = A.eq(valid.size(), 1, "new has 1 transition")
	if r is String: return r
	return A.eq(valid[0], "triaged")


func test_bug_terminal_state_empty() -> Variant:
	var valid = StateMachine.get_valid_transitions(schema, "bug", "closed")
	return A.eq(valid.size(), 0, "closed is terminal")


func test_bug_resolve_requires_resolution() -> Variant:
	var item = DataModel.create_item(schema, "bug", {"title": "Test"})
	item.status = "active"
	var result = StateMachine.perform_transition(schema, item, "resolved", "agent")
	return A.has_key(result, "error", "should require resolution")


func test_bug_resolve_with_resolution() -> Variant:
	var item = DataModel.create_item(schema, "bug", {"title": "Test"})
	item.status = "active"
	var result = StateMachine.perform_transition(schema, item, "resolved", "agent", "", {"resolution": "fixed"})
	var r = A.eq(result.get("error", ""), "", "no error")
	if r is String: return r
	return A.eq(item.status, "resolved", "status changed")


func test_dcr_full_lifecycle() -> Variant:
	var states := ["proposed", "approved", "designing", "implementing", "reviewing", "shipped"]
	for i in range(states.size() - 1):
		var r = A.is_true(
			StateMachine.can_transition(schema, "dcr", states[i], states[i + 1]),
			"%s->%s" % [states[i], states[i + 1]]
		)
		if r is String: return r
	return true


func test_chore_lifecycle() -> Variant:
	var r = A.is_true(StateMachine.can_transition(schema, "chore", "open", "in_progress"))
	if r is String: return r
	return A.is_true(StateMachine.can_transition(schema, "chore", "in_progress", "done"))


func test_insight_lifecycle() -> Variant:
	var item = DataModel.create_item(schema, "insight", {
		"title": "Test", "assumed": "A", "corrected": "B"
	})
	var r = A.eq(item.status, "draft")
	if r is String: return r
	var result = StateMachine.perform_transition(schema, item, "confirmed", "agent")
	r = A.eq(result.get("error", ""), "")
	if r is String: return r
	return A.eq(item.status, "confirmed")


func test_question_escalate_and_answer() -> Variant:
	var item = DataModel.create_item(schema, "question", {"title": "What port?"})
	var result = StateMachine.perform_transition(schema, item, "escalated", "agent")
	var r = A.eq(item.status, "escalated")
	if r is String: return r
	result = StateMachine.perform_transition(schema, item, "answered", "human")
	return A.eq(item.status, "answered")


func test_discussion_lifecycle() -> Variant:
	var item = DataModel.create_item(schema, "discussion", {"title": "API design"})
	var r = A.eq(item.status, "active", "initial state is active")
	if r is String: return r

	var result = StateMachine.perform_transition(schema, item, "resolved", "agent")
	r = A.eq(result.get("error", ""), "", "active->resolved ok")
	if r is String: return r
	r = A.eq(item.status, "resolved", "status is resolved")
	if r is String: return r

	result = StateMachine.perform_transition(schema, item, "active", "agent")
	r = A.eq(result.get("error", ""), "", "resolved->active (reopen) ok")
	if r is String: return r
	return A.eq(item.status, "active", "status is active again")


func test_discussion_invalid_transition() -> Variant:
	return A.is_false(
		StateMachine.can_transition(schema, "discussion", "active", "closed"),
		"discussion has no closed state"
	)


func test_discussion_transitions_from_active() -> Variant:
	var valid = StateMachine.get_valid_transitions(schema, "discussion", "active")
	var r = A.eq(valid.size(), 1, "active has 1 valid transition")
	if r is String: return r
	return A.eq(valid[0], "resolved")


func test_discussion_transitions_from_resolved() -> Variant:
	var valid = StateMachine.get_valid_transitions(schema, "discussion", "resolved")
	var r = A.eq(valid.size(), 1, "resolved has 1 valid transition (reopen)")
	if r is String: return r
	return A.eq(valid[0], "active")


func test_all_types_have_machines() -> Variant:
	for type_name in ["bug", "dcr", "rca", "chore", "insight", "question", "work_item", "discussion", "skill", "prompt", "kb"]:
		var valid = StateMachine.get_valid_transitions(schema, type_name,
			schema.types[type_name].initial_state)
		var r = A.gt(valid.size(), 0, "%s has transitions" % type_name)
		if r is String: return r
	return true


func test_perform_transition_appends_event() -> Variant:
	var item = DataModel.create_item(schema, "chore", {"title": "Test"})
	var before = item.events.size()
	StateMachine.perform_transition(schema, item, "in_progress", "agent")
	return A.eq(item.events.size(), before + 1, "event appended")


# -- Work Item ----------------------------------------------------------------

func test_work_item_lifecycle() -> Variant:
	var item = DataModel.create_item(schema, "work_item", {"title": "Task A"})
	var r = A.eq(item.status, "backlog", "initial state is backlog")
	if r is String: return r

	var result = StateMachine.perform_transition(schema, item, "open", "agent")
	r = A.eq(result.get("error", ""), "", "backlog->open ok")
	if r is String: return r
	r = A.eq(item.status, "open")
	if r is String: return r

	result = StateMachine.perform_transition(schema, item, "in_progress", "agent")
	r = A.eq(item.status, "in_progress")
	if r is String: return r

	result = StateMachine.perform_transition(schema, item, "done", "agent")
	return A.eq(item.status, "done", "reached terminal state")


func test_work_item_blocked_requires_blocked_by() -> Variant:
	var item = DataModel.create_item(schema, "work_item", {"title": "Task B"})
	item.status = "in_progress"
	var result = StateMachine.perform_transition(schema, item, "blocked", "agent")
	return A.has_key(result, "error", "should require blocked_by")


func test_work_item_blocked_with_blocked_by() -> Variant:
	var item = DataModel.create_item(schema, "work_item", {"title": "Task C"})
	item.status = "in_progress"
	var result = StateMachine.perform_transition(schema, item, "blocked", "agent", "", {"blocked_by": "DKT-0042"})
	var r = A.eq(result.get("error", ""), "", "no error with blocked_by")
	if r is String: return r
	return A.eq(item.status, "blocked")


func test_work_item_unblock() -> Variant:
	var item = DataModel.create_item(schema, "work_item", {"title": "Task D"})
	item.status = "blocked"
	var result = StateMachine.perform_transition(schema, item, "in_progress", "agent")
	var r = A.eq(result.get("error", ""), "")
	if r is String: return r
	return A.eq(item.status, "in_progress", "unblocked to in_progress")


func test_work_item_invalid_transition() -> Variant:
	return A.is_false(StateMachine.can_transition(schema, "work_item", "backlog", "done"),
		"can't skip from backlog to done")


# -- find_path BFS ------------------------------------------------------------

func test_find_path_direct_neighbor() -> Variant:
	var path = StateMachine.find_path(schema, "work_item", "backlog", "open")
	var r = A.eq(path.size(), 1, "single step")
	if r is String: return r
	return A.eq(path[0], "open")


func test_find_path_multi_hop() -> Variant:
	var path = StateMachine.find_path(schema, "work_item", "backlog", "done")
	# backlog -> open -> in_progress -> done
	var r = A.eq(path.size(), 3, "3 hops")
	if r is String: return r
	r = A.eq(path[0], "open")
	if r is String: return r
	r = A.eq(path[1], "in_progress")
	if r is String: return r
	return A.eq(path[2], "done")


func test_find_path_no_route() -> Variant:
	# Terminal state "done" has no outgoing transitions
	var path = StateMachine.find_path(schema, "work_item", "done", "backlog")
	return A.eq(path.size(), 0, "no path from terminal")


func test_find_path_same_state() -> Variant:
	var path = StateMachine.find_path(schema, "work_item", "open", "open")
	return A.eq(path.size(), 0, "same state returns empty")


func test_find_path_bug_new_to_closed() -> Variant:
	# new -> triaged -> closed (shortest, since triaged can go directly to closed)
	var path = StateMachine.find_path(schema, "bug", "new", "closed")
	var r = A.eq(path.size(), 2, "2 hops for bug new->closed")
	if r is String: return r
	r = A.eq(path[0], "triaged")
	if r is String: return r
	return A.eq(path[1], "closed")


# -- perform_transition_auto ---------------------------------------------------

func test_auto_transition_direct_unchanged() -> Variant:
	# Direct transition should work exactly as before
	var item = DataModel.create_item(schema, "chore", {"title": "Test"})
	var result = StateMachine.perform_transition_auto(schema, item, "in_progress", "agent")
	var r = A.eq(result.get("error", ""), "", "no error")
	if r is String: return r
	return A.eq(item.status, "in_progress", "direct transition works")


func test_auto_transition_shortcut_work_item_backlog_to_done() -> Variant:
	var item = DataModel.create_item(schema, "work_item", {"title": "Auto"})
	var r = A.eq(item.status, "backlog")
	if r is String: return r
	var result = StateMachine.perform_transition_auto(schema, item, "done", "agent", "finished it")
	r = A.eq(result.get("error", ""), "", "auto-walk succeeds")
	if r is String: return r
	r = A.eq(item.status, "done", "reached done")
	if r is String: return r
	# Should have 3 transition events (backlog->open, open->in_progress, in_progress->done)
	# plus the creation event = 4 total
	return A.eq(item.events.size(), 4, "1 creation + 3 transition events")


func test_auto_transition_note_only_on_final() -> Variant:
	var item = DataModel.create_item(schema, "work_item", {"title": "Note test"})
	StateMachine.perform_transition_auto(schema, item, "done", "agent", "final note")
	# Check that intermediate events do NOT have the note
	var transition_events: Array = []
	for ev in item.events:
		if ev.event_type == "transition":
			transition_events.append(ev)
	# First two intermediate transitions should not contain "final note"
	var r = A.is_false(transition_events[0].note.contains("final note"), "intermediate 1 no note")
	if r is String: return r
	r = A.is_false(transition_events[1].note.contains("final note"), "intermediate 2 no note")
	if r is String: return r
	# Final transition should contain the note
	return A.is_true(transition_events[2].note.contains("final note"), "final has note")


func test_auto_transition_no_path_returns_error() -> Variant:
	var item = DataModel.create_item(schema, "work_item", {"title": "Stuck"})
	item.status = "done"
	var result = StateMachine.perform_transition_auto(schema, item, "backlog", "agent")
	return A.has_key(result, "error", "no path from terminal returns error")


# -- improved error messages --------------------------------------------------

func test_error_nonexistent_state() -> Variant:
	var item = DataModel.create_item(schema, "bug", {"title": "Test"})
	var result = StateMachine.perform_transition(schema, item, "flying", "agent")
	var r = A.has_key(result, "error", "should error on nonexistent state")
	if r is String: return r
	return A.is_true(result.error.contains("does not exist"), "error mentions 'does not exist'")


func test_error_no_path_mentions_valid_next() -> Variant:
	# bug "new" cannot reach "resolved" directly (new->triaged->...->resolved)
	var item = DataModel.create_item(schema, "bug", {"title": "Test"})
	var result = StateMachine.perform_transition(schema, item, "resolved", "agent")
	var r = A.has_key(result, "error", "should error")
	if r is String: return r
	return A.is_true(result.error.contains("No valid path exists"), "error mentions no valid path")


func test_error_nonexistent_state_lists_all_states() -> Variant:
	var item = DataModel.create_item(schema, "chore", {"title": "Test"})
	var result = StateMachine.perform_transition(schema, item, "nonexistent", "agent")
	var r = A.has_key(result, "error", "should error")
	if r is String: return r
	# Should list all valid states for the type
	r = A.is_true(result.error.contains("open"), "lists 'open' state")
	if r is String: return r
	return A.is_true(result.error.contains("done"), "lists 'done' state")


func test_error_no_path_from_terminal_lists_empty() -> Variant:
	var item = DataModel.create_item(schema, "work_item", {"title": "Test"})
	item.status = "done"
	var result = StateMachine.perform_transition(schema, item, "open", "agent")
	var r = A.has_key(result, "error", "should error")
	if r is String: return r
	return A.is_true(result.error.contains("No valid path exists"), "no path from terminal")


func test_auto_transition_extra_only_on_final() -> Variant:
	# Bug: new -> triaged -> active -> resolved (requires resolution extra)
	var item = DataModel.create_item(schema, "bug", {"title": "Bug auto"})
	var result = StateMachine.perform_transition_auto(schema, item, "resolved", "agent", "", {"resolution": "fixed"})
	var r = A.eq(result.get("error", ""), "", "auto-walk with extra succeeds")
	if r is String: return r
	r = A.eq(item.status, "resolved")
	if r is String: return r
	return A.eq(item.get("resolution", ""), "fixed", "resolution applied")
