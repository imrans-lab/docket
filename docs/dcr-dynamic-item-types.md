# DCR: Project-local dynamic item types across storage, MCP, and GUI

Status: Complete on the local `feature/dynamic-item-types` branch — approved and accepted on 2026-09-12 (America/Los_Angeles). No release published.

Docket item: `01a096e77f2f778781b03d0aeb8384e3` (project `docket`).

Prepared: 2026-09-12. Code reviewed: `ed48d8e98e5f9fe5510dfc746572bf78b004bcef`.

Source discussion: Docket `01a03b7cd4547406b1c3c873ec5a8534`, “State sprawl:
usage data, type-scoped status filtering, and canonical state categories,”
including comment 22. Source paper:
[Dynamic Types and Agent Interoperability in Docket](thought-papers/dynamic-types.md).

## Problem and intended behavior

A project cannot introduce a work concept with its own fields and lifecycle
without changing Docket's code. Definitions partly live in `data/schema.json`,
but persistence, MCP inputs, and GUI controls still enumerate fields. Merely
extending the schema would produce items whose custom values disappear or
cannot be edited and queried. Status discovery also mixes states from unrelated
types.

After this change, a human or agent can define `code_review` in one project,
give it fields such as `revision`, `reviewer`, and `findings_summary`, and a
lifecycle such as `requested → reviewing → approved / changes_requested`.
Docket validates the definition, exposes it through discovery, and generates
the item form, transition controls, and query fields. The definition and its
items travel together in the project's `.dct`. No application rebuild or
per-type SQLite migration is needed.

This DCR delivers the paper's first end-to-end type-system milestone. Its
later runtime and coordination proposals remain separate follow-up work.

## Requirements inherited from the discussion

1. Types are first-class, enumerable records with their own cache tables; they
   are not an opaque project metadata blob.
2. Adding a type or field never requires another cache table or column. Import,
   export, reload, and ordinary updates preserve values they do not understand.
3. Definitions use deterministic JSONL records and ordinary Git merges.
   Conflicting definitions require an explicit resolution; timestamp ordering
   must not silently pick their meaning.
4. Both interfaces can discover the states of a particular type and construct
   queries scoped to that type. Cross-type activity queries have separate,
   explicit semantics.

## Findings in the current code

| Boundary | Current implementation | Required change |
| --- | --- | --- |
| Project context | `app_state.gd:452` loads one schema; `tool_registry.gd:121` selects a database but passes the global schema | Resolve a registry for the selected project and item revision |
| Validation | `data_model.gd:6` copies named fields; `state_machine.gd:34` implements advisory flow and field guards | Shared typed validation, complete candidate validation before writes, per-definition enforcement |
| Canonical storage | `jsonl_parser.gd:223`, `docket_db.gd:302`, and `jsonl_serializer.gd:383` enumerate item fields | Lossless generic field envelope through every layer |
| Cache | `docket_db_schema.gd:11` creates a wide items table; later fields require ALTER TABLE | Fixed registry tables and a JSON field column; retain legacy columns during rollout |
| Queries | `docket_db.gd:730` validates against SQL columns; sorting has another fixed list; `docket_db_filter.gd` uses static allowed-field state | Project-scoped field resolution for filters and sorts, retaining SQL validation |
| Discovery | `docket_get_state_machine.gd:35` already returns initial state, but omits terminal states, guards, and enforcement | Complete project-aware discovery; correct the discussion's older initial-state gap |
| MCP | `docket_create.gd:15` fixes the type enum; create/update enumerate fields; transition accepts only two extra fields | Generic fields input and on-demand type discovery |
| GUI | `record_form.gd:886` has a fixed widget map; schema controls visibility; `query_grid.gd:24` fixes query fields and unions all statuses | Generate controls and facets from descriptors; invalidate on registry changes |
| Alternate writes | `record_form.gd:1319` changes type directly; move/import and mirror have independent paths | Shared validation and definition-aware transfer; no direct retyping bypass |
| Format handling | Serializer always emits `1.0.0`; parser rejects unknown record kinds, but the inspected path has no effective higher-version guard | Explicit format compatibility checks and a tested upgrade boundary |

The secrets pipeline already preserves unknown fields using `extra_json` in
`jsonl_cache.gd`. It supplies a useful local precedent for lossless storage.

