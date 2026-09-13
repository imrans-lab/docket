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
checks. The checks below now confirm that refusal on disposable files.

Terra's independent source audit confirmed the baseline standalone reader has
no effective higher-version check and can bypass parsing with a matching old
`.cache`. The supported upgrade must remove that cache and use `.v2.cache`.
Post-review compatibility checks will leave the real v2 cache present and
exercise the old application's open path. Artificially restoring a matching
legacy cache is outside the supported upgrade workflow.

## Batch evidence

| Batch | Implementation | Review | Verification |
| --- | --- | --- | --- |
| A: Query UX | `1fd1046` | Terra cleared | 61 targeted tests pass; GUI accepted |
| B: Storage | `8fe623a` | Terra cleared | Storage 45/45, freshness 14/14; broader failures resolved; old-reader checks pass |
| C: Registry and validation | `59b3e1c` | Terra cleared | Registry 27/27 and 174 related regressions pass |
| D: MCP and queries | `c9ef61c` | Terra cleared | 263 targeted and related tests pass |
| E: GUI and integration | `ff6d9ab`; final GUI delta under review | Terra cleared through `ff6d9ab` | 786/786 full-suite pass; final GUI corrections pending |

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

At `96ed0d3`, Terra accepted the pointer/digest/FK-order/orphan corrections
and found remaining unchecked attachment import, comment resolution,
reference rewriting, project metadata and vault/retrieval mutations. The
ordinary-write finding remains open. Sol is consolidating all canonical-data
mutations behind a shared nested transaction/completion mechanism; cache-only
operational telemetry remains outside canonical persistence.

### B: accepted

Final reviewed source/test snapshot: `8fe623a04845ed184a01c7d2e040aff5e4608837`.
The shared mutation boundary coalesces nested operations, propagates SQL and
canonical write/read errors, restores the cache after failures, and prevents
public flush/close/reload calls from publishing or swapping mid-transaction.
Registry and legacy counter operations use the same checked boundary. Close
releases the cache without rewriting canonical data; checked mutations already
persist their changes immediately.

Verification found and corrected NULL parent revision serialization, unnecessary
close-time writes, stale test helper state, assertion typing, and a deletion
trigger fixture with no target event. Terra reviewed each correction before
reruns. Storage now passes 45/45, including SQLite JSON capability, envelope
preservation and injected write/read/rollback failures. Freshness passes 14/14.

The full `./run_tests.sh` run from reviewed `f120b28` completed 691 tests,
with 689 passing and two failures. Both were test setup/expectation defects:
the deletion fixture and the older orphan-warning expectation. Their reviewed
corrections pass in the targeted runs above; application source did not change
after that full run. The integrated E gate will run the full suite again.

Actual standalone baseline `ed48d8e` refused new records through cold validation
and the server's open path with a real `.v2.cache` present and no legacy cache.
Canonical SHA-256 remained
`5685c683b4592ad9bddc33e793b61f260839387261832112228e7540930c2324`;
v2 cache SHA-256 remained
`eba0f2e10a694ba1a5439d0d539ef26cab861f954de81cee1ffba60323944d3f`.
The current reader created that cache successfully. These checks do not make
Minerva compatible; incompatible writers remain excluded from upgraded files.

Evidence under `/tmp/docket-dynamic-verification/logs/`:
`b-storage-3.log`, `b-freshness-final.log`, `b-full-1.log`,
`b-old-cold-validate.log`, `b-old-warm-open.log`, and
`b-current-warm-open.log`. Matching Godot 4.7.1 imports are clean.
No live files or other repositories were changed or upgraded.

### C: first review

Terra reviewed `bf08a2d40486926bea621af9380c31415c2b5002` against `4d28a59`.
The batch adds project registries, typed operations, lifecycle/repair/evolution
and 20 authored behavioral tests. No C runtime checks have run.

Five findings require corrections: shared registry ownership and refresh before
data publication; semantic/protected-behavior validation of loaded snapshots;
deep-copy boundaries around immutable revisions; refusal of unsupported guard
declarations; and rejection of invalid pinned items in evolution selections.
Findings are children of C-R; Sol is implementing corrections before delta
review and coordinator verification.

