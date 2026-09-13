# Plan: Project-local dynamic item types and query UX

Docket plan: `01a096fa277f7683bc6d1fd8a18e3053` (project `docket`).
Parent DCR: `01a096e77f2f778781b03d0aeb8384e3`; [proposal](dcr-dynamic-item-types.md).
Source proposal: /home/imran/github/docket/docs/dcr-dynamic-item-types.md.
Prepared 2026-09-12. Main thread coordinates; gpt-5.6-sol implements; gpt-5.6-terra reviews.

Five batches cover twelve implementation tasks, five independent review gates and five coordinator verification gates. Task identifiers and explicit blocks links are recorded below.

## Assignment and execution policy

The main Codex thread coordinates all batches, resolves cross-cutting design questions, owns review/test gates, and reports to the user. Implementation and test authoring: gpt-5.6-sol. Independent code review: gpt-5.6-terra. These are user-selected role assignments, not runtime routing enforced by Docket. The coordinator must explicitly spawn the assigned model for each implementation/review assignment. No implementation task needs a planned switch to Terra.

The user approved this plan and autonomous implementation on 2026-09-12. All five batches are complete; the final reviewed source passes 788/788 tests and GUI/HTTP acceptance. See the [verification record](implementation-dynamic-item-types.md). Implementation and post-review verification are authorized; live-file upgrades and publishing remain outside this implementation run. The approval supersedes the planning-time approval placeholders in task descriptions.

## Decision rubric

Apply the user's priorities in this order: **durability, reliability, salience, discoverability, debuggability, cost**. Preserve durable data and dependable behavior before optimizing clarity, ease of finding capabilities, diagnosis, or resource expense. Record material tradeoffs and evidence in Docket. Cost governs batching and unnecessary work; it does not justify data loss, weaker checks, or hidden failures.

## Batch workflow

For each batch: Sol writes implementation and relevant tests -> coordinator freezes a review snapshot and supplies a focused packet -> Terra reviews the combined batch -> Sol fixes findings -> the same Terra reviewer inspects the delta -> coordinator runs tests/checks only after review clearance. Complete the verification gate before starting the next batch. Use one primary review per coherent batch rather than one per task; do not combine the whole DCR into one final review.

Before review, do not execute tests, test discovery/collection, test-producing CI, capability probes, application imports/builds, or GUI acceptance runs. Source reading and static diff inspection are allowed. Test execution, compilation/import checks and walkthroughs happen at the coordinator's post-review verification gate. Reading test code is not evidence that it passes.

If verification finds a problem, Sol authors the fix and any needed tests; Terra reviews the changed code/tests before the coordinator reruns affected checks. Reuse the reviewer for focused follow-up in that batch. Broaden reruns only when changes or failures justify it. The final E gate runs the full regression suite after the integrated code has been reviewed.

Keep implementation serial where files overlap; only one writer edits a shared area at a time. Review an immutable commit or isolated snapshot, with its baseline and revision recorded in Docket. Give the reviewer requirements, acceptance criteria, the diff and necessary surrounding code; do not seed it with the implementer's reasoning transcript. Ask for no source edits by the reviewer. Five primary batch reviews are planned, with additional delta reviews only for fixes or uncovered risks.

## Review contract: code, comments and tests

Terra reviews all three areas in every batch:
1. Code quality and correctness: behavior, data preservation, compatibility, error propagation, state consistency, project/revision isolation, clear interfaces and avoidable duplication. Report concrete defects; distinguish blockers from optional improvements.
2. Comment salience: comments must explain how the code works, invariants, non-obvious constraints or technical rationale useful to the next implementer and reviewer. Remove stale or redundant commentary. Do not add conversation history, author/model attribution, phrases such as "owner decision on ...", approval narration, or task-management history to source comments or product copy. Preserve required license/copyright notices. Record design decisions and provenance in Docket/design documentation.
3. Test quality: meaningful observable behavior and independent expected results, relevant edge/error cases, deterministic isolated fixtures, regression value and useful assertions. Flag tests that merely mirror implementation or hardcode its incidental shape, excessive mocking, accidental environment dependencies and missing failure coverage. Review test quality before execution; never report passing tests from static review.

