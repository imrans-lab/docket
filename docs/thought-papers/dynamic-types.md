# Dynamic Types and Agent Interoperability in Docket

- **Status:** Initial thought-paper draft
- **Date:** 2026-08-11
- **Scope:** Product and architecture exploration; not an implementation specification

## Abstract

Docket is most valuable when it remains "just a database": a durable,
queryable, git-native meeting place for humans and language models. It should
not need embedded intelligence to understand a project's work. The intelligence
lives in the humans and LLMs using it; Docket supplies structure, validation,
history, relationships, queries, and a shared user interface.

The current fixed set of item types works well for common cases, but real
projects develop concepts that Docket did not know at birth. Goals, epochs,
reviews, decisions, acceptance criteria, findings, and handoffs emerge through
use. Today these concepts are compressed into generic work items, questions,
chores, tests, tags, title prefixes, and comments. Their distinct lifecycles are
therefore implicit and difficult to query reliably.

This paper explores making types project-local, first-class data. An LLM or
human could define a new type, including its fields and lifecycle, through MCP
or the GUI. Docket would validate and store the definition, then mechanically
render forms, transitions, tables, boards, and query facets from it. A small set
of strict bootstrap types would remain available at project birth, while each
project's vocabulary could evolve from actual usage.

The paper also distinguishes stored meaning from runtime behavior. A Docket
record called a skill is not automatically a native skill in Codex, Claude
Code, OpenCode, or another agent framework. A policy cannot enforce a
must-read rule unless the host reports the triggering event and honors the
result. Dynamic types therefore need to work alongside portable behavioral
profiles, artifact formats, MCP runtime contracts, and thin host adapters.

The same distinction applies to long-running coordination. A review item can
record that Claude was asked to review a revision, but it does not by itself
wake Codex when findings arrive. A durable monitor can record the condition,
recipient, delivery policy, and resulting obligation, while a host adapter or
supervisor performs the actual wait and wake. The stateless MCP `2026-07-28`
revision makes these handoffs more robust by replacing connection-scoped state
with explicit handles, but Docket records must remain the source of truth
across disconnected clients and repeated review rounds.

The design challenge is not merely allowing arbitrary names and states. It is
enabling emergence without producing an incoherent taxonomy, breaking saved
queries, or hiding semantic changes from humans.

## 1. Position

Dynamic types are a better long-term direction than continually adding
project-specific nouns to Docket's global built-in schema.

The core principle is:

> Create a type when records need different behavior, not merely a different
> name.

A new type is warranted when at least one of the following is true:

- It has a distinct lifecycle or terminal meaning.
- It requires fields that other types do not.
- Its transitions require different evidence or permissions.
- It has container, rollup, or relationship behavior of its own.
- Humans need to query or operate on it as a first-class project concept.

If the distinction is only vocabulary, presentation, or temporary grouping, a
tag, template, saved query, or view is a better fit.

## 2. Why the Fixed Taxonomy Strains

Docket's prescribed types currently mix several different dimensions:

- The semantic nature of a record: defect, question, knowledge, policy.
- The kind of activity being performed: design, implementation, review.
- The record's position in a hierarchy: task, plan, goal, campaign.
- The evidence or outcome being tracked: test result, acceptance, verification.

In active use, projects naturally introduce additional concepts. One Minerva
workflow, for example, uses generic work items for goals, campaigns, epochs,
implementation plans, acceptance gates, human-review queues, and executable
tasks. Review requests are often questions. Review findings become a mixture of
bugs, chores, work items, or comments depending on how certain the reviewer is.
Tests serve both as persistent test cases and as acceptance criteria.

Those choices are individually understandable, but they weaken the data model:

- A goal can remain `backlog` while dozens of descendants are active or done.
- An epoch marked `done` may mean the timebox closed, not that every child was
  completed.
- An answered review question cannot distinguish approval from changes
  requested.
- A test state can conflate definition maturity with its latest execution
  result.
- A handoff stored as a hint lacks consumed, stale, and superseded states.
- Abandoned work often remains proposed or backlog because many types have no
  cancelled, rejected, obsolete, or superseded outcome.

This is not primarily a failure by the people or agents choosing types. The
repeated title prefixes and tags are evidence that the project has developed a
richer ontology than the database can currently express.

## 3. Docket Remains a Database

Dynamic types do not require Docket to infer intent or embed an LLM.

The responsibilities remain deliberately separated:

- **Humans and LLMs** recognize recurring concepts and propose useful
  structure.
- **Docket** validates, stores, versions, indexes, and queries declarations.
- **The GUI** deterministically renders standard controls from declarations.
- **MCP** exposes the same declarations and records to agents.

Docket need not decide that eleven similarly tagged questions "look like code
reviews." An LLM may notice that pattern and propose a `code_review` type.
Docket's job is to record the proposal, detect structural conflicts, expose it
to the human, and make the activated type usable everywhere.

The resulting ontology is shared project data. It is not trapped in an agent's
prompt, a human convention, or bespoke UI code.

This database boundary also limits what a stored record can do by itself.
Dynamic types make a project's vocabulary extensible; they do not cause a host
framework to execute a skill, inject knowledge, or enforce a policy. Those
behaviors require an explicit contract with the host. Docket should describe
and evaluate that contract deterministically while leaving interception and
enforcement to the framework in which the agent is running.

## 4. Bootstrap Types

A new project still needs useful types before it has developed its own
vocabulary. Docket should ship with a small, strict bootstrap set.

A possible kernel is:

- `work_item`: a concrete, executable unit of work.
- `bug`: observed broken behavior.
- `question`: a bounded knowledge request.
- `discussion`: a collaborative thread.
- `type_definition`: a tracked definition of a project-local type.

Other familiar types could be supplied as a starter library rather than coded
through a separate mechanism. A DCR, RCA, test case, skill, policy, or knowledge
article would then be a protected system-supplied definition expressed through
the same type machinery used by project types.

This avoids creating two classes of type: powerful built-ins and second-class
custom types. System definitions may be protected from destructive edits, but
they should otherwise be inspectable, queryable, and renderable in the same
way.

The exact bootstrap set is an open question. The important constraint is that
birth types should be semantically narrow and have transitions that reflect
their real meaning.

## 5. A Type Definition

A first-class type definition needs more than a label and list of statuses.
At minimum it should include:

### Identity and guidance

- Stable internal ID.
- Stable project-local slug.
- Human-readable singular and plural labels.
- Description and purpose.
- "Use when" guidance.
- "Do not use when" guidance.
- Examples and counterexamples.
- Creator, creation reason, and source records that motivated it.

### Fields

