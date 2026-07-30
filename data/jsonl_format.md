# Docket JSONL Format Specification

**Version:** 1.0.0
**Status:** Draft
**Date:** 2026-07-28

---

## 1. Overview

A `.dct` file is the canonical text representation of a JSONL-backed Docket
project. Each line is a self-contained JSON object with a `_type` discriminator
field. The file is designed to be committed to Git: diffable, mergeable, and
human-readable.

The adjacent SQLite cache is disposable and rebuilt from the `.dct` source.

### 1.1 File Extension

- Canonical file: `<project>.dct`
- Cache file: `<project>.dct.cache` (SQLite, gitignored)
- Lock file: `<project>.dct.lock` (advisory; contains owner PID and timestamp)

### 1.2 Encoding

- UTF-8, no BOM
- One JSON object per line (no pretty-printing, no trailing commas)
- Lines terminated by `\n` (LF, not CRLF)
- File MUST end with a final `\n`

---

## 2. Line Types and Ordering

Every line is a JSON object containing at minimum a `_type` field. Lines appear in the following deterministic order:

| Order | `_type`            | Cardinality | Description |
|------:|--------------------|-------------|-------------|
|     1 | `meta`             | Exactly 1   | File header / project metadata |
|     2 | `item`             | 0..N        | Work items (bugs, DCRs, chores, etc.) |
|     3 | `event`            | 0..N        | Item lifecycle events |
|     4 | `comment`          | 0..N        | Item comments (threaded) |
|     5 | `link`             | 0..N        | Directed relationships between items |
|     6 | `attachment`       | 0..N        | File attachments (base64-encoded data) |
|     7 | `secret`           | 0..N        | Encrypted secret values |
|     8 | `secret_version`   | 0..N        | Archived secret rotation history |
|     9 | `saved_query`      | 0..N        | Named saved queries |

**Rationale:** Meta first gives parsers the format version before any data. Items before their dependents (events, comments, links, attachments) enables single-pass cache loading with forward references resolved at the end.

---

## 3. Sort Order Within Each Type

Deterministic sort order is critical: the same logical data must always produce byte-identical output. All sort keys use **ascending lexicographic order** unless noted.

| `_type`            | Primary sort key       | Secondary sort key |
|--------------------|------------------------|--------------------|
| `meta`             | (singleton, no sort)   | -- |
| `item`             | `id`                   | -- |
| `event`            | `item_id`              | `seq` |
| `comment`          | `item_id`              | `id` |
| `link`             | `from_id`              | `to_id`, then `relation` |
| `attachment`       | `item_id`              | `id` |
| `secret`           | `handle`               | -- |
| `secret_version`   | `handle`               | `version` (ascending numeric) |
| `saved_query`      | `name`                 | -- |

---

## 4. Null and Empty Field Handling

**Rule: Omit null, empty-string, zero-integer, and empty-array fields.**

Fields with the following values MUST be omitted from the JSON line:
- `null`
- `""` (empty string)
- `0` (zero integer, including `priority`, `severity`, `retrieval_count`,
  `research_cost`, `quality`, `customised`, and `deprecated`)
- `[]` (empty array, including `tags`, `tool_deps`, and `unsatisfied_deps`)
- `{}` (empty object, including `optimization` and `pristine_content`)
- `false` for optional boolean flags

**Always-present fields** (never omitted, even if empty):
- Items: `_type`, `id`, `type`, `status`, `title`, `created_at`, `updated_at`
- Events: `_type`, `item_id`, `seq`, `event_type`, `timestamp`
- Comments: `_type`, `id`, `item_id`, `created_at`
- Links: `_type`, `from_id`, `to_id`, `relation`
- Attachments: `_type`, `id`, `item_id`, `filename`, `data`, `created_at`
- Secrets: `_type`, `handle`, `ciphertext`, `iv`, `mac`, `created_at`, `updated_at`
- Secret versions: `_type`, `handle`, `version`, `ciphertext`, `iv`, `mac`, `created_at`
- Saved queries: `_type`, `name`, `query`
- Meta: `_type`, `version`, `counter`, `id_prefix`

