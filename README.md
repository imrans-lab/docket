# Docket

[![CI](https://github.com/imrans-lab/docket/actions/workflows/ci.yml/badge.svg)](https://github.com/imrans-lab/docket/actions/workflows/ci.yml)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-brightgreen.svg)](LICENSE)

A local-first, RAID-inspired work-item and project-memory tracker built in
Godot. Docket gives different kinds of engineering work their own fields and
state machines, stores the canonical record as Git-friendly text, and exposes
the same projects to people through a desktop GUI and to coding agents through
MCP.

## Features

- **14 creatable work-item types** with enforced state machines: Bug, DCR, RCA,
  Chore, Work Item, Test, Hint, Insight, Question, Discussion, KB, Skill, Prompt,
  and Policy. The schema retains the former Secret and Encrypted Note item types
  for backward compatibility.
- **Visual query builder** with field/operator/value rows, AND/OR logic, substring search, wildcard patterns
- **Multi-project support** — load multiple `.dct` files, query them together in
  the GUI, and create cross-project references
- **`.dcq` query files** — save and share queries between projects
- **JSONL-canonical storage** — `.dct` files are human-readable, diffable, mergeable text (committed to git)
  - Automatic SQLite cache (`.dct.cache`, gitignored) for fast queries and concurrent access
  - Spec in `data/jsonl_format.md` (deterministic key order, one-line JSON objects, atomic writes, advisory locking)
- **MCP tool registry** over HTTP JSON-RPC 2.0 for items, queries, comments,
  attachments, projects, knowledge retrieval, diagnostics, and the vault
- **Binary attachments** up to 5 MB, stored as BLOBs in the SQLite cache,
  serialized as base64 in `.dct`, and transported as base64 over MCP
- **Saved queries** and tag-based contextual briefings
- **Item linking** with typed relations: caused_by, blocks, duplicates, follow_up, surfaced
- **Handle-based vault** — AES-256-CBC with encrypt-then-HMAC authentication,
  rotation history, and optional secondary-password double encryption

## Install

Download a release from the [Releases page](https://github.com/imrans-lab/docket/releases).

**Release binaries are not platform-signed.** Docket's release workflow can
sign the checksum manifest with GPG. A release is independently verifiable only
when it contains both `SHA256SUMS` and `SHA256SUMS.asc`; compare the signing
key's fingerprint with the value published below.

```bash
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

- **macOS** — right-click the app and choose *Open* on first launch (it is ad-hoc
  signed but not notarized).
- **Windows** — SmartScreen will warn; choose *More info* → *Run anyway*.
- **Linux** — extract and run `./docket.x86_64`.

Release signing key fingerprint:

```
178DFC3E 42D55743 B0186526 5BC259EB 7ED2C464
```

The public key ships with the repository at
[`docs/docket-release-signing-key.asc`](docs/docket-release-signing-key.asc).

See [docs/SIGNING.md](docs/SIGNING.md) for why, and how to verify.

## Requirements

- [Godot 4.6+](https://godotengine.org/download) (standard or headless build; CI pins an exact patch release)
- macOS (universal), Linux x86_64, or Windows x86_64

Building from source additionally needs SCons and a C++ toolchain — see
[docs/BUILDING.md](docs/BUILDING.md).

## Quick Start

These assume you downloaded a release (see [Install](#install)). Running from
source instead? See [docs/BUILDING.md](docs/BUILDING.md).

The examples use `docket` for the executable. Substitute the real path for your
platform:

| Platform | Executable |
|----------|------------|
| macOS | `/Applications/Docket.app/Contents/MacOS/Docket` |
| Linux | `./docket.x86_64` |
| Windows | `Docket.exe` |

### GUI

Launch the app normally — double-click it, or:

```bash
docket
```

Opens the tracker UI with menu bar, query grid, and item detail forms. Use
**File > New Docket** to create a `.dct`, or **File > Open...** for an existing
one.

### MCP server

```bash
docket --headless -- serve --port 3010 --file myproject.dct
```

Serves JSON-RPC 2.0 at `POST http://127.0.0.1:3010/mcp`.

On macOS the binary lives inside the app bundle:

```bash
/Applications/Docket.app/Contents/MacOS/Docket --headless -- serve --port 3010 --file myproject.dct
```

### Connect from Claude Code

Add to your `.mcp.json`:

```json
{
  "mcpServers": {
    "docket": {
      "type": "http",
      "url": "http://127.0.0.1:3010/mcp"
    }
  }
}
```

Start the server before launching Claude Code.

#### What the endpoint accepts

The MCP endpoint binds to loopback and has no credential — anything that can
reach it can drive it. That is fine for a same-user local tool (such a process
can already read your `.dct` files directly) but **not** for a web page, which
can reach `127.0.0.1` while having no filesystem access.

So the server refuses requests that could only have come from a browser:

- any request carrying an `Origin` header
- a `Host` that is not a loopback address, which defeats DNS rebinding
- `Content-Type: text/plain`, `application/x-www-form-urlencoded`, or
  `multipart/form-data` — the three types a browser can send without a CORS
  preflight

Anything else is allowed, including a missing `Content-Type`, so ordinary
clients are never locked out. Rejections return `403` with the reason.

### Enable the vault

Vault entries are stored under string handles and encrypted with AES-256-CBC
plus HMAC-SHA256. MCP clients use `docket_secret_set`, `docket_secret_get`,
`docket_secret_list`, and `docket_secret_delete`. Existing `secret` and
`encrypted_note` work items remain readable for backward compatibility, but new
MCP secrets are not work items.

Open **Docket > Preferences** (or **File > Preferences** on Linux/Windows),
fill in **Vault Password**, and optionally a **hint**. The hint is stored in the
`.dct`; the password is not.

The first time you save a secret, Docket writes a `vault_salt` and a
`vault_verify` token into the `.dct` so it can tell a wrong password from a
corrupt value. Losing the password means losing the secrets — there is no
recovery path, by design.

For higher-value entries you can require a **second password**. This is
secondary-password double encryption, not a separate authentication factor.
The second password is never stored and must be supplied for every decrypt.

Deriving the vault key takes **about two seconds**. That is deliberate — the
key-stretching cost is what makes a stolen `.dct` expensive to brute-force. It
happens once per operation, not per keystroke.

Every vault access is recorded to `<yourfile>.dct.audit.jsonl` next to the
`.dct`: which secret, when, from the GUI or MCP, and whether it succeeded.
Values and passwords are never written there. The file is local and gitignored —
it is not shared between machines. Read it with the `docket_audit_log` tool, or
just open it.

> **Know what this protects.** The vault protects secrets *inside the `.dct`* —
> the file you commit to git and sync between machines. Your vault password is
> saved in plain text in `user://docket_prefs.json` on the local machine, so
> anyone with access to your account can read it. It is not a defence against
> local disk access, and Docket is not a replacement for a password manager or
> a real secrets store.

Where `user://` lives:

| Platform | Path |
|----------|------|
| macOS | `~/Library/Application Support/Godot/app_userdata/Docket/` |
| Linux | `~/.local/share/godot/app_userdata/Docket/` |
| Windows | `%APPDATA%\Godot\app_userdata\Docket\` |

### GUI and MCP together

Launching the GUI also starts the MCP server, so an agent and a human can work
the same file at once. Both pick up external edits — including a `git pull` —
automatically; see [Concurrent Access](#concurrent-access-and-multi-machine-use).

## CLI Reference

```
godot --path <project-dir> [godot-flags] -- [docket-flags]

Modes:
  (default)                 Launch GUI
  serve                     Headless MCP server
  test                      Run tests and exit
  migrate                   Migrate legacy monolithic JSON .dct to SQLite
  migrate-jsonl             Migrate SQLite .dct to canonical JSONL
  validate                  Check .dct files for structural problems and exit

Options:
  --file <path.dct>         Data file (repeatable for multi-project)
  --query <path.dcq>        Load a saved query file on startup
  --port <number>           MCP server port (default: 3010)
  -h, --help, -?            Show help
```

### Examples

```bash
# GUI with a specific file
godot --path . -- --file myproject.dct

# MCP server on custom port
godot --headless --path . -- serve --port 4000

# Legacy monolithic JSON requires two explicit conversions:
godot --headless --path . -- migrate --file old.dct
godot --headless --path . -- migrate-jsonl --file old.dct

# An existing SQLite .dct needs only the second command:
godot --headless --path . -- migrate-jsonl --file old-sqlite.dct

# Run tests
godot --headless --path . -- test

# Check a .dct after resolving a merge conflict (exits 1 if anything is wrong)
godot --headless --path . -- validate --file myproject.dct

# Multi-project with query file
godot --path . -- --file minerva.dct --file services.dct --query bugs.dcq
```

## Data Storage

### JSONL Format (Canonical)
- **File:** `.dct` (committed to git)
- **Structure:** one JSON object per line (JSONL), human-readable and diffable
- **Spec:** `data/jsonl_format.md` documents line types, sort order, encoding rules
- **Atomic writes:** temp file + rename, with a best-effort advisory `.dct.lock`
- **Conciseness:** omit empty fields, deterministic key order for byte-identical output

### SQLite Cache
- **File:** `.dct.cache` (auto-generated, gitignored)
- **Auto-rebuilt:** from `.dct` on first access or after modification
- **Concurrent access:** WAL mode, 15-second busy timeout
- **Performance:** fast queries, efficient indexing

### Legacy Formats

- New projects are JSONL-backed.
- Existing JSONL, SQLite, and legacy monolithic JSON `.dct` files are detected
  when opened.
- Opening a legacy JSON file currently converts it to SQLite, not JSONL.
- Run `migrate-jsonl` explicitly to promote an SQLite `.dct` to canonical JSONL;
  the original is retained as `<file>.sqlite.bak`.

## Build

Docket bundles [godot-sqlite](https://github.com/2shady4u/godot-sqlite) (MIT) as
a GDExtension. **No prebuilt binaries are checked in or downloaded** — the
extension is compiled from source pinned in `third_party/`.

```bash
git clone --recurse-submodules https://github.com/imrans-lab/docket.git
cd docket
./scripts/build/build_gdextension.sh macos universal   # or: linux x86_64 / windows x86_64
godot --headless --path . --import
./run_tests.sh
```

The first build compiles `godot-cpp` and takes 10-20 minutes; later builds take
seconds. Full detail, including how to bump the vendored version, is in
[docs/BUILDING.md](docs/BUILDING.md).

### Exporting

Presets for `macOS` (universal), `Linux` (x86_64), and `Windows` (x86_64) are in
`export_presets.cfg`. Export templates for your Godot version must be installed.

```bash
godot --headless --path . --export-release "Linux" build/linux/docket.x86_64
```

Tagging `v*` runs the release workflow, which builds all three platforms, runs
the test suite, and publishes checksums. It also publishes a GPG signature when
the repository signing secrets are configured. Run
`scripts/build/preflight.sh` before pushing — secret scan, FCIB, version skew,
dead links. See [docs/RELEASING.md](docs/RELEASING.md).

## MCP Tools

| Tool | Description |
|------|-------------|
| `docket_create` | Create a new work item |
| `docket_get` | Get item by ID with full event history |
| `docket_update` | Update fields on an existing item |
| `docket_transition` | Move item to a new state (enforces state machine) |
| `docket_query` | Filter, sort, and limit items |
| `docket_link` | Link two items with a typed relation |
| `docket_context` | Get a curated briefing by tags |
| `docket_saved_query` | Save, load, or list query templates |
| `docket_hint_set` | Store a hint by component + key |
| `docket_hint_get` | Retrieve a hint (auto-increments retrieval count) |
| `docket_hint_query` | Search hints by component, tags, or research cost |
| `docket_attach` | Attach a binary file (base64) to an item |
| `docket_detach` | List, download, or delete attachments |
| `docket_comment` | Add, list, reply to, accept, or reject comments |
| `docket_move` | Move an item between loaded projects |
| `docket_mirror` | Copy selected fields between items and optionally transition the target |
| `docket_delete` | Permanently delete an item and its dependent data |
| `docket_transition_report` | Aggregate failed transition attempts |
| `docket_error_report` | Aggregate MCP tool errors |
| `docket_secret_set` | Create or replace an encrypted vault entry |
| `docket_secret_get` | Decrypt a vault entry or archived version |
| `docket_secret_list` | List vault handles without decrypting values |
| `docket_secret_delete` | Delete a vault entry |
| `docket_audit_log` | Read the local metadata-only vault access audit log |
| `docket_secret_promote` | Wrap a standalone vault entry in a tracked Secret item, without re-entering the value |
| `docket_project_list` | List loaded projects |
| `docket_project_add` | Load or create another project |
| `docket_project_remove` | Close a loaded project |
| `docket_project_meta` | Get or set project lifecycle metadata |
| `docket_gui_open` | Ask the running GUI to open an item or query |
| `docket_get_state_machine` | Inspect one or all schema-defined state machines |
| `docket_quality` | Score and review a knowledge item |
| `docket_skill_list` | Discover stored skills |
| `docket_skill_get` | Retrieve a stored skill's executable content |
| `docket_reload` | Re-read `.dct` files from disk, discarding the cache (after a `git pull`) |
| `docket_flush` | Force serialization to disk — an explicit "settle before `git commit`" step |
| `docket_validate` | Check a `.dct` for conflict markers, duplicate IDs, and dangling references |

## Item Types and State Machines

Fourteen types are available for new MCP work items. Their states, transitions,
required fields, and optional fields are defined in `data/schema.json`. The
schema also retains the legacy `secret` and `encrypted_note` item definitions so
old projects can still be read.

### Tracking work

**Bug** — `new` &rarr; `triaged` &rarr; `active` &rarr; `resolved` &rarr; `verified` &rarr; `closed`
Resolving requires a resolution: fixed, wont_fix, by_design, duplicate, not_repro.

**DCR** (Design Change Request) — `proposed` &rarr; `approved` &rarr; `designing` &rarr; `implementing` &rarr; `reviewing` &rarr; `shipped`

**RCA** (Root Cause Analysis) — `detected` &rarr; `investigating` &rarr; `root_caused` &rarr; `remediating` &rarr; `verified` &rarr; `closed`

**Work Item** — `backlog` &rarr; `open` &rarr; `in_progress` &rarr; `done`
Can also go `blocked` from `in_progress` (requires `blocked_by` — an item ID,
optionally cross-project qualified like `project:DKT-0042`). Unblocks back to
`in_progress` or `open`.

**Chore** — `open` &rarr; `in_progress` &rarr; `done`

**Test** — `draft` &rarr; `ready` &rarr; `passing` &rarr; `failing` &rarr; `skipped` &rarr; `retired`

### Capturing knowledge

**Hint** — `draft` &rarr; `validated` &rarr; `promoted`
Keyed by component + key, with a retrieval count. Built for agents to look up
a working command or path instead of rediscovering it.

**Insight** — `draft` &rarr; `confirmed`
Requires `assumed` and `corrected` — what you believed, and what turned out to
be true.

**Question** — states: `asked`, `researching`, `escalated`, `answered`

**Discussion** — `active` &rarr; `resolved`
Collaborative exploration through threaded comments. Participation is implicit
in comment authorship; Docket does not maintain a separate participant roster.
A summary comment recording decisions, next steps, and open questions is a
recommended convention rather than an enforced transition rule.

**KB** — `draft` &rarr; `active` &rarr; `archived`
Reference material with no lifecycle of its own.

**Skill** — `draft` &rarr; `active` &rarr; `archived`
A reusable procedure an agent can retrieve and follow.

**Prompt** — `draft` &rarr; `active` &rarr; `archived`
A stored prompt template.

**Policy** — `draft` &rarr; `proposed` &rarr; `active` &rarr; `suspended` &rarr; `archived`
A standing rule that governs how work is done, rather than a unit of work
itself. The longer lifecycle is the point: policies get proposed and reviewed
before taking effect, and can be suspended without being discarded — so a rule
that is temporarily lifted stays on the record with its history intact.

### Vault and legacy encrypted items

New MCP vault entries are handle-based and do not have an item state machine.
Replacing a value archives the previous encrypted value; version history can be
decrypted on demand.

Older projects may contain **Secret** (`active`, `rotated`, `revoked`) or
**Encrypted Note** (`draft`, `sealed`) work items. Those schema definitions and
GUI fields remain for compatibility. Vault values use AES-256-CBC with
HMAC-SHA256 and optional secondary-password double encryption.

### Owned versus standalone entries

A vault entry either belongs to a work item or stands alone, and the two behave
differently:

- **Owned** — the encrypted value behind a Secret or Encrypted Note work item.
  It has a title, status, comments and history, and appears in the item list.
- **Standalone** — created over MCP with `docket_secret_set`, typically by an
  agent. A handle and a value, with no work item behind it.

Standalone entries have no row in the item table, so they cannot appear in the
query grid. **File > Vault** lists them, and `docket_secret_promote` converts one
into a tracked Secret item without decrypting or re-entering the value.

Ownership is recorded explicitly rather than inferred from the handle text, so an
agent cannot overwrite an item's encrypted value by choosing a colliding handle —
that is refused. Replacing a value over MCP now archives the previous one, as the
GUI has always done.

## Concurrent Access and Multi-Machine Use

For JSONL-backed projects, the `.dct` file is canonical and the SQLite
`.dct.cache` is disposable. Every mutation rewrites the complete `.dct` through
a temporary file and rename.

Because a write rewrites the entire file from cache, a cache that has gone stale would overwrite whatever landed on disk in the meantime. Docket therefore re-checks the file's fingerprint (size + mtime) before every MCP tool call and on each GUI poll tick, and rebuilds the cache from the `.dct` when it changed. This is what makes `git pull` safe while Docket is running.

Two consequences worth knowing:

- **Fingerprint granularity.** Staleness is detected by size + mtime, and mtime has 1-second resolution. An external write in the same second as Docket's own write that leaves the file exactly the same size can be missed. Use `docket_reload` (or **File > Reload from Disk**) if you suspect this.
- **The lock is advisory and best-effort.** Lock creation is not an operating
  system atomic-create primitive, and the current writer proceeds after a lock
  timeout. It reduces ordinary overlap but is not a correctness boundary.
- **Last writer wins within a file.** Two processes writing the same `.dct`
  concurrently still serialize whole-file snapshots. For genuinely concurrent
  editing, let Git mediate: commit on each machine and merge.

### Merging across machines

`.dct` files are line-oriented and deterministically sorted, so ordinary `git merge` handles them without any merge driver, `.gitattributes`, or per-clone configuration.

When git does leave conflict markers, Docket **refuses to open the file** rather than silently dropping the markers and unioning both sides. Resolve the conflict, then check the result before committing:

```bash
godot --headless --path . -- validate --file mydocket.dct
```

`validate` reports unresolved conflict markers, malformed lines, duplicate item IDs, and dangling references, and exits non-zero on error — so it can gate a commit. The same check is available over MCP as `docket_validate`.

Event ordering survives merges: events are read and written in timestamp order, so a merge that interleaved event lines "ours before theirs" does not permanently reorder an item's history.

## Testing

```bash
./run_tests.sh
# or
godot --headless --path . -- test
```

The repository currently contains 500+ tests across the registered test classes,
covering the data model, state machines, SQLite and JSONL layers, migration,
attachments, HTTP/MCP handling, tools, vault behavior, and end-to-end flows.

## Project Structure

```
scripts/
  main.gd                   CLI entry point & mode routing
  core/
    docket_db.gd             SQLite backend (all CRUD, queries, hints, attachments)
    data_model.gd            Item factory & validation
    state_machine.gd         Type-specific state transitions
    docket_db_jsonl.gd        JSONL-backed write-through database
    jsonl_*.gd                Parser, serializer, cache, migration, validation
    migration.gd              Legacy monolithic JSON -> SQLite converter
    app_state.gd             GUI state container
  mcp/
    http_server.gd           TCP/HTTP server
    mcp_handler.gd           JSON-RPC 2.0 router
  tools/
    tool_registry.gd         Tool dispatcher
    docket_*.gd              One file per MCP tool
  ui/
    app_shell.gd             Top-level layout
    query_grid.gd            Filterable item table
    record_form.gd           Item detail form
data/
  schema.json                Schema source of truth (types, states, fields)
addons/
  godot-sqlite/              GDExtension for SQLite (MIT, 2shady4u)
test/
  test_runner.gd             Test discovery & runner
  test_*.gd                  Test classes
```

## License

Docket is licensed under the **Mozilla Public License 2.0** — see [LICENSE](LICENSE).

Copyright (c) 2026 Imran Peerbhai.

MPL-2.0 is file-level copyleft. In practice:

- **You may embed Docket in a proprietary product.** Combining it with your own
  code in a larger work does not require you to open-source that work.
- **If you modify a Docket source file, publish that file's source.** Improvements
  to Docket itself flow back; your surrounding code stays yours.
- **Keep the copyright and license notices intact.** That is the attribution.

### Third-party

Full component inventory with pinned commits: [docs/SBOM.md](docs/SBOM.md).

| Component | License | Copyright |
|-----------|---------|-----------|
| [godot-sqlite](https://github.com/2shady4u/godot-sqlite) | MIT | Piet Bronders & Jeroen De Geeter |
| [godot-cpp](https://github.com/godotengine/godot-cpp) | MIT | Godot Engine contributors |
| [Godot Engine](https://godotengine.org) | MIT | Juan Linietsky, Ariel Manzur & contributors |
