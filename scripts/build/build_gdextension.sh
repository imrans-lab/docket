#!/usr/bin/env bash
## Build the godot-sqlite GDExtension from vendored source.
##
## Docket does not check in or download prebuilt binaries: everything that ends
## up inside a shipped bundle is compiled here, from source pinned in
## third_party/. See docs/BUILDING.md.
##
## Usage:
##   scripts/build/build_gdextension.sh <platform> [arch] [target]
##
##   platform  macos | linux | windows
##   arch      universal | x86_64 | arm64   (default: platform-appropriate)
##   target    template_release | template_debug | all   (default: all)
##
## Both targets are built by default, and both are needed. gdsqlite.gdextension
## maps <platform>.debug and <platform>.release to separate library files:
## exported builds load the release one, but the Godot editor/tool binary — which
## is what runs `-- test` in CI — loads the debug one. Building only release
## leaves the debug entry pointing at a missing file, and the extension fails to
## load with "Can't open dynamic library: ." while most tests still pass.
##
## Output lands in addons/godot-sqlite/bin/, which is gitignored.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SQLITE_SRC="$REPO_ROOT/third_party/godot-sqlite"
OUT_DIR="$REPO_ROOT/addons/godot-sqlite/bin"

PLATFORM="${1:?platform required: macos | linux | windows}"
ARCH="${2:-}"
TARGET="${3:-all}"

if [[ -z "$ARCH" ]]; then
	case "$PLATFORM" in
		macos) ARCH="universal" ;;
		*)     ARCH="x86_64" ;;
	esac
fi

# -- Preconditions ------------------------------------------------------------

if [[ ! -f "$SQLITE_SRC/SConstruct" ]]; then
	echo "error: $SQLITE_SRC is empty — run: git submodule update --init --recursive" >&2
	exit 1
fi
if [[ ! -f "$SQLITE_SRC/godot-cpp/SConstruct" ]]; then
	echo "error: godot-cpp submodule missing — run: git submodule update --init --recursive" >&2
	exit 1
fi
if ! command -v scons >/dev/null 2>&1; then
	echo "error: scons not found. Install it (pip install scons) and retry." >&2
	exit 1
fi

# -- Build --------------------------------------------------------------------

mkdir -p "$OUT_DIR"

if [[ "$TARGET" == "all" ]]; then
	TARGETS=(template_release template_debug)
else
	TARGETS=("$TARGET")
fi

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

for t in "${TARGETS[@]}"; do
	echo "==> Building godot-sqlite: platform=$PLATFORM arch=$ARCH target=$t"
	echo "    source:  $SQLITE_SRC ($(git -C "$SQLITE_SRC" rev-parse --short HEAD))"
	echo "    output:  $OUT_DIR"

	# godot-sqlite's SConstruct takes target_path/target_name and appends the
	# platform/arch/target suffixes itself, matching gdsqlite.gdextension's
	# expected library filenames. The trailing slash on target_path is required.
	scons -C "$SQLITE_SRC" \
		platform="$PLATFORM" \
		target="$t" \
		arch="$ARCH" \
		target_path="$OUT_DIR/" \
		target_name="libgdsqlite" \
		-j"$JOBS"
done

echo "==> Built artifacts:"
ls -la "$OUT_DIR"
