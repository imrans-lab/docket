extends Node

var A := AssertHelpers
var schema: Dictionary


func setup() -> void:
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	schema = JSON.parse_string(f.get_as_text())


func test_create_bug() -> Variant:
	var item = DataModel.create_item(schema, "bug", {"title": "Login fails"})
	var r = A.eq(item.type, "bug", "type")
	if r is String: return r
	r = A.eq(item.status, "new", "initial status")
	if r is String: return r
	r = A.eq(item.title, "Login fails", "title")
	if r is String: return r
	r = A.has_key(item, "created_at", "created_at present")
	if r is String: return r
	r = A.has_key(item, "events", "events present")
	if r is String: return r
	return A.eq(item.events.size(), 1, "creation event")


func test_create_dcr() -> Variant:
	var item = DataModel.create_item(schema, "dcr", {"title": "Add dark mode"})
	var r = A.eq(item.type, "dcr")
	if r is String: return r
	return A.eq(item.status, "proposed", "dcr initial status")


func test_create_rca() -> Variant:
	var item = DataModel.create_item(schema, "rca", {"title": "Outage 2026-02"})
	var r = A.eq(item.type, "rca")
	if r is String: return r
	return A.eq(item.status, "detected", "rca initial status")


func test_create_chore() -> Variant:
	var item = DataModel.create_item(schema, "chore", {"title": "Update deps"})
	var r = A.eq(item.type, "chore")
	if r is String: return r
	return A.eq(item.status, "open", "chore initial status")


func test_create_insight() -> Variant:
	var item = DataModel.create_item(schema, "insight", {
		"title": "Caching matters",
		"assumed": "DB is fast enough",
		"corrected": "Need Redis for reads"
	})
	var r = A.eq(item.type, "insight")
	if r is String: return r
	r = A.eq(item.status, "draft", "insight initial status")
	if r is String: return r
	r = A.eq(item.assumed, "DB is fast enough")
	if r is String: return r
	return A.eq(item.corrected, "Need Redis for reads")


func test_create_question() -> Variant:
	var item = DataModel.create_item(schema, "question", {"title": "What port?"})
	var r = A.eq(item.type, "question")
	if r is String: return r
	return A.eq(item.status, "asked", "question initial status")


func test_create_insight_missing_required() -> Variant:
	var item = DataModel.create_item(schema, "insight", {"title": "Missing fields"})
	# Should fail — insight requires assumed + corrected
	return A.has_key(item, "error", "should return error")


func test_create_invalid_type() -> Variant:
	var item = DataModel.create_item(schema, "invalid_type", {"title": "Nope"})
	return A.has_key(item, "error", "should return error for invalid type")


func test_event_append() -> Variant:
	var item = DataModel.create_item(schema, "bug", {"title": "Test"})
	DataModel.add_event(item, "note", "agent", "Added a comment")
	var r = A.eq(item.events.size(), 2, "two events after add")
	if r is String: return r
	return A.eq(item.events[1].event_type, "note", "event type")


func test_update_fields() -> Variant:
	var item = DataModel.create_item(schema, "bug", {"title": "Test"})
	var result = DataModel.update_item(schema, item, {"priority": 1, "description": "Details"})
	var r = A.eq(result.get("error", ""), "", "no error")
	if r is String: return r
	r = A.eq(item.priority, 1, "priority set")
	if r is String: return r
	return A.eq(item.description, "Details", "description set")


func test_update_rejects_invalid_field() -> Variant:
	var item = DataModel.create_item(schema, "chore", {"title": "Test"})
	var result = DataModel.update_item(schema, item, {"resolution": "fixed"})
	return A.has_key(result, "error", "chore has no resolution field")


func test_create_discussion() -> Variant:
	var item = DataModel.create_item(schema, "discussion", {"title": "API design options"})
	var r = A.eq(item.type, "discussion", "type")
	if r is String: return r
	r = A.eq(item.status, "active", "initial status is active")
	if r is String: return r
	return A.eq(item.title, "API design options", "title")


func test_create_discussion_missing_title() -> Variant:
	var item = DataModel.create_item(schema, "discussion", {})
	return A.has_key(item, "error", "should return error when title missing")


func test_create_discussion_with_optional_fields() -> Variant:
	var item = DataModel.create_item(schema, "discussion", {
		"title": "Performance concerns",
		"description": "Let's discuss caching strategies",
		"tags": ["perf", "caching"],
		"priority": 2
	})
	var r = A.eq(item.type, "discussion")
	if r is String: return r
	r = A.eq(item.description, "Let's discuss caching strategies", "description set")
	if r is String: return r
	r = A.eq(item.priority, 2, "priority set")
	if r is String: return r
	return A.eq(item.tags.size(), 2, "tags set")


func test_common_fields_present() -> Variant:
	var item = DataModel.create_item(schema, "bug", {"title": "Test"})
	for field in ["type", "status", "title", "created_at", "updated_at", "tags", "links", "events"]:
		var r = A.has_key(item, field, field)
		if r is String: return r
	return true