Terra reviewed the correction at `d689e237`: the five structural findings are
addressed. A second bounded correction is required for JSON numeric constraint
roundtrips, finite numeric values, refusal of unknown unsets, immutable array
constraints, and validation of preserved opaque values that become declared
fields during an explicit revision upgrade. Three additional finding items
track these corrections. No C runtime checks have run.

### C: accepted

Final reviewed snapshot: `59b3e1c2f99c529166ab87490c6ab6edadfac694`.
The registry validates stored definitions before publication, shares project
semantics across interfaces, protects immutable revisions, and validates whole
candidates before typed writes or selected revision upgrades. Unknown values
survive edits, unsupported unsets are refused, and explicit upgrades preserve
existing false/zero/null/empty values before considering defaults.

After Terra clearance, verification corrected GDScript type inference and two
test defects (JSON numeric comparison and legacy SQLite fixture initialization).
Each correction received delta review before rerun. The Godot 4.7.1 import is
clean; all 27 registry tests pass. An isolated checkout of reviewed `8327523`
also passes storage 45, freshness 14, DataModel 15, StateMachine 30, MCP 67,
and functional cross-project 3 tests (174 total). Application source is unchanged
between those related checks and the final test-only snapshot.

Evidence: `c-import-2.log`, `c-registry-2.log`, and `c-test_*-1.log` under
`/tmp/docket-dynamic-verification/logs/`. All C findings and gates are complete.

### D: implementation in progress

Baseline: `7ceccaf0747b3acab9b0c0bbbacacfe0de0a61f5`.
Sol is implementing type discovery/definition operations, shared typed MCP
mutations, definition-aware transfers, pinned-revision query resolution, and
saved-query bindings. Queries must preserve literal legacy filters and report
unsupported typed conditions without dropping branches. Transfers must preserve
opaque payloads and threaded comments, and commit the destination before source
deletion. Runtime verification remains pending until Terra clears the batch.

### D: first review

Terra reviewed `f117b71d2db6d43da1c2cc594ea7e91a1ae1f0f7` against `7ceccaf`.
Eight grouped findings require corrections: complete source export and legacy
vault checks; references and incoming/threaded relations during moves; exact
historical revision provenance and trusted builtin import; atomic legacy/SQLite
mirror; query shape and branch-scope validation; pinned cross-project sorting;
saved-query/MCP validation; and multi-type chooser binding preservation.
Sol is implementing the corrections and regression coverage. Comments were
generally salient; no D runtime checks have run.

Terra reviewed the correction snapshot `5bce28f`: the eight original groups
are addressed statically. Two remaining findings require malformed `conditions`
wrapper validation and clear public/UI diagnostics for invalid registries.
Sol is correcting these before delta review. No D runtime checks have run.

Terra cleared `5518494` and its Godot 4.7.1 import is clean. Initial D checks
report 26 total, 4 passed and 22 failed, with many cascades from definition
setup errors. Isolated related checks on that reviewed snapshot pass storage
45, freshness 14, query-field validation 11 and functional cross-project 3.
Registry (3/27), type catalog (27/32) and MCP (63/67) expose regressions still
requiring fixes. Logs are `d-tools-query-1.log` and `d-test_*-1.log` under the
verification directory. Sol is correcting the causes before another reviewed
verification pass; D remains unaccepted.

The reviewed correction `47add87` imports cleanly and restores registry 27/27,
MCP 67/67, query-field validation 11/11 and functional cross-project 3/3.
D tools/query checks now pass 19/27, while catalog remains 27/32. Remaining
work includes null ancestry handling, custom-field absence authority, valid
comment import/reopen checks and updating schema-only catalog integration
fixtures to use real project registries. Logs are `d-test_*-2.log`.

### D: accepted

Final reviewed source/test snapshot: `c9ef61c956754270fdf27974d368bc1559a291e3`.
Terra reviewed each correction before execution. The final Godot 4.7.1 import
is clean. All 263 checks pass on this snapshot: tools/query 27, catalog 32,
registry 27, storage 45, parser 37, MCP 67, freshness 14, query-field validation
11 and functional cross-project 3.

