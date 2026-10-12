"""Real sibling-process discovery oracle, run only in an isolated container/VM."""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import BinaryIO


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def rpc(port: int, method: str = "ping") -> dict[str, object]:
    payload = json.dumps({"jsonrpc":"2.0", "id":1, "method":method}).encode()
    request = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", payload,
                                     {"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(request, timeout=2) as reply:
            return json.load(reply)
    except (OSError, urllib.error.URLError):
        return {}


def ping(port: int) -> bool:
    return rpc(port).get("result") == {}


def run(project: Path, scratch: Path, godot: str) -> None:
    scratch.mkdir(parents=True, exist_ok=False)

    environment = os.environ.copy()
    for key in ("DOCKET_SESSION_DIR", "DOCKET_PANEL_SECRET"):
        environment.pop(key, None)
    for key, suffix in {"XDG_DATA_HOME":"data", "XDG_CONFIG_HOME":"config",
                        "XDG_CACHE_HOME":"cache", "APPDATA":"data", "LOCALAPPDATA":"cache"}.items():
        environment[key] = str(scratch / suffix)
    # Resolve Godot's actual standalone profile on this OS before any startup.
    probe = project / "test" / "fixtures" / "userdir_probe.gd"
    subprocess.run([godot, "--headless", "--quiet", "--path", str(project), "-s", str(probe),
                    "--", str(scratch)], env=environment, check=True, timeout=30,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    profile = Path(json.loads((scratch / "userdir-report.json").read_text())).resolve()
    assert scratch in profile.parents, "profile escaped isolated scratch"
    processes: list[subprocess.Popen[bytes]] = []
    logs: list[BinaryIO] = []

    def start(name: str, port: int | None, frames: int, extra: tuple[str, ...] = ()) -> subprocess.Popen[bytes]:
        log = (scratch / (name + ".log")).open("wb")
        logs.append(log)
        process = subprocess.Popen([godot, "--headless", "--path", str(project),
                                    "--quit-after", str(frames), "--", "--serve",
                                    "--file", str(scratch / (name + ".dct"))]
                                   + ([] if port is None else ["--port", str(port)]) + list(extra), env=environment, stdout=log, stderr=log)
        processes.append(process)
        return process

    try:
        first_port, second_port = free_port(), free_port()
        assert first_port != 3010 and second_port != 3010
        first = start("first", first_port, 20)
        record = profile / "instance.json"
        deadline = time.monotonic() + 8
        while not record.exists():
            assert first.poll() is None and time.monotonic() < deadline, "registration missing"
            time.sleep(0.05)
        first_bytes = record.read_bytes()
        registered = json.loads(first_bytes)
        assert registered["pid"] == first.pid, "registration PID mismatch"
        assert registered["endpoint"] == {"host":"127.0.0.1", "port":first_port}, "endpoint mismatch"
        assert Path(registered["profile"]).resolve() == profile, "profile mismatch"
        assert registered["version"] and registered["protocol_version"] and registered["started_at"], "identity incomplete"
        assert ping(first_port), "registered HTTP endpoint unavailable"
        second = start("second", second_port, 5)
        assert second.wait(timeout=12) == 2, "unregistered sibling did not refuse startup"
        assert not ping(second_port), "unregistered sibling kept serving"
        assert "profile_occupied" in (scratch / "second.log").read_text(), "registration failure missing from log"
        assert record.read_bytes() == first_bytes, "live sibling registration overwritten"
        assert record.read_bytes() == first_bytes, "loser exit removed winner registration"
        assert first.wait(timeout=30) == 0, "first clean exit failed"
        assert not record.exists(), "registration retained after clean exit"
        # A restart on another port must publish its actual endpoint.
        third = start("restart", second_port, 5)
        deadline = time.monotonic() + 8
        while not record.exists():
            assert third.poll() is None and time.monotonic() < deadline, "restart registration missing"
            time.sleep(0.05)
        assert json.loads(record.read_bytes())["endpoint"]["port"] == second_port, "restart retained old endpoint"
        assert third.wait(timeout=12) == 0 and not record.exists(), "restart cleanup failed"
        # A forced exit retains a stale record; SQLite releases any native lock.
        crashed = start("crashed", first_port, 60)
        deadline = time.monotonic() + 8
        while not record.exists():
            assert crashed.poll() is None and time.monotonic() < deadline, "crash fixture registration missing"
            time.sleep(0.05)
        crashed.kill()
        crashed.wait(timeout=5)
        assert record.exists(), "forced exit unexpectedly cleaned registration"
        recovered = start("recovered", second_port, 5)
        deadline = time.monotonic() + 8
        while json.loads(record.read_bytes())["pid"] != recovered.pid:
            assert recovered.poll() is None and time.monotonic() < deadline, "stale record not replaced"
            time.sleep(0.05)
        assert recovered.wait(timeout=12) == 0 and not record.exists(), "recovered cleanup failed"
        # Binding the configured port must fail loudly, without choosing another.
        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            refused = start("occupied", occupied.getsockname()[1], 60)
            assert refused.wait(timeout=10) == 2, "occupied port did not exit nonzero"
            assert "Failed to listen on port" in (scratch / "occupied.log").read_text(), "bind error missing"
            assert not record.exists(), "failed bind registered an endpoint"
        for flag in ("--stdio", "--host-authority", "--state-dir", "--restore-session"):
            refused = start("retired-" + flag[2:], free_port(), 60, (flag,))
            assert refused.wait(timeout=10) == 2, "retired flag accepted"
            assert "Unknown option: " + flag in (scratch / ("retired-" + flag[2:] + ".log")).read_text()
        # Real filesystem failures use the same fatal registration path.
        record.mkdir()
        refused = start("write-failed", free_port(), 60)
        assert refused.wait(timeout=10) == 2, "registration write failure kept running"
        assert "write_failed" in (scratch / "write-failed.log").read_text()
        record.rmdir()
        lock_path = profile / "instance.lock.sqlite"
        lock_path.unlink(missing_ok=True)
        lock_path.mkdir()
        refused = start("lock-failed", free_port(), 60)
        assert refused.wait(timeout=12) == 2, "registration lock failure kept running"
        assert "lock_unavailable" in (scratch / "lock-failed.log").read_text()
        lock_path.rmdir()
        # Preference survives a CLI override; both publish actual bound ports.
        preferred_port, override_port = free_port(), free_port()
        prefs = profile / "docket_prefs.json"
        prefs.write_text(json.dumps({"mcp_port":preferred_port}))
        preferred = start("preferred", None, 5)
        deadline = time.monotonic() + 8
        while not record.exists():
            assert preferred.poll() is None and time.monotonic() < deadline, "preferred registration missing"
            time.sleep(.05)
        assert json.loads(record.read_text())["endpoint"]["port"] == preferred_port
        assert preferred.wait(timeout=12) == 0
        overridden = start("override", override_port, 5)
        deadline = time.monotonic() + 8
        while not record.exists():
            assert overridden.poll() is None and time.monotonic() < deadline, "override registration missing"
            time.sleep(.05)
        assert json.loads(record.read_text())["endpoint"]["port"] == override_port
        assert overridden.wait(timeout=12) == 0
        assert json.loads(prefs.read_text())["mcp_port"] == preferred_port, "CLI changed saved port"
        print(json.dumps({"passed":True, "observations":["identity", "HTTP", "live-sibling", "loser-cleanup", "owner-cleanup", "port-restart", "killed-owner-recovery", "occupied-port-exit", "retired-flags", "registration-write-lock-failure", "preference-and-override"], "raw_logs":"isolated scratch only"}))
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        for log in logs:
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--godot", default="godot")
    arguments = parser.parse_args()
    run(arguments.project.resolve(), arguments.scratch.resolve(), arguments.godot)