## Proposed design decisions

### 1. One registry per project

Introduce a `TypeRegistry` owned by each open project/database. Both MCP and
GUI use it for definitions, field descriptors, lifecycle rules, and presentation
metadata. A reload rebuilds the registry before publishing refreshed items and
invalidates form and query caches. Project switching must never reuse another
project's definitions or field allowlist.

Give each type a stable ID and immutable project-local slug. Field keys and
state keys are immutable within that type and serve as their stable identities;
labels may change. Identical slugs in different projects do not establish type
equivalence. Reserve universal item keys and internal metadata names.

Normalize the existing built-ins through the same registry. Keep today's
vocabulary, transitions, and creation restrictions. Built-in definitions are
protected starter definitions in this release; project types use the same
validation and rendering machinery. Reducing the bootstrap vocabulary or
allowing built-in overrides needs a separate migration decision.

### 2. Definitions and revisions are JSONL records

Use two fixed record kinds and corresponding cache tables:

- `type_def`: stable identity, slug, lifecycle (`draft`, `active`, `deprecated`),
  current revision pointer, and provenance/ratification metadata.
- `type_def_version`: immutable revision ID, type ID, parent revision ID,
  complete declarative definition, author, timestamp, and reason.

Store each complete definition in one revision line. Do not split every field
and state into separate records in v1. New items pin `type_id` and
`type_revision`; keep the existing `type` slug and `status` keys for familiar
API output. Load definitions before resolving items, regardless of input line
order. Reject duplicate IDs, ambiguous slugs, inconsistent revision references,
and invalid activation pointers.

Different type additions can be combined by ordinary Git merging, subject to
normal adjacent-line conflicts. Concurrent revisions retain both snapshots.
Competing changes to the same current pointer require manual conflict resolution
and validation. Never select a winner by timestamp or largest version number.
Runtime activation supplies an expected current revision and refuses a stale
proposal. This detects stale proposals within the supported writer model; it
does not create a cross-process compare-and-swap guarantee.

New files seed the current starter definitions. Existing files receive a
previewed format upgrade that snapshots the starter definitions and binds
legacy items without changing their IDs or statuses. Until upgraded, they use
a compatibility registry and keep their existing format. Legacy SQLite files
must be explicitly promoted to JSONL before activating custom types.

Use a format-specific cache path for upgraded files and invalidate the old
cache during upgrade. Otherwise an older executable can reuse a newer cache
without encountering the unknown JSONL records that would make it refuse the
file. Upgrade assumes other writers are stopped; already-running older writers
cannot be made compatible by changing a format number.

### 3. Lossless fields with a fixed cache schema

Keep universal values in columns and store custom values in an item `fields`
object, backed by one JSON column. Retain existing built-in columns and flat
API fields initially through a fixed compatibility mapping. A field must have
one authoritative storage location; reject ambiguous flat/nested inputs rather
than choosing one silently. An additional opaque extras envelope preserves
unknown legacy top-level values.

The parser, CRUD decoder/encoder, serializer, full export/import, mirror, and
update paths must preserve the entire payload. An unrelated title edit cannot
remove unknown values. Preserve `false`, `0`, empty strings, empty containers,
and explicit `null`; do not apply today's blanket empty-value omission to
custom data. Define unset separately from setting a value to null.

Start with string, Markdown, integer, number, boolean, enum, date/timestamp,
item reference, and reference-list descriptors. Preserve unknown JSON values
even when no current descriptor supports editing them. Support required,
nullable, default, enum, and simple numeric/length constraints. Creation,
update, and transition validate the resulting candidate item before mutation.
Required values cannot be removed through an update or an empty transition
payload. Defaults apply on creation or explicit upgrade, never silently on read.

Resolve query fields to bound JSON extraction expressions using validated
registry identities; bind values and JSON paths where supported. Verify JSON
function support in the shipped Godot SQLite extension as an early gate. No
generated columns, per-field tables, or per-field indexes are required for
correctness. Additional indexes can follow measured query costs. Avoid the
discussion's generated-column suggestion as a prerequisite: it would reintroduce
DDL on field growth.

### 4. Explicit lifecycle semantics

