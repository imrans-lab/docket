extends Node

var A := AssertHelpers
var schema: Dictionary


func setup() -> void:
	var f := FileAccess.open("res://data/schema.json", FileAccess.READ)
	schema = JSON.parse_string(f.get_as_text())


# -- Skill creation -----------------------------------------------------------

func test_create_skill() -> Variant:
	var item = DataModel.create_item(schema, "skill", {"title": "Deploy to staging"})
	var r = A.eq(item.type, "skill", "type")
	if r is String: return r
	r = A.eq(item.status, "draft", "initial status")
	if r is String: return r
	return A.eq(item.title, "Deploy to staging", "title")


func test_create_skill_with_fields() -> Variant:
	var item = DataModel.create_item(schema, "skill", {
		"title": "List files",
		"steps": "1. Run: ls -la [path]\n2. Parse output for file names, sizes, permissions",
		"preconditions": "Must be in a unix shell",
		"outcome": "Directory listing with file details",
		"tool_deps": ["minerva_bash", "minerva_file_read"],
		"optimization": {"context_window": 16000, "tool_budget": 4},
		"component": "filesystem",
	})
	var r = A.eq(item.type, "skill")
	if r is String: return r
	r = A.eq(item.steps, "1. Run: ls -la [path]\n2. Parse output for file names, sizes, permissions", "steps stored")
	if r is String: return r
	r = A.eq(item.preconditions, "Must be in a unix shell", "preconditions stored")
	if r is String: return r
	r = A.eq(item.outcome, "Directory listing with file details", "outcome stored")
	if r is String: return r
	r = A.eq(item.tool_deps.size(), 2, "tool_deps stored")
	if r is String: return r
	return A.eq(int(item.optimization.get("tool_budget", 0)), 4, "optimization stored")


# -- Prompt creation ----------------------------------------------------------

func test_create_prompt() -> Variant:
	var item = DataModel.create_item(schema, "prompt", {"title": "Code review checklist"})
	var r = A.eq(item.type, "prompt", "type")
	if r is String: return r
	return A.eq(item.status, "draft", "initial status")


func test_create_prompt_with_fields() -> Variant:
	var item = DataModel.create_item(schema, "prompt", {
		"title": "Supervisor system prompt",
		"prompt_text": "You are a supervisor agent. Decompose tasks, assign workers, track via Docket.",
		"parameters": "{{project_name}}, {{worker_count}}",
		"key": "agentic-base",
		"target": "sonnet:<=4.6@openrouter",
		"topic": "supervision",
	})
	var r = A.eq(item.type, "prompt")
	if r is String: return r
	r = A.eq(item.prompt_text, "You are a supervisor agent. Decompose tasks, assign workers, track via Docket.", "prompt_text stored")
	if r is String: return r
	r = A.eq(item.parameters, "{{project_name}}, {{worker_count}}", "parameters stored")
	if r is String: return r
	r = A.eq(item.key, "agentic-base", "key stored")
	if r is String: return r
	return A.eq(item.target, "sonnet:<=4.6@openrouter", "target stored")


# -- KB creation --------------------------------------------------------------

func test_create_kb() -> Variant:
	var item = DataModel.create_item(schema, "kb", {"title": "How the trigger system works"})
	var r = A.eq(item.type, "kb", "type")
	if r is String: return r
	return A.eq(item.status, "draft", "initial status")


func test_create_kb_with_fields() -> Variant:
	var item = DataModel.create_item(schema, "kb", {
		"title": "Minerva trigger system",
		"key": "triggers",
		"article": "Triggers are event subscriptions that wake sleeping chats. When a docket item matching a filter changes state, the trigger fires and injects a synthetic user turn into the subscribed chat.",
		"summary": "Event subscriptions that wake sleeping chats on docket state changes",
		"topic": "architecture",
		"subtopic": "events",
	})
	var r = A.eq(item.type, "kb")
	if r is String: return r
	r = A.eq(item.key, "triggers", "key stored")
	if r is String: return r
	r = A.eq(item.summary, "Event subscriptions that wake sleeping chats on docket state changes", "summary stored")
	if r is String: return r
	return A.eq(item.article.begins_with("Triggers are event subscriptions"), true, "article stored")


func test_create_policy() -> Variant:
	var item = DataModel.create_item(schema, "policy", {
		"title": "Escalate on write actions",
		"description": "Require approval before destructive operations.",
		"component": "agent-safety",
		"steps": "1. Detect destructive tool calls\n2. Pause for approval",
		"preconditions": "Action mutates user state",
		"outcome": "Human-approved changes only",
	})
	var r = A.eq(item.type, "policy", "type")
	if r is String: return r
	r = A.eq(item.status, "draft", "initial status")
	if r is String: return r
	r = A.eq(item.component, "agent-safety", "component stored")
	if r is String: return r
	return A.is_true(item.steps.contains("Detect destructive"), "steps stored")


# -- State machine: skill lifecycle -------------------------------------------

func test_skill_lifecycle() -> Variant:
	var item = DataModel.create_item(schema, "skill", {"title": "Test skill"})
	var r = A.eq(item.status, "draft")
	if r is String: return r

	var result = StateMachine.perform_transition(schema, item, "active", "agent")
	r = A.eq(result.get("error", ""), "", "draft->active ok")
	if r is String: return r
	r = A.eq(item.status, "active")
	if r is String: return r

	result = StateMachine.perform_transition(schema, item, "archived", "agent")
	r = A.eq(result.get("error", ""), "", "active->archived ok")
	if r is String: return r
	return A.eq(item.status, "archived")


