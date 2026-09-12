extends Node
## Observable catalog and query-scope behavior. Fixtures use registry-shaped
## records so the same expectations apply when project registries replace the
## built-in schema adapter.

var A := AssertHelpers


func _schema() -> Dictionary:
	return {"types": {
		"discussion": {"label": "discussion", "description": "Async decisions", "aliases": ["thread"], "states": ["active", "resolved"], "required_fields": ["title"], "optional_fields": ["priority"]},
		"code_review": {"id": "type-2", "label": "Code Review", "description": "Review a revision", "use_when": "approval is required", "states": ["requested", "approved"], "required_fields": ["title", "revision"], "optional_fields": ["reviewer"]},
		"old_review": {"label": "Code Review", "description": "Historical review", "lifecycle": "deprecated", "states": ["closed"]},
	}}


func test_catalog_is_case_insensitive_and_stably_sorted() -> Variant:
	var records := TypeCatalog.from_schema(_schema(), "Zulu", {"discussion": 4})
	var other := TypeCatalog.from_schema({"types": {"review": {"id": "type-1", "label": "Code Review", "states": []}}}, "alpha")
	records.append_array(other)
	records = TypeCatalog.sorted(records)
	var identities := []
	for record in records:
		identities.append("%s/%s/%s" % [record.label, record.project, record.id])
	return A.eq(identities, ["Code Review/alpha/type-1", "Code Review/Zulu/type-2", "Code Review/Zulu/old_review", "discussion/Zulu/discussion"], "label, project, slug/id tie-break order")


func test_search_matches_metadata_without_reordering() -> Variant:
	var records := TypeCatalog.from_schema(_schema(), "docket")
	var purpose_matches := TypeCatalog.filter(records, "APPROVAL")
	var r = A.eq(purpose_matches.size(), 1, "use-when match")
	if r != true: return r
	r = A.eq(purpose_matches[0].slug, "code_review", "metadata identifies code review")
	if r != true: return r
	var alias_matches := TypeCatalog.filter(records, "THREAD")
	r = A.eq(alias_matches.size(), 1, "alias match is case insensitive")
	if r != true: return r
	return A.eq(alias_matches[0].item_count, 0, "active zero-count type remains discoverable")


func test_deprecated_types_require_explicit_option() -> Variant:
	var records := TypeCatalog.from_schema(_schema())
	var hidden := TypeCatalog.filter(records, "historical")
	var shown := TypeCatalog.filter(records, "historical", true)
	var r = A.eq(hidden.size(), 0, "deprecated hidden by default")
	if r != true: return r
	return A.eq(shown[0].slug, "old_review", "deprecated available for historical query")


func test_discussion_scope_only_offers_discussion_states() -> Variant:
	var catalog := TypeCatalog.from_schema(_schema())
	var groups := QueryTypeScope.statuses(catalog, ["discussion"])
	var r = A.eq(groups.size(), 1, "one selected type group")
	if r != true: return r
	return A.eq(groups[0].values, ["active", "resolved"], "discussion states")


func test_multiple_types_keep_separate_status_groups() -> Variant:
	var groups := QueryTypeScope.statuses(TypeCatalog.from_schema(_schema()), ["discussion", "code_review"])
	var values_by_type := {}
	for group in groups:
		values_by_type[group.type] = group.values
	var r = A.eq(values_by_type.discussion, ["active", "resolved"], "discussion group")
	if r != true: return r
	return A.eq(values_by_type.code_review, ["requested", "approved"], "review group")


func test_or_branches_do_not_share_type_scope() -> Variant:
	var conditions := [
		{"field": "type", "op": "eq", "value": "discussion"},
		{"field": "status", "op": "eq", "value": "active", "conj": "and"},
		{"field": "type", "op": "eq", "value": "code_review", "conj": "or"},
		{"field": "status", "op": "eq", "value": "requested", "conj": "and"},
	]
	var r = A.eq(QueryTypeScope.selected_types(conditions, 1), ["discussion"], "first branch scope")
	if r != true: return r
	return A.eq(QueryTypeScope.selected_types(conditions, 3), ["code_review"], "second branch scope")