- Stable field key and mutable label.
- Scalar, enum, Markdown, date/time, item reference, reference list, or other
  supported storage type.
- Required or optional status.
- Default value, if safe.
- Validation constraints.
- Query operators appropriate to the field type.
- Help text for humans and LLMs.

Arbitrary executable validators should not be part of the first version.
Declarative constraints preserve portability, safety, and deterministic
validation.

### Lifecycle

- Initial state.
- States and display order.
- Allowed transition edges.
- Terminal states.
- Reopen paths.
- Transition requirements, such as required fields or relationships.
- Optional actor constraints, such as human-only approval.
- Transition enforcement mode.

### Structure

- Whether instances are normally leaves, containers, threads, or evidence.
- Permitted or suggested parent and child types.
- Suggested relationship kinds.
- Optional completion or rollup policy.

### Presentation

- Default columns and sort order.
- Optional icon and color.
- Summary fields.
- Suggested saved queries and views.

Presentation metadata should remain hints interpreted by standard Docket UI.
A type definition must not contain arbitrary UI code.

### Behavioral conformance

A type may optionally declare that it implements one or more stable behavioral
profiles, such as `agent.skill/v1`, `agent.knowledge/v1`, or
`docket.policy/v1`. The declaration maps the dynamic type's fields onto the
portable profile and identifies the capabilities a host must provide.

Profiles are interfaces, not prescribed project nouns. A project may define
`deployment_runbook`, `incident_playbook`, and `release_checklist` as distinct
types while allowing all three to implement `agent.skill/v1`. Unknown dynamic
types remain ordinary queryable records; defining a new type does not grant it
execution authority.

## 6. Canonical State Semantics

Project-defined state names must not destroy cross-project queries.

Every state should map to a small canonical activity category:

- `queued`
- `active`
- `waiting`
- `terminal`

A terminal state should additionally declare an outcome:

- `success`
- `action_required`
- `cancelled`
- `rejected`
- `duplicate`
- `superseded`
- `obsolete`
- `failed`

The exact vocabulary may change, but activity and outcome should remain
separate. This permits a project to use domain language while preserving
portable queries such as:

```text
is:open
state_category:waiting
outcome:success
outcome:superseded
```

It also prevents every lifecycle from needing bespoke spellings of the same
negative dispositions.

## 7. Transition Enforcement

The current model treats the transition graph as a recommended path: an
off-flow move is allowed when accompanied by a note. Dynamic types make the
meaning of the graph more important.

A type could declare one of three enforcement modes:

- `strict`: only declared edges are valid.
- `guided`: off-flow moves are allowed with an explanation.
- `open`: any declared state is reachable.

Bootstrap work types should generally be strict. Repairs to historical data
should use an explicit administrative override rather than looking like an
ordinary lifecycle transition.

Transition guards should remain declarative and produce actionable errors. For
example:

- Answering a question requires an answer field or accepted answer comment.
- Approving a review requires a reviewed revision and disposition of blocking
  findings.
- Resolving a bug requires a resolution.
- Achieving a goal requires its required acceptance criteria to be satisfied.
- Closing an iteration with unfinished children requires a carryover
  disposition.

An LLM-facing error should identify the failed guard, related item IDs, and
valid next actions rather than merely reporting an invalid transition.

## 8. Human Use Through the GUI

The human should not need an LLM to interpret a type created by an LLM. The GUI
should behave as a deterministic schema browser.

When a new type is activated, the UI can mechanically provide:

- A create and edit form generated from its fields.
- Valid transition buttons generated from its state machine.
- Table columns and query facets for its fields.
- A board generated from its ordered states.
- A type home page with open, recent, terminal, and all-item views.
- A schema page showing its purpose, lifecycle, fields, provenance, and usage.

### Schema-change inbox

Ontology changes should be visible project events. A human-facing schema inbox
could show:

- Type created or activated.
- Field or state added.
- Lifecycle changed.
- Type deprecated or replaced.
- Items migrated between types.

For an agent-created type, the UI might display:

> New project type: Code Review
>
> Created by `codex` because repeated review requests were being represented as
> questions. Three existing records are candidates for migration.

The human can inspect, ratify, rename, pin, deprecate, merge, or replace the
type. A project policy determines whether ratification is required before use
or is simply a trust marker after immediate activation.

### Navigation without clutter

Every dynamic type should not automatically become a permanent top-level
sidebar entry. New types can appear under a "Project Types" section with usage
counts and a `New` or `Agent-created` marker. Humans can pin the types and views
that matter to their workflow.

## 9. Queries as the Shared Interface

Queries are where dynamic types become practical human/LLM collaboration rather
than schema novelty.

Given a `code_review` type, both interfaces should understand queries such as:

```text
type:code_review is:open
type:code_review state:changes_requested
type:code_review reviewer:me
type:code_review outcome:success
```

The visual query builder should discover fields from the selected types. It
should show universal fields first, fields shared by all selected types next,
and type-specific fields in clearly labelled sections.

If a condition only applies to one of several selected types, the UI should
make the narrowing explicit. It should not silently produce surprising empty
results.

### Saved queries and views

Saved queries should be ordinary shared project records. An LLM can create a
view, a human can edit it visually, and the LLM can later retrieve and use the
same modified query.

A type definition may include suggested views:

- Open reviews.
- Waiting on me.
- Changes requested.
- Approved this release.

These are stored query definitions with provenance, not special UI behavior.
Humans can pin, edit, hide, or delete them.

### Stable references

Saved queries should bind internally to stable type, field, and state IDs rather
than mutable labels. Renaming "Code Review" to "Engineering Review" must not
break a dashboard. Old slugs can remain aliases for human-written query text.

## 10. MCP and LLM Ergonomics

Reusing an existing type must be easier than inventing a new one. Otherwise
dynamic types will turn today's tag entropy into schema entropy.

A likely MCP surface includes:

- `docket_type_list`: compact catalog of available types.
- `docket_type_search`: find types by intended use.
- `docket_type_get`: retrieve a complete definition.
- `docket_type_define`: idempotently define a type by stable slug.
- `docket_type_validate`: dry-run a definition and example transitions.
- `docket_type_activate`: activate a draft when policy permits.
- `docket_type_evolve`: create a new version of a populated type.
- `docket_retype`: preview and apply an item type migration.
- `docket_type_health`: report near-duplicates, unused types, unused states, and
  frequently forced transitions.

The full catalog should not be embedded into every MCP tool description. Agents
should receive a compact catalog and retrieve detailed schemas only when
needed.

Before defining a type, an agent should search for close matches. Docket can
deterministically compare slugs, labels, field sets, and lifecycle shapes and
return possible overlap. Semantic judgment remains with the agent or human.

