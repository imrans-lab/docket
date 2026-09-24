#!/usr/bin/env bash
# Builds Docket's native extension (native/docket_native) from source for this
# machine and copies it to addons/docket_native/bin/, where
# addons/docket_native/docket_native.gdextension looks for it.
#
# Usage: native/build.sh [debug|release]   (both when omitted)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/native/docket_native"
OUT="$ROOT/addons/docket_native/bin"

case "$(uname -s)" in
	Linux) platform=linux; built=libdocket_native.so; ext=so ;;
	Darwin) platform=macos; built=libdocket_native.dylib; ext=dylib ;;
	MINGW*|MSYS*|CYGWIN*) platform=windows; built=docket_native.dll; ext=dll ;;
	*) echo "unsupported platform: $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
	x86_64|amd64) arch=x86_64 ;;
	aarch64|arm64) arch=arm64 ;;
	*) echo "unsupported architecture: $(uname -m)"; exit 1 ;;
esac

mkdir -p "$OUT"
for target in ${1:-debug release}; do
	case "$target" in
		debug) cargo build --locked --manifest-path "$CRATE/Cargo.toml" ;;
		release) cargo build --locked --release --manifest-path "$CRATE/Cargo.toml" ;;
		*) echo "unknown target: $target (debug or release)"; exit 1 ;;
	esac
	cp "$CRATE/target/$target/$built" "$OUT/docket_native.$platform.template_$target.$arch.$ext"
done
