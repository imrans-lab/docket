# Dynamic item types

Docket 2.0 stores type meaning inside each project. Items pin a stable type ID and immutable revision, so later presentation or schema changes do not reinterpret history. Identical slugs in different projects are unrelated identities.

## Manage types

Open **Project Types** for the intended project. Search covers labels, slugs, descriptions, aliases, and usage guidance while preserving alphabetical order. Active zero-item types remain visible; enable the historical option to inspect deprecated definitions.

A new definition begins as a draft. Edit its presentation, complete typed field descriptors, lifecycle states, categories, outcomes, edges, guards, and enforcement, then validate the whole snapshot. Activation and deprecation require an explicit reason and expected current revision. Recorded author and ratification metadata support review; they are not authenticated identity. Draft or deprecated types cannot create ordinary items.

Evolution publishes another complete immutable revision. Compatible changes may adjust presentation, add optional fields, and add states and edges without changing the graph or meaning induced by old states. Preview reports saved-query impact and validates selected items. Existing items retain old pins unless explicitly selected for repinning. Defaults apply only on creation or selected repin and never replace stored false, zero, null, or empty values. The revision browser exposes parent, author, time, reason, provenance, and the full snapshot. Protected starter definitions and behavior cannot be overridden.

## MCP and items

Use `docket_type_list`, `docket_type_get`, `docket_type_validate`, `docket_type_define`, `docket_type_activate` (also explicit deprecation), and `docket_type_evolve`. A complete strict example is [`code_review_definition.json`](../test/fixtures/code_review_definition.json). Validate it, define the draft, inspect the returned revision, then activate it. Its `revision`, `reviewer`, and `findings_summary` fields and approval guard require no per-type application rebuild.

Custom values use `fields`; `unset_fields` removes a value, while JSON null remains explicitly stored. Updates and transitions accept `expected_revision` for the pinned type revision and `expected_item_token` for full backend item content. Unknown `extras` remain visible and preserved but read-only through typed operations.

Typed queries bind `field_key` with `type_id`. Status and derived `state_category`, `state_outcome`, and `is_terminal` use pinned meaning. Saved queries and `.dcq` retain IDs, keys, states, columns, sort direction, and null ordering. A missing identity requires an explicit destination binding; labels and equal slugs never substitute automatically.

## Upgrade safely

New files use 2.0 and `.v2.cache`; existing JSONL files remain 1.0 with `.cache`. SQLite projects must first be explicitly promoted with `docket --migrate-jsonl --file path/to/project.dct`. Promotion and the later JSONL 1.0-to-2.0 type upgrade are separate operations.

Use Project Types to preview before applying a JSONL upgrade. Preview reports starter definitions, item/status bindings, unresolved data, cache changes, and backup path. Apply requires acknowledgement that incompatible writers are stopped. Minerva's independent writer is incompatible and must be excluded from upgraded files. Verified older Docket readers refuse 2.0 through cold and warm cache paths.

Upgrade keeps a recovery snapshot and invalidates the old cache. Rollback refuses if the upgraded source has since changed, so it cannot silently erase later edits. Stop other writers and resolve Git conflicts explicitly before retrying from a fresh preview. The local lock is advisory; Docket does not promise cross-process transactions or compare-and-swap. Opening a file never upgrades it, and shared live files must not be upgraded automatically.

## Acceptance walkthrough

Run the post-review [GUI and HTTP MCP acceptance walkthrough](dynamic-item-types-acceptance.md) against disposable projects.