`docket_create` can accept a stable type reference and a generic fields object,
then validate it at runtime. Errors should teach the caller how to recover:

> `review_target` is required for `code_review`. Optional fields are
> `revision`, `reviewer`, and `scope`. Did you mean `review_finding`?

Type creation should record a concise justification: what existing types were
considered and which required behavior they lacked.

## 11. Portable Agent Runtime

Dynamic types address how projects name and structure records. Agent
interoperability addresses how selected records become usable capabilities,
context, or constraints in a host framework.

The architecture should have four layers:

1. **Project data:** types, skills, policies, knowledge, relationships, and
   audit receipts stored in Docket.
2. **Behavioral profiles:** stable contracts describing what a record can mean
   to an agent host.
3. **MCP runtime surface:** discovery, retrieval, policy evaluation, and
   acknowledgement operations.
4. **Host adapter:** framework-specific loading, event translation, permission
   handling, context injection, and enforcement.

MCP is the portable transport, but connectivity alone is not native
integration. An MCP client can call `docket_skill_get`; that does not
automatically place the result in the client's skill picker or intercept its
next browser action. A host adapter closes that final gap.

A compact runtime surface might include:

- `docket_agent_handshake`: declare host identity and supported capabilities.
- `docket_context_resolve`: retrieve matched skills, policies, knowledge, and
  outstanding obligations for an intent or event.
- `docket_artifact_catalog`: list compatible artifacts without loading their
  bodies.
- `docket_artifact_get`: retrieve a versioned skill or knowledge package.
- `docket_policy_evaluate`: deterministically evaluate an event.
- `docket_obligation_satisfy`: record that a required action was performed.
- `docket_receipt_get`: inspect enforcement evidence.
- `docket_changes_since`: refresh a host cache without reloading everything.
- `docket_monitor_arm`: create or arm a durable condition against a subject or
  saved query.
- `docket_delivery_claim`: atomically claim a fired obligation for an actor.
- `docket_delivery_complete`: record the result of handling an obligation.
- `docket_inbox_next`: retrieve claimable deliveries after a host reconnects.

The complete type and artifact catalog should not be injected into every model
turn. Hosts can advertise concise names and descriptions, then progressively
retrieve bodies when selected.

## 12. Skills as Portable Artifacts

Docket should not invent a new skill body format. Codex, Claude Code, and
OpenCode all consume the Agent Skills `SKILL.md` model, with host-specific
extensions around a portable core. Docket should store or own an
Agent Skills-compatible package:

```text
skill/
├── SKILL.md
├── scripts/
├── references/
└── assets/
```

The Docket record adds database concerns around the package:

- Stable item ID and project scope.
- Lifecycle state.
- Version and content digest.
- Provenance and ratification.
- Tool dependencies and compatibility.
- Quality, usage, and review history.
- Relationships to policies, knowledge, and work.

The package contains the actual reusable instructions and supporting files.
This is more portable than translating a Docket-specific `steps` field into a
different format for every framework.

Current host support provides a practical interoperability base:

