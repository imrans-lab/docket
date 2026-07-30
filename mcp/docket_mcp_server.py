#!/usr/bin/env python3
"""
Docket MCP Server — Python FastMCP fallback for when Godot isn't running.
Operates on the same .dct files as the Godot app.
"""

import json
import os
import glob
import fnmatch
from datetime import datetime, timezone
from typing import Optional

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("docket")

# Schema loaded at startup
_schema: dict = {}
_schema_path = os.path.join(os.path.dirname(__file__), "..", "data", "schema.json")


def _load_schema() -> dict:
    global _schema
    if not _schema:
        with open(_schema_path) as f:
            _schema = json.load(f)
    return _schema


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
    "{path} is a JSONL .dct, which this fallback server cannot read or write.\n"
    "It would rewrite the file as a single JSON object and destroy it.\n"
    "Use the Godot server instead:\n"
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


def _save_dct(path: str, data: dict) -> None:
    if os.path.exists(path) and _is_jsonl_dct(path):
        raise UnsupportedFormatError(_JSONL_REFUSAL.format(path=path))
    with open(path, "w") as f:
        json.dump(data, f, indent="\t")


def _ensure_dct(path: str) -> dict:
    if os.path.exists(path):
        return _load_dct(path)
    data = {"version": "1.0.0", "counter": 0, "items": {}, "queries": {}}
    _save_dct(path, data)
    return data


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def _add_event(item: dict, event_type: str, actor: str, note: str = "") -> None:
    item.setdefault("events", []).append({
        "event_type": event_type,
        "actor": actor,
        "timestamp": _now(),
        "note": note,
    })
    item["updated_at"] = _now()


def _next_id(data: dict) -> str:
    data["counter"] = data.get("counter", 0) + 1
    c = data["counter"]
    return f"DKT-{c:04d}" if c <= 9999 else f"DKT-{c}"


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
    """Create a new work item. Types: bug, dcr, rca, chore, hint, insight, question, work_item."""
    schema = _load_schema()
    if type not in schema["types"]:
        return {"error": f"Unknown type: {type}"}

    type_def = schema["types"][type]

    # Check required fields
    fields = {"title": title, "description": description, "assumed": assumed, "corrected": corrected}
    for req in type_def["required_fields"]:
        if not fields.get(req, ""):
            return {"error": f"Missing required field '{req}' for type '{type}'"}

    path = _find_dct_file(file)
    data = _ensure_dct(path)

    now = _now()
    item = {
        "type": type, "status": type_def["initial_state"],
        "title": title, "description": description,
        "created_at": now, "updated_at": now,
        "created_by": "", "assigned_to": assigned_to, "directed_to": directed_to,
        "priority": priority, "severity": severity,
        "tags": tags or [], "links": [], "events": [],
    }
    # Type-specific fields
    for f in type_def.get("optional_fields", []) + type_def.get("required_fields", []):
        if f not in item and fields.get(f):
            item[f] = fields[f]

    _add_event(item, "created", "", "Item created")
    item_id = _next_id(data)
    data["items"][item_id] = item
    _save_dct(path, data)
    return {**item, "id": item_id}


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
    """Update fields on an existing item. Not for state transitions."""
    schema = _load_schema()
    path = _find_dct_file(file)
    data = _load_dct(path)
    if "error" in data:
        return data
    if id not in data["items"]:
        return {"error": f"Item not found: {id}"}

    item = data["items"][id]
    type_def = schema["types"][item["type"]]
    allowed = set(type_def["required_fields"] + type_def.get("optional_fields", []))
    allowed |= {"title", "description", "assigned_to", "directed_to", "priority", "severity", "tags"}
    protected = {"type", "status", "id", "events", "links", "created_at", "updated_at"}

    for key, val in kwargs.items():
        if key in ("file",):
            continue
        if key in protected:
            continue
        if key not in allowed:
            return {"error": f"Field '{key}' not valid for type '{item['type']}'"}
        item[key] = val

    item["updated_at"] = _now()
    _save_dct(path, data)
    return {"id": id, "status": "updated"}


@mcp.tool()
def docket_transition(
    id: str, to: str, resolution: str = "", note: str = "",
    blocked_by: str = "", file: Optional[str] = None
) -> dict:
    """Transition an item to a new state. When transitioning to 'blocked', supply blocked_by."""
    schema = _load_schema()
    path = _find_dct_file(file)
    data = _load_dct(path)
    if "error" in data:
        return data
    if id not in data["items"]:
        return {"error": f"Item not found: {id}"}

    item = data["items"][id]
    type_def = schema["types"][item["type"]]
    transitions = type_def["transitions"]
    current = item["status"]

    if current not in transitions or to not in transitions[current]:
        valid = transitions.get(current, [])
        return {"error": f"Cannot transition from '{current}' to '{to}'. Valid: {valid}"}

    # Check transition rules
    rules = type_def.get("transition_rules", {}).get(to, {})
    for field in rules.get("required_fields", []):
        if field == "resolution" and not resolution:
            return {"error": f"Transition to '{to}' requires field '{field}'"}
        if field == "blocked_by" and not blocked_by:
            return {"error": f"Transition to '{to}' requires field '{field}'"}

    if resolution:
        item["resolution"] = resolution
    if blocked_by:
        item["blocked_by"] = blocked_by

    old = item["status"]
    item["status"] = to
    event_note = f"{old} → {to}"
    if note:
        event_note += f". {note}"
    _add_event(item, "transition", "agent", event_note)

    # Auto-create blocks link when transitioning to blocked
    if to == "blocked" and blocked_by:
        blocker_id = blocked_by.split(":")[-1] if ":" in blocked_by else blocked_by
        if blocker_id in data["items"]:
            data["items"][blocker_id].setdefault("links", []).append(
                {"to": id, "relation": "blocks"}
            )

    _save_dct(path, data)
    return {"id": id, "status": to}


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
    """Link two work items with a typed relationship."""
    schema = _load_schema()
    path = _find_dct_file(file)
    data = _load_dct(path)
    if "error" in data:
        return data

    if from_id not in data["items"]:
        return {"error": f"Item not found: {from_id}"}
    if to_id not in data["items"]:
        return {"error": f"Item not found: {to_id}"}

    valid_relations = schema.get("link_relations", [])
    if relation not in valid_relations:
        return {"error": f"Invalid relation '{relation}'. Valid: {valid_relations}"}

    data["items"][from_id].setdefault("links", []).append({"to": to_id, "relation": relation})
    _add_event(data["items"][from_id], "linked", "agent", f"Linked {from_id} → {to_id} ({relation})")
    _save_dct(path, data)
    return {"from": from_id, "to": to_id, "relation": relation}


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
    """Save, load, or list saved queries within the .dct file."""
    path = _find_dct_file(file)
    data = _ensure_dct(path)

    if action == "save":
        if not name:
            return {"error": "Query name required"}
        query = {}
        if filter:
            query["filter"] = filter
        if sort:
            query["sort"] = sort
        if columns:
            query["columns"] = columns
        data.setdefault("queries", {})[name] = query
        _save_dct(path, data)
        return {"saved": name}
    elif action == "load":
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
