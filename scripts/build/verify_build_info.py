#!/usr/bin/env python3
"""Assert exported runtime identity and native metadata against generated JSON."""
import argparse
import json
import os
import pathlib
import plistlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]


def exported_binary(platform: str, root: pathlib.Path = ROOT) -> pathlib.Path:
    if platform == "macos":
        contents = root / "build/macos/Docket.app/Contents"
        with (contents / "Info.plist").open("rb") as source:
            return contents / "MacOS" / plistlib.load(source)["CFBundleExecutable"]
    return root / ("build/windows/Docket.exe" if platform == "windows"
                   else "build/linux/docket.x86_64")


def verify(platform: str) -> None:
    expected = json.loads((ROOT / "build_info.json").read_text())
    if platform == "macos":
        bundle = ROOT / "build/macos/Docket.app/Contents"
        with (bundle / "Info.plist").open("rb") as source:
            plist = plistlib.load(source)
        assert plist["CFBundleShortVersionString"] == expected["macos_short_version"], plist
        assert plist["CFBundleVersion"] == expected["macos_version"], plist
        binary = bundle / "MacOS" / plist["CFBundleExecutable"]
    elif platform == "windows":
        binary = ROOT / "build/windows/Docket.exe"
        env = os.environ.copy()
        env["DOCKET_EXPORT_BINARY"] = str(binary)
        command = """$v=[Diagnostics.FileVersionInfo]::GetVersionInfo($env:DOCKET_EXPORT_BINARY)
@{file=@($v.FileMajorPart,$v.FileMinorPart,$v.FileBuildPart,$v.FilePrivatePart);product=@($v.ProductMajorPart,$v.ProductMinorPart,$v.ProductBuildPart,$v.ProductPrivatePart)} | ConvertTo-Json -Compress"""
        stamped = json.loads(subprocess.check_output(
            ["powershell", "-NoProfile", "-Command", command], env=env, text=True))
        numeric = list(map(int, expected["windows_version"].split(".")))
        assert stamped["file"] == numeric and stamped["product"] == numeric, stamped
    else:
        binary = ROOT / "build/linux/docket.x86_64"
    from verify_native_bundle import staged_bundle, run
    with staged_bundle(platform, ROOT) as (binary, base, env):
        output = run(binary, base, env, ["--", "--build-info"])
    rows = [json.loads(line) for line in output.splitlines() if line.startswith('{"')]
    assert len(rows) == 1, output
    actual = rows[0]
    identity = expected["version"] + "+" + expected["commit"]
    assert actual.pop("identity") == identity, actual
    assert actual.pop("server_version") == identity, actual
    assert actual == expected, (actual, expected)
    print(f"Verified {platform} exported build: {identity}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["linux", "macos", "windows"])
    verify(parser.parse_args().platform)
