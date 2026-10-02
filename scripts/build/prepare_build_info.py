#!/usr/bin/env python3
"""Generate one build identity, then project it into valid platform versions."""
import argparse
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def prepare(tag: str) -> None:
    commit = git("rev-parse", "HEAD")
    if tag:
        if git("rev-parse", f"refs/tags/{tag}^{{commit}}") != commit:
            raise ValueError("release tag does not identify the checked-out commit")
        version = tag
    else:
        version = git("describe", "--tags", "--always")
    match = re.match(r"^v?(\d+)\.(\d+)\.(\d+)(?:-|$)", version)
    if match is None:
        raise ValueError(f"cannot derive platform numeric versions from {version!r}")
    major, minor, patch = map(int, match.groups())
    # CFBundleVersion's documented numeric widths are narrower than Windows'.
    if major >= 9999 or minor > 99 or patch > 99:
        raise ValueError("version exceeds macOS numeric component widths")
    numeric = f"{major}.{minor}.{patch}"
    info = {"version": version, "commit": commit,
            "macos_short_version": numeric, "macos_version": f"{major + 1}.{minor}.{patch}",
            "windows_version": numeric + ".0"}
    (ROOT / "build_info.json").write_text(json.dumps(info, indent=2) + "\n")
    # The generated JSON is the sole input to export stamping.
    stamp(json.loads((ROOT / "build_info.json").read_text()))


def stamp(info: dict[str, str]) -> None:
    preset = ROOT / "export_presets.cfg"
    text = preset.read_text()
    values = {"application/short_version": info["macos_short_version"],
              "application/version": info["macos_version"],
              "application/file_version": info["windows_version"],
              "application/product_version": info["windows_version"]}
    for key, value in values.items():
        text, count = re.subn(rf'^{re.escape(key)}="[^"]*"$',
                              f'{key}="{value}"', text, flags=re.MULTILINE)
        if count != 1:
            raise ValueError(f"expected one preset field {key}, found {count}")
    preset.write_text(text)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default="")
    prepare(parser.parse_args().tag)