func test_skill_reactivate() -> Variant:
	var item = DataModel.create_item(schema, "skill", {"title": "Test"})
	item.status = "archived"
	var result = StateMachine.perform_transition(schema, item, "active", "agent")
	var r = A.eq(result.get("error", ""), "", "archived->active ok")
	if r is String: return r
	return A.eq(item.status, "active", "reactivated")


func test_skill_invalid_transition() -> Variant:
	return A.is_false(
		StateMachine.can_transition(schema, "skill", "draft", "archived"),
		"draft cannot go directly to archived"
	)


# -- State machine: prompt lifecycle ------------------------------------------

func test_prompt_lifecycle() -> Variant:
	var item = DataModel.create_item(schema, "prompt", {"title": "Test prompt"})
	var r = A.eq(item.status, "draft")
	if r is String: return r

	var result = StateMachine.perform_transition(schema, item, "active", "agent")
	r = A.eq(result.get("error", ""), "", "draft->active ok")
	if r is String: return r

	result = StateMachine.perform_transition(schema, item, "archived", "agent")
	r = A.eq(result.get("error", ""), "", "active->archived ok")
	if r is String: return r
	return A.eq(item.status, "archived")


# -- State machine: kb lifecycle ----------------------------------------------

func test_kb_lifecycle() -> Variant:
	var item = DataModel.create_item(schema, "kb", {"title": "Test KB"})
	var r = A.eq(item.status, "draft")
	if r is String: return r

	var result = StateMachine.perform_transition(schema, item, "active", "agent")
	r = A.eq(result.get("error", ""), "", "draft->active ok")
	if r is String: return r

	result = StateMachine.perform_transition(schema, item, "archived", "agent")
	r = A.eq(result.get("error", ""), "", "active->archived ok")
	if r is String: return r
	return A.eq(item.status, "archived")


# -- All types in schema have state machines ----------------------------------

func test_all_knowledge_types_have_machines() -> Variant:
	for type_name in ["skill", "prompt", "kb", "policy"]:
		var valid = StateMachine.get_valid_transitions(schema, type_name,
			schema.types[type_name].initial_state)
		var r = A.gt(valid.size(), 0, "%s has transitions from initial state" % type_name)
		if r is String: return r
	return true


# -- Update rejects invalid fields per type -----------------------------------

func test_skill_rejects_repro_steps() -> Variant:
	var item = DataModel.create_item(schema, "skill", {"title": "Test"})
	var result = DataModel.update_item(schema, item, {"repro_steps": "steps"})
	return A.has_key(result, "error", "skill has no repro_steps field")


func test_kb_accepts_article_field() -> Variant:
	var item = DataModel.create_item(schema, "kb", {"title": "Test"})
	var result = DataModel.update_item(schema, item, {"article": "Full article text here."})
	var r = A.eq(result.get("error", ""), "", "kb accepts article field")
	if r is String: return r
	return A.eq(item.article, "Full article text here.", "article value updated")


func test_prompt_accepts_prompt_text_field() -> Variant:
	var item = DataModel.create_item(schema, "prompt", {"title": "Test"})
	var result = DataModel.update_item(schema, item, {"prompt_text": "You are a helpful agent."})
	var r = A.eq(result.get("error", ""), "", "prompt accepts prompt_text field")
	if r is String: return r
	return A.eq(item.prompt_text, "You are a helpful agent.", "prompt_text updated")


func test_skill_accepts_steps_field() -> Variant:
	var item = DataModel.create_item(schema, "skill", {"title": "Test"})
	var result = DataModel.update_item(schema, item, {"steps": "1. git status\n2. review changes"})
	var r = A.eq(result.get("error", ""), "", "skill accepts steps field")
	if r is String: return r
	return A.eq(item.steps, "1. git status\n2. review changes", "steps updated")


func test_prompt_accepts_target_field() -> Variant:
	var item = DataModel.create_item(schema, "prompt", {"title": "Targeted prompt"})
	var result = DataModel.update_item(schema, item, {"target": "all"})
	var r = A.eq(result.get("error", ""), "", "prompt accepts target field")
	if r is String: return r
	return A.eq(item.target, "all", "target updated")


func test_skill_accepts_tool_deps_and_optimization() -> Variant:
	var item = DataModel.create_item(schema, "skill", {"title": "Tooling"})
	var result = DataModel.update_item(schema, item, {
		"tool_deps": ["docket_query", "docket_get"],
		"optimization": {"summary_mode": "deterministic", "tool_budget": 2},
	})
	var r = A.eq(result.get("error", ""), "", "skill accepts structured fields")
	if r is String: return r
	r = A.eq(item.tool_deps.size(), 2, "tool_deps updated")
	if r is String: return r
	return A.eq(int(item.optimization.get("tool_budget", 0)), 2, "optimization updated")


# -- Tags work on knowledge types ---------------------------------------------

func test_skill_with_tags() -> Variant:
	var item = DataModel.create_item(schema, "skill", {
		"title": "Tagged skill",
		"tags": ["refactoring", "gdscript"],
	})
	var r = A.eq(item.tags.size(), 2, "tags stored")
	if r is String: return r
	return A.is_true(item.tags.has("refactoring"), "tag present")
