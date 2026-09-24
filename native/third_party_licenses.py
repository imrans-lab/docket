#!/usr/bin/env python3
"""Prints the license text of every Rust crate compiled into docket_native.

Usage: native/third_party_licenses.py TARGET[,TARGET...]

Follows the crate's normal dependencies for the given target triples, the
same Cargo.lock as the build. Procedural macros and build-time dependencies
run only while compiling, so nothing of them ships and they are left out.
"""
import json
import pathlib
import subprocess
import sys

CRATE = pathlib.Path(__file__).resolve().parent / "docket_native"


def shipped_packages(target):
    meta = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--locked", "--format-version", "1", "--filter-platform", target],
        cwd=CRATE))
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    root = meta["resolve"]["root"]
    found, stack = {}, [root]
    while stack:
        for dep in nodes[stack.pop()]["deps"]:
            package = packages[dep["pkg"]]
            normal = any(kind["kind"] is None for kind in dep["dep_kinds"])
            macro = all("proc-macro" in t["kind"] for t in package["targets"] if "lib" in t["kind"] or "proc-macro" in t["kind"])
            if normal and not macro and dep["pkg"] not in found:
                found[dep["pkg"]] = package
                stack.append(dep["pkg"])
    return found.values()


def main():
    print("=" * 64)
    print("Rust standard library (std, core, alloc), statically linked (MIT OR Apache-2.0)")
    print("source: https://github.com/rust-lang/rust")
    print("=" * 64)
    print("See https://github.com/rust-lang/rust/blob/master/COPYRIGHT for its license terms.")
    print()
    packages = {}
    for target in sys.argv[1].split(","):
        for package in shipped_packages(target):
            packages[(package["name"], package["version"])] = package
    for (name, version), package in sorted(packages.items()):
        print("=" * 64)
        print(f"{name} {version} (Rust crate, {package.get('license') or 'no license expression'})")
        print(f"source: https://crates.io/crates/{name}/{version}")
        print("=" * 64)
        directory = pathlib.Path(package["manifest_path"]).parent
        texts = sorted(p for p in directory.iterdir()
                       if p.is_file() and p.name.upper().startswith(("LICENSE", "LICENCE", "COPYING")))
        if not texts:
            print(f"(the crate ships no license file; its declared license is {package.get('license')}"
                  + ("; the MPL-2.0 text is in Docket's LICENSE)" if package.get("license") == "MPL-2.0" else ")"))
        for text in texts:
            print(text.read_text(encoding="utf-8", errors="replace"))
        print()


if __name__ == "__main__":
    main()
