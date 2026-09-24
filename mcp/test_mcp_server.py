"""Tests for the read-only Docket Python MCP server."""
import json
import os

import pytest

# Import the server module
import docket_mcp_server as docket

ITEMS = {
    "DKT-0001": {"type": "bug", "status": "new", "title": "API bug", "tags": ["api"], "events": []},
    "DKT-0002": {"type": "chore", "status": "new", "title": "Chore 1", "tags": [], "events": []},
    "DKT-0003": {"type": "insight", "status": "draft", "title": "Insight", "tags": ["api"], "events": []},
}


@pytest.fixture(autouse=True)
def tmp_dct(tmp_path, monkeypatch):
    """A temp monolithic-JSON .dct with three items and one saved query."""
    path = str(tmp_path / "test.dct")
    data = {"version": "1.0.0", "counter": 3, "items": ITEMS, "queries": {"p1": {"filter": {"priority": 1}}}}
    with open(path, "w") as f:
        json.dump(data, f)

    monkeypatch.setattr(docket, "_find_dct_file", lambda file=None: file or path)
    return path


def test_get_existing(tmp_dct):
    assert docket.docket_get(id="DKT-0001")["title"] == "API bug"


def test_get_missing(tmp_dct):
    assert "error" in docket.docket_get(id="DKT-9999")


def test_query_all_and_filtered(tmp_dct):
    assert docket.docket_query()["count"] == 3
    assert docket.docket_query(filter={"type": "bug"})["count"] == 1


def test_context(tmp_dct):
    assert docket.docket_context(tags=["api"])["count"] == 2


def test_saved_query_load_and_list(tmp_dct):
    assert docket.docket_saved_query(action="load", name="p1")["filter"]["priority"] == 1
    assert "p1" in docket.docket_saved_query(action="list")["queries"]


def test_every_write_is_refused_and_changes_nothing(tmp_dct):
    """Project changes go through Docket, which coordinates them; here none are made."""
    with open(tmp_dct, "rb") as f:
        before = f.read()
    results = [
        docket.docket_create(type="bug", title="New"),
        docket.docket_update(id="DKT-0001", title="Changed"),
        docket.docket_transition(id="DKT-0002", to="in_progress"),
        docket.docket_link(from_id="DKT-0001", to_id="DKT-0003", relation="caused_by"),
        docket.docket_saved_query(action="save", name="q1", filter={}),
    ]
    assert all("read-only" in r.get("error", "") for r in results)
    with open(tmp_dct, "rb") as f:
        assert f.read() == before
    # Nor does it create a project that is missing.
    missing = tmp_dct + ".missing"
    assert "error" in docket.docket_saved_query(action="list", file=missing)
    assert "read-only" in docket.docket_create(type="bug", title="New", file=missing)["error"]
    assert not os.path.exists(missing)
