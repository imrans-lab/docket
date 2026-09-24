#!/usr/bin/env python3
"""Stage Docket as a plugin a host (Minerva) installs: its panel (the Docket
UI, embedded) and the Docket process the panel talks to, in one directory.

The panel's files are found from its scene by following what each file loads
(ext_resource paths, preload()/load() and extends of literal paths, all
relative to the file), plus the schema the UI reads beside it. Every one must
exist, none may use a res:// path (the host is not this project) or declare
a class_name (a host accepts only names prefixed for the plugin, and the
panel needs none), and every tool
RemoteDocketSource calls must be one of the panel's IPC channels.

A release package carries the whole release export of one target
(plugin_export.py checks it: executable, native and SQLite libraries, and on
macOS the bundle, copied intact), and the host starts its executable from
there: there is no fallback to a Godot on PATH or to these sources.
--dev-godot and --dev-checkout instead write a package whose process is an
explicit Godot running this checkout, named as a development build; it is
never a release.

Usage:
  package_plugin.py --out DIR --version VERSION --target linux|windows|macos --export-root EXPORT
  package_plugin.py --out DIR --dev-godot GODOT --dev-checkout CHECKOUT

EXPORT is the directory Godot exported Linux or Windows into (build/linux,
build/windows), or the macOS bundle itself (build/macos/Docket.app).
"""
import argparse
import json
import os
import posixpath
import re
import shutil
import sys

import plugin_export

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ENTRY_SCENE = "scripts/panel/docket_panel.tscn"
MANIFEST_TEMPLATE = "scripts/panel/plugin_manifest.json"
REMOTE_SOURCE = "scripts/ui/remote_docket_source.gd"
# Read by the UI at run time by a path built from its own (not a preload).
RUNTIME_FILES = ["data/schema.json"]
# The Docket process, as the host starts it: stdio MCP with item events,
# serving only the projects the host opens (no session of its own).
BACKEND_ARGS = ["--headless", "--no-header", "--", "--serve", "--stdio", "--host-events", "--host-managed"]

# What a script loads by a literal path, and a scene's ext_resource paths.
SCRIPT_LOADS = re.compile(r"""(?:\bpreload|\bload)\(\s*["']([^"']+)["']\s*\)|^extends\s+["']([^"']+)["']""", re.M)
SCENE_LOADS = re.compile(r'^\[ext_resource\b[^\]]*\bpath="([^"]+)"', re.M)
CLASS_NAME = re.compile(r"^class_name\b", re.M)
TOOL_CALL = re.compile(r'_(?:call|mutate)\(\s*"(docket_[a-z_]+)"')


class PackageError(Exception):
    pass


def closure(entry):
    """The repository paths `entry` loads, directly or not, itself included."""
    found, pending = set(), [entry]
    while pending:
        path = pending.pop()
        if path in found:
            continue
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full):
            raise PackageError("%s is loaded but does not exist" % path)
        found.add(path)
        pattern = SCRIPT_LOADS if path.endswith(".gd") else SCENE_LOADS if path.endswith(".tscn") else None
        if pattern is None:
            continue
        text = open(full, encoding="utf-8").read()
        for match in pattern.finditer(text):
            target = next(group for group in match.groups() if group)
            if target.startswith("res://") or target.startswith("user://"):
                raise PackageError("%s loads %s; a packaged panel file may only load by relative path" % (path, target))
            # Package paths are "/"-separated on every platform.
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
            if resolved.startswith(".."):
                raise PackageError("%s loads %s, outside the repository" % (path, target))
            pending.append(resolved)
    return sorted(found)


def check(files, manifest):
    for path in files:
        if path.endswith(".gd") and CLASS_NAME.search(open(os.path.join(ROOT, path), encoding="utf-8").read()):
            raise PackageError("%s declares a class_name, which the host refuses" % path)
    channels = set(manifest["ui"]["panels"][0]["ipc_channels"])
    called = set(TOOL_CALL.findall(open(os.path.join(ROOT, REMOTE_SOURCE), encoding="utf-8").read()))
    missing = sorted(called - channels)
    if missing:
        raise PackageError("tools the panel calls are not IPC channels of its manifest: %s" % ", ".join(missing))


def stage(out, files, manifest, export):
    """Write the package: `files` from the repository, the checked `export`
    (if any), the manifest, and SHA256SUMS over every file in it."""
    os.makedirs(out)
    for path in files:
        target = os.path.join(out, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(os.path.join(ROOT, path), target)
    if export is not None:
        plugin_export.copy(export, out)
    with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent="\t")
        handle.write("\n")
    sums = []
    for base, _dirs, names in os.walk(out):
        for name in names:
            path = os.path.join(base, name)
            if os.path.islink(path):
                continue
            sums.append("%s  %s" % (plugin_export.file_digest(path), os.path.relpath(path, out).replace(os.sep, "/")))
    sums.sort(key=lambda line: line[66:])
    with open(os.path.join(out, "SHA256SUMS"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(sums) + "\n")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("--version")
    parser.add_argument("--target")
    parser.add_argument("--export-root")
    parser.add_argument("--dev-godot")
    parser.add_argument("--dev-checkout")
    args = parser.parse_args(argv)
    dev = args.dev_godot is not None or args.dev_checkout is not None
    if dev and (args.target or args.export_root or args.version):
        raise PackageError("a development package takes --dev-godot and --dev-checkout only")
    if dev and not (args.dev_godot and args.dev_checkout):
        raise PackageError("a development package needs both --dev-godot and --dev-checkout")
    if not dev and not (args.target and args.export_root and args.version):
        raise PackageError("a release package needs --target, --export-root (the release export) and --version")
    if os.path.exists(args.out):
        raise PackageError("%s already exists" % args.out)

    manifest = json.load(open(os.path.join(ROOT, MANIFEST_TEMPLATE), encoding="utf-8"))
    files = closure(ENTRY_SCENE)
    files += [path for path in RUNTIME_FILES if path not in files]
    for path in RUNTIME_FILES:
        if not os.path.isfile(os.path.join(ROOT, path)):
            raise PackageError("%s is read by the UI but does not exist" % path)
    check(files, manifest)
    panel = manifest["ui"]["panels"][0]
    panel["scripts"] = [path for path in files if path.endswith(".gd")]
    # The host allows a panel only the channels the plugin lists as its own.
    manifest["ui"]["ipc_messages"] = list(panel["ipc_channels"])

    if dev:
        godot, checkout = os.path.abspath(args.dev_godot), os.path.abspath(args.dev_checkout)
        if not os.path.isfile(godot) or not os.path.isfile(os.path.join(checkout, "project.godot")):
            raise PackageError("--dev-godot must be a Godot executable and --dev-checkout a Docket checkout")
        manifest["name"] += " (development)"
        manifest["version"] = "0.0.0-dev"
        manifest["backend"]["entrypoint"] = godot
        manifest["backend"]["args"] = ["--headless", "--no-header", "--path", checkout] + BACKEND_ARGS[2:]
        stage(args.out, files, manifest, None)
        return 0

    try:
        export = plugin_export.inspect(ROOT, args.target, args.export_root)
    except plugin_export.ExportError as error:
        raise PackageError(str(error))
    manifest["version"] = args.version
    manifest["backend"]["entrypoint"] = "./" + export.entrypoint
    manifest["backend"]["args"] = BACKEND_ARGS
    try:
        stage(args.out, files, manifest, export)
    except plugin_export.ExportError as error:
        raise PackageError(str(error))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except PackageError as error:
        print("package_plugin: %s" % error, file=sys.stderr)
        sys.exit(1)
