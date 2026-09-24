#!/usr/bin/env python3
"""
Docket MCP Server — Python FastMCP fallback for when Godot isn't running.

Read-only: it reads obsolete monolithic-JSON .dct files and changes nothing.
Changes to a project go through Docket itself, which coordinates its writes
with its other processes of the account; this server takes no part in that,
so it makes no changes. Its write tools say so.
"""

import json
import os
import glob
import fnmatch
from typing import Optional

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("docket")

def _find_dct_file(file: Optional[str] = None) -> str:
    if file:
        return file
    matches = glob.glob("*.dct")
    if matches:
        return matches[0]
    return "docket.dct"


class UnsupportedFormatError(RuntimeError):
    """Raised when asked to touch a .dct this server cannot safely handle."""


def _is_jsonl_dct(path: str) -> bool:
    """A canonical .dct is JSONL: the first line is a complete JSON object."""
    try:
        with open(path, encoding="utf-8") as f:
            first = f.readline().strip()
    except (OSError, UnicodeDecodeError):
        return False
    if not first.startswith("{") or not first.endswith("}"):
        return False
    try:
        return json.loads(first).get("_type") == "meta"
    except json.JSONDecodeError:
        return False


_JSONL_REFUSAL = (
    "{path} is a JSONL .dct; this fallback server reads only the older\n"
    "monolithic-JSON format. Use the Godot server instead:\n"
    "    godot --headless --path <docket-repo> -- serve --port 3010 --file {path}"
)


def _load_dct(path: str) -> dict:
    if not os.path.exists(path):
        return {"error": f"File not found: {path}"}
    # Refuse before reading. This server predates the JSONL format and speaks
    # only the obsolete monolithic-JSON layout; opening a JSONL file here either
    # raises or, worse, succeeds partially and is then written back flattened.
    if _is_jsonl_dct(path):
        raise UnsupportedFormatError(_JSONL_REFUSAL.format(path=path))
    with open(path) as f:
        return json.load(f)


_READ_ONLY = (
    "This fallback server is read-only. Make changes through Docket itself, "
    "which coordinates them with its other processes:\n"
    "    godot --headless --path <docket-repo> -- serve --port 3010 --file <project.dct>"
)


def _read_only() -> dict:
    return {"error": _READ_ONLY}


# =============================================================================
# Tools
# =============================================================================

@mcp.tool()
def docket_create(
    type: str,
    title: str,
    description: str = "",
    priority: int = 0,
    severity: int = 0,
    tags: Optional[list[str]] = None,
    assigned_to: str = "",
    directed_to: str = "",
    assumed: str = "",
    corrected: str = "",
    file: Optional[str] = None,
) -> dict:
    """Create a new work item. Types: bug, dcr, rca, chore, hint, insight, question, work_item. Refused here: this server is read-only."""
    return _read_only()


@mcp.tool()
def docket_get(id: str, file: Optional[str] = None) -> dict:
    """Get a single work item by ID."""
    path = _find_dct_file(file)
    data = _load_dct(path)
    if "error" in data:
        return data
    if id not in data.get("items", {}):
        return {"error": f"Item not found: {id}"}
    return {**data["items"][id], "id": id}


@mcp.tool()
def docket_update(id: str, file: Optional[str] = None, **kwargs) -> dict:
    """Update fields on an existing item. Not for state transitions. Refused here: this server is read-only."""
    return _read_only()


@mcp.tool()
def docket_transition(
    id: str, to: str, resolution: str = "", note: str = "",
    blocked_by: str = "", file: Optional[str] = None
) -> dict:
    """Transition an item to a new state. When transitioning to 'blocked', supply blocked_by. Refused here: this server is read-only."""
    return _read_only()


@mcp.tool()
def docket_query(
    filter: Optional[dict] = None,
    sort: Optional[list[dict]] = None,
    limit: int = 0,
    file: Optional[str] = None,
) -> dict:
    """Query work items with filtering, sorting, and limiting.
    Three filter formats: (1) flat dict {key: value, key__ne: value},
    (2) nested tree {$or: [...], $and: [...]},
    (3) conditions list {conditions: [{field, op, value, conj?}, ...]}.
    """
    path = _find_dct_file(file)
    data = _load_dct(path)
    if "error" in data:
        return data

    items = data.get("items", {})
    results = []
    filt = filter or {}

    for item_id, item in items.items():
        entry = {**item, "id": item_id}
        if "conditions" in filt:
            if _matches_conditions(entry, filt["conditions"]):
                results.append(entry)
        elif "$or" in filt or "$and" in filt:
            if _eval_tree(entry, filt):
                results.append(entry)
        else:
            if _matches(entry, filt):
                results.append(entry)

    if sort:
        for spec in reversed(sort):
            field = spec.get("field", "")
            rev = spec.get("dir", "asc") == "desc"
            results.sort(key=lambda x: (x.get(field) is None, x.get(field, "")), reverse=rev)

    if limit > 0:
        results = results[:limit]

    return {"items": results, "count": len(results)}


