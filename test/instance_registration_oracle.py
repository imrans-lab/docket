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
    profile = scratch / "profile"
    environment = os.environ.copy()
    for key in ("DOCKET_SESSION_DIR", "DOCKET_PANEL_SECRET"):
        environment.pop(key, None)
    for key, suffix in {"XDG_DATA_HOME":"data", "XDG_CONFIG_HOME":"config",
                        "XDG_CACHE_HOME":"cache", "APPDATA":"data", "LOCALAPPDATA":"cache"}.items():
        environment[key] = str(scratch / suffix)
    processes: list[subprocess.Popen[bytes]] = []
    logs: list[BinaryIO] = []

    def start(name: str, port: int, frames: int) -> subprocess.Popen[bytes]:
        log = (scratch / (name + ".log")).open("wb")
        logs.append(log)
        process = subprocess.Popen([godot, "--headless", "--path", str(project),
                                    "--quit-after", str(frames), "--", "--serve",
                                    "--state-dir", str(profile), "--file", str(scratch / (name + ".dct")),
                                    "--port", str(port)], env=environment, stdout=log, stderr=log)
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
        assert registered["profile"] == str(profile), "profile mismatch"
        assert registered["version"] and registered["protocol_version"] and registered["started_at"], "identity incomplete"
        assert ping(first_port), "registered HTTP endpoint unavailable"
        second = start("second", second_port, 5)
        deadline = time.monotonic() + 8
        while not ping(second_port):
            assert second.poll() is None and time.monotonic() < deadline, "second HTTP endpoint unavailable"
        assert record.read_bytes() == first_bytes, "live sibling registration overwritten"
        assert second.wait(timeout=12) == 0, "second clean exit failed"
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
        # Concurrent siblings must retain the first live publisher, both serving.
        left = start("left", first_port, 15)
        right = start("right", second_port, 15)
        deadline = time.monotonic() + 8
        while not (record.exists() and ping(first_port) and ping(second_port)):
            assert left.poll() is None and right.poll() is None and time.monotonic() < deadline, "concurrent endpoints unavailable"
        winner_bytes = record.read_bytes()
        winner = json.loads(winner_bytes)["pid"]
        assert winner in (left.pid, right.pid), "concurrent winner unknown"
        states = []
        for port in (first_port, second_port):
            initialized = rpc(port, "initialize")
            result = initialized.get("result")
            assert isinstance(result, dict), "initialize unavailable"
            meta = result.get("_meta")
            assert isinstance(meta, dict), "registration status missing"
            states.append(meta.get("registration_status"))
        assert sorted(states) == ["profile_occupied", "registered"], "concurrent registration statuses incorrect"
        assert record.read_bytes() == winner_bytes, "concurrent winner overwritten"
        assert left.wait(timeout=25) == 0 and right.wait(timeout=25) == 0 and not record.exists(), "concurrent cleanup failed"
        print(json.dumps({"passed":True, "observations":["identity", "HTTP", "live-sibling", "loser-cleanup", "owner-cleanup", "port-restart", "killed-owner-recovery", "concurrent-first-wins", "status"], "raw_logs":"isolated scratch only"}))
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