This matches the existing `_strip_empty()` semantics in `docket_db.gd`.

---

## 5. Line Schemas

### 5.1 `meta`

The first line of the file. Contains project-level configuration and vault parameters.

```json
{
  "_type": "meta",
  "version": "1.0.0",
  "counter": 42,
  "id_prefix": "MNV",
  "project": "minerva",
  "vault_salt": "<base64>",
  "vault_verify": "<base64>",
  "vault_kdf_iterations": 600000,
  "project_stage": "experiment",
  "project_hypothesis": "A Git-native tracker improves human-agent continuity",
  "project_success_criteria": "Used for all project work for 30 days"
}
```

| Field                       | Type    | Required | Description |
|-----------------------------|---------|----------|-------------|
| `_type`                     | string  | yes      | Always `"meta"` |
| `version`                   | string  | yes      | JSONL format version (semver). Current: `"1.0.0"` |
| `counter`                   | integer | yes      | Legacy sequential-ID counter |
| `id_prefix`                 | string  | yes      | Legacy sequential-ID prefix (for example, `"MNV"`) |
| `project`                   | string  | no       | Human-readable project name |
| `vault_salt`                | string  | no       | Base64-encoded vault salt |
| `vault_verify`              | string  | no       | Base64-encoded vault verification hash |
| `vault_kdf_iterations`      | integer | no       | PBKDF2 iteration count used to derive this vault's key |
| `project_stage`             | string  | no       | Project lifecycle stage |
| `project_hypothesis`        | string  | no       | Hypothesis the project is testing |
| `project_success_criteria`  | string  | no       | Definition of project success |
| `project_promoted_to`       | string  | no       | Destination when a project is promoted |

Readers MUST preserve unknown metadata fields so later format revisions can add
project-level data without making old files unreadable.

### 5.2 `item`

One line per work item. Tags are embedded as an array (they always change with the item).

```json
{
  "_type": "item",
  "id": "019706a1b2c3d4e5f6a7b8c9d0e1f2a3",
  "type": "bug",
  "status": "active",
  "title": "Crash on startup with empty config",
  "description": "Steps to reproduce...",
  "created_at": "2026-03-15T10:30:00Z",
  "updated_at": "2026-03-20T14:22:00Z",
  "created_by": "imran",
  "assigned_to": "imran",
  "priority": 2,
  "severity": 1,
  "tags": ["crash", "config"],
  "environment": "Linux 6.8",
  "resolution": "fixed",
  "parent": "minerva:MNV-0012"
}
```

