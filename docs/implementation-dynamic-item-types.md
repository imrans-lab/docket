# Dynamic item types: implementation and verification record

DCR: `01a096e77f2f778781b03d0aeb8384e3` in the `docket` project.
Plan: `01a096fa277f7683bc6d1fd8a18e3053`.
Branch: `feature/dynamic-item-types`.
Approved plan baseline: `a5f3c740bc2143f9f29ee878a482c68ad17ae1b2`.
Application baseline: `ed48d8e98e5f9fe5510dfc746572bf78b004bcef`.

The user approved autonomous execution on 2026-09-12. Decisions prioritize
durability, reliability, salience, discoverability, debuggability, then cost.
Sol implements and authors tests; Terra reviews code, comments and test quality;
the coordinator runs checks after review clearance. Source changes arising
from failed checks receive delta review before reruns.

## Compatibility evidence

Read-only inspection of Minerva's independent Docket implementation found that
`src/Scripts/Services/Docket/Core/jsonl_parser.gd` skips unknown record kinds,
while its serializer writes format `1.0.0`. It cannot safely share upgraded
files. Existing files must remain compatible by default, and shared-file
upgrades must be withheld for incompatible writers. No Minerva source or live
Docket file is upgraded as part of this implementation run.

The standalone Docket baseline instead refuses unknown record kinds. A detached
checkout of that exact baseline is prepared for post-review compatibility
checks. No legacy-reader check has run yet.

## Batch evidence

| Batch | Implementation | Review | Verification |
| --- | --- | --- | --- |
| A: Query UX | `1fd1046` | Terra cleared | 61 targeted tests pass; GUI accepted |
| B: Storage | In progress | Pending | Not run |
| C: Registry and validation | Pending | Pending | Not run |
| D: MCP and queries | Pending | Pending | Not run |
| E: GUI and integration | Pending | Pending | Not run |

Specific revisions, findings and command results are recorded here and in the
corresponding Docket review/verification tasks as each gate is completed.

### A: first review

Terra reviewed `4c2b89dd114368af733a034530dac9830b8895d4` against the approved
plan baseline. Five blockers were recorded as children of the A-R Docket task:
unsupported project operators broaden results; selected type identity loses
project scope; pins/recents are informational rather than actionable; selected
labels expose slugs; and integration coverage is insufficient. Sol is revising
the batch and authoring the missing behavioral tests. Comments were found to be
technical and salient. No runtime verification has run.

The next review, at `00086e3`, found the original issues substantially
addressed and identified two further blockers: grouped status selections could
lose their project/type identity on saved-query reload, and shortcuts needed
consistent limits across loading and actions. The corrected snapshot
`cd185e5` is with Terra for delta review. Review findings are recorded as
children of A-R. All application/runtime checks remain unexecuted.

### A: post-review verification

Terra cleared `cd185e5`, then reviewed explicit GDScript type corrections
`1d50bb4` and `f0962ad` after compilation failures. The initial PATH engine
was 4.6.2 while the installed extension requires 4.7. A local Godot 4.7.1,
matching CI, is used for verification. Its application import is clean.

At `f0962ad`, isolated targeted suites pass: catalog/query UX 26, preferences
13, query field validation 11, functional cross-project 3 (53 total). Logs
are under `/tmp/docket-dynamic-verification/logs/`. Expected invalid-query
diagnostics occur in negative tests; no script exceptions occur.

The GUI walkthrough on a disposable format-1.0 file found issues not exercised
by the helper-based checks: stale chooser counts/catalog after actual file
load, popup positioning/background and mouse opening, fused purpose text, and
keyboard movement from search. These are assigned to Sol for corrections and
event/load regression coverage before another review/verification pass. The
batch is not accepted yet. No live data files have been upgraded.

### A: accepted

Final reviewed source: `1fd104647ce42462afc52f08aae596fcbbc6e95b`.
All 61 targeted checks pass: catalog/query UX 32, preferences 13, query-field
validation 11, functional cross-project 3, and async-runner regressions 2.
The runner now directly awaits Godot 4 coroutine hooks and test methods;
the nested intentional-failure fixture verifies failure accounting.

The GUI walkthrough confirms alphabetical readable rows, correct item counts,
mouse opening, keyboard selection, multi-selection retained across searches,
and Discussion-only `active` / `resolved` choices. The final row-lifecycle
regression also verifies immediate scope refresh and correct callbacks after
middle-row removal. A disposable legacy file remained format `1.0.0`.

Evidence: `/tmp/docket-dynamic-verification/logs/a-type-catalog-7.log`,
`a-*-final.log`, and screenshots `a-mouse-hold-final.png`,
`a-multiselect-final.png`, `a-discussion-statuses-final.png` in the same
verification directory. The final Godot 4.7.1 import has no script errors.
All A implementation, finding, review and verification items are done.

### B: storage implementation in progress

Starter revisions must contain complete field and lifecycle meaning, with
content-derived revision identities. State categories are assigned explicitly
per built-in type; historical terminal membership is preserved, and terminal
outcomes remain `unspecified` where the schema gives no stronger meaning.

Canonical writes must reject missing or unresolved sources before changing
the cache, compare strong source hashes to catch same-size external edits,
and propagate lock/write failures. Compound registry writes stage revision,
current pointer, item bindings and audit evidence together. Failed canonical
writes restore the disposable cache from committed canonical state.

Upgrade preview/apply must compare complete source content, preserve unrelated
records including vault and attachment payloads, and require an exclusive
writer workflow. Rollback must refuse to overwrite post-upgrade changes.
These are implementation/review requirements, not yet verified results.

The post-review gate will run storage/JSON capability checks and existing
persistence regressions, then exercise the actual baseline standalone reader
against cold and warm disposable v2 files. No B runtime checks have run.

### B: first review

Terra reviewed `2fb7b5fd4663d380ee7d7e6dc25312ae5815f8d6` against `45e4e7d`.
Changes are required: reject invalid current revision pointers and forged
content-derived revision identities; insert new type/revision rows in valid
foreign-key order; make ordinary CRUD failures transactional and observable;
and refuse cache rebuilds that would skip canonical records. Tests must prove
successful new-type compound creation and ordinary failure rollback, including
reopened state. Five finding items are children of B-R. Sol is correcting the
batch; runtime verification remains unexecuted.
