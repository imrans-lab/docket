#!/usr/bin/env python3
"""Write-path bench: what one mutation costs on a scratch copy of a session.

The bench copies the given .dct files into a scratch directory, starts a fresh
Docket process on those copies with its own port and its own user data
directory, drives mutations through the MCP endpoint, and reports per call:

  wall_ms_http   time from sending the HTTP request to having the parsed reply,
                 measured in this process. It includes HTTP and JSON overhead,
                 not only Docket's work.
  before/after   bytes, sha256 and mtime of the target canonical .dct, read
                 from disk by this process outside the timed window, plus the
                 sizes of files beside it whose names start with its name
                 (lock, cache, owner record, and any sidecar). "after" is read
                 when the reply arrives; a write finishing later shows up in
                 the next row's "before" or in fixture_final.

With --gui-probe it then starts the Docket GUI on the same scratch copies with
the frame-time probe enabled (scripts/ui/frame_probe.gd), requests one
File → Save through the probe's trigger file, and reports the longest frame and
the count of frames over 100 ms, with every canonical's before/after figures.

Isolation:
  - The run directory is created new (an existing path, including a symlink,
    is refused), so no earlier prefs or links can be waiting inside it.
  - Sources are only read (stat, bytes, hash). Their mtime, size and sha256 are
    recorded before and after the run and the report says whether they held.
    A concurrent edit by the owner's own Docket also shows up as a change.
  - The child's user:// and Docket session directory are redirected into the
    scratch directory by environment (XDG_DATA_HOME on Linux, APPDATA on
    Windows, DOCKET_SESSION_DIR everywhere). macOS has no such redirection for
    Godot's user data directory, so the bench refuses to run there. Before each
    launch and at the end, every path under the redirected directory must
    resolve inside scratch.
  - A headless Docket server merges the session paths saved in its prefs into
    its --file list. Once the child answers, the bench lists its projects and
    stops at once if any path lies outside the scratch directory.
  - The report is written only inside the run directory, to a new file; its
    path is checked before any source is fingerprinted.
  - SIGINT or SIGTERM stops and reaps every Docket child; the exit code is then
    128 + the signal number.
  - Port 3010 is refused, as is any port that is already bound. The chosen
    port stays bound by the bench until just before the child starts.

Standard library only. Usage:
  python3 scripts/bench/write_bench.py --source A.dct --source B.dct ...
      [--target NAME] [--rounds 5] [--kinds create,tags,comment,append]
      [--gui-probe] [--godot PATH] [--scratch DIR] [--port N]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OWNER_PORT = 3010
MIN_GODOT = (4, 7)
KINDS = ("create", "tags", "comment", "append")
READY_TIMEOUT_S = 300.0
PROBE_TIMEOUT_S = 300.0
USERDATA = "userdata"
FIXTURE = "fixture"
SERVE_LOG = "docket-serve.log"
GUI_LOG = "docket-gui.log"
PROBE_OUT = "frame_probe.json"
# Top-level names in the run directory the bench writes itself.
RESERVED = (USERDATA, FIXTURE, SERVE_LOG, GUI_LOG, PROBE_OUT, PROBE_OUT + ".save")


class BenchError(RuntimeError):
    pass


class Interrupted(Exception):
    def __init__(self, signum: int):
        super().__init__(f"interrupted by signal {signum}")
        self.signum = signum


# Docket children not yet reaped; main() stops any left here however run() ends.
_children: list[subprocess.Popen] = []
# While _deferring is set, _on_signal records the signal in _pending_signal
# instead of raising; start_docket raises it once the child is registered.
_deferring = False
_pending_signal: int | None = None


# -- File observation ---------------------------------------------------------

def snapshot(path: Path) -> dict:
    """Bytes, sha256 and mtime of one file, plus sizes of its name-prefixed siblings."""
    data = path.read_bytes()
    st = path.stat()
    siblings = {}
    for other in sorted(path.parent.iterdir()):
        if other != path and other.name.startswith(path.name) and other.is_file():
            siblings[other.name] = other.stat().st_size
    return {
        "bytes": len(data),
        "lines": data.count(b"\n"),
        "sha256": hashlib.sha256(data).hexdigest(),
        "mtime_ns": st.st_mtime_ns,
        "siblings": siblings,
    }


def live_fingerprint(path: Path) -> dict:
    data = path.read_bytes()
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "mtime_ns": path.stat().st_mtime_ns}


def stat_fingerprint(path: Path) -> dict:
    """Metadata only, for watched files whose contents the bench must not read."""
    if not path.exists():
        return {"exists": False}
    st = path.stat()
    return {"exists": True, "bytes": st.st_size, "mtime_ns": st.st_mtime_ns}


# -- Scratch confinement ------------------------------------------------------

def inside(path: Path, scratch: Path) -> bool:
    return scratch in Path(os.path.realpath(path)).parents


def make_run_dir(requested: str | None) -> Path:
    """Create the run directory new; an existing entry at that path is refused."""
    if not requested:
        return Path(tempfile.mkdtemp(prefix="docket-bench-")).resolve()
    path = Path(os.path.expanduser(requested)).absolute()
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.mkdir()
    except FileExistsError:
        raise BenchError(f"run directory already exists: {path}; name a new one")
    return path.resolve()


def check_tree_in_scratch(root: Path, scratch: Path) -> None:
    """Every entry under root, symlinks included, must resolve inside scratch."""
    if not inside(root, scratch):
        raise BenchError(f"isolation breach: {root} resolves outside {scratch}")
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            entry = Path(dirpath, name)
            if not inside(entry, scratch):
                raise BenchError(f"isolation breach: {entry} resolves to "
                                 f"{os.path.realpath(entry)}, outside {scratch}")


def report_path(requested: str | None, scratch: Path) -> Path:
    """The report file, relative paths taken from the run directory. It must
    resolve inside the run directory and outside the bench's own files."""
    out = scratch / os.path.expanduser(requested or "report.json")
    real = Path(os.path.realpath(out))
    if scratch not in real.parents:
        raise BenchError(f"--report must lie inside the run directory {scratch}: {real}")
    if real.relative_to(scratch).parts[0] in RESERVED:
        raise BenchError(f"--report names a file the bench writes itself: {real}")
    return real