def _matches(item: dict, filt: dict) -> bool:
    """Old flat dict format matching."""
    for key, value in filt.items():
        if key == "tags_contains":
            if value not in item.get("tags", []):
                return False
        elif key.endswith("__ne"):
            field = key[:-4]
            if item.get(field) == value:
                return False
        elif key.endswith("__in"):
            field = key[:-4]
            if item.get(field) not in value:
                return False
        else:
            if item.get(key) != value:
                return False
    return True


def _eval_condition(item: dict, cond: dict) -> bool:
    """Evaluate a single {field, op, value} condition against an item."""
    field = cond.get("field", "")
    op = cond.get("op", "eq")
    value = cond.get("value")

    # Pseudo-field: has_attachment (not applicable in JSON format, always false)
    if field == "has_attachment":
        return not (value is True or str(value).lower() == "true")

    # Pseudo-field: tags
    if field == "tags":
        tags = item.get("tags", [])
        if op == "eq":
            return str(value) in tags
        elif op == "neq":
            return str(value) not in tags
        return True

    item_val = item.get(field, "")

    if op == "eq":
        return item_val == value
    elif op == "neq":
        return item_val != value
    elif op == "contains":
        return str(value).lower() in str(item_val).lower()
    elif op == "not_contains":
        return str(value).lower() not in str(item_val).lower()
    elif op == "like":
        pattern = str(value).replace(".", "?").replace("*", "*")
        return fnmatch.fnmatch(str(item_val), pattern)
    elif op in ("gt", "after"):
        return item_val > value if item_val is not None else False
    elif op in ("lt", "before"):
        return item_val < value if item_val is not None else False
    elif op == "gte":
        return item_val >= value if item_val is not None else False
    elif op == "lte":
        return item_val <= value if item_val is not None else False
    elif op == "is_empty":
        return not item_val
    elif op == "is_not_empty":
        return bool(item_val)
    return True


def _matches_conditions(item: dict, conditions: list) -> bool:
    """Evaluate a flat conditions list with AND-binds-tighter-than-OR precedence."""
    if not conditions:
        return True

    # Group by OR boundaries
    groups = []
    current_group = []
    for i, cond in enumerate(conditions):
        if i == 0:
            current_group.append(cond)
        elif cond.get("conj", "and").lower() == "or":
            groups.append(current_group)
            current_group = [cond]
        else:
            current_group.append(cond)
    groups.append(current_group)

    # OR between groups, AND within groups
    for group in groups:
        if all(_eval_condition(item, c) for c in group):
            return True
    return False


def _eval_tree(item: dict, tree: dict) -> bool:
    """Evaluate a nested $and/$or boolean tree."""
    if "$or" in tree:
        return any(
            _eval_tree(item, child) if ("$or" in child or "$and" in child) else _eval_condition(item, child)
            for child in tree["$or"]
        )
    elif "$and" in tree:
        return all(
            _eval_tree(item, child) if ("$or" in child or "$and" in child) else _eval_condition(item, child)
            for child in tree["$and"]
        )
    else:
        return _eval_condition(item, tree)


@mcp.tool()
def docket_link(
    from_id: str, to_id: str, relation: str, file: Optional[str] = None
) -> dict:
    """Link two work items with a typed relationship. Refused here: this server is read-only."""
    return _read_only()


@mcp.tool()
def docket_context(
    tags: list[str],
    include: Optional[list[str]] = None,
    lookback_days: int = 30,
    file: Optional[str] = None,
) -> dict:
    """Get a curated briefing for an area by tags."""
    path = _find_dct_file(file)
    data = _load_dct(path)
    if "error" in data:
        return data

    results = []
    for item_id, item in data.get("items", {}).items():
        item_tags = item.get("tags", [])
        if not any(t in item_tags for t in tags):
            continue
        if include and item.get("type") not in include:
            continue
        results.append({**item, "id": item_id})

    return {"items": results, "count": len(results), "tags": tags}


@mcp.tool()
def docket_saved_query(
    action: str,
    name: str = "",
    filter: Optional[dict] = None,
    sort: Optional[list] = None,
    columns: Optional[list[str]] = None,
    file: Optional[str] = None,
) -> dict:
    """Load or list saved queries within the .dct file (saving is refused: read-only)."""
    if action == "save":
        return _read_only()
    path = _find_dct_file(file)
    data = _load_dct(path)
    if "error" in data:
        return data
    if action == "load":
        queries = data.get("queries", {})
        if name not in queries:
            return {"error": f"Query not found: {name}"}
        return queries[name]
    elif action == "list":
        return {"queries": list(data.get("queries", {}).keys())}
    else:
        return {"error": f"Invalid action: {action}"}


if __name__ == "__main__":
    mcp.run()
