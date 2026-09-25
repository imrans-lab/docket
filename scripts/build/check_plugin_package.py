#!/usr/bin/env python3
"""Checks a Docket plugin archive the way a host receives it, outside this
checkout: extracted with tar into a new temporary directory, every file
matching SHA256SUMS and every file listed there (a macOS bundle must also
still verify its signature), and the backend started with the manifest's
entrypoint and arguments (without a host's panel secret, so the panel
channel stays closed).

Over stdio it then opens a new project in a temporary directory, creates an
item there (which must be announced as an item_changed host event) and
closes stdin, after which the process must exit 0. A second start of the
same backend opens that project again and must read the item back.

Every reply, and each exit, has a time limit; missing one, an error reply,
a nonzero exit or a crash fails the check, and the backend's stderr is shown.

Usage: check_plugin_package.py <archive.tar.gz> <version>
"""
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

import plugin_export

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
# A backend starting for the first time may be slow (a macOS first launch
# assesses the bundle), so a reply's limit is generous; a hang still ends.
REPLY_TIMEOUT_S = 120
EXIT_TIMEOUT_S = 60
TOOL_TIMEOUT_S = 600
ITEM_TITLE = "plugin package check"


class CheckError(Exception):
    pass


def check_files(package):
    """Every file SHA256SUMS lists matches, and it lists every other file."""
    listed = {}
    with open(os.path.join(package, "SHA256SUMS"), encoding="utf-8") as handle:
        for line in handle.read().splitlines():
            if line:
                hexdigest, name = line.split("  ", 1)
                listed[name] = hexdigest
    present = set()
    for base, _dirs, names in os.walk(package):
        for name in names:
            path = os.path.join(base, name)
            relative = os.path.relpath(path, package).replace(os.sep, "/")
            if relative != "SHA256SUMS" and not os.path.islink(path):
                present.add(relative)
    if present != set(listed):
        raise CheckError("SHA256SUMS does not list exactly the package's files: missing %s, unlisted %s"
                         % (sorted(set(listed) - present), sorted(present - set(listed))))
    for name, hexdigest in listed.items():
        if plugin_export.file_digest(os.path.join(package, name)) != hexdigest:
            raise CheckError("%s does not match SHA256SUMS" % name)


class Backend:
    """The package's backend as its manifest starts it, speaking
    newline-delimited JSON-RPC on stdin/stdout."""

    def __init__(self, package, manifest, run_dir, env):
        backend = manifest["backend"]
        command = [os.path.normpath(os.path.join(package, backend["entrypoint"]))] + backend["args"]
        self.process = subprocess.Popen(command, cwd=run_dir, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.lines = queue.Queue()
        self.events = []
        self.stderr = []
        self.next_id = 1
        self.readers = [threading.Thread(target=self._read, args=(self.process.stdout, self.lines.put), daemon=True),
                        threading.Thread(target=self._read, args=(self.process.stderr, self.stderr.append), daemon=True)]
        for reader in self.readers:
            reader.start()

    @staticmethod
    def _read(stream, put):
        for raw in stream:
            put(raw.decode("utf-8", "replace").rstrip("\r\n"))
        put(None)

    def send(self, message):
        self.process.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
        self.process.stdin.flush()

    def request(self, method, params):
        """The result of `method`; notifications read meanwhile are kept."""
        request_id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + REPLY_TIMEOUT_S
        while True:
            try:
                line = self.lines.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty:
                raise CheckError("no reply to %s within %d s" % (method, REPLY_TIMEOUT_S))
            if line is None:
                raise CheckError("the backend closed its output before replying to %s" % method)
            try:
                message = json.loads(line)
            except ValueError:
                raise CheckError("the backend wrote a line that is not JSON-RPC: %r" % line)
            if "id" not in message:
                self.events.append(message)
            elif message["id"] == request_id:
                if "error" in message:
                    raise CheckError("%s failed: %s" % (method, message["error"]))
                return message["result"]

    def call(self, tool, arguments):
        result = self.request("tools/call", {"name": tool, "arguments": arguments})
        text = result["content"][0]["text"]
        if result.get("isError"):
            raise CheckError("%s failed: %s" % (tool, text))
        return json.loads(text)

    def stop(self):
        """Closes stdin, as a host does, and requires a clean exit."""
        self.process.stdin.close()
        try:
            code = self.process.wait(timeout=EXIT_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            raise CheckError("the backend did not exit within %d s of stdin closing" % EXIT_TIMEOUT_S)
        if code != 0:
            raise CheckError("the backend exited %d" % code)

    def kill(self):
        """Ends the process if it still runs, and waits for its output."""
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        for reader in self.readers:
            reader.join(timeout=EXIT_TIMEOUT_S)


def session(package, manifest, run_dir, env, steps):
    backend = Backend(package, manifest, run_dir, env)
    try:
        info = backend.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                              "clientInfo": {"name": "check_plugin_package", "version": "1"}})
        if info.get("serverInfo", {}).get("name") != "docket":
            raise CheckError("initialize answered %s" % info)
        backend.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        result = steps(backend)
        backend.stop()
        return result
    finally:
        backend.kill()
        if backend.stderr:
            print("--- backend stderr ---\n" + "\n".join(line for line in backend.stderr if line is not None))