def write_report(report: dict, scratch: Path) -> Path:
    out = report_path(str(report["report_path"]), scratch)
    out.parent.mkdir(parents=True, exist_ok=True)
    out = report_path(str(out), scratch)  # re-check once the parents exist
    with open(out, "x") as f:
        f.write(json.dumps(report, indent=2))
    return out


# -- Fixture ------------------------------------------------------------------

def build_fixture(sources: list[Path], scratch: Path) -> dict:
    """Copy each source to scratch/fixture/<n>/<name>; the name is kept because
    Docket may derive the project name from it. Returns the manifest."""
    scratch = scratch.resolve()
    fixture_root = scratch / FIXTURE
    if fixture_root.exists():
        raise BenchError(f"scratch already holds a fixture: {fixture_root}")
    manifest = {"scratch": str(scratch), "files": []}
    for n, src in enumerate(sources):
        src = src.resolve()
        if src == scratch or scratch in src.parents:
            raise BenchError(f"source lies inside the scratch directory: {src}")
        dest_dir = fixture_root / str(n)
        dest_dir.mkdir(parents=True)
        dest = dest_dir / src.name
        # Docket replaces a canonical by rename, so a copy sees one whole
        # version; re-reading the source detects a replacement mid-copy.
        before = live_fingerprint(src)
        shutil.copyfile(src, dest)
        copied = snapshot(dest)
        after = live_fingerprint(src)
        if before["sha256"] != after["sha256"] or copied["sha256"] != before["sha256"]:
            raise BenchError(f"source changed while being copied: {src}")
        manifest["files"].append({"source": str(src), "copy": str(dest), **copied})
    return manifest


# -- Child process ------------------------------------------------------------