| Field                   | Type     | Required | Notes |
|-------------------------|----------|----------|-------|
| `_type`                 | string   | yes      | Always `"item"` |
| `id`                    | string   | yes      | UUID7 hex (32 chars) or legacy `PREFIX-NNNN` |
| `type`                  | string   | yes      | Creatable type: `bug`, `dcr`, `rca`, `chore`, `hint`, `insight`, `question`, `work_item`, `test`, `discussion`, `skill`, `prompt`, `kb`, or `policy`. Readers also accept legacy `secret` and `encrypted_note` items |
| `status`                | string   | yes      | Current state (type-specific, from schema transitions) |
| `title`                 | string   | yes      | Item title (always present even if empty string) |
| `created_at`            | string   | yes      | ISO 8601 UTC timestamp |
| `updated_at`            | string   | yes      | ISO 8601 UTC timestamp |
| `description`           | string   | no       | Free-text description |
| `created_by`            | string   | no       | Creator identifier |
| `assigned_to`           | string   | no       | Assignee identifier |
| `directed_to`           | string   | no       | Directed-to identifier |
| `priority`              | integer  | no       | 1-4 (omit if 0) |
| `severity`              | integer  | no       | 1-4 (omit if 0) |
| `tags`                  | string[] | no       | Tag array (omit if empty) |
| `parent`                | string   | no       | Parent item ref (bare ID or `project:ID`) |
| `resolution`            | string   | no       | Bug resolution: `fixed`, `wont_fix`, `by_design`, `duplicate`, `not_repro` |
| `environment`           | string   | no       | Environment description |
| `repro_steps`           | string   | no       | Bug reproduction steps |
| `assumed`               | string   | no       | Insight: what was assumed |
| `corrected`             | string   | no       | Insight: the correction |
| `findings`              | string   | no       | Question: research findings |
| `answer`                | string   | no       | Question: final answer |
| `occurred_at`           | string   | no       | RCA: when the incident occurred (ISO 8601) |
| `detected_at`           | string   | no       | RCA: when detected (ISO 8601) |
| `reported_at`           | string   | no       | RCA: when reported (ISO 8601) |
| `why_chain`             | string   | no       | RCA: chain of "why" analysis |
| `significant_events`    | string   | no       | RCA: significant events timeline |
| `contributing_factors`  | string   | no       | RCA: contributing factors |
| `value`                 | string   | no       | Hint: the hint value |
| `component`             | string   | no       | Hint/Test: component name |
| `key`                   | string   | no       | Hint/Secret: lookup key |
| `topic`                 | string   | no       | Hint/Insight: topic |
| `subtopic`              | string   | no       | Hint/Insight: subtopic |
| `confidence`            | string   | no       | Hint/Insight: confidence level |
| `surprise`              | string   | no       | Insight: surprise level |
| `surfaced_from`         | string   | no       | Insight/Secret: source |
| `retrieval_count`       | integer  | no       | Hint/Insight: times retrieved (omit if 0) |
| `research_cost`         | integer  | no       | Hint/Insight: cost to discover (omit if 0) |
| `blocked_by`            | string   | no       | Work item: blocking reference |
| `test_setup`            | string   | no       | Test: setup instructions |
| `test_steps`            | string   | no       | Test: step-by-step procedure |
| `expected_result`       | string   | no       | Test: expected outcome |
| `quality`               | integer  | no       | Knowledge quality score, -5 through +5 |
| `last_reviewed`         | string   | no       | Knowledge review timestamp |
| `command`               | string   | no       | Legacy knowledge command field |
| `usage`                 | string   | no       | Legacy knowledge usage field |
| `prompt_text`           | string   | no       | Prompt or skill content |
| `preconditions`         | string   | no       | Preconditions for a reusable procedure |
| `summary`               | string   | no       | Short knowledge summary |
| `article`               | string   | no       | KB article body |
| `parameters`            | string   | no       | Prompt parameters |
| `steps`                 | string   | no       | Skill or policy steps |
| `outcome`               | string   | no       | Expected procedure outcome |
| `target`                | string   | no       | Model-targeting expression |
| `tool_deps`             | string[] | no       | Tools required by a skill |
| `optimization`          | object   | no       | Skill runtime optimization profile |
| `source`                | string   | no       | Knowledge or plugin origin |
| `customised`            | integer  | no       | Nonzero when plugin-seeded content was customized |
| `pristine_hash`         | string   | no       | Hash of original plugin content |
| `pristine_content`      | object   | no       | Original plugin-provided record |
| `unsatisfied_deps`      | string[] | no       | Skill dependencies that cannot be resolved |
| `deprecated`            | integer  | no       | Nonzero when upstream deprecated a seeded skill |

### 5.3 `event`

One line per lifecycle event. Events are separate from items to minimize merge conflicts when concurrent agents append events to the same item.

```json
{
  "_type": "event",
  "item_id": "019706a1b2c3d4e5f6a7b8c9d0e1f2a3",
  "seq": 1,
  "event_type": "created",
  "actor": "imran",
  "timestamp": "2026-03-15T10:30:00Z",
  "note": "Item created"
}
```

