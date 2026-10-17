# Docket agent instructions

## Engineering process

Before writing or reviewing code, read Docket `minerva:01a147ee08057a52ad61a4ba692c255a` (policy) and `minerva:01a147ee229d7787b8b5c4f905763b8d` (language rules).

## Build and test

- After cloning: `git submodule update --init --recursive`; build natives with `./scripts/build/build_gdextension.sh linux x86_64` (or `macos universal` / `windows x86_64`).
- In the isolated checkout, import with `godot --headless --path . --import`, then run `./run_tests.sh`.

## Non-obvious hazards

- Authorized vault replies may contain secrets; do not capture HTTP response bodies or enable diagnostic logging that exposes them.
- Isolate child XDG/APPDATA paths. Opening a `.dct` can write sibling caches or recovery data; it is not a read-only binding.