def child_env(scratch: Path) -> dict:
    user_root = scratch / USERDATA
    env = dict(os.environ)
    env["XDG_DATA_HOME"] = str(user_root / "data")
    env["XDG_CONFIG_HOME"] = str(user_root / "config")
    env["XDG_CACHE_HOME"] = str(user_root / "cache")
    env["APPDATA"] = str(user_root / "appdata")
    env["LOCALAPPDATA"] = str(user_root / "localappdata")
    env["DOCKET_SESSION_DIR"] = str(user_root / "sessions")
    for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "APPDATA",
                "LOCALAPPDATA", "DOCKET_SESSION_DIR"):
        Path(env[key]).mkdir(parents=True, exist_ok=True)
    env.pop("DOCKET_FRAME_PROBE_OUT", None)
    env.pop("DOCKET_FRAME_PROBE_QUIT", None)
    return env


def resolve_godot(explicit: str | None) -> str:
    candidate = explicit or os.environ.get("GODOT") or shutil.which("godot") or ""
    if not candidate:
        raise BenchError("no Godot binary: pass --godot or set GODOT")
    out = subprocess.run([candidate, "--version"], capture_output=True, text=True,
                         timeout=60).stdout.strip()
    parts = out.split(".")
    try:
        version = (int(parts[0]), int(parts[1]))
    except (IndexError, ValueError):
        raise BenchError(f"cannot read Godot version from {candidate!r}: {out!r}")
    if version < MIN_GODOT:
        raise BenchError(f"Godot {out} is older than the project's {MIN_GODOT[0]}.{MIN_GODOT[1]}")
    return candidate


def reserve_port(requested: int | None) -> socket.socket:
    """A socket bound to the port; start_docket closes it just before launch."""
    if requested == OWNER_PORT:
        raise BenchError(f"port {OWNER_PORT} belongs to the owner's Docket; choose another")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", requested or 0))
    except OSError:
        s.close()
        raise BenchError(f"port {requested} is already bound")
    return s


def start_docket(godot: str, files: list[str], reserved: socket.socket, env: dict,
                 log: Path, gui: bool) -> subprocess.Popen:
    port = reserved.getsockname()[1]
    args = [godot]
    if not gui:
        args.append("--headless")
    args += ["--path", str(REPO), "--"]
    if not gui:
        args.append("--serve")
    for f in files:
        args += ["--file", f]
    args += ["--port", str(port)]
    reserved.close()
    # Creation and registration run with Interrupted deferred, so a signal
    # arriving in between cannot leave a child that stop_all_children misses.
    global _deferring, _pending_signal
    _deferring = True
    try:
        proc = subprocess.Popen(args, env=env, stdout=log.open("wb"),
                                stderr=subprocess.STDOUT)
        _children.append(proc)
    finally:
        _deferring = False
        if _pending_signal is not None:
            pending, _pending_signal = _pending_signal, None
            raise Interrupted(pending)
    return proc


def stop_docket(proc: subprocess.Popen) -> None:
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    if proc in _children:
        _children.remove(proc)


def stop_all_children() -> None:
    for proc in list(_children):
        stop_docket(proc)


def _on_signal(signum, _frame) -> None:
    # Later signals are ignored so the cleanup in main() is not cut short.
    global _pending_signal
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, signal.SIG_IGN)
    if _deferring:
        _pending_signal = signum
        return
    raise Interrupted(signum)


# -- MCP client ---------------------------------------------------------------

class Mcp:
    def __init__(self, port: int):
        self.url = f"http://127.0.0.1:{port}/mcp"
        self._id = 0

    def rpc(self, method: str, params: dict | None = None, timeout: float = 600.0) -> dict:
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method,
                           "params": params or {}}).encode()
        req = urllib.request.Request(self.url, data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())

    def call(self, tool: str, arguments: dict) -> tuple[float, dict]:
        """(wall ms including HTTP round trip, decoded tool result or {'error': ...})."""
        start = time.perf_counter()
        reply = self.rpc("tools/call", {"name": tool, "arguments": arguments})
        wall_ms = (time.perf_counter() - start) * 1000.0
        if "error" in reply:
            return wall_ms, {"error": reply["error"]}
        result = reply.get("result", {})
        text = (result.get("content") or [{}])[0].get("text", "")
        if result.get("isError"):
            return wall_ms, {"error": text}
        try:
            return wall_ms, json.loads(text)
        except json.JSONDecodeError:
            return wall_ms, {"text": text}

    def wait_ready(self, proc: subprocess.Popen, log: Path) -> None:
        deadline = time.monotonic() + READY_TIMEOUT_S
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise BenchError(f"Docket exited with {proc.returncode}; see {log}")
            try:
                self.rpc("initialize", timeout=5.0)
                return
            except (urllib.error.URLError, ConnectionError, TimeoutError, OSError):
                time.sleep(0.5)
        raise BenchError(f"Docket did not answer within {READY_TIMEOUT_S:.0f} s; see {log}")