| Field        | Type    | Required | Notes |
|--------------|---------|----------|-------|
| `_type`      | string  | yes      | Always `"event"` |
| `item_id`    | string  | yes      | Parent item ID |
| `seq`        | integer | yes      | 1-based sequence number within the item (from SQLite autoincrement order) |
| `event_type` | string  | yes      | Event type: `created`, `status_changed`, `updated`, `comment_added`, `comment_reply`, `comment_accepted`, `comment_rejected`, `moved`, etc. |
| `timestamp`  | string  | yes      | ISO 8601 UTC timestamp |
| `actor`      | string  | no       | Who triggered the event |
| `note`       | string  | no       | Human-readable note |

**`seq` field:** The SQLite `item_events` table uses an autoincrement `id` column. When serializing to JSONL, events for each item are numbered sequentially starting at 1. This provides a stable, item-local ordering without exposing database-internal IDs. On import, `seq` determines insertion order and the database assigns its own autoincrement IDs.

### 5.4 `comment`

One line per comment. Thread structure is expressed via `parent_id`.

```json
{
  "_type": "comment",
  "id": 7,
  "item_id": "019706a1b2c3d4e5f6a7b8c9d0e1f2a3",
  "author": "imran",
  "text": "I can reproduce this on Linux.",
  "status": "open",
  "created_at": "2026-03-16T09:00:00Z",
  "parent_id": 5,
  "resolved_at": "2026-03-17T11:00:00Z",
  "resolved_by": "dana"
}
```

| Field         | Type    | Required | Notes |
|---------------|---------|----------|-------|
| `_type`       | string  | yes      | Always `"comment"` |
| `id`          | integer | yes      | Comment ID (autoincrement, unique within file). Stable across roundtrips |
| `item_id`     | string  | yes      | Parent item ID |
| `created_at`  | string  | yes      | ISO 8601 UTC timestamp |
| `author`      | string  | no       | Comment author |
| `text`        | string  | no       | Comment body |
| `status`      | string  | no       | `"open"`, `"accepted"`, or `"rejected"`. Omit if `"open"` |
| `parent_id`   | integer | no       | Parent comment ID for threading. Omit if 0 (top-level) |
| `resolved_at` | string  | no       | ISO 8601 UTC timestamp of resolution |
| `resolved_by` | string  | no       | Who resolved the comment |

**Note:** Comment `id` values are preserved across roundtrips (SQLite autoincrement `id` is written directly). `parent_id` references another comment's `id` within the same item.

### 5.5 `link`

One line per directed relationship between items.

```json
{
  "_type": "link",
  "from_id": "019706a1b2c3d4e5f6a7b8c9d0e1f2a3",
  "to_id": "019706b2c3d4e5f6a7b8c9d0e1f2a3b4",
  "relation": "blocks"
}
```

| Field      | Type   | Required | Notes |
|------------|--------|----------|-------|
| `_type`    | string | yes      | Always `"link"` |
| `from_id`  | string | yes      | Source item ID |
| `to_id`    | string | yes      | Target item ID (may be cross-project qualified: `"project:ID"`) |
| `relation` | string | yes      | One of: `caused_by`, `blocks`, `duplicates`, `follow_up`, `surfaced` |

### 5.6 `attachment`

One line per attachment. Binary data is base64-encoded.

```json
{
  "_type": "attachment",
  "id": 3,
  "item_id": "019706a1b2c3d4e5f6a7b8c9d0e1f2a3",
  "filename": "screenshot.png",
  "mime_type": "image/png",
  "size_bytes": 24576,
  "data": "<base64-encoded bytes>",
  "created_at": "2026-03-16T09:15:00Z",
  "description": "Error dialog screenshot"
}
```

| Field         | Type    | Required | Notes |
|---------------|---------|----------|-------|
| `_type`       | string  | yes      | Always `"attachment"` |
| `id`          | integer | yes      | Attachment ID (autoincrement, stable across roundtrips) |
| `item_id`     | string  | yes      | Parent item ID |
| `filename`    | string  | yes      | Original filename |
| `data`        | string  | yes      | Base64-encoded file content (standard alphabet, no line breaks) |
| `created_at`  | string  | yes      | ISO 8601 UTC timestamp |
| `mime_type`   | string  | no       | MIME type. Omit if `"application/octet-stream"` |
| `size_bytes`  | integer | no       | Original file size in bytes. Omit if 0 |
| `description` | string  | no       | Human-readable description |