def check(archive, version, work):
    package = os.path.join(work, "package")
    os.makedirs(package)
    # Relative names only, so no tar can read a drive letter as a host name.
    shutil.copyfile(archive, os.path.join(work, "plugin.tar.gz"))
    subprocess.run(["tar", "-xzf", "plugin.tar.gz", "-C", "package"], cwd=work, check=True, timeout=TOOL_TIMEOUT_S)
    check_files(package)
    with open(os.path.join(package, "manifest.json"), encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest["id"] != "docket" or manifest["version"] != version or manifest["backend"]["transport"] != "stdio":
        raise CheckError("the manifest is not Docket %s over stdio: %s" % (version, manifest))
    if sys.platform == "darwin":
        bundle = manifest["backend"]["entrypoint"].split("/Contents/MacOS/")[0]
        subprocess.run(["codesign", "--verify", "--deep", "--strict", os.path.join(package, bundle)],
                       check=True, timeout=TOOL_TIMEOUT_S)
    channels = manifest["ui"]["panels"][0]["ipc_channels"]

    # On Linux and macOS the backend's Godot user data stays in the work
    # directory; its native coordination directory is found from the OS
    # account, not the environment, so it stays in the account's home. On
    # Windows the backend gets this environment as it is, so its user data
    # goes to the account's own profile: the native coordinator asks Windows
    # for the local application data folder (SHGetKnownFolderPath), and
    # USERPROFILE, APPDATA and LOCALAPPDATA pointed into the work directory
    # can make that fail (0x80070002).
    env = dict(os.environ)
    if sys.platform != "win32":
        home = os.path.join(work, "home")
        env.update(HOME=home, USERPROFILE=home, APPDATA=os.path.join(home, "appdata"),
                   LOCALAPPDATA=os.path.join(home, "localappdata"), XDG_DATA_HOME=os.path.join(home, "data"),
                   XDG_CONFIG_HOME=os.path.join(home, "config"), XDG_CACHE_HOME=os.path.join(home, "cache"))
        for variable in ["APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]:
            os.makedirs(env[variable], exist_ok=True)
    run_dir = os.path.join(work, "run")
    os.makedirs(run_dir)
    project = os.path.join(work, "projects", "check.dct")
    os.makedirs(os.path.dirname(project))

    def create(backend):
        tools = {tool["name"] for tool in backend.request("tools/list", {})["tools"]}
        missing = sorted(set(channels) - tools)
        if missing:
            raise CheckError("the backend lacks the panel's tools: %s" % ", ".join(missing))
        opened = backend.call("docket_project_add", {"path": project, "create": True})
        created = backend.call("docket_create", {"type": "chore", "title": ITEM_TITLE, "project": opened["name"]})
        # Announced as the change is committed, before the call's reply.
        announced = [event for event in backend.events if event.get("method") == "minerva/plugin_event"
                     and event["params"]["event"] == "item_changed"
                     and event["params"]["payload"].get("id") == created["id"]]
        if not announced:
            raise CheckError("creating %s sent no item_changed event: %s" % (created["id"], backend.events))
        return created["id"]

    def read_back(backend):
        opened = backend.call("docket_project_add", {"path": project})
        item = backend.call("docket_get", {"id": item_id, "project": opened["name"], "include": []})
        if item.get("title") != ITEM_TITLE:
            raise CheckError("the reopened project has %s as %s" % (item_id, item))

    item_id = session(package, manifest, run_dir, env, create)
    session(package, manifest, run_dir, env, read_back)
    print("%s: Docket %s starts from its extracted package, keeps an item across a restart, and stops cleanly"
          % (os.path.basename(archive), version))


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    work = tempfile.mkdtemp(prefix="docket-plugin-check-")
    checkout = os.path.realpath(ROOT)
    try:
        inside = os.path.commonpath([os.path.realpath(work), checkout]) == checkout
    except ValueError:
        inside = False  # on another Windows drive
    if inside:
        shutil.rmtree(work, ignore_errors=True)
        raise CheckError("the temporary directory %s is inside the checkout" % work)
    try:
        check(argv[0], argv[1], work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (CheckError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print("check_plugin_package: %s" % error, file=sys.stderr)
        sys.exit(1)