def check_projects_in_scratch(mcp: Mcp, scratch: Path) -> list[dict]:
    """Every loaded project must be a scratch copy; anything else is a leak."""
    _, listing = mcp.call("docket_project_list", {})
    if "error" in listing:
        raise BenchError(f"docket_project_list failed: {listing['error']}")
    projects = listing.get("projects", [])
    for p in projects:
        path = Path(str(p.get("path", ""))).resolve()
        if scratch not in path.parents:
            raise BenchError(f"isolation breach: Docket loaded {path} outside {scratch}")
    return projects


# -- Mutations ----------------------------------------------------------------

def mutation_args(kind: str, item_id: str, project: str, n: int, create_type: str,
                  append_field: str) -> tuple[str, dict]:
    tag = f"bench-{n}"
    if kind == "create":
        return "docket_create", {"project": project, "type": create_type,
                                 "title": f"bench item {n}", "tags": ["bench"]}
    if kind == "tags":
        return "docket_update", {"project": project, "id": item_id, "tags": ["bench", tag]}
    if kind == "comment":
        return "docket_comment", {"project": project, "action": "add", "item_id": item_id,
                                  "text": f"bench comment {n}", "author": "bench"}
    if kind == "append":
        return "docket_append", {"project": project, "id": item_id, "field": append_field,
                                 "text": f"bench append {n}\n",
                                 "request_id": str(uuid.uuid4())}
    raise BenchError(f"unknown mutation kind: {kind}")


def run_mutations(mcp: Mcp, target: Path, project: str, opts) -> list[dict]:
    rows = []
    item_id = opts.item or ""
    for n in range(opts.rounds):
        for kind in opts.kinds:
            if kind != "create" and not item_id:
                raise BenchError(f"'{kind}' needs an item: include create or pass --item")
            tool, args = mutation_args(kind, item_id, project, n, opts.create_type,
                                       opts.append_field)
            before = snapshot(target)
            wall_ms, result = mcp.call(tool, args)
            after = snapshot(target)
            if kind == "create" and "id" in result:
                item_id = str(result["id"])
            rows.append({"round": n, "kind": kind, "tool": tool, "wall_ms_http": wall_ms,
                         "error": result.get("error"), "before": before, "after": after})
    before = snapshot(target)
    wall_ms, result = mcp.call("docket_flush", {})
    rows.append({"round": None, "kind": "flush", "tool": "docket_flush",
                 "wall_ms_http": wall_ms, "error": result.get("error"),
                 "before": before, "after": snapshot(target)})
    return rows


# -- GUI frame probe ----------------------------------------------------------

