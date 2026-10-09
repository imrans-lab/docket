# Docket agent instructions

## Engineering process

Before writing or reviewing code, read Docket `Master:01a11a91820a` (policy) and `Master:01a11c7bf705` (language rules).

## Build and test

- After cloning: `git submodule update --init --recursive`; build natives with `./scripts/build/build_gdextension.sh linux x86_64` (or `macos universal` / `windows x86_64`).
- In the isolated checkout, import with `godot --headless --path . --import`, then run `./run_tests.sh`.

## Non-obvious hazards

- STDIO must use `--quiet`; keep diagnostics off stdout and never enable `--log-file` (authorized vault replies may contain secrets). Close stdin, drain output and wait for clean settlement before replacing the process.
- `--state-dir` does not isolate Godot's engine profile or redirect project/cache paths. Isolate child XDG/APPDATA paths. Opening a `.dct` can write sibling caches or recovery data; it is not a read-only binding.
