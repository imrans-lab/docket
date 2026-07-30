"""Tests for Docket Python MCP server — file operations."""
import json
import os
import tempfile
import pytest

# Import the server module
import docket_mcp_server as docket


@pytest.fixture(autouse=True)
def tmp_dct(tmp_path, monkeypatch):
    """Create a temp .dct file and patch _find_dct_file to use it."""
    path = str(tmp_path / "test.dct")
    data = {"version": "1.0.0", "counter": 0, "items": {}, "queries": {}}
    with open(path, "w") as f:
        json.dump(data, f)

    monkeypatch.setattr(docket, "_find_dct_file", lambda file=None: file or path)
    docket._load_schema()
    return path


def test_create_bug(tmp_dct):
    result = docket.docket_create(type="bug", title="Login fails")
    assert "id" in result
    assert result["id"] == "DKT-0001"
    assert result["type"] == "bug"
    assert result["status"] == "new"


def test_create_insight_requires_fields(tmp_dct):
    result = docket.docket_create(type="insight", title="Test")
    assert "error" in result


def test_create_insight_with_fields(tmp_dct):
    result = docket.docket_create(
        type="insight", title="Caching", assumed="DB fast", corrected="Need Redis"
    )
    assert result["type"] == "insight"
    assert result["status"] == "draft"


def test_get_existing(tmp_dct):
    docket.docket_create(type="bug", title="Test bug")
    result = docket.docket_get(id="DKT-0001")
    assert result["title"] == "Test bug"


def test_get_missing(tmp_dct):
    result = docket.docket_get(id="DKT-9999")
    assert "error" in result


def test_transition_valid(tmp_dct):
    docket.docket_create(type="chore", title="Update deps")
    result = docket.docket_transition(id="DKT-0001", to="in_progress")
    assert result["status"] == "in_progress"


def test_transition_invalid(tmp_dct):
    docket.docket_create(type="chore", title="Update deps")
    result = docket.docket_transition(id="DKT-0001", to="done")
    assert "error" in result


def test_transition_bug_resolve_requires_resolution(tmp_dct):
    docket.docket_create(type="bug", title="Test")
    docket.docket_transition(id="DKT-0001", to="triaged")
    docket.docket_transition(id="DKT-0001", to="active")
    result = docket.docket_transition(id="DKT-0001", to="resolved")
    assert "error" in result


def test_transition_bug_resolve_with_resolution(tmp_dct):
    docket.docket_create(type="bug", title="Test")
    docket.docket_transition(id="DKT-0001", to="triaged")
    docket.docket_transition(id="DKT-0001", to="active")
    result = docket.docket_transition(id="DKT-0001", to="resolved", resolution="fixed")
    assert result["status"] == "resolved"


def test_query_all(tmp_dct):
    docket.docket_create(type="bug", title="Bug 1")
    docket.docket_create(type="chore", title="Chore 1")
    result = docket.docket_query()
    assert result["count"] == 2


def test_query_filtered(tmp_dct):
    docket.docket_create(type="bug", title="Bug 1")
    docket.docket_create(type="chore", title="Chore 1")
    result = docket.docket_query(filter={"type": "bug"})
    assert result["count"] == 1


def test_link_valid(tmp_dct):
    docket.docket_create(type="bug", title="Bug")
    docket.docket_create(type="rca", title="RCA")
    result = docket.docket_link(from_id="DKT-0001", to_id="DKT-0002", relation="caused_by")
    assert result["relation"] == "caused_by"


def test_link_invalid_relation(tmp_dct):
    docket.docket_create(type="bug", title="Bug")
    docket.docket_create(type="rca", title="RCA")
    result = docket.docket_link(from_id="DKT-0001", to_id="DKT-0002", relation="invalid")
    assert "error" in result


def test_context(tmp_dct):
    docket.docket_create(type="bug", title="API bug", tags=["api"])
    docket.docket_create(type="insight", title="Insight", tags=["api"],
                         assumed="A", corrected="B")
    result = docket.docket_context(tags=["api"])
    assert result["count"] == 2


def test_saved_query_roundtrip(tmp_dct):
    docket.docket_saved_query(action="save", name="p1", filter={"priority": 1})
    result = docket.docket_saved_query(action="load", name="p1")
    assert result["filter"]["priority"] == 1


def test_saved_query_list(tmp_dct):
    docket.docket_saved_query(action="save", name="q1", filter={})
    result = docket.docket_saved_query(action="list")
    assert "q1" in result["queries"]


def test_full_bug_lifecycle(tmp_dct):
    """Full bug lifecycle: create → triage → active → resolve → verify → close."""
    docket.docket_create(type="bug", title="Crash", priority=1)
    docket.docket_transition(id="DKT-0001", to="triaged")
    docket.docket_transition(id="DKT-0001", to="active")
    docket.docket_transition(id="DKT-0001", to="resolved", resolution="fixed")
    docket.docket_transition(id="DKT-0001", to="verified")
    result = docket.docket_transition(id="DKT-0001", to="closed")
    assert result["status"] == "closed"

    item = docket.docket_get(id="DKT-0001")
    assert len(item["events"]) >= 6