def run_gui_probe(godot: str, copies: list[Path], scratch: Path, env: dict) -> dict:
    out = scratch / PROBE_OUT
    probe_env = dict(env)
    probe_env["DOCKET_FRAME_PROBE_OUT"] = str(out)
    probe_env["DOCKET_FRAME_PROBE_QUIT"] = "1"
    log = scratch / GUI_LOG
    check_tree_in_scratch(scratch / USERDATA, scratch)
    reserved = reserve_port(None)
    port = reserved.getsockname()[1]
    proc = start_docket(godot, [str(c) for c in copies], reserved, probe_env, log, gui=True)
    try:
        mcp = Mcp(port)
        mcp.wait_ready(proc, log)
        check_projects_in_scratch(mcp, scratch)
        report = _read_probe(out, proc, log, lambda r: True)
        if scratch not in Path(report["user_data_dir"]).resolve().parents:
            raise BenchError(f"isolation breach: GUI user data dir is {report['user_data_dir']}")
        before = {str(c): snapshot(c) for c in copies}
        Path(str(out) + ".save").write_bytes(b"")
        report = _read_probe(out, proc, log, lambda r: len(r.get("saves", [])) > 0)
        after = {str(c): snapshot(c) for c in copies}
        proc.wait(timeout=60)
        window = report["saves"][0]
        return {"longest_frame_ms": window["longest_frame_ms"],
                "frames_over_slow_ms": window["frames_over_slow_ms"],
                "slow_frame_ms": report["slow_frame_ms"],
                "baseline_longest_ms": window["baseline_longest_ms"],
                "save_call_ms": window["save_call_ms"],
                "window_complete": window["complete"],
                "user_data_dir": report["user_data_dir"],
                "canonicals": {k: {"before": before[k], "after": after[k]} for k in before},
                "probe_file": str(out)}
    finally:
        stop_docket(proc)


def _read_probe(out: Path, proc: subprocess.Popen, log: Path, done) -> dict:
    deadline = time.monotonic() + PROBE_TIMEOUT_S
    while time.monotonic() < deadline:
        if out.exists():
            report = json.loads(out.read_text())
            if done(report):
                return report
        if proc.poll() is not None and not out.exists():
            raise BenchError(f"Docket GUI exited with {proc.returncode}; see {log}")
        time.sleep(0.2)
    raise BenchError(f"frame probe produced no result within {PROBE_TIMEOUT_S:.0f} s")


# -- Driver -------------------------------------------------------------------

def parse_args(argv: list[str] | None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--source", action="append", default=[], help=".dct to copy (repeatable)")
    ap.add_argument("--sources-file", help="file listing one .dct path per line")
    ap.add_argument("--target", help="project name to mutate (default: first source's project)")
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--kinds", default=",".join(KINDS),
                    help="comma-separated, from: " + ", ".join(KINDS))
    ap.add_argument("--item", help="existing item id to mutate when create is not in --kinds")
    ap.add_argument("--create-type", default="chore")
    ap.add_argument("--append-field", default="description")
    ap.add_argument("--watch", action="append", default=[],
                    help="extra path checked by metadata only (e.g. the owner's prefs)")
    ap.add_argument("--gui-probe", action="store_true", help="also time File → Save in the GUI")
    ap.add_argument("--godot")
    ap.add_argument("--scratch", help="new directory for the run; must not exist "
                                      "(default: a new temp dir)")
    ap.add_argument("--port", type=int)
    ap.add_argument("--report", help="new file for the JSON report, inside the run "
                                     "directory; relative paths are taken from it "
                                     "(default: report.json)")
    opts = ap.parse_args(argv)
    if opts.sources_file:
        for line in Path(opts.sources_file).read_text().splitlines():
            if line.strip() and not line.lstrip().startswith("#"):
                opts.source.append(os.path.expanduser(line.strip()))
    if not opts.source:
        ap.error("at least one --source is required")
    opts.kinds = [k.strip() for k in opts.kinds.split(",") if k.strip()]
    for k in opts.kinds:
        if k not in KINDS:
            ap.error(f"unknown kind {k!r}")
    return opts


def default_watch() -> list[Path]:
    """The owner's real Docket prefs on Linux, checked by metadata only."""
    if sys.platform.startswith("linux"):
        base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
        return [base / "godot" / "app_userdata" / "Docket" / "docket_prefs.json"]
    return []


def repo_sha() -> str:
    r = subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True,
                       text=True)
    return r.stdout.strip()