### 5.7 `secret`

One line per encrypted secret. All binary cryptographic material is base64-encoded.

```json
{
  "_type": "secret",
  "handle": "019706a1b2c3d4e5f6a7b8c9d0e1f2a3",
  "ciphertext": "<base64>",
  "iv": "<base64>",
  "mac": "<base64>",
  "created_at": "2026-03-15T10:30:00Z",
  "updated_at": "2026-03-20T14:22:00Z",
  "requires_2fa": true
}
```

| Field          | Type    | Required | Notes |
|----------------|---------|----------|-------|
| `_type`        | string  | yes      | Always `"secret"` |
| `handle`       | string  | yes      | Secret handle. For an owned entry this is the item ID, or `"<id>:notes"` for encrypted notes. A standalone entry may use any handle |
| `ciphertext`   | string  | yes      | Base64-encoded ciphertext |
| `iv`           | string  | yes      | Base64-encoded initialization vector |
| `mac`          | string  | yes      | Base64-encoded message authentication code |
| `created_at`   | string  | yes      | ISO 8601 UTC timestamp |
| `updated_at`   | string  | yes      | ISO 8601 UTC timestamp |
| `requires_2fa` | boolean | no       | Omit if `false`. Legacy field name: when `true`, a secondary password is required for double decryption; this is not a separate authentication factor |
| `owner_item_id`| string  | no       | Work item this secret belongs to. Omit for a standalone entry (typically created over MCP). Owned entries are keyed by item ID, so a reader that predates this field can re-derive it from `handle` |

### 5.8 `secret_version`

One line per archived secret rotation. Sorted by handle, then version ascending.

```json
{
  "_type": "secret_version",
  "handle": "019706a1b2c3d4e5f6a7b8c9d0e1f2a3",
  "version": 1,
  "ciphertext": "<base64>",
  "iv": "<base64>",
  "mac": "<base64>",
  "created_at": "2026-03-18T08:00:00Z",
  "rotated_by": "imran"
}
```

