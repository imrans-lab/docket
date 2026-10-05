# Building Docket

## The FCIB rule

**No compilable binaries are checked into this repository.** Nothing that
executes — `.so`, `.dylib`, `.dll`, `.framework`, object files — is ever
committed. Everything that ends up inside a shipped artifact is compiled from
source pinned in `third_party/`.

This is enforced, not just documented: `scripts/build/check_no_binaries.sh` runs
in CI and fails the build if a tracked file has an executable extension or
carries ELF/Mach-O/PE magic bytes.

Source assets with no compiled form — `icon.png`, `icon.svg` — are not build
outputs and are tracked normally.

Why bother: the app bundles a native SQLite extension. If that arrived as a
prebuilt blob from a third-party release, you would be shipping, and eventually
signing, code you never built and cannot audit.

## Prerequisites

- **Godot 4.7+** — standard or headless build (CI pins an exact patch release; see the workflows)
- **SCons** — `pipx install scons` (or `pip install scons`)
- **A C++ toolchain** — Xcode CLT on macOS, gcc/clang on Linux, MSVC on Windows
- **Python 3** — required by SCons

## First build

```bash
git clone --recurse-submodules https://github.com/imrans-lab/docket.git
cd docket

# Already cloned without --recurse-submodules?
git submodule update --init --recursive

# Build the native extension (both debug and release targets)
./scripts/build/build_gdextension.sh macos universal     # or: linux x86_64 / windows x86_64
```

Output lands in `addons/godot-sqlite/bin/`, which is gitignored.

The first build compiles `godot-cpp` and takes roughly 10–20 minutes. Subsequent
builds reuse the object files and take seconds. CI caches this keyed on the
pinned submodule commit.

### Disk cost

Docket's own source is about 1.5 MB. The vendored dependencies are not: a full
recursive clone pulls godot-cpp's entire history (~600 MB of git objects), and
the build then generates another ~250 MB of C++ bindings under
`godot-cpp/gen/` — generated, not stored upstream.

To skip the history you do not need:

```bash
git submodule update --init --recursive --depth 1
```

Nothing here is committed to this repository. `git ls-files` shows 1.5 MB of
source plus a single 40-byte gitlink.

### Both targets are required

`gdsqlite.gdextension` maps `<platform>.debug` and `<platform>.release` to
separate library files. Exported builds load the release library; the Godot
editor and tool binary — which is what runs the test suite — loads the debug
one. The build script builds both by default.

If you build only `template_release`, the extension fails to load under the tool
binary with `Can't open dynamic library: .` and around 50 tests fail in ways
that look like unrelated SQLite bugs.

## Running

```bash
# First run in a fresh clone: import assets and register class_name globals
godot --headless --path . --import

# GUI
godot --path .

# Headless MCP server
godot --headless --path . -- serve --port 3010

# Tests
./run_tests.sh                      # uses $GODOT or auto-detects a Godot binary
GODOT=/opt/homebrew/bin/godot ./run_tests.sh
```

`--import` matters after adding any script with a `class_name`. Godot registers
those globals during a filesystem scan; a headless run without one fails to
resolve the identifier and the process hangs rather than reporting an error.

## Exporting

Export presets live in `export_presets.cfg`: `macOS` (universal), `Linux`
(x86_64), `Windows` (x86_64). Export templates for your Godot version must be
installed.

```bash
godot --headless --path . --export-release "Linux" build/linux/docket.x86_64
```

Artifacts are unsigned. See [SIGNING.md](SIGNING.md).

## Vendored dependencies

| Path | Upstream | Pinned at | License |
|------|----------|-----------|---------|
| `third_party/godot-sqlite` | [2shady4u/godot-sqlite](https://github.com/2shady4u/godot-sqlite) | `v4.7` | MIT |
| `third_party/godot-sqlite/godot-cpp` | [godotengine/godot-cpp](https://github.com/godotengine/godot-cpp) | pinned by godot-sqlite | MIT |

To move to a new godot-sqlite release:

```bash
cd third_party/godot-sqlite
git fetch --tags && git checkout --detach v4.8
cd ../.. && git add third_party/godot-sqlite
git submodule update --init --recursive     # refresh the nested godot-cpp pin
```

Then rebuild and run the tests before committing the new pin.

If a local patch is ever needed, add it under `third_party/patches/` and apply
it from the build script — never commit modified vendored source in place, so
the delta from upstream stays visible.

The same wrapper builds Docket's file-identity extension from `native/file_identity`
and the unchanged pinned godot-cpp source, in a private temporary build copy.
Both debug and release libraries are mapped by its descriptor; macOS builds are
universal dylibs exported and signed as nested app libraries by Godot. Outputs
and a candidate/dependency/hash build stamp live in the ignored addon `bin/`.
Identity query errors or missing libraries refuse cross-project moves. CI must
execute the identity fixtures on Linux, macOS and Windows before acceptance.

Release exports also run `python test/test_export_native_bundle.py linux` (or
`macos` / `windows`). This copies the actual export outside the checkout, proves
engine `user://` containment, checks the descriptor-mapped release helper and
its architecture, then executes all 11 existing native identity scenarios.
An escaped userdir boundary must fail before any test runs. A separate
disposable copy missing the helper must fail the presence verifier.
macOS copies use `ditto` and verify the existing deep strict signature; the
positive signed app is never modified.

Manual Release dispatch defaults to a nonpublishing preview: `source_ref`
selects the exact candidate independently of `tag`, build identity comes from
`git describe` and the actual commit, and artifact filenames use `preview-<SHA>`.
The entire signing/publish job is skipped. Tag pushes still publish; explicit
manual publication requires an existing tag identifying the checked-out HEAD.
Three-platform exported preview evidence is required before release acceptance.
