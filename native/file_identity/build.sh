#!/usr/bin/env bash
# Build in a private copy: never emit objects into the pinned dependency checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; TARGET="${3:-all}"
CPP="$ROOT/third_party/godot-sqlite/godot-cpp"
[[ -f "$CPP/SConstruct" ]]
[[ "$(git -C "$ROOT/third_party/godot-sqlite" rev-parse HEAD)" == "$(git -C "$ROOT" rev-parse HEAD:third_party/godot-sqlite)" ]]
[[ "$(git -C "$CPP" rev-parse HEAD)" == "$(git -C "$ROOT/third_party/godot-sqlite" rev-parse HEAD:godot-cpp)" ]]
git -C "$ROOT" diff --quiet HEAD -- native/file_identity
PYTHON=python3; command -v "$PYTHON" >/dev/null || PYTHON=python
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
cp "$ROOT/native/file_identity/"{SConstruct,file_identity.cpp,build_profile.json} "$BUILD/"
mkdir "$BUILD/godot-cpp"
# Tracked source only, excluding old generated output and binaries.
git -C "$CPP" archive HEAD | tar -x -C "$BUILD/godot-cpp"
TARGETS=("$TARGET"); [[ "$TARGET" != all ]] || TARGETS=(template_debug template_release)
for target in "${TARGETS[@]}"; do
    scons -C "$BUILD" platform="$PLATFORM" arch="$ARCH" target="$target" build_profile="$BUILD/build_profile.json" -j"${DOCKET_BUILD_JOBS:-6}"
done
OUT="$ROOT/addons/docket-file-identity/bin"
mkdir -p "$OUT"
cp "$BUILD"/bin/* "$OUT/"
{ git -C "$ROOT" rev-parse HEAD; git -C "$ROOT/third_party/godot-sqlite" rev-parse HEAD;
  git -C "$CPP" rev-parse HEAD; printf '%s %s %s\n' "$PLATFORM" "$ARCH" "$TARGET";
  "$PYTHON" - "$OUT" <<'PY'
import hashlib,pathlib,sys
for p in sorted(pathlib.Path(sys.argv[1]).glob('*')):
    if p.is_file() and p.name != 'build-stamp.txt': print(p.name,hashlib.sha256(p.read_bytes()).hexdigest())
PY
} > "$OUT/build-stamp.txt"