| Field        | Type    | Required | Notes |
|--------------|---------|----------|-------|
| `_type`      | string  | yes      | Always `"secret_version"` |
| `handle`     | string  | yes      | Secret handle (matches a `secret` line's `handle`) |
| `version`    | integer | yes      | Version number (1-based, ascending) |
| `ciphertext` | string  | yes      | Base64-encoded ciphertext |
| `iv`         | string  | yes      | Base64-encoded IV |
| `mac`        | string  | yes      | Base64-encoded MAC |
| `created_at` | string  | yes      | ISO 8601 UTC timestamp when this version was archived |
| `rotated_by` | string  | no       | Who performed the rotation |

### 5.9 `saved_query`

One line per named saved query. The `query` field is an embedded JSON object (not a string).

```json
{
  "_type": "saved_query",
  "name": "open-bugs",
  "query": {"filter": {"type": "bug", "status__ne": "closed"}, "sort": [{"field": "priority", "dir": "asc"}]}
}
```

| Field   | Type   | Required | Notes |
|---------|--------|----------|-------|
| `_type` | string | yes      | Always `"saved_query"` |
| `name`  | string | yes      | Unique query name |
| `query` | object | yes      | Query definition as a JSON object (same schema accepted by `execute_query()`) |

---

## 6. Encoding Rules

### 6.1 Timestamps

All timestamps are **ISO 8601 UTC** strings: `YYYY-MM-DDTHH:MM:SSZ`.

- Always include the `T` separator and `Z` suffix
- Seconds precision (no sub-second digits)
- When reading files that contain non-UTC timestamps, convert to UTC on import
- Example: `"2026-03-15T10:30:00Z"`

### 6.2 Binary Data (base64)

All binary fields (`data`, `ciphertext`, `iv`, `mac`, `vault_salt`, `vault_verify`) use **standard base64** encoding (RFC 4648 Section 4, alphabet `A-Z a-z 0-9 + /`, `=` padding).

- No line breaks within the base64 string
- Attachment data is encoded directly; format version 1.0.0 does not define a
  compressed attachment encoding.

### 6.3 Text Fields

- JSON string escaping rules apply (backslash-escape `"`, `\`, control characters)
- Newlines within text fields are encoded as `\n` in the JSON string (standard JSON escaping)
- No additional escaping beyond standard JSON

### 6.4 Integer Fields

- Stored as JSON numbers (not strings): `"priority": 2`
- Integer fields: `counter`, `vault_kdf_iterations`, `id`, `seq`, `parent_id`,
  `version`, `size_bytes`, `priority`, `severity`, `retrieval_count`,
  `research_cost`, `quality`, `customised`, `deprecated`
- Boolean fields: stored as JSON `true`/`false` (only `requires_2fa` currently)

### 6.5 JSON Key Order

Within each line, keys MUST be serialized in the order they appear in the schema tables in Section 5 (i.e., `_type` first, then fields in the order listed). This ensures byte-identical output from conforming writers.

---

## 7. Transition Log and Error Log

The `transition_log` and `mcp_error_log` tables are **NOT serialized** to JSONL. They are diagnostic/telemetry data local to the SQLite cache:

- `transition_log`: records of failed state transitions (for the transition report)
- `mcp_error_log`: records of MCP tool errors (for the error report)

These tables are rebuilt as needed during normal operation and do not need to survive a cache rebuild. They are ephemeral by nature.

---

## 8. Concurrency

### 8.1 File-Level Locking

Writers MUST acquire an advisory lock before modifying the JSONL file:

1. Atomically create `<file>.lock` (fail if exists)
2. Write the complete JSONL file (atomic rename from temp file)
3. Remove the lock file

### 8.2 Atomic Writes

The JSONL file MUST be written atomically:

1. Write to a temporary file in the same directory: `<file>.tmp.<pid>`
2. `fsync` the temporary file
3. Rename the temporary file to the target path (atomic on POSIX)

This ensures readers never see a partial file.

---

## 9. Version Evolution

The `meta.version` field uses semver:

- **Patch** (1.0.x): new optional fields added to existing line types. Old readers ignore unknown fields.
- **Minor** (1.x.0): new `_type` values added. Old readers skip unknown `_type` lines.
- **Major** (x.0.0): breaking changes to existing field semantics or required fields.

**Unknown fields within known types MUST be preserved, not merely ignored.** A
reader that also writes must round-trip them; dropping a field it does not model
deletes data on the next flush.

**Unknown `_type` values MUST be refused, not skipped.** This is a deliberate
departure from "skip and continue", and the reason is that Docket is not a
read-only reader: every mutation rewrites the entire file from cache. A line the
writer cannot reproduce is a line the next flush removes, so "skipping" an
unknown record silently destroys it — the opposite of forward compatibility.

The practical consequence is that a **minor** version bump is not transparent to
older readers: they will refuse the file with a clear error rather than quietly
truncating it. That is the intended trade. Refusing is recoverable; silent
deletion of a record nobody knew was there is not.

Writers introducing a new `_type` MUST bump `meta.version` accordingly so the
refusal message can name the cause.

---

## 10. Roundtrip Guarantee

The format guarantees perfect roundtrip fidelity:

```
SQLite DB  -->  serialize to JSONL  -->  parse JSONL  -->  rebuild SQLite cache
```

The rebuilt SQLite cache MUST produce identical query results to the original database for all item data, events, comments, links, attachments, secrets, secret versions, saved queries, and metadata. The only exceptions are:

- **Autoincrement IDs for events:** SQLite `item_events.id` is not preserved. The `seq` field preserves ordering within each item. On import, events are inserted in `(item_id, seq)` order and receive new autoincrement IDs.
- **Autoincrement IDs for links:** SQLite `item_links.id` is not preserved. Links are identified by `(from_id, to_id, relation)`.
- **Transition log and error log:** Not serialized (Section 7).
- **SQLite-internal state:** WAL files, page layout, rowid gaps.

Comment `id` and attachment `id` values ARE preserved across roundtrips since they are referenced by other data (comment `parent_id` threading).

---

## 11. Complete Example

```jsonl
{"_type":"meta","version":"1.0.0","counter":3,"id_prefix":"MNV","project":"minerva"}
{"_type":"item","id":"MNV-0001","type":"bug","status":"active","title":"Crash on empty config","description":"App crashes when config file is missing.","created_at":"2026-03-15T10:30:00Z","updated_at":"2026-03-20T14:22:00Z","created_by":"imran","assigned_to":"imran","priority":2,"severity":1,"tags":["crash","config"],"environment":"Linux 6.8"}
{"_type":"item","id":"MNV-0002","type":"chore","status":"open","title":"Update dependencies","created_at":"2026-03-16T08:00:00Z","updated_at":"2026-03-16T08:00:00Z","created_by":"imran","tags":["maintenance"]}
{"_type":"item","id":"MNV-0003","type":"hint","status":"draft","title":"Build command","created_at":"2026-03-17T12:00:00Z","updated_at":"2026-03-17T12:00:00Z","value":"scons platform=linux","component":"build","key":"run"}
{"_type":"event","item_id":"MNV-0001","seq":1,"event_type":"created","actor":"imran","timestamp":"2026-03-15T10:30:00Z","note":"Item created"}
{"_type":"event","item_id":"MNV-0001","seq":2,"event_type":"status_changed","actor":"imran","timestamp":"2026-03-16T09:00:00Z","note":"new -> triaged"}
{"_type":"event","item_id":"MNV-0001","seq":3,"event_type":"status_changed","actor":"imran","timestamp":"2026-03-18T11:00:00Z","note":"triaged -> active"}
{"_type":"event","item_id":"MNV-0001","seq":4,"event_type":"comment_added","actor":"dana","timestamp":"2026-03-19T15:30:00Z","note":"I can reproduce this on"}
{"_type":"event","item_id":"MNV-0002","seq":1,"event_type":"created","actor":"imran","timestamp":"2026-03-16T08:00:00Z","note":"Item created"}
{"_type":"event","item_id":"MNV-0003","seq":1,"event_type":"created","timestamp":"2026-03-17T12:00:00Z","note":"Item created"}
{"_type":"comment","id":1,"item_id":"MNV-0001","author":"dana","text":"I can reproduce this on Linux 6.8 and 6.10.","created_at":"2026-03-19T15:30:00Z"}
{"_type":"comment","id":2,"item_id":"MNV-0001","author":"imran","text":"Thanks, I'll look into it.","created_at":"2026-03-19T16:00:00Z","parent_id":1}
{"_type":"link","from_id":"MNV-0002","to_id":"MNV-0001","relation":"follow_up"}
{"_type":"saved_query","name":"open-bugs","query":{"filter":{"type":"bug","status__ne":"closed"},"sort":[{"field":"priority","dir":"asc"}]}}
```

---

## 12. Design Rationale

### Why separate lines for events, comments, and links?

When two agents concurrently add events or comments to the same item, nested structures create unavoidable merge conflicts (both sides modify the same JSON array on the same line). Separate lines allow Git's line-based merge to auto-resolve most concurrent appends: each new event/comment is a new line, and Git can merge additions from both branches as long as they don't touch the same line.

### Why embed tags in item lines?

Tags change when the item changes (they are part of the "update item" operation). Keeping them as a separate line type would double the lines touched on every tag edit and add no merge benefit -- tag conflicts always co-occur with item field conflicts.

### Why omit empty fields?

Conciseness (lines are shorter, diffs are cleaner) and merge-friendliness (fewer fields means fewer potential conflict points). The always-present fields provide enough structure for human readability.

### Why deterministic key order?

Without deterministic key order, logically identical data can produce different byte sequences, causing spurious Git diffs. Deterministic ordering ensures that `serialize(parse(file)) == file` for a conforming writer.
