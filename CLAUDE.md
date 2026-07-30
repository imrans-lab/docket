# Docket — RAID-Inspired Work-Item Tracker

## Build / Test / Run

```bash
# Build the native extension from vendored source (required once after cloning)
git submodule update --init --recursive
./scripts/build/build_gdextension.sh macos universal   # or: linux x86_64 / windows x86_64
godot --headless --path . --import   # registers class_name globals

# Run tests (headless)
./run_tests.sh

# Or directly:
godot --headless --path . -- test

# Start MCP server
godot --headless --path . -- serve --port 3010

# Launch GUI (default)
godot --path .

# Convert legacy monolithic JSON to SQLite, then SQLite to canonical JSONL
godot --headless --path . -- migrate --file old.dct
godot --headless --path . -- migrate-jsonl --file old.dct

# Check a .dct for conflict markers / duplicate IDs / dangling refs (exit 1 on error)
godot --headless --path . -- validate --file docket.dct
```

## Architecture

### Data Format
- **Canonical format:** `.dct` files are **JSONL text** (committed to git)
  - Human-readable, diffable, mergeable per `data/jsonl_format.md` spec
  - One JSON object per line, deterministic key order, omit empty fields
  - Uses a best-effort advisory `.lock`; it reduces overlap but is not a
    correctness boundary
- **Cache layer:** `.dct.cache` (SQLite, gitignored, auto-rebuilt)
  - Fast query engine, concurrent read/write (WAL mode, 15s timeout)
  - Transitional logs and error logs (ephemeral, not serialized)
- **Legacy formats:** SQLite and monolithic JSON remain readable; promotion to
  JSONL is currently explicit
- **New files:** created in JSONL format by default

### Core Components
- **SQLite cache backend:** `DocketDB` class wraps cache operations via godot-sqlite GDExtension (2shady4u, MIT) for fast queries
- **14 creatable work-item types:** Bug, DCR, RCA, Chore, Work Item, Test,
  Hint, Insight, Question, Discussion, KB, Skill, Prompt, Policy. The schema
  keeps Secret and Encrypted Note definitions for backward compatibility.
- **Visual query builder:** conditions with AND/OR logic, 13 operators,
  wildcards, and pseudo-fields (`tags`, `has_attachment`)
- **Multi-project:** multiple `.dct` files loaded simultaneously, GUI
  cross-project queries, qualified parent/blocked_by references (`project:ID`),
  and item movement between projects
- **`.dcq` files:** standalone saved query files for sharing between projects
- **Attachments:** Binary BLOB storage in SQLite (max 5 MB), transported as base64 over MCP
- **Schema source of truth:** `data/schema.json`
- **MCP transport:** HTTP server on 127.0.0.1:3010, JSON-RPC 2.0 over POST `/mcp`
- **MCP tools:** the authoritative tool registry is
  `scripts/tools/tool_registry.gd`; do not maintain a second hardcoded list here
- **Vault encryption:** handle-based vault entries use AES-256-CBC with
  HMAC-SHA256. Optional secondary-password double encryption is not a separate
  authentication factor.
- **Secret rotation:** replacing a vault value archives the old version, over
  MCP as well as in the GUI. Full version history is available for
  decrypt-on-demand.
- **Vault ownership:** an entry either belongs to a work item (`owner_item_id`
  set — the payload behind a Secret or Encrypted Note) or is standalone
  (created by `docket_secret_set`). Ownership is stored explicitly, not inferred
  from the handle. Standalone entries have no item row, so they appear under
  **File > Vault** rather than in the query grid; `docket_secret_promote` wraps
  one in a tracked item without decrypting it. A handle colliding with an
  existing item id is refused.

## Key Files

- `scripts/core/docket_db.gd` — SQLite cache operations (CRUD, queries, hints, attachments)
- `scripts/core/migration.gd` — Legacy monolithic JSON → SQLite converter
- `scripts/core/docket_db_jsonl.gd` — JSONL-backed write-through DB
- `scripts/core/jsonl_parser.gd`, `jsonl_serializer.gd`, `jsonl_cache.gd` —
  canonical data I/O and disposable cache rebuilding
- `scripts/core/jsonl_migration.gd` — SQLite → canonical JSONL converter
- `scripts/core/jsonl_validator.gd` — Structural validation without opening a DB
- `scripts/core/data_model.gd` — Item creation & validation
- `scripts/core/state_machine.gd` — Type-specific state transitions
- `scripts/core/app_state.gd` — Centralized GUI state container
- `scripts/tools/tool_registry.gd` — Tool dispatcher
- `data/jsonl_format.md` — JSONL spec (line types, sort order, encoding rules)
- `addons/godot-sqlite/` — GDExtension bindings

