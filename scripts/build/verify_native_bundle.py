#!/usr/bin/env python3
"""Run the existing native identity scenarios using only an exported bundle."""
import argparse
from contextlib import contextmanager
import configparser
import json
import os
import pathlib
import re
import shutil
import struct
import subprocess
import tempfile

from verify_build_info import ROOT, exported_binary


class BundleError(RuntimeError):
    pass


def run(binary, base, env, args, timeout=180):
    cwd = base / "build" / binary.relative_to(base / "build").parts[0]
    result = subprocess.run([str(binary), "--headless", *args], cwd=cwd,
                            env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    print(result.stdout, end="", flush=True)
    engine_error = re.search(
        r"SCRIPT ERROR|ERROR:|Can't open dynamic library|Failed loading", result.stdout)
    if "EXPORT_USERDIR_PROBE_FAIL stage=before-tests" in result.stdout:
        if (result.returncode != 1 or engine_error
                or result.stdout.splitlines().count("EXPORT_USERDIR_PROBE_FAIL stage=before-tests") != 1):
            raise BundleError("invalid exported userdir refusal receipt or exit")
        if re.search(r"=== test_|^  (?:PASS|FAIL):", result.stdout, re.MULTILINE):
            raise BundleError("userdir refusal occurred after test traffic")
        raise BundleError("exported userdir probe failed before tests")
    if result.returncode or engine_error:
        raise BundleError("exported child failed or reported an engine/native error")
    return result.stdout


def copy_bundle(platform, source, destination):
    if platform == "macos":
        subprocess.run(["ditto", str(source), str(destination)], check=True, timeout=60)
    else:
        shutil.copytree(source, destination)


@contextmanager
def staged_bundle(platform, root=ROOT, probe_base=None):
    with tempfile.TemporaryDirectory(prefix="docket-export-") as temporary:
        base = pathlib.Path(temporary).resolve()
        if base == root or root in base.parents:
            raise BundleError("bundle scratch must be outside source checkout")
        destination = base / "build" / platform
        destination.parent.mkdir()
        copy_bundle(platform, root / "build" / platform, destination)
        binary = exported_binary(platform, base)
        env = os.environ.copy()
        # Release startup changes cwd into bundle resources before userdir setup.
        private_home = base / "home"
        private_home.mkdir()
        env["HOME"] = str(private_home)
        for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "APPDATA", "LOCALAPPDATA"):
            env[key] = str(base / key)
            pathlib.Path(env[key]).mkdir()
        env["DOCKET_EXPORT_SCRATCH"] = (base if probe_base is None else probe_base).as_posix()
        app = destination / "Docket.app"
        if platform == "macos":
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                           check=True, timeout=60)
        try:
            output = run(binary, base, env, ["--", "test", "--test-class=test_move_identity"])
            if (output.count("EXPORT_USERDIR_PROBE_PASS stage=before-tests") != 1
                    or re.findall(r"Results: (\d+) total, (\d+) passed, (\d+) failed", output) != [("11", "11", "0")]
                    or "Skipped (not executed): 0" not in output or "ALL TESTS PASSED" not in output
                    or len(re.findall(r"^  PASS: test_", output, re.MULTILINE)) != 11):
                raise BundleError("exported native identity oracle requires containment, 11 passed, 0 failed, 0 skipped")
            report = base / "userdir-report.json"
            if not report.is_file():
                raise BundleError("exported engine userdir probe produced no report")
            actual = pathlib.Path(json.loads(report.read_text())).resolve()
            if base not in actual.parents or (actual / "docket-fixture-userdir.txt").read_text() != "private fixture marker":
                raise BundleError("exported engine userdir escaped private scratch")
            if platform == "macos" and (actual == app or app in actual.parents):
                raise BundleError("exported engine userdir is inside signed app")
            print(f"EXPORT_USERDIR contained=true platform={platform}", flush=True)
            yield binary, base, env
        finally:
            if platform == "macos":
                subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                               check=True, timeout=60)


def helper_name(platform, root=ROOT):
    descriptor = configparser.ConfigParser()
    descriptor.read(root / "addons/docket-file-identity/file_identity.gdextension")
    key = platform + ".release" + ("" if platform == "macos" else ".x86_64")
    return pathlib.PurePosixPath(descriptor["libraries"][key].strip('"')).name


def find_helper(platform, root, name):
    matches = list((root / "build" / platform).rglob(name))
    if len(matches) != 1 or not matches[0].is_file():
        raise BundleError(f"missing mapped release helper: {name}")
    return matches[0]


def architecture(platform, helper):
    data = helper.read_bytes()
    if platform == "macos":
        arches = subprocess.check_output(["lipo", "-archs", str(helper)], text=True, timeout=30).split()
        valid = set(arches) == {"x86_64", "arm64"}
    elif platform == "linux":
        valid = data[:6] == b"\x7fELF\x02\x01" and struct.unpack_from("<H", data, 18)[0] == 62
    else:
        offset = struct.unpack_from("<I", data, 60)[0]
        valid = data[:2] == b"MZ" and data[offset:offset + 6] == b"PE\0\0\x64\x86"
    if not valid:
        raise BundleError("mapped release helper architecture mismatch")


def verify(platform, root=ROOT):
    name = helper_name(platform)
    architecture(platform, find_helper(platform, root, name))
    with staged_bundle(platform, root) as (binary, base, env):
        architecture(platform, find_helper(platform, base, name))
    print(f"EXPORT_NATIVE PASS platform={platform} tests=11 skipped=0")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["linux", "macos", "windows"])
    verify(parser.parse_args().platform)
