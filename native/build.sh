#!/usr/bin/env bash
# Builds Docket's native extension (native/docket_native) from source for this
# machine and copies it to addons/docket_native/bin/, where
# addons/docket_native/docket_native.gdextension looks for it. On macOS it
# builds both architectures and joins them into one universal library.
#
# Needs the exact Rust named in rust-toolchain.toml, installed with rustup,
# with its target for this machine (both Apple targets on macOS); it names
# that toolchain on every call and stops rather than use another.
#
# Usage: native/build.sh [debug|release]   (both when omitted)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/native/docket_native"
OUT="$ROOT/addons/docket_native/bin"

expected="$(tr -d '\r' < "$ROOT/rust-toolchain.toml" | sed -n 's/^channel = "\(.*\)"$/\1/p')"
[ -n "$expected" ] || { echo "rust-toolchain.toml names no channel"; exit 1; }
actual="$(cd "$ROOT" && rustc "+$expected" --version)"
case "$actual" in
	"rustc $expected "*) ;;
	*) echo "native/build.sh needs Rust $expected (rust-toolchain.toml), found: $actual"; exit 1 ;;
esac

case "$(uname -m)" in
	x86_64|amd64) arch=x86_64 ;;
	aarch64|arm64) arch=arm64 ;;
	*) echo "unsupported architecture: $(uname -m)"; exit 1 ;;
esac
case "$(uname -s)" in
	Linux)
		platform=linux; built=libdocket_native.so; ext=so
		triples=("$([ "$arch" = x86_64 ] && echo x86_64 || echo aarch64)-unknown-linux-gnu") ;;
	Darwin)
		platform=macos; built=libdocket_native.dylib; ext=dylib; arch=universal
		triples=(x86_64-apple-darwin aarch64-apple-darwin) ;;
	MINGW*|MSYS*|CYGWIN*)
		platform=windows; built=docket_native.dll; ext=dll
		[ "$arch" = x86_64 ] || { echo "unsupported Windows architecture: $arch"; exit 1; }
		triples=(x86_64-pc-windows-msvc) ;;
	*) echo "unsupported platform: $(uname -s)"; exit 1 ;;
esac

mkdir -p "$OUT"
for target in ${1:-debug release}; do
	case "$target" in
		debug|release) ;;
		*) echo "unknown target: $target (debug or release)"; exit 1 ;;
	esac
	libs=()
	for triple in "${triples[@]}"; do
		if [ "$target" = release ]; then
			(cd "$ROOT" && cargo "+$expected" build --locked --release --target "$triple" --manifest-path "$CRATE/Cargo.toml")
		else
			(cd "$ROOT" && cargo "+$expected" build --locked --target "$triple" --manifest-path "$CRATE/Cargo.toml")
		fi
		libs+=("$CRATE/target/$triple/$target/$built")
	done
	dest="$OUT/docket_native.$platform.template_$target.$arch.$ext"
	if [ "$platform" = macos ]; then
		lipo -create "${libs[@]}" -output "$dest"
	else
		cp "${libs[0]}" "$dest"
	fi
done