def run(opts) -> dict:
    if sys.platform == "darwin":
        raise BenchError("macOS: Godot's user data directory cannot be redirected by "
                         "environment, so the bench cannot isolate prefs; not running")
    sources = [Path(os.path.expanduser(s)).resolve() for s in opts.source]
    for s in sources:
        if not s.is_file():
            raise BenchError(f"source not found: {s}")
    watched = [Path(w).expanduser() for w in opts.watch] + default_watch()
    scratch = make_run_dir(opts.scratch)
    # Checked before any fingerprint, so the report can never land on a watched input.
    out = report_path(opts.report, scratch)
    godot = resolve_godot(opts.godot)

    live_before = {str(s): live_fingerprint(s) for s in sources}
    watched_before = {str(w): stat_fingerprint(w) for w in watched}
    manifest = build_fixture(sources, scratch)
    copies = [Path(f["copy"]) for f in manifest["files"]]
    env = child_env(scratch)
    check_tree_in_scratch(scratch / USERDATA, scratch)
    reserved = reserve_port(opts.port)
    port = reserved.getsockname()[1]

    report = {"docket_sha": repo_sha(), "godot": godot, "port": port,
              "wall_note": "wall_ms_http is measured by the MCP client and includes "
                           "HTTP round-trip and JSON encode/decode overhead",
              "fixture": manifest, "report_path": str(out)}
    log = scratch / SERVE_LOG
    proc = start_docket(godot, [str(c) for c in copies], reserved, env, log, gui=False)
    try:
        mcp = Mcp(port)
        mcp.wait_ready(proc, log)
        projects = check_projects_in_scratch(mcp, scratch)
        target_name = opts.target
        target_path = None
        for p in projects:
            path = Path(str(p["path"])).resolve()
            if (target_name and p["name"] == target_name) or (not target_name and path == copies[0]):
                target_name, target_path = p["name"], path
        if target_path is None:
            raise BenchError(f"target project not loaded: {opts.target or copies[0]}")
        report["target"] = {"project": target_name, "path": str(target_path),
                            "after_load": snapshot(target_path)}
        report["mutations"] = run_mutations(mcp, target_path, target_name, opts)
    finally:
        stop_docket(proc)
    report["fixture_final"] = {str(c): snapshot(c) for c in copies}

    if opts.gui_probe:
        report["gui_probe"] = run_gui_probe(godot, copies, scratch, env)
    check_tree_in_scratch(scratch / USERDATA, scratch)

    live_after = {str(s): live_fingerprint(s) for s in sources}
    watched_after = {str(w): stat_fingerprint(w) for w in watched}
    report["live_untouched"] = live_before == live_after and watched_before == watched_after
    report["live"] = {"before": live_before, "after": live_after,
                      "watched_before": watched_before, "watched_after": watched_after}
    return report


def print_summary(report: dict) -> None:
    print(f"docket {report['docket_sha'][:10]}  target {report['target']['project']}  "
          f"({report['target']['after_load']['bytes']} bytes after load)")
    print("wall_ms_http includes HTTP round-trip overhead")
    print(f"{'kind':8} {'wall_ms_http':>12} {'bytes_before':>13} {'bytes_after':>12} "
          f"{'rewritten':>9}  error")
    for m in report["mutations"]:
        rewritten = m["before"]["mtime_ns"] != m["after"]["mtime_ns"]
        print(f"{m['kind']:8} {m['wall_ms_http']:12.1f} {m['before']['bytes']:13d} "
              f"{m['after']['bytes']:12d} {str(rewritten):>9}  {m['error'] or ''}")
    probe = report.get("gui_probe")
    if probe:
        print(f"File → Save: longest frame {probe['longest_frame_ms']:.1f} ms, "
              f"{probe['frames_over_slow_ms']} frame(s) over {probe['slow_frame_ms']:.0f} ms")
    print(f"live files untouched: {report['live_untouched']}")


def main(argv: list[str] | None = None) -> int:
    opts = parse_args(argv)
    previous = {s: signal.signal(s, _on_signal) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        report = run(opts)
        out = write_report(report, Path(report["fixture"]["scratch"]))
    except Interrupted as e:
        print(f"bench: {e}; Docket children stopped", file=sys.stderr)
        return 128 + e.signum
    except (BenchError, OSError) as e:
        print(f"bench: {e}", file=sys.stderr)
        return 2
    finally:
        for s in previous:
            signal.signal(s, signal.SIG_IGN)
        stop_all_children()
        for s, handler in previous.items():
            signal.signal(s, handler)
    print_summary(report)
    print(f"report: {out}")
    return 0 if report["live_untouched"] else 1


if __name__ == "__main__":
    sys.exit(main())