The final changes preserve custom-field absence/default authority, exact
historical definitions and threaded relations through transfers, and explicit
query bindings across projects and saved queries. Tests cover rejected target,
source, reference and audit writes; malformed input; public diagnostics; and
reopened data. Expected injected SQL failures are logged; no script exceptions
occur. No live file was upgraded.

Evidence: `d-import-3.log`, `d-test_*-3.log`, and `d-test_*-final.log` in
`/tmp/docket-dynamic-verification/logs/`. All D findings and gates are complete.

### E: implementation in progress

Baseline: `40872273a04bcce73da2cd270de6afb3ae72806b`.
Sol is implementing Project Types, generated forms, registry-aware creation and
query presentation, explicit legacy upgrade controls, and integration guidance.
Complete saves must remain atomic, preserve unsaved edits on stale conflicts,
and retain the originating project for item operations. Terra reviews the whole
batch before the coordinator runs the full suite and actual GUI acceptance.

E1 artifacts are checkpointed at `358152f`, with Project Types management and
explicit SQLite promotion / JSONL v2 upgrade controls. E2 form and interface
integration is underway; the combined E review remains pending.

An isolated full-suite preflight on accepted D source `c9ef61c` completed 745
tests, with 741 passing and four failures. E3 tracks missing creation audit
events and built-in quality timestamps rejected during later transitions.
Evidence: `pre-e-full.log`. This ran only reviewed D code; no E code has run.

E3 documentation is checkpointed at `208fe80` and the prospective GUI/MCP
walkthrough at `844c92c`. Terra began the combined E review with immutable E1
`358152f` while independent E2/E3 source work continues. Required corrections
cover project-aware row/navigation consumers, full definition fidelity,
source-scoped upgrade acknowledgement, unsaved proposal navigation, literal
diagnostic rendering, and explicit recovery state after post-write upgrade
failures. These are tracked under E-R. Overall E review remains pending.

Coordinator preflight also found that protected payload writes followed the
metadata commit. E2 must use the existing checked nested transaction and prove
rollback through a real storage failure after metadata staging. Ordinary built-in
creation and saved string-column ordering also require explicit regressions.
No E import, application run, or test execution has occurred.

E3 core and documentation are statically cleared at `7d5cebe`. The complete
GUI/application/test batch is frozen at `d3c5e62`, and all writers are stopped.
Terra is reviewing the remaining GUI delta and confirming E1 corrections.
Implementation artifacts are done; the overall E review and verification gates
remain pending. No E code has been imported or executed.


### E: integrated review and runtime corrections

Terra cleared the combined implementation at `abd1e0e` and each subsequent
correction before execution. Initial imports exposed incorrect registry API use
and GDScript inference errors; `6c9ae39` imports cleanly. Runtime checks then
exposed test preload/fixture isolation defects and an outdated creation-event
expectation. The first full run aborted and is not counted as a successful gate.
After reviewed corrections, Project Types passes 12/12 targeted checks.

The next complete run reported 786 tests, 785 passing. Reopening an integral
JSON number rendered `3.0` in an integer editor and blocked an unrelated save.
The corrected editor uses an exact finite-integer check, preserving invalid
fractional values for validation rather than rounding them. Reviewed `ff6d9ab`
imports cleanly and passes **786/786** tests with no script exceptions.
Evidence: `e-import-4.log` and `e-full-3.log`. Headless UI fixtures report object
and resource cleanup warnings; these are not script exceptions or test failures.

Actual GUI and HTTP MCP acceptance on a disposable project exercised draft
definition, activation, generated creation, strict transition refusal, required
field and kind validation, guarded approval with unsaved fields, typed queries,
selected-item additive evolution, historical revision retention, and the new
field editor. Comment and attachment payloads were captured for a cache-deletion
reopen check. Two additional GUI findings remain under review at `ebc7cf8`:
qualified child navigation in single/multiple projects and preserving default
columns while offering query-scoped custom columns. Final acceptance requires
rerunning checks on the corrected source and completing the disposable upgrade
and cache-rebuild walkthrough. No live file was upgraded.
