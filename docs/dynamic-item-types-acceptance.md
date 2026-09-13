# Dynamic item types acceptance walkthrough

This is a post-review manual check. It describes expected results; it is not an execution record. Use only disposable files and the reviewed build.

## Setup and MCP helper

Create two new projects in the GUI with **File > New Docket**, for example `/tmp/docket-accept/alpha.dct` and `beta.dct`, then add both to the same window. New files should report format `2.0.0` and use adjacent `.v2.cache` files.

Start a separate disposable server:

```bash
docket --headless -- serve --port 3010 --file /tmp/docket-accept/alpha.dct
```

Use this helper for the exact JSON-RPC envelope:

```bash
mcp () {
  curl --fail-with-body -sS http://127.0.0.1:3010/mcp \
    -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg n "$1" --argjson a "$2" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$n,arguments:$a}}')"
}
tool_json () { mcp "$1" "$2" | jq -r '.result.content[0].text' | jq .; }
DEF=$(jq -c . test/fixtures/code_review_definition.json)
```

Every successful response should contain a JSON-RPC `result`; tool failures should be returned as tool error content and must not change the file.

## Define, inspect, and activate

```bash
tool_json docket_type_validate "$(jq -cn --argjson d "$DEF" '{project:"alpha",slug:"code_review",definition:$d}')"
tool_json docket_type_define "$(jq -cn --argjson d "$DEF" '{project:"alpha",slug:"code_review",definition:$d,author:"acceptance",reason:"review workflow"}')"
tool_json docket_type_list '{"project":"alpha","search":"review"}'
tool_json docket_type_get '{"project":"alpha","type":"code_review"}'
```

Expect validation to report `valid:true`, define to return a draft with a stable type ID and full revision ID, list to return one compact match, and get to return the complete fields, strict lifecycle, guards, and provenance. Save the returned current revision:

```bash
REV=$(tool_json docket_type_get '{"project":"alpha","type":"code_review"}' | jq -r '.current_revision')
tool_json docket_type_activate "$(jq -cn --arg r "$REV" '{project:"alpha",type:"code_review",action:"activate",expected_revision:$r,author:"acceptance",reason:"definition reviewed"}')"
```

In the GUI choose **File > Project Types...**, select `alpha`, and use **Search names, slugs, descriptions, and guidance**. Verify alphabetical results, purpose text, zero-item Code Review, and that **Show deprecated** is explicit. Selecting Code Review should show **Display label**, **Description**, **Use when**, the complete **Fields and lifecycle JSON**, and **Immutable revision history and provenance**. The active revision and ratification should match MCP. A stale `expected_revision` activation should be refused.

## Generated creation and editing

Choose **File > New...**, use **Search type name, purpose, or slug**, and create Code Review. The form should render controls for `revision`, `reviewer`, and `findings_summary`, including descriptor help. Create with title `Review A`, revision `abc123`, and reviewer `sam`; expect status `requested`, a pinned type revision, and no raw-JSON-only item workflow.

Edit reviewer and save with **Save Changes**. Reopen the result and verify values remain under the generated controls. Comments, attachments, hierarchy, and **Transitions & Events** must remain usable. There must be no direct type-change control for this registry item.

From MCP, query the same item with its returned stable type ID:

```bash
TYPE_ID=$(tool_json docket_type_get '{"project":"alpha","type":"code_review"}' | jq -r '.id')
tool_json docket_query "$(jq -cn --arg t "$TYPE_ID" '{project:"alpha",filter:{field_key:"reviewer",type_id:$t,op:"eq",value:"sam"},sort:[{field_key:"revision",type_id:$t,dir:"asc",nulls:"last"}]}')"
```

In Query mode, select Code Review through the searchable type chooser. Verify project, count, and purpose; searching must retain alphabetical order and selection. Add its reviewer condition, a grouped status, and a typed sort. Open **Columns...** and select custom plus derived columns. Expect the same item and correct `state_category`, `state_outcome`, and `is_terminal`; `skill.outcome` remains ordinary content.

## Atomic transition behavior

Attempt `requested` directly to `approved`; strict lifecycle must refuse even with a note. Transition to `reviewing`. Clear required `revision` and attempt approval while adding `findings_summary`; expect refusal with no field, status, comment, or event change. Restore revision, enter findings, and approve. The pending generated edits, transition, and audit should appear together.

For a guided built-in off-flow transition, change an unsaved field and open **Reason required**. Cancel: expect no saved field or status change. Repeat and confirm: expect both together. While that dialog is open, change the same backend item through MCP. Confirmation should report a stale conflict and retain the form edits for review.

Modify the open item externally again. On polling, **Item changed on disk** should offer **Load from disk** and **Keep my edits**. Keep preserves the form; load deliberately replaces it. Switching projects with unsaved type-definition edits should likewise require deliberate discard or preserve them.

## Evolution and selected repin

In **Project Types**, select Code Review and add this optional descriptor to **Fields and lifecycle JSON**:

```json
{"key":"review_url","type":"string","required":false,"nullable":true,"help":"Review page URL"}
```

Enter the created item ID in **Repin item IDs (optional)**, an author and reason, then use **Validate preview**. Expect a compatible preview naming one selected item and saved-query impact. **Save draft / evolve** should create a child revision, advance the current pointer, repin only the selected item, and record an audit event. The generated form and Query **Columns...** should expose `review_url`. Unselected historical items retain their old meaning.

## Cache rebuild comparison

Record `docket_type_get`, `docket_get`, query output, comments, events, links, and attachment metadata. Stop Docket, delete only `alpha.dct.v2.cache` (and its `-wal`/`-shm` companions), reopen, and repeat. Definitions, pins, payload including false/zero/null/empty/Unicode/escapes, references, comments, events, and attachment bytes must agree semantically. JSON numbers may decode as integral floats; compare numeric value rather than runtime variant type.

## Project identity and duplicate IDs

Create an independently defined `code_review` in beta; its type ID must differ. Arrange the same item ID in both disposable projects (a retained source plus durable partial copy is one valid setup). Query both projects and open each result. The detail project label, edits, comments, attachments, child navigation, and transitions must target the selected row's project. A beta field/status binding must not match alpha solely because labels or slugs agree.

## Legacy upgrade

Copy a disposable valid 1.0 JSONL fixture and open it. In **File > Project Types...**, select it under **Legacy project upgrade**. Before acknowledgement, **Apply previewed upgrade** must refuse. Select **I confirm incompatible writers are stopped**, then **Preview JSONL 2.0 upgrade**. Expect item and starter-definition counts, rollback snapshot, and v2-cache path, with canonical bytes still unchanged. Apply the preview and expect the project to close/reopen with format 2.0, pinned items, preserved IDs/statuses, a backup, and `.v2.cache`; the old `.cache` must not authorize a stale read.

For SQLite, first use **Promote SQLite to JSONL** (or `docket --migrate-jsonl --file PATH`), verify the `.sqlite.bak`, and then perform the separate JSONL preview/apply. Keep Minerva and all incompatible writers stopped. After any post-upgrade edit, rollback must refuse rather than erase that edit.