Each definition declares an initial state, ordered states, terminal states,
transition edges, required-field guards, and `strict`, `guided`, or `open`
enforcement. New custom types default to strict. Existing types retain guided
behavior and the off-flow note requirement. Notes never bypass strict edges or
required-field validation.

Each state declares `state_category` (`queued`, `active`, `waiting`, `terminal`)
and terminal states declare `state_outcome`. Use the latter name because
`outcome` already means skill completion guidance. Terminal outcomes start with
success, action_required, cancelled, rejected, duplicate, superseded, obsolete,
failed, and unspecified. These are lifecycle outcomes, not task instructions.

Assign categories per type, not from the spelling of a status. Publish and
review the built-in mapping as part of implementation. Preserve historical
terminal meaning conservatively: use unspecified where existing data does not
prove success or cancellation. Invalid historical statuses remain visible with
diagnostics and unknown derived semantics; import must not silently repair them.
An explicit validated repair is required before further lifecycle operations.

The first guard vocabulary is required fields and scalar constraints.
Relationship guards, actor authorization, rollups, and executable effects are
follow-up work. A custom state named `blocked` must not automatically acquire
the built-in work item's side effects; preserve those through protected built-in
behavior metadata until a generic relationship mechanism is designed.

### 5. MCP and GUI use the same operations

Add compact `docket_type_list` (including text search), `docket_type_get`,
`docket_type_validate`, `docket_type_define`, `docket_type_activate`, and
`docket_type_evolve` operations. Definition creation is idempotent for the same
slug and content and reports conflicts for different content. Return likely
existing matches using deterministic name/field comparisons, and record why a
new type is needed. Keep the catalog out of every tool description.

Create accepts a type reference and `fields`; update and transition accept
typed field patches, including explicit unsets. Existing flat built-in calls
continue working. Type discovery returns revisions, fields, initial/terminal
states, edges, guards, categories, and enforcement. Errors identify the offending
field/state, expected value shape, and relevant definition revision.

Provide a Project Types screen with discovery, definition editing, validation
preview, activation, provenance, and deprecation. Draft definitions can be
previewed but cannot create ordinary items. Activation is explicit from either
GUI or MCP in the current local trust model. Ratification records review; it is
not proof of authenticated human identity. Enforced human-only or organization
governance requires a later identity/permissions design.

Generate field widgets, validation help, transition actions, and selectable
result columns from descriptors. Keep comments, attachments, hierarchy, and
vault facilities as existing shared services. A project/registry change refreshes
the controls without discarding unsaved edits; a stale form receives a revision
conflict to review. The GUI must surface validation errors before any save.

### 6. Queries stay usable within and across types

Replace the query builder's expanding type dropdown with a searchable catalog
whose main list is always alphabetical by human-readable type label. Use
case-insensitive ordering with deterministic project/slug/ID tie-breakers.
Typing filters the list while preserving that alphabetical order; do not
reorder matches by relevance, popularity, or recency. Clearing the search
restores the full alphabetically sorted list for the selected scope.

Search matches names, slugs, aliases, descriptions, and "use when" guidance
where available, using deterministic matching. Each result shows its label,
brief purpose, and item count so similarly named types are distinguishable.
Scope to the selected project(s), and show project labels when multiple
projects are included. Include active types with zero items; expose deprecated
types through an explicit option for historical queries.

Pinned and recently used types are separate shortcuts, not exceptions inserted
into the main list's sort order. Store those preferences per user/project.
Allow keyboard navigation and multi-selection without repeatedly reopening the
chooser. Selections persist when search text changes; show selected types
separately so filtering cannot hide what the query already includes. The
search box filters the catalog, not the item query itself. Use a bounded,
scrollable list and an explicit no-matches state. Optional type collections
are deferred until usage establishes useful groupings.

When a condition's type scope is known, offer only those types' fields and
states. For example, `type = discussion AND status =` offers only `active` and
`resolved`. With several selected types, group statuses by type. When a type
selection changes, retain a still-valid status; otherwise mark the existing
condition as needing correction without silently replacing or removing it.
Without a type selection, group states by project/type; choosing a
grouped state creates the matching type-and-status predicate. Derive colors
from state metadata. Preserve the existing structured query formats; introducing
the paper's textual query language is unnecessary for this DCR.