## Migration Guide

### Legacy migration

Legacy formats are detected on open, but opening a monolithic JSON file
currently converts it only to SQLite. Promote it to canonical JSONL explicitly:

```bash
godot --headless --path . -- migrate --file legacy.dct
godot --headless --path . -- migrate-jsonl --file legacy.dct
```

- JSONL is written to the same filename (`legacy.dct`).
- The intermediate/original SQLite file is backed up as
  `legacy.dct.sqlite.bak`.
- New `.dct.cache` is built from JSONL on next access

### Cleaning Up Git Filters (per repo)
If the repo previously used smudge/clean filters for SQLite storage:

```bash
# Remove filters
git config diff.clean ""
git config diff.smudge ""
git config diff.textconv ""

# Add .dct.cache to .gitignore if not already present
echo ".dct.cache" >> .gitignore

# Remove any filter setup scripts (no longer needed)
rm -f scripts/setup-git-filters.sh scripts/sqlite-clean.sh scripts/sqlite-smudge.sh
```

## Conventions

- Dictionary-based items (no custom classes for serialization)
- Static methods on RefCounted where possible
- Test methods return `true` (pass) or error `String` (fail)
- All timestamps via `Time.get_datetime_string_from_system(true)` (UTC, ISO 8601 format)
- IDs: UUID7 (32-char lowercase hex, time-ordered, globally unique). Displayed as git-style shortest unique prefix (min 7 chars). Legacy `PREFIX-NNNN` IDs still work. MCP tools accept short hex prefixes (min 4 chars).
- Cross-project references: always-qualified `project:ID` format (e.g. `minerva:0196a3b4c5d6e7f`). UUID7 items keep their ID when moved between projects.
- Writes are immediate: every mutation writes SQLite *and* rewrites the whole
  JSONL through a temp file and rename. No explicit save step is needed —
  `docket_flush` and **File > Save** are explicit "settle before `git commit`"
  steps.
- Reads re-check the `.dct` fingerprint before each MCP call / GUI poll and rebuild the cache if it changed on disk, so `git pull` is safe while Docket is running
- The `.lock` is advisory and best-effort. Its creation is not atomic, and the
  writer currently proceeds after a lock timeout.

## Discussions

Discussions facilitate collaborative exploration of topics, decisions, and design questions. They capture the evolution of thinking through comments and summaries.

### Workflow

**1. Create a discussion**
```python
docket_create(type="discussion", title="Should we migrate to SQLite?",
              description="Current JSON format is reaching limits. Explore pros/cons of migration to SQLite backend.")
# Returns: discussion_id, e.g. "0196a3b4c5d6e7f"
```

**2. People and agents add comments**
```python
docket_comment(action="add", item_id="0196a3b4c5d6e7f",
               text="SQLite would give us better query performance. I'd suggest using godot-sqlite GDExtension.")
```
Participation is implicit in comment authorship. There is no separate
participant roster, role, or assignment model.

**3. Reach consensus and resolve**
```python
docket_transition(id="0196a3b4c5d6e7f", to="resolved")

# Add a summary comment capturing decisions, next steps, and open questions
docket_comment(action="add", item_id="0196a3b4c5d6e7f",
               text="Summary: Decision to migrate to SQLite. Use godot-sqlite GDExtension. Next: implement DocketDB class. Open: handle schema versioning.")
```

### Summary Comment Convention

When resolving a discussion, add a summary comment that includes:
- **Decisions made:** What was agreed upon
- **Next steps:** Actionable outcomes (often spawn child DCRs/work items)
- **Open questions:** What remains unresolved for future discussion

### Reopening and Evolution

Discussions can reopen if new information emerges:
```python
docket_transition(id="0196a3b4c5d6e7f", to="active")
# Continue adding comments
docket_transition(id="0196a3b4c5d6e7f", to="resolved")
docket_comment(action="add", item_id="0196a3b4c5d6e7f",
               text="Summary (updated): Additional findings on schema versioning...")
```

Previous summaries remain in the comment stream — the discussion history preserves how ideas evolved over time.

### Spawning Work

Discussion outcomes often become concrete work. Create child items (DCRs, bugs, chores) referencing the discussion:
```python
docket_create(type="dcr", title="Implement DocketDB SQLite wrapper",
              parent="0196a3b4c5d6e7f",
              description="From discussion on data backend migration...")
```

Use `docket_link()` if the work item was created outside the discussion context:
```python
docket_link(from="work_item_id", to="0196a3b4c5d6e7f", relation="surfaced")
```