Each report records baseline/reviewed revision, files and task coverage, findings with severity and file/line evidence, proposed test gaps, and a verdict: ready for post-review verification or changes required. Cover source comments and test comments as well as UI text. A clear static review is not final acceptance; the coordinator must record actual test results later.

## Completion semantics and budget discipline

Implementation tasks are done when their code/test artifacts are ready for review, with no test run claimed. Findings reopen the affected task. A review task is done when blocking findings are addressed and the current snapshot is cleared for verification. A verification task is done only after the prescribed checks pass. Unresolved required external compatibility work remains incomplete with the blocker recorded; it does not count as a passed gate. Do not call the overall DCR complete with unresolved required acceptance work.

Prefer bounded task packets and reuse the batch reviewer for follow-up. Keep model roles stable unless the user changes them. If a batch becomes too broad to review reliably, split that review by subsystem and record why; do not silently omit checks to preserve the initial review count. No token or monetary cap has been specified.

## DCR tree

All listed work items are done and are direct children of this plan; batch letters group related tasks without introducing additional task types.

```text
DCR 01a096e77f2f778781b03d0aeb8384e3 — Dynamic item types [complete locally; no release published]
└── Plan 01a096fa277f7683bc6d1fd8a18e3053 — Query UX and dynamic types [done]
    ├── A1: Build searchable alphabetical type chooser [gpt-5.6-sol]
    ├── A2: Scope query fields and statuses to selected types [gpt-5.6-sol]
    ├── A-R: Review — Query-builder usability [gpt-5.6-terra]
    ├── A-V: Verify after review — Query-builder usability [codex-coordinator]
    ├── B1: Specify versioned type and field storage contracts [gpt-5.6-sol]
    ├── B2: Preserve generic item fields across persistence paths [gpt-5.6-sol]
    ├── B3: Persist type revisions and implement safe file upgrades [gpt-5.6-sol]
    ├── B-R: Review — Lossless storage and format compatibility [gpt-5.6-terra]
    ├── B-V: Verify after review — Lossless storage and format compatibility [codex-coordinator]
    ├── C1: Resolve project-local registries and built-in descriptors [gpt-5.6-sol]
    ├── C2: Validate typed changes, lifecycles and compatible evolution [gpt-5.6-sol]
    ├── C-R: Review — Registry, validation and evolution [gpt-5.6-terra]
    ├── C-V: Verify after review — Registry, validation and evolution [codex-coordinator]
    ├── D1: Expose dynamic types and safe item operations through MCP [gpt-5.6-sol]
    ├── D2: Compile dynamic queries and preserve saved-query meaning [gpt-5.6-sol]
    ├── D-R: Review — MCP operations and dynamic queries [gpt-5.6-terra]
    ├── D-V: Verify after review — MCP operations and dynamic queries [codex-coordinator]
    ├── E1: Build the Project Types management screen [gpt-5.6-sol]
    ├── E2: Generate item forms and integrate registry-aware query UX [gpt-5.6-sol]
    ├── E3: Author release integration fixtures and compatibility guidance [gpt-5.6-sol]
    ├── E-R: Review — GUI integration and release readiness [gpt-5.6-terra]
    └── E-V: Verify after review — GUI integration and release readiness [codex-coordinator]
```

## Agent assignment table

| Batch | Implementation tasks | Implementer | Reviewer | Test execution |
| --- | --- | --- | --- | --- |
| A: Query-builder usability | A1: Build searchable alphabetical type chooser; A2: Scope query fields and statuses to selected types | gpt-5.6-sol | gpt-5.6-terra (A-R) | Main coordinator (A-V), after review |
| B: Lossless storage and format compatibility | B1: Specify versioned type and field storage contracts; B2: Preserve generic item fields across persistence paths; B3: Persist type revisions and implement safe file upgrades | gpt-5.6-sol | gpt-5.6-terra (B-R) | Main coordinator (B-V), after review |
| C: Registry, validation and evolution | C1: Resolve project-local registries and built-in descriptors; C2: Validate typed changes, lifecycles and compatible evolution | gpt-5.6-sol | gpt-5.6-terra (C-R) | Main coordinator (C-V), after review |
| D: MCP operations and dynamic queries | D1: Expose dynamic types and safe item operations through MCP; D2: Compile dynamic queries and preserve saved-query meaning | gpt-5.6-sol | gpt-5.6-terra (D-R) | Main coordinator (D-V), after review |
| E: GUI integration and release readiness | E1: Build the Project Types management screen; E2: Generate item forms and integrate registry-aware query UX; E3: Author release integration fixtures and compatibility guidance | gpt-5.6-sol | gpt-5.6-terra (E-R) | Main coordinator (E-V), after review |