- Codex discovers Agent Skills from repository and user locations and through
  plugins, then loads the full instructions progressively when selected.
  [OpenAI skill documentation](https://learn.chatgpt.com/docs/build-skills)
- Claude Code supports the Agent Skills standard with additional invocation,
  tool, path, and hook controls.
  [Claude Code skill documentation](https://code.claude.com/docs/en/skills)
- OpenCode discovers `SKILL.md` packages and provides a native skill tool and
  plugin-level skill sources.
  [OpenCode skill documentation](https://opencode.ai/docs/skills/)

### Integration levels

Docket should support three levels rather than assuming every host has the same
extension mechanism.

1. **MCP-only cooperative mode.** Server instructions tell the agent to call
   `docket_context_resolve`; matching skills are retrieved as ordinary MCP
   data. This is widely portable but depends on agent cooperation.
2. **Materialized Agent Skills.** A bridge synchronizes active Docket skills
   into `.agents/skills`, `.claude/skills`, or another native discovery path.
   The generated directory is a cache carrying Docket ID, version, and digest,
   not a second source of truth.
3. **Native provider plugin.** A host plugin contributes Docket as a live skill
   source, preserving native selectors, implicit matching, permissions, and
   progressive loading without copying files.

Materialization requires explicit conflict behavior. A bridge must never
overwrite a locally edited skill silently. It can refuse, import the local
change as a proposed Docket revision, or materialize under a namespaced ID.

## 13. Policies, Triggers, and Obligations

A skill is a procedure the model may select. A policy is a conditional
obligation that applies whether or not the model remembers to select it.

This distinction is essential. A policy such as "before navigating to
amazon.com, read the Amazon purchasing KB" should not rely only on prompt
matching. Guaranteed enforcement requires a host interception point outside
the model.

The portable flow is:

1. A host is about to perform an operation.
2. Its adapter sends a normalized event to Docket.
3. Docket deterministically matches active policies.
4. Docket returns a decision and any obligations.
5. The adapter enforces them using native host controls.
6. Docket records evidence against the exact policy and resource versions.

For example, an adapter might submit:

```json
{
  "event": "operation.before",
  "operation": "browser.navigate",
  "target": {"url": "https://www.amazon.com/example"},
  "actor": {"host": "codex", "session_id": "abc123"}
}
```

Docket could return:

```json
{
  "decision": "require",
  "obligations": [
    {
      "kind": "read_resource",
      "resource_id": "amazon-purchasing-policy",
      "version": 4,
      "digest": "sha256:..."
    }
  ]
}
```

The adapter retrieves and injects the knowledge, records a receipt, and only
then permits navigation. Docket does not infer that Amazon is relevant; the
policy author declared the matcher.

### Normalized events

A small event vocabulary could begin with:

- `session.start` and `session.end`.
- `prompt.before`.
- `operation.before` and `operation.after`.
- `tool.before` and `tool.after`.
- `file.write.before`.
- `browser.navigate.before`.
- `resource.read`.
- `item.transition.before`.
- `item.transition.after`.
- `item.created` and `item.updated`.
- `relationship.changed`.
- `monitor.fired`.
- `delivery.claimed` and `delivery.completed`.

Events should carry the host and adapter version, project, session and actor,
operation or tool name, structured arguments, target URI or path, and current
host capabilities.

### Portable effects

An initial declarative effect vocabulary could include:

- `inject_context`.
- `require_read`.
- `require_skill`.
- `allow`, `deny`, or `ask_human`.
- `require_acknowledgement`.
- `redact`.
- `log`.
- `create_item`.

Arbitrary shell execution and arbitrary callback code should not be portable
policy effects. They create security and reproducibility problems and belong,
if supported at all, in reviewed host-specific extensions.

## 14. Behavioral Profiles and Dynamic Types

An arbitrary dynamic type cannot become executable merely because its name
contains "skill" or "policy." Hosts need an explicit conformance declaration.

```yaml
slug: site_compliance_policy
implements:
  docket.policy/v1:
    matcher_field: trigger
    effects_field: obligations
    failure_mode_field: failure_mode
    content_field: instructions
```

Likewise:

```yaml
slug: deployment_runbook
implements:
  agent.skill/v1:
    package_field: artifact
```

Types remain an open, project-defined vocabulary. Behavioral profiles remain a
small, stable interoperability vocabulary. A host executes only profiles it
understands and is configured to trust.

Potential profiles include:

- `agent.skill/v1`.
- `agent.knowledge/v1`.
- `docket.policy/v1`.
- `docket.trigger/v1`.
- `docket.monitor/v1`.
- `docket.delivery/v1`.
- `docket.container/v1`.
- `docket.workflow/v1`.
- `docket.review/v1`.
- `docket.finding/v1`.

Profiles may require fields, relationships, lifecycle properties, and host
capabilities, but should not embed arbitrary executable code. Conformance is
validated when a type is activated or evolved.

## 15. Capability Negotiation, Trust, and Receipts

A policy can only be enforced when a host exposes the necessary event and
control point. An adapter should declare a capability set on each stateless
request or through an explicit, refreshable registration such as:

```json
{
  "host": "codex",
  "supports": [
    "skills.agent-skills.v1",
    "event.tool.before",
    "effect.inject_context",
    "effect.ask_human",
    "effect.deny"
  ]
}
```

Docket can then distinguish fully enforceable, advisory-only, and unsupported
policies. Every policy should declare a failure mode:

- `fail_closed`.
- `fail_open_with_warning`.
- `advisory`.

Without capability negotiation, a human may see an active policy and wrongly
believe it is enforced by the current host.

Executable artifacts also require trust metadata separate from their ordinary
lifecycle:

- Agent-created and unratified.
- Human-ratified.
- Organization-managed.
- Revoked.

Adapters can map trust levels to host behavior. For example, an agent-created
skill may require confirmation, while an organization-managed policy is
enforced and fails closed. An agent should not be able to weaken a human or
organization policy by creating a competing type or record.

For must-read and similar obligations, Docket should record a receipt containing
the policy ID and version, resource ID and digest, session and actor, triggering
event, time, enforcement level, and whether content was injected, acknowledged,
or merely made available. A changed policy or resource digest invalidates the
old receipt.

## 16. Host Adapters

The portable contract remains stable while adapters use each framework's native
surfaces.

| Host | Native integration | Docket adapter approach |
|---|---|---|
| Minerva | Docket-aware skill loader, event bus, and policy engine | Directly map Minerva events and native Docket records to the portable contract. |
| Codex | Agent Skills, MCP, plugins, and plugin hooks | Bundle the MCP connection, contribute or materialize skills, and translate exposed lifecycle/tool events into policy evaluations. [OpenAI MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) and [plugin documentation](https://learn.chatgpt.com/docs/plugins) |
| Claude Code | Agent Skills, MCP prompts/resources, and lifecycle hooks | Materialize or provide skills, and call Docket from `UserPromptSubmit`, `PreToolUse`, and related hooks. [Claude Code hooks](https://code.claude.com/docs/en/hooks) and [MCP documentation](https://code.claude.com/docs/en/mcp) |
| OpenCode | Agent Skills plus plugin skill transforms and runtime hooks | Register Docket as a skill source and translate request/tool hooks to portable events. [OpenCode plugin documentation](https://opencode.ai/v2/docs/build/plugins) |
| Generic MCP client | Tools and server instructions only | Use cooperative `docket_context_resolve`; report policies as advisory unless the client exposes enforcement hooks. |

The adapter must report what it cannot observe or enforce. A browser policy is
not guaranteed merely because Docket and a browser tool are both connected. If
the host cannot intercept the navigation before execution, the policy is
advisory or unsupported.

Reference adapters should share event fixtures and conformance tests. Given the
same normalized event and Docket state, every adapter should receive the same
policy decision even though enforcement uses different host APIs.

Adapters also provide liveness. Docket can durably record that a monitor fired
for a Codex author or Claude reviewer, but only an adapter, scheduler, or agent
supervisor can start or resume that host. When native push is unavailable, the
adapter should poll a claimable Docket inbox. The difference is latency, not
semantics: both paths claim the same durable delivery record.

## 17. Governance

Dynamic types should be project-local by default and stored in the project's
canonical `.dct` file. Their definitions and changes then travel with branches,
reviews, and project history.

Projects may select a governance policy:

- `open`: trusted agents and humans may activate new types immediately.
- `reviewed`: agents may create drafts; designated humans activate them.
- `locked`: only designated maintainers may define or evolve types.

Creating a brand-new type with no instances is low risk and reversible.
Changing a populated type is a migration and deserves stronger validation.

The definition should carry provenance:

- Created by whom and when.
- Human or agent origin.
- Reason for creation.
- Similar types considered.
- Source items demonstrating the need.
- Ratification status and ratifier, if applicable.

## 18. Evolution and Migration

An emergent ontology must be able to consolidate itself.

Types need support for:

- Aliases and display-name changes.
- Deprecation and a declared replacement.
- Versioned field and state changes.
- Field mappings.
- State mappings.
- Dry-run migration with affected-item counts.
- Bulk retyping.
- Saved-query compatibility checks.
- Retention of old definitions for history.

Existing items should remain readable against the definition version under
which they were created. Whether each item pins an explicit version or Docket
maintains compatible schema snapshots is an implementation question.

The GUI and MCP should surface type-health signals such as:

- Types with zero or one instance.
- Near-duplicate type definitions.
- States that are never used.
- Fields that are almost never populated.
- Transitions that are commonly forced.
- Generic records whose repeated shape suggests a missing type.

Docket may report these facts without deciding what they mean. An LLM or human
can propose consolidation.

## 19. Container Types and Rollups

Goals, initiatives, plans, and iterations are the strongest examples of
behavior that generic work items cannot express cleanly.

A container type should declare its completion policy, potentially including:

- `manual`: state is independent of descendants.
- `all_required_children_terminal`.
- `all_acceptance_criteria_satisfied`.
- `derived_progress_manual_completion`.
- `iteration_close_with_carryover`.

The UI can show derived progress without silently transitioning the parent.
Closing a time-bounded iteration with incomplete work is legitimate; achieving
a goal with unmet required criteria may not be. Those are different lifecycle
semantics and should live in type definitions rather than title conventions.

Parent/child restrictions should probably begin as warnings rather than hard
walls. Relationships often evolve faster than the original schema predicts.

## 20. Example: Emergent Code Review Types

Code review is a representative dynamic-type use case because it combines a
request, an immutable technical target, an external actor, structured findings,
an outcome, and frequently several rounds of remediation. Treating the whole
exchange as a question or comment thread loses exactly the state that an agent
needs in order to continue autonomously.

An agent observing repeated review questions could propose a `code_review`
type implementing `docket.review/v1`:

```yaml
slug: code_review
label: Code Review
purpose: Review one immutable revision and disposition its findings.
enforcement: strict

implements:
  docket.review/v1:
    target_field: review_target
    revision_field: revision
    reviewer_field: reviewer
    findings_relationship: findings
    verdict_states: [changes_requested, approved, inconclusive, rejected]

states:
  requested:
    category: queued
    transitions: [reviewing, blocked, withdrawn, superseded]
  blocked:
    category: waiting
    transitions: [requested, withdrawn, superseded]
  reviewing:
    category: active
    transitions:
      [changes_requested, approved, inconclusive, rejected, blocked]
  changes_requested:
    category: terminal
    outcome: action_required
  approved:
    category: terminal
    outcome: success
  inconclusive:
    category: terminal
    outcome: failed
  rejected:
    category: terminal
    outcome: rejected
  withdrawn:
    category: terminal
    outcome: cancelled
  superseded:
    category: terminal
    outcome: superseded

required_fields:
  - review_target
  - revision
  - scope

transition_rules:
  changes_requested:
    require_relationships: [blocking_finding]
    require_fields: [findings_summary]
  approved:
    require_fields: [findings_summary]
    require_no_open_relationships: [blocking_finding]

suggested_views:
  - name: Awaiting review
    query: "type:code_review state:requested"
  - name: Changes requested
    query: "type:code_review state:changes_requested"
  - name: Approved reviews
    query: "type:code_review outcome:success"
```

`changes_requested` is terminal for a review round. Remediation changes the
revision, so reusing the same item would erase which code was actually
reviewed. A corrected revision receives a new `code_review` item related to the
previous one as a follow-up. The full exchange is grouped by a `review_cycle`
container implementing `docket.workflow/v1`.

Findings also deserve a distinct type when they must be individually accepted,
addressed, and verified:

```text
reported -> accepted -> addressed -> verified
    |          |            |
    |          +-> waived    +-> accepted  (verification failed)
    |          +-> deferred
    +-> dismissed
```

A blocking or must-fix finding cannot be waived without whatever actor or
evidence the project policy requires. A finding points to the review round that
reported it, the remediation work that addressed it, and the later round that
verified it. This allows an approval guard to ask a deterministic question:
"Are all blocking findings in this review cycle verified or validly
dispositioned?"

"Cold review," "Codex review," and "security review" would initially remain
tags or templates unless they require meaningfully different fields,
permissions, or lifecycles. Author and reviewer are roles; Codex and Claude are
actor bindings. The data model should not encode vendor names into its
semantics.

## 21. A Monitor Type System

A trigger and a monitor are related but not identical. A trigger is a reusable
rule that maps an event or condition to an effect. A monitor is a durable,
bound instance of such a rule: it names the subject, the exact condition, the
recipient, the delivery policy, the event cursor, and the obligation to create
when the condition matches.

This distinction matters for long-running agent work. "Tell the author when
this review is done" must remain true after every MCP connection and agent
process involved in creating it has disappeared.

### Stable profile, dynamic project noun

A project may invent `review_result_watch`, `deployment_guard`, or
`approval_wait` as distinct human-facing types. A host understands them only
when they implement the stable `docket.monitor/v1` profile:

```yaml
slug: review_result_watch
label: Review Result Watch
purpose: Resume an author when a bound review reaches a verdict.
enforcement: strict

implements:
  docket.monitor/v1:
    subject_field: review
    condition_field: condition
    recipient_field: resume_actor
    obligation_field: on_match
    deadline_field: deadline
    cursor_field: event_cursor

fields:
  review:
    type: item_reference
    allowed_types: [code_review]
    required: true
  condition:
    type: declarative_condition
    required: true
  resume_actor:
    type: actor_reference
    required: true
  on_match:
    type: obligation
    required: true
  deadline:
    type: timestamp
  event_cursor:
    type: event_cursor

states:
  draft:
    category: queued
    transitions: [armed, cancelled]
  armed:
    category: waiting
    transitions: [paused, fired, expired, cancelled]
  paused:
    category: waiting
    transitions: [armed, cancelled]
  fired:
    category: waiting
    transitions: [claimed, cancelled]
  claimed:
    category: active
    transitions: [satisfied, failed]
  failed:
    category: waiting
    transitions: [claimed, cancelled]
  satisfied:
    category: terminal
    outcome: success
  expired:
    category: terminal
    outcome: failed
  cancelled:
    category: terminal
    outcome: cancelled
```

`fired` is an immutable fact: the declared condition matched a particular
event. Retrying delivery does not move the monitor back to `armed`. One-shot
monitors are the safe default. A workflow that needs another wait creates a new
monitor bound to the next review round; a recurring monitor is an explicit
advanced mode with a separate firing record for every match.

### Declarative conditions

Monitor conditions must be deterministic and inspectable. An initial condition
language should support:

- Exact subject IDs and relationship traversal.
- Item creation, update, and transition events.
- Stable field and state IDs rather than mutable labels.
- Before/after value predicates.
- Canonical state category and terminal outcome predicates.
- Saved-query membership changes.
- `all`, `any`, and `none` over bounded related records.
- A deadline condition.

The review watch can therefore say:

```yaml
review: CR-17
condition:
  event: item.transition.after
  subject: CR-17
  to_state_in:
    [changes_requested, approved, inconclusive, rejected, withdrawn]
resume_actor:
  role: author
  host_preference: codex
on_match:
  kind: require_skill
  skill: address-code-review-result
  arguments:
    review: CR-17
deadline: 2026-08-12T17:00:00-07:00
```

Docket evaluates the declaration mechanically. It does not decide that a
review seems complete, choose which feedback matters, or repair code.

### Firing, delivery, and claims

Condition matching and agent execution must not be one transaction. When an
armed monitor matches, Docket atomically records:

- The monitor ID and definition version.
- The exact event ID and event cursor that matched.
- A frozen snapshot or digest of the relevant condition inputs.
- The recipient selector and obligation.
- A unique firing and idempotency key.
- One or more pending delivery records.

A host adapter then claims a delivery with a lease and fencing token. The
adapter may wake a native background agent, resume a long-running goal, enqueue
a new agent turn, or simply return the delivery from its next inbox poll. If it
crashes, the lease expires and another compatible worker can reclaim the same
delivery. Completion writes a receipt that names the agent run, consumed input
versions, produced records, result, and any follow-up monitor.

This is at-least-once delivery with idempotent handling, not an unsafe promise
of exactly-once execution. Replaying the same delivery must return the existing
claim or result instead of applying the code fix twice.

### Monitor queries and human use

Humans and agents should share views such as:

```text
type:review_result_watch state:armed recipient:me
implements:docket.monitor/v1 state:fired
implements:docket.monitor/v1 state:failed
parent:EPOCH-42 has:expired_monitor
```

The GUI should show what each monitor is waiting for in plain language, its
deadline, last evaluated cursor, enforceability for the selected host, and the
delivery history. A monitor that no installed adapter can service must be shown
as unsupported rather than merely active.

## 22. End-to-End Scenario: A Review-Gated Epoch

Consider an Epoch of implementation work owned by a Codex author. The Epoch has
more work after the current change, but project policy requires an independent
Claude review before the author may continue. The expected first review finds
must-fix issues and at least one remediation round is required. No human should
have to copy findings between chats, tell Codex that Claude finished, or ask
Claude to review the revised commit.

The durable record graph can look like:

```text
Epoch E-42
├── implementation work W-8
├── review cycle RC-7
│   ├── review CR-17 @ revision abc123
│   │   ├── finding F-1 (must-fix)
│   │   ├── finding F-2 (must-fix)
│   │   └── result watch M-17
│   ├── remediation work R-1 and R-2
│   └── review CR-18 @ revision def456
│       └── result watch M-18
└── remaining Epoch work W-9 ...
```

### 1. Reach the review gate

Codex completes and verifies `W-8`, records revision `abc123`, and creates
review cycle `RC-7`. The Epoch moves from `active` to `waiting_review`; it is
not complete and its remaining work is not abandoned.

### 2. Create the immutable review round

Codex creates `CR-17` with author role bound to Codex, reviewer role bound to
Claude, exact repository and revision, scope, verification evidence, and the
relationship to `RC-7`. Transitioning it to `requested` creates a durable
`perform-code-review` delivery addressed to any trusted adapter capable of
acting as the Claude reviewer.

### 3. Arm the author's result monitor

Codex creates `M-17`, bound specifically to `CR-17`, before yielding. The
monitor watches all terminal review verdicts, not merely success. Its
obligation is `address-code-review-result`, addressed to the Epoch's author.
Creating the review and arming its monitor should be atomic or use a guard that
prevents the review from becoming claimable until the monitor exists.

### 4. Dispatch and perform the review

A Claude adapter claims the review delivery. It loads the exact target,
applicable review skill, project policies, and prior context from Docket. Claude
transitions `CR-17` to `reviewing`, inspects `abc123`, and creates `F-1` and
`F-2` as structured `review_finding` records rather than relying on prose in a
comment.

Claude transitions `CR-17` to terminal `changes_requested`. Docket validates
that blocking findings and a findings summary exist, appends the transition
event, and fires `M-17` against that exact event.

### 5. Resume the author

The Codex adapter either receives a live notification or discovers the pending
delivery through `docket_inbox_next`. It atomically claims the firing and starts
a Codex turn with a compact context package: Epoch, review cycle, review round,
target revision, findings, applicable skill and policy versions, and the
idempotency key. The Epoch moves to `remediating_review`.

### 6. Address findings as tracked work

Codex accepts the must-fix findings, creates or relates remediation items `R-1`
and `R-2`, changes the code, runs the required tests, and moves each finding to
`addressed` with revision and evidence. Dismissal, waiver, or deferral would use
their own guarded transitions and may require a human, but the assumed
must-fix path does not.

### 7. Create a fresh review round

Because the revision changed, Codex creates `CR-18` for `def456`, relates it as
a follow-up to `CR-17`, and identifies `F-1` and `F-2` as findings requiring
verification. It creates `M-18`, completes the `M-17` delivery receipt, and
requests Claude review. The Epoch returns to `waiting_review`.

### 8. Verify remediation and iterate if necessary

Claude claims the second review delivery, verifies the old findings and reviews
the new diff. Verified findings transition to `verified`. If another must-fix
issue appears, `CR-18` ends in `changes_requested`, `M-18` wakes Codex, and the
same process creates `CR-19`. The number of rounds is data, not a hardcoded
workflow branch.

### 9. Satisfy the review gate and continue the Epoch

When a round is approved, its result monitor wakes Codex one final time. Docket
can mechanically verify that the approved revision is the current review-cycle
revision and that every blocking finding is verified or validly dispositioned.
Codex marks `RC-7` approved, completes the monitor delivery, transitions `E-42`
from `waiting_review` back to `active`, and proceeds to `W-9` from Docket's
stored Epoch plan.

The review does not automatically complete the Epoch unless it was the final
acceptance gate. It removes one obligation and restores eligibility for the
next work.

### 10. Recover without a human shuttle

Every boundary is recoverable from Docket:

- If Codex exits after creating `CR-17`, Claude still sees its review delivery.
- If Claude exits after saving findings but before the verdict, another Claude
  worker can resume from the review and claim lease.
- If a notification is lost, Codex later finds the pending durable delivery.
- If a handler runs twice, the idempotency key returns the prior result.
- If a deadline expires, the monitor becomes `expired` and creates a visible
  escalation obligation according to project policy.
- If a newer revision supersedes an unstarted round, its monitor and delivery
  are cancelled with an explicit reason.

No human is the transport. Humans remain decision-makers only where policy
requires judgment, such as waiving a must-fix finding, changing review scope,
or resolving repeated inconclusive reviews.

## 23. Stateless MCP and Durable Agent Coordination

The MCP `2026-07-28` specification makes the protocol stateless by removing the
mandatory `initialize`/`notifications/initialized` handshake and the
`Mcp-Session-Id` transport session. Each request carries its protocol version
and capabilities and should carry client identity; `server/discover` provides
optional up-front discovery. The release also standardizes an extensions
framework and moves asynchronous work into the MCP Tasks extension.

Relevant primary documents are the
[2026-07-28 specification](https://modelcontextprotocol.io/specification/2026-07-28),
its [changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
[SEP-2575](https://modelcontextprotocol.io/seps/2575-stateless-mcp),
[SEP-2567](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/seps/2567-sessionless-mcp.md),
and the [MCP Tasks extension](https://modelcontextprotocol.io/extensions/tasks/overview).

### Why statelessness helps Docket

Docket item IDs already fit the explicit-state-handle pattern recommended by
SEP-2567. A review, finding, Epoch, monitor, delivery, or review cycle can be
retrieved by any compatible client after either side restarts. The author does
not need the MCP connection on which the review was requested, and Claude does
not need to share Codex's hidden session state.

This improves:

- Horizontal deployment: any Docket MCP instance can serve the next request.
- Recovery: adapters can reconnect and continue from explicit record IDs.
- Cross-host handoff: Claude and Codex exchange durable handles rather than a
  transport session.
- Capability clarity: support for Tasks, monitor extensions, or notifications
  is declared per request.
- Routing and authorization: method and tool headers can be handled by ordinary
  HTTP infrastructure.

### Tasks, subscriptions, and monitors are different

The new protocol provides two useful mechanisms, neither of which replaces the
Docket monitor model:

| Mechanism | Purpose | Limitation for the Epoch scenario |
|---|---|---|
| MCP Task | Durable handle for one asynchronous MCP operation, with `working`, `input_required`, `completed`, `failed`, and `cancelled` states | Does not express review verdicts, findings, review rounds, Epoch gates, or recipient delivery semantics |
| `subscriptions/listen` | Opt-in live stream for supported server-to-client notifications, including optional Task notifications | Requires a live stream; disconnected clients need another recovery path |
| Docket monitor | Durable project condition, firing, recipient, obligation, claim, and receipt | Requires an adapter or supervisor to evaluate or deliver it; it cannot wake a host by database semantics alone |

A `request_code_review` tool may return an MCP Task if Docket or an integration
service owns a long-running dispatch operation. The Task can point to `CR-17`,
and a client can poll `tasks/get` after reconnecting. The canonical verdict and
findings still belong to `CR-17` and its related records. A synchronous
`docket_create` call that durably creates those records need not become a Task
merely because the later human or agent work takes time.

Task notifications over `subscriptions/listen` can reduce latency while Codex
is connected. They cannot be the only wake path: the specification removes SSE
resumability and message redelivery, so a broken stream loses in-flight
delivery. Docket must retain the pending firing and delivery until a compatible
adapter claims it. Reconnecting and calling `docket_inbox_next` is the durable
fallback.

### MCP does not create agent-to-agent messaging

Stateless MCP standardizes client-server requests. It does not decide that
Claude should review code, launch Claude, or resume a sleeping Codex process.
Those remain host or orchestration responsibilities. Docket supplies the
portable coordination contract:

```text
Docket record and event
        -> deterministic monitor firing
        -> durable recipient delivery
        -> host adapter claim and wake
        -> agent work and Docket receipt
```

A Docket-specific extension such as `io.docket/monitors` could add typed
monitor notifications to `subscriptions/listen`, but it must remain an
optimization over the same durable inbox. Clients that only support ordinary
tools can poll. Clients that support the extension can receive low-latency
push. Both act on the same firing ID and idempotency key.

### Compatibility and migration

At the time of writing, Docket's MCP handler advertises protocol
`2025-03-26`, implements the legacy initialization handshake, and exposes
synchronous tools only. Adoption therefore requires a real protocol upgrade,
not a documentation change. Docket should:

1. Implement `server/discover` and per-request metadata for `2026-07-28`.
2. Preserve a legacy initialization path while major hosts adopt the new
   revision.
3. Treat Docket record IDs as explicit application-state handles.
4. Add durable event cursors, monitor firings, deliveries, leases, and
   idempotency primitives independently of transport sessions.
5. Add MCP Tasks only for genuinely asynchronous tool operations.
6. Add `subscriptions/listen` and optional monitor notifications as a latency
   optimization.
7. Publish conformance tests showing that polling, reconnecting, and live push
   all produce the same claimed delivery and receipt.

Stateless MCP removes accidental connection state from the design. It makes
the desired architecture easier to implement, but it also makes the remaining
application state explicit. For Docket, that is a benefit: the durable review,
monitor, and Epoch graph becomes visibly and queryably authoritative.

## 24. Risks

### Taxonomy explosion

Agents may create synonyms instead of reusing types.

Mitigations include search-before-create, overlap warnings, creation rationale,
aliases, type-health reports, and easy merge/migration tools.

### Context and tool-schema growth

A large project may have dozens of types.

Mitigations include compact catalogs, on-demand schema retrieval, type search,
and avoiding a full type enum in every MCP tool definition.

### Query breakage

Renamed fields, states, and types may invalidate saved views.

Mitigations include stable internal IDs, aliases, versioned evolution, and
query dry-runs before activation.

### Overly powerful validators

Arbitrary code in type definitions would create security, portability, and
reproducibility problems.

The initial system should use declarative fields, guards, relationships, and
rollup rules only.

### Human surprise

An agent may silently alter the project's vocabulary.

Mitigations include schema-change events, provenance, a visible new-type inbox,
project governance modes, and ratification markers.

### Executable-record trust

A skill or policy stored in a project can contain hostile, stale, or simply
incorrect instructions. Treating every active record as trusted host
configuration would turn Docket into a prompt-injection and policy-escalation
surface.

Mitigations include behavioral-profile validation, separate trust states,
human or organization ratification, version digests, host permission mapping,
and a rule that dynamic definitions cannot introduce arbitrary executable
effects.

### False enforcement claims

A policy can be active in Docket while a particular host cannot observe its
trigger or enforce its effect.

Mitigations include capability handshakes, explicit failure modes, UI status
showing enforceable/advisory/unsupported, and receipts that record the actual
host enforcement level.

### Adapter divergence

Different host adapters may translate similar native events differently,
causing one framework to enforce a policy that another misses.

Mitigations include a small normalized event vocabulary, shared conformance
fixtures, deterministic policy evaluation in Docket, adapter version reporting,
and audit comparison across hosts.

### Materialized-skill drift

A generated `SKILL.md` cache may be edited locally or become stale relative to
its Docket source.

Mitigations include version and digest markers, refusal to overwrite divergent
content, explicit import/reconcile flows, and native provider plugins where a
host supports them.

### Lost wakes and duplicate execution

A live notification can be lost, or two adapters can both observe the same
firing and perform the same write-producing obligation.

Mitigations include durable delivery records, monotonic event cursors, atomic
claims with expiring leases and fencing tokens, at-least-once delivery,
idempotency keys, and receipts checked before re-execution. A notification is
only a hint that durable inbox state may be available.

### Runaway monitor loops

A monitor's handling action may produce another event that matches itself or a
cycle of monitors, creating unbounded agent work.

Mitigations include one-shot monitors by default, cause-chain IDs, maximum
delivery depth, bounded retries, deadlines, declarative effects, loop detection,
and a policy-controlled human escalation state. Dynamic type definitions must
not grant an agent broader execution authority merely by naming itself as a
monitor.

### False precision

A complicated lifecycle can make work harder without improving decisions.

Types should remain small. Docket should report unused states and forced
transitions so humans and LLMs can simplify definitions based on evidence.

## 25. Possible Incremental Path

This idea can be explored without immediately replacing the existing schema.

1. Represent type definitions as data and load the current built-ins through
   the new registry.
2. Remove hardcoded MCP type enumerations in favor of registry discovery.
3. Add canonical state categories and terminal outcomes to existing types.
4. Make forms, transition controls, and query facets consume the registry.
5. Permit project-local draft types and render them in a schema inspector.
6. Add activation policy and MCP type-definition tools.
7. Define the first behavioral profiles for skills, knowledge, policies,
   reviews, findings, workflows, monitors, and deliveries.
8. Store and serve a versioned Agent Skills-compatible package from Docket.
9. Upgrade the MCP server to `2026-07-28` stateless requests and
   `server/discover` while retaining legacy negotiation during adoption.
10. Add per-request capability declaration, context resolution, and artifact
    retrieval over MCP.
11. Add a monotonic event stream and `docket_changes_since` before adding live
    notification optimizations.
12. Add normalized policy events, declarative effects, capability negotiation,
    and receipts.
13. Add monitor firing, durable deliveries, atomic claims, leases,
    idempotency, deadlines, and actor inbox queries.
14. Implement an MCP-only polling adapter and one native wake-capable reference
    adapter.
15. Add MCP Tasks for genuinely asynchronous integration calls and
    `subscriptions/listen` as an optional low-latency path.
16. Add the `code_review`, `review_finding`, and `review_cycle` example types
    and exercise them through a multi-round review-gated Epoch.
17. Add safe retyping and versioned evolution.
18. Add container rollups and type-health reporting after real usage reveals
    which mechanisms are necessary.

The first milestone should prove that one dynamically defined type can be
created over MCP, inspected and ratified in the GUI, used in generated forms and
queries, transitioned under its own rules, and serialized entirely in the
project's `.dct` file.

A second interoperability milestone should prove that a Docket-owned skill is
discovered natively by two different host frameworks, and that both adapters
produce the same policy decision and auditable receipt for a shared normalized
event.

A third coordination milestone should start an Epoch in one host, dispatch a
review to another host, survive both hosts disconnecting, deliver must-fix
findings back to the author, complete at least one remediation and re-review
round, and resume the Epoch without a human copying an ID or message. Polling
and live subscription paths must produce the same record graph and receipts.

## 26. Open Questions

- Which types are truly required at project birth?
- Are system-supplied starter types editable, forkable, or only replaceable?
- Is a type definition itself a Docket item, a separate JSONL record kind, or
  both?
- Can a provisional type have instances before activation?
- Should canonical terminal outcomes be fixed globally or extensible?
- How are custom fields represented efficiently in the SQLite query cache?
- Do type versions belong on each item, or can compatibility be maintained at
  the registry level?
- How should schema changes merge when two git branches evolve the same type?
- What transition guards are useful while remaining safely declarative?
- Which rollup behaviors belong in Docket, and which should remain saved
  queries or external policy?
- How should `$current_user` and agent identity work in portable saved views?
- Should relationships be dynamically definable alongside types?
- How does a human distinguish an active but unratified type from a trusted
  project convention?
- When should Docket warn about a likely new type rather than simply reporting
  repeated record shapes for an external LLM to interpret?
- Which behavioral profiles belong in Docket's stable interoperability kernel?
- Should skills be stored as attachments owned by an item, as a dedicated
  package record, or through content-addressed resources?
- Which parts of Agent Skills metadata are portable, and where should
  host-specific overlays live?
- What normalized event vocabulary is broad enough for multiple frameworks
  without becoming an imitation of every host API?
- How should policy conflicts and precedence be resolved across project, user,
  organization, and host scopes?
- Which effects must always require human ratification?
- What does fail-closed mean when the Docket server itself is unavailable?
- Are policy evaluation and receipts part of the core database, a bundled
  reference service, or an optional plugin?
- How should a host expose that a policy is advisory or unsupported without
  overwhelming the human?
- Can materialized skill caches be made portable across Codex, Claude Code, and
  OpenCode without losing host-specific features?
- How are actors and resumable work targets identified consistently without
  relying on an MCP transport session?
- Is monitor evaluation part of the core Docket process, a bundled stateless
  worker, or an optional service operating on the same event log?
- Which condition operators are powerful enough for useful monitors without
  becoming an embedded programming language?
- Should monitor firings and delivery attempts be items, separate JSONL record
  kinds, or append-only events projected into the query cache?
- How does a delivery name a portable role such as `author` while still routing
  to a concrete Codex, Claude, or OpenCode environment?
- Which host capabilities are sufficient to claim a delivery, and how should a
  project express fallback actors?
- What are the retention and compaction rules for event cursors, firings,
  leases, and receipts?
- When should a failed or expired monitor escalate to a human rather than
  another agent?

## 27. Summary

Dynamic types fit Docket's role as shared infrastructure for humans and LLMs.
They allow a project's language to emerge from its work while keeping that
language durable, queryable, reviewable, and visible in the GUI.

The strongest version of the idea is not "agents may invent arbitrary status
lists." It is a coherent type system with:

- A small strict bootstrap vocabulary.
- Project-local first-class definitions.
- Canonical cross-type state semantics.
- Declarative lifecycle guards.
- Deterministic generated UI.
- Shared saved queries.
- Search-before-create MCP ergonomics.
- Stable behavioral profiles for executable semantics.
- Agent Skills-compatible skill packages.
- Deterministic policy evaluation over normalized events.
- First-class review rounds, findings, and review-cycle relationships.
- Durable declarative monitors with firings, claims, leases, and receipts.
- Stateless MCP handles, optional Tasks, and live notifications that optimize
  rather than replace durable inbox state.
- Capability negotiation, trust, and audit receipts.
- Thin host adapters that use native skill and hook surfaces.
- Visible governance and provenance.
- Versioning, migration, and consolidation.

Docket remains unintelligent by design. Its power comes from making the
structure proposed by humans and LLMs equally legible and operable to both.
Dynamic types let projects extend their language; behavioral profiles let
selected records cross framework boundaries without asking Docket to become an
agent framework itself.