func test_and_type_predicates_intersect() -> Variant:
	var conditions := [
		{"field": "type", "op": "in", "value": ["discussion", "code_review"]},
		{"field": "type", "op": "eq", "value": "discussion", "conj": "and"},
	]
	var scope := QueryTypeScope.branch_scope(conditions, 1)
	var r = A.is_true(scope.known, "positive type scope recognized")
	if r != true: return r
	return A.eq(scope.types, ["discussion"], "AND computes intersection")


func test_scope_retains_valid_and_reports_incompatible_values() -> Variant:
	var catalog := TypeCatalog.from_schema(_schema())
	var retained := QueryTypeScope.validate_value("status", "active", catalog, ["discussion"])
	var invalidated := QueryTypeScope.validate_value("status", "active", catalog, ["code_review"])
	var r = A.is_true(retained.valid, "valid state retained")
	if r != true: return r
	r = A.is_false(invalidated.valid, "incompatible state invalidated")
	if r != true: return r
	return A.is_true(str(invalidated.message).contains("active"), "message identifies retained literal")


func test_type_scoped_fields_are_a_union() -> Variant:
	var fields := QueryTypeScope.fields(TypeCatalog.from_schema(_schema()), ["discussion", "code_review"])
	var r = A.is_true(fields.has("priority"), "discussion field")
	if r != true: return r
	r = A.is_true(fields.has("revision"), "review field")
	if r != true: return r
	return A.is_true(fields.has("title"), "shared field")


func test_grouped_status_materializes_project_and_type_identity() -> Variant:
	var condition := {"field": "status", "op": "eq", "value": "requested", "conj": "or"}
	var expanded := QueryTypeScope.expand_grouped_status(condition, {"value": "requested", "type": "code_review", "project": "alpha"}, true)
	var r = A.eq(expanded[0], {"field": "project", "op": "eq", "value": "alpha", "conj": "or"}, "project starts original branch")
	if r != true: return r
	r = A.eq(expanded[1], {"field": "type", "op": "eq", "value": "code_review", "conj": "and"}, "type is bound inside group")
	if r != true: return r
	return A.eq(expanded[2].value, "requested", "status literal retained")


func test_type_chooser_keeps_selection_when_search_hides_it() -> Variant:
	var chooser := TypeChooser.new()
	add_child(chooser)
	chooser.configure(TypeCatalog.from_schema(_schema()), "chooser-test")
	chooser.set_selected_values(["discussion", "code_review"])
	chooser._search.text = "approval"
	chooser._rebuild()
	var r = A.eq(chooser.selected_values(), ["discussion", "code_review"], "search does not discard hidden selections")
	chooser.queue_free()
	return r


func test_membership_operator_translates_to_bound_in_predicate() -> Variant:
	DocketDBFilter.set_allowed_fields(["type"])
	var translated := DocketDBFilter.translate_conditions([{"field": "type", "op": "in", "value": ["discussion", "code_review"]}])
	var r = A.eq(translated.where, "type IN (?,?)", "membership SQL")
	if r != true: return r
	return A.eq(translated.bindings, ["discussion", "code_review"], "values remain bound")


func test_cross_project_binding_preserves_or_branches() -> Variant:
	var state := AppState.new()
	var query := {"filter": {"conditions": [
		{"field": "project", "op": "eq", "value": "alpha"},
		{"field": "type", "op": "eq", "value": "discussion", "conj": "and"},
		{"field": "type", "op": "eq", "value": "code_review", "conj": "or"},
	]}}
	var alpha := state._bind_project_conditions(query, "alpha").query.filter.conditions
	var beta := state._bind_project_conditions(query, "beta").query.filter.conditions
	var r = A.eq(alpha[0].op, "is_not_empty", "matching project keeps first branch true")
	if r != true: return r
	r = A.eq(beta[0].value, "__project_scope_never_matches__", "other project disables only scoped branch")
	if r != true: return r
	return A.eq(beta[2].conj, "or", "independent sibling branch is retained")