Add `state_category`, `state_outcome`, and `is_terminal` query fields. Evaluate
them against the item's pinned definition, including in cross-project views.
Stable type IDs and immutable field/state keys back newly saved queries;
`.dcq` portability requires explicit binding when a destination lacks those IDs.
Do not silently bind two unrelated types merely because their labels match.

Legacy raw status filters retain their literal meaning. Add query validation
that reports impossible type/state combinations and ambiguous custom fields
before saving or running newly authored typed queries. Analyze each boolean
branch independently: a type constraint in one OR branch does not scope its
sibling. Missing custom values, explicit nulls, incompatible field kinds,
operator support, and null ordering must have documented, tested semantics.
Never silently drop an unsupported condition or widen a query.

### 7. Bounded evolution and transfer

Revision publication does not silently reinterpret existing items. V1 evolution
supports labels/help text and additive optional fields or new states, provided
existing field kinds, defaults, state categories, edges, and guards retain their
meaning. A previewed, explicitly applied same-type revision upgrade validates
selected items and saved queries before moving their pins. Incompatible changes
are refused with an impact report; general field/state remapping and bulk
retyping are deferred.

Remove the GUI's direct type assignment path for registry-backed items. Move
requires the destination to contain the exact referenced type revision, or an
explicit definition import first; a same-slug different-ID definition is a
conflict. Validate target persistence before deleting the source. Mirror
validates fields and transitions against the target's registry. Existing vault
restrictions continue to apply.

## Delivery sequence

1. **Query-builder usability:** deliver the searchable, alphabetically sorted
   type chooser, separate pins/recents, and type-scoped status choices against
   today's schema. Use available descriptions and derive the status mapping
   from the schema. This milestone can ship before dynamic types and requires
   no `.dct` format upgrade. Subsequent registry work supplies additional
   metadata and project-local definitions through the same chooser interface.
2. **Storage contract:** specify the new JSONL version and record shapes;
   implement lossless field envelopes, registry tables, deterministic recursive
   serialization, version checks, cache-generation invalidation, and read-only
   diagnostics for unresolved definitions. Test reconstruction before exposing
   type creation.
3. **Registry and validation:** normalize built-ins; resolve project/revision
   context; implement definition validation, typed item patches, lifecycle
   semantics, and revision publication/upgrade. Stage compound writes so
   definition snapshots, pointers, items, and audit evidence reach canonical
   storage together, with errors propagated to callers.
4. **MCP:** add discovery/definition operations and generic fields; route
   existing tools through shared operations, including mirror and move.
5. **Queries:** implement registry-based filter/sort resolution and validation,
   derived state fields, saved-query identities, and cross-project behavior.
6. **GUI:** implement Project Types, generated forms, connect the query chooser
   to project registries, and implement state presentation and reload/stale-form
   handling.
7. **Compatibility and release proof:** exercise upgrade, Git merges, older
   readers, full regression tests, and the acceptance scenario below. Document
   the format boundary and supported writer versions, including Minerva's
   independent Docket implementation before enabling shared-file upgrades.

These are implementation slices of one DCR; the feature is complete only when
the end-to-end behavior works.

## Acceptance criteria

- With a catalog fixture containing hundreds of types, the query type chooser
  displays labels alphabetically before and after search. Verify mixed case,
  duplicate labels across projects, metadata matches, zero matches, and clearing
  search. Pinning or recent use never changes the main list's alphabetical
  order. Keyboard and multi-select interactions retain selected types across
  searches; active zero-item types and historical deprecated types are findable.
- Build `type = discussion AND status =` and verify that only `active` and
  `resolved` are offered. Verify multi-type grouping, type changes that preserve
  or invalidate an existing status, and independent OR branches. Demonstrate
  the initial chooser/scoping milestone on an existing `.dct` without upgrading
  its format, then repeat with project-local dynamic definitions.
- Define a previously unknown `code_review` over MCP with revision/reviewer
  fields, a required findings summary at verdict, and strict review states.
  Inspect and activate it in the GUI, create/edit an item there, query it through
  both interfaces, and complete a valid transition. No type-specific code or
  cache migration is added for this fixture.
