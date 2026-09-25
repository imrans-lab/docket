#!/usr/bin/env bash
# The headless Godot editor Docket's CI and release run: official Godot
# 4.7.1 source (third_party/godot/PINS) with editor-null-doc-guard.patch
# applied, built from source for this runner. The patch touches the editor
# only (a doc generation queued past the docs' teardown is skipped instead
# of crashing the first import of a project with a native extension);
# exports still use the official templates (install_godot_templates.sh).
#
# Into an empty <out-dir> it fetches the pinned commit, checks it is exactly
# that, applies the patch, checks the result is the pinned tree, builds, and
# writes <out-dir>/manifest.txt: inputs, toolchain, options, the
# executable's SHA-256 and its --version. Given an <out-dir> that already
# holds a build (restored from a cache keyed on these inputs), it only
# checks that the manifest names these pins, this platform and the
# executable as it is, and fails otherwise; it never falls back to another
# binary. Either way it prints the executable's path last.
#
# Usage: build_godot_editor.sh <linux|macos|windows> <x86_64|arm64> <out-dir>
set -euo pipefail

PLATFORM="${1:?usage: build_godot_editor.sh <platform> <arch> <out-dir>}"
ARCH="${2:?usage: build_godot_editor.sh <platform> <arch> <out-dir>}"
OUT="${3:?usage: build_godot_editor.sh <platform> <arch> <out-dir>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../third_party/godot/PINS
source "$ROOT/third_party/godot/PINS"
PATCH="$ROOT/third_party/godot/editor-null-doc-guard.patch"

sha256() { if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

case "$PLATFORM/$ARCH" in
	linux/x86_64) SCONS_PLATFORM=linuxbsd; EXE=godot ;;
	macos/arm64|macos/x86_64) SCONS_PLATFORM=macos; EXE=godot ;;
	# The console executable, so the editor's output reaches the log.
	windows/x86_64) SCONS_PLATFORM=windows; EXE=godot.console.exe ;;
	*) echo "unsupported platform/arch: $PLATFORM/$ARCH" >&2; exit 1 ;;
esac
# The official editor's modules, optimized, without link-time optimization
# (it only makes the build slower) or debug symbols. CI runs this editor only
# with --headless (import, export, scripts, GDExtensions), so the display and
# accessibility drivers that need an SDK or build tool the runners lack are
# left out rather than built only where a runner happens to have it.
OPTIONS=(target=editor production=yes lto=none debug_symbols=no)
case "$SCONS_PLATFORM" in
	macos) OPTIONS+=(vulkan=no angle=no accesskit=no) ;;
	windows) OPTIONS+=(d3d12=no angle=no accesskit=no) ;;
	linuxbsd) OPTIONS+=(accesskit=no wayland=no) ;;
esac
PATCH_SHA="$(sha256 "$PATCH")"

# The manifest lines that name the inputs; a restored build must match them.
expected_inputs() {
	printf '%s\n' "source $GODOT_SOURCE_REPO $GODOT_SOURCE_COMMIT" "patch $PATCH_SHA" \
		"patched_tree $GODOT_PATCHED_TREE" "build_name $GODOT_BUILD_NAME" \
		"platform $PLATFORM $ARCH" "options ${OPTIONS[*]}"
}

if [ -f "$OUT/manifest.txt" ]; then
	expected_inputs | while IFS= read -r line; do
		grep -qxF "$line" "$OUT/manifest.txt" || { echo "the editor in $OUT was not built from these inputs (no '$line')" >&2; exit 1; }
	done
	recorded="$(sed -n 's/^executable_sha256 //p' "$OUT/manifest.txt")"
	[ -f "$OUT/$EXE" ] && [ "$(sha256 "$OUT/$EXE")" = "$recorded" ] \
		|| { echo "$OUT/$EXE is not the executable its manifest records" >&2; exit 1; }
	if [ "$SCONS_PLATFORM" = windows ]; then
		[ -f "$OUT/godot.exe" ] && [ "$(sha256 "$OUT/godot.exe")" = "$(sed -n 's/^editor_sha256 //p' "$OUT/manifest.txt")" ] \
			|| { echo "$OUT/godot.exe is not the editor its manifest records" >&2; exit 1; }
	fi
	cat "$OUT/manifest.txt" >&2
	echo "$OUT/$EXE"
	exit 0
fi

[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "$OUT holds something other than a build; start from an empty directory" >&2; exit 1; }
mkdir -p "$OUT"
SRC="$OUT/source"
git init -q "$SRC"
git -C "$SRC" fetch -q --depth 1 "$GODOT_SOURCE_REPO" "$GODOT_SOURCE_COMMIT"
git -C "$SRC" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
[ "$(git -C "$SRC" rev-parse HEAD)" = "$GODOT_SOURCE_COMMIT" ] || { echo "the fetched source is not $GODOT_SOURCE_COMMIT" >&2; exit 1; }
[ -z "$(git -C "$SRC" status --porcelain)" ] || { echo "the fetched source is not clean" >&2; exit 1; }
# Applied to the index, then checked out, so the Godot checkout's line
# endings do not matter (the patch's own are pinned LF by
# third_party/godot/.gitattributes); the result must be exactly the pinned
# tree.
git -C "$SRC" apply --cached "$PATCH"
[ "$(git -C "$SRC" write-tree)" = "$GODOT_PATCHED_TREE" ] || { echo "the patched source is not tree $GODOT_PATCHED_TREE" >&2; exit 1; }
git -C "$SRC" diff --cached --name-only -z | xargs -0 git -C "$SRC" checkout --

JOBS="$(nproc 2> /dev/null || sysctl -n hw.ncpu)"
(cd "$SRC" && BUILD_NAME="$GODOT_BUILD_NAME" scons -j"$JOBS" platform="$SCONS_PLATFORM" arch="$ARCH" "${OPTIONS[@]}") >&2
if [ "$SCONS_PLATFORM" = windows ]; then
	cp "$SRC/bin/godot.windows.editor.$ARCH.console.exe" "$OUT/$EXE"
	# The console executable starts the one named as it is, less ".console".
	cp "$SRC/bin/godot.windows.editor.$ARCH.exe" "$OUT/godot.exe"
else
	cp "$SRC/bin/godot.$SCONS_PLATFORM.editor.$ARCH" "$OUT/$EXE"
fi
chmod +x "$OUT/$EXE"

VERSION="$("$OUT/$EXE" --headless --version | tr -d '\r')"
case "$VERSION" in
	4.7.1.stable.$GODOT_BUILD_NAME.*) ;;
	*) echo "the built editor reports version '$VERSION', not 4.7.1.stable.$GODOT_BUILD_NAME" >&2; exit 1 ;;
esac
{
	expected_inputs
	echo "scons $(scons --version | grep -m1 'SCons: v' | sed 's/^[[:space:]]*//')"
	case "$SCONS_PLATFORM" in
		# SCons finds MSVC itself; cl is not on this shell's path.
		windows) echo "compiler MSVC $("/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -latest -property catalog_productDisplayVersion)" ;;
		*) echo "compiler $(c++ --version | head -1)" ;;
	esac
	echo "version $VERSION"
	echo "executable_sha256 $(sha256 "$OUT/$EXE")"
	if [ "$SCONS_PLATFORM" = windows ]; then echo "editor_sha256 $(sha256 "$OUT/godot.exe")"; fi
} > "$OUT/manifest.txt"
rm -rf "$SRC"
cat "$OUT/manifest.txt" >&2
echo "$OUT/$EXE"