## Task records

| Task | Docket ID | Assigned to |
| --- | --- | --- |
| A1: Build searchable alphabetical type chooser | `01a096faa7cd7055a5897afe8450b3e9` | gpt-5.6-sol |
| A2: Scope query fields and statuses to selected types | `01a096faa93a7170876630cd4e740815` | gpt-5.6-sol |
| A-R: Review — Query-builder usability | `01a096fb5f5b768b8efe498ede867598` | gpt-5.6-terra |
| A-V: Verify after review — Query-builder usability | `01a096fb60e975378fa9c19e868a4809` | codex-coordinator |
| B1: Specify versioned type and field storage contracts | `01a096faaaa5754bb65e421dd119ec84` | gpt-5.6-sol |
| B2: Preserve generic item fields across persistence paths | `01a096faac15703987ef04075637405d` | gpt-5.6-sol |
| B3: Persist type revisions and implement safe file upgrades | `01a096faad8c7a778e9caae5ec686a0e` | gpt-5.6-sol |
| B-R: Review — Lossless storage and format compatibility | `01a096fb626c75f09c0f3b8142dcaf9b` | gpt-5.6-terra |
| B-V: Verify after review — Lossless storage and format compatibility | `01a096fb63e7768b84ae9b4976977156` | codex-coordinator |
| C1: Resolve project-local registries and built-in descriptors | `01a096faaefd7336889237c3ee6b96d9` | gpt-5.6-sol |
| C2: Validate typed changes, lifecycles and compatible evolution | `01a096fab0707251b9a3ee90bd5419fc` | gpt-5.6-sol |
| C-R: Review — Registry, validation and evolution | `01a096fb656b7ec7ab5c541464c12694` | gpt-5.6-terra |
| C-V: Verify after review — Registry, validation and evolution | `01a096fb66f07fc480a97ccb3e7d8132` | codex-coordinator |
| D1: Expose dynamic types and safe item operations through MCP | `01a096fab1e67aa0a4c465ee8c608d78` | gpt-5.6-sol |
| D2: Compile dynamic queries and preserve saved-query meaning | `01a096fab3657934b5380384a8969aba` | gpt-5.6-sol |
| D-R: Review — MCP operations and dynamic queries | `01a096fb687671c78dd3eadfd2673ffa` | gpt-5.6-terra |
| D-V: Verify after review — MCP operations and dynamic queries | `01a096fb69f97ddbad63f6c135b324a5` | codex-coordinator |
| E1: Build the Project Types management screen | `01a096fab4d975ce8a40b176f77c7b5e` | gpt-5.6-sol |
| E2: Generate item forms and integrate registry-aware query UX | `01a096fab65c7256bf3a915d41c57d21` | gpt-5.6-sol |
| E3: Author release integration fixtures and compatibility guidance | `01a096fab7d47f259a6ecfcc4ac5905d` | gpt-5.6-sol |
| E-R: Review — GUI integration and release readiness | `01a096fb6b7579979eb97c992a7981eb` | gpt-5.6-terra |
| E-V: Verify after review — GUI integration and release readiness | `01a096fb6cf177d0a989690ad13774ff` | codex-coordinator |

## Dependency links

```text
A1 → A2
A1 → A-R
A2 → A-R
A-R → A-V
A-V → B1
B1 → B2
B2 → B3
B1 → B-R
B2 → B-R
B3 → B-R
B-R → B-V
B-V → C1
C1 → C2
C1 → C-R
C2 → C-R
C-R → C-V
C-V → D1
D1 → D2
D1 → D-R
D2 → D-R
D-R → D-V
D-V → E1
E1 → E2
E2 → E3
E1 → E-R
E2 → E-R
E3 → E-R
E-R → E-V
```

## Review packets and execution scope

Use the parent DCR and each task's description for detailed code areas, acceptance criteria, authored evidence and constraints. Execution was approved on 2026-09-12. Docket task states and gate comments record current progress and evidence. Review precedes all test execution; only the coordinator executes post-review checks.