- Missing summary, invalid field kinds, clearing required fields, and forbidden
  transitions fail consistently without partial writes. A note cannot bypass
  strict rules. Existing guided built-in transitions remain compatible.
- Add an optional field to a populated type, preview and apply a compatible
  revision upgrade, and use the field. Retained revisions remain readable;
  changing existing semantics is refused in v1.
- Serialize, delete/rebuild the cache, reopen, and compare all definitions,
  values, references, comments, and events. Cover false/zero/null/empty values,
  Unicode, literal escape sequences, arrays/objects, and unknown future fields.
  Repeated serialization is byte-identical after normalization.
- Combine two branch additions; create competing revisions of one type; resolve
  the current pointer deliberately. Validate duplicates, missing revisions,
  conflict markers, and same-slug collisions. No flush erases unresolved data.
- Open two projects defining the same slug differently. CRUD, mirror, move,
  GUI switching, OR queries, custom sorting, and category queries use the right
  definitions. Reload after a Git change refreshes both interfaces.
- Existing built-in fixtures and flat MCP requests work; legacy invalid states
  are reported without being rewritten. New terminal semantics do not overwrite
  the skill `outcome` field.
- Unsupported format versions fail before cache mutation or canonical writes,
  including the warm-cache path. Test actual old-reader refusal with the new
  records; a version bump alone cannot fix readers that ignore version metadata.
- Inject persistence failures during compound operations. Callers receive an
  error, the canonical file remains valid, and the next load reconstructs its
  committed state. Schema activation and moves must not claim success after
  failed target writes.
- Extend the existing data model, state machine, query-field validation, JSONL
  roundtrip/freshness/malformed-refusal, MCP, and functional suites; run
  `./run_tests.sh`. Include a GUI walkthrough for definition creation and use.

## Implementation plan and agent assignments

The [execution plan](plan-dynamic-item-types.md) is stored in Docket as
`01a096fa277f7683bc6d1fd8a18e3053`, a child of this DCR. It contains twelve
implementation tasks, five batch review gates, five post-review verification
gates, and explicit dependency links.

The main Codex thread coordinates. `gpt-5.6-sol` implements every planned task
and authors relevant tests. `gpt-5.6-terra` independently reviews the combined
changes in five batches: query UX; storage; registry/validation; MCP/queries;
and GUI/integration. No implementation task is assigned to Terra.

Implementers write tests without running them. Terra reviews code quality and
correctness, comment salience, and test quality. Source/test comments explain
mechanics, invariants, constraints and technical rationale; conversation,
owner-decision narration and task history belong in Docket/design records.
After findings are fixed and Terra clears the exact snapshot, the coordinator
runs relevant checks. Fixes arising from test failures receive delta review
before reruns. The final verification gate runs the full suite.

The user approved the DCR tree and agent plan on 2026-09-12 and authorized
autonomous implementation through completion. Decisions follow this priority
order: durability, reliability, salience, discoverability, debuggability, cost.
The coordinator records material tradeoffs and review/verification evidence in
Docket; test execution follows review clearance.

## Scope limits and risks

This release does not add agent-host adapters, policy enforcement, monitor
delivery/leases, protocol upgrades, automatic type inference, relationship
schemas, rollups, boards, arbitrary validators, built-in pruning, or general
breaking migrations. Those can use the registry once it is dependable. Protocol
and host claims in the thought paper are not dependencies of this proposal.

The principal risks are lossy compatibility paths, inconsistent project/revision
resolution, query cost for JSON fields, and older writers overwriting a newer
format. Gate the release on the corresponding acceptance tests. The current
whole-file writer and best-effort lock do not guarantee concurrent multi-process
transactions; this DCR does not promise that. Use the existing supported writer
model and Git for branch reconciliation, with explicit errors for stale schema
proposals and failed canonical writes.

## Review basis

The design began with the full discussion, thought paper and baseline source
audit. Implementation is complete through reviewed snapshot `38062eb`, with
788/788 tests passing and actual GUI/HTTP acceptance on disposable files.
See the [implementation and verification record](implementation-dynamic-item-types.md)
for batch reviews, corrections, compatibility evidence and remaining operational
limits. Existing live files were not upgraded; Minerva compatibility remains a
prerequisite for upgrading files shared with its independent writer.
