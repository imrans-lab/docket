#!/usr/bin/env bash
# The official Godot 4.7.1 export templates (third_party/godot/PINS), put
# where Godot looks for them: downloaded, checked against their pinned
# SHA-512 and their own version.txt, then installed. Exports are made with
# these unmodified templates; only the editor Docket builds itself is
# patched (build_godot_editor.sh).
#
# Usage: install_godot_templates.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../third_party/godot/PINS
source "$ROOT/third_party/godot/PINS"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fSL -o "$WORK/templates.tpz" "$GODOT_TEMPLATES_URL"
if command -v sha512sum > /dev/null; then
	actual="$(sha512sum "$WORK/templates.tpz" | cut -d' ' -f1)"
else
	actual="$(shasum -a 512 "$WORK/templates.tpz" | cut -d' ' -f1)"
fi
[ "$actual" = "$GODOT_TEMPLATES_SHA512" ] || { echo "the export templates are not the pinned ones (SHA-512 $actual)" >&2; exit 1; }
unzip -q "$WORK/templates.tpz" -d "$WORK/unpacked"
VERSION="$(tr -d '\r\n' < "$WORK/unpacked/templates/version.txt")"
[ "$VERSION" = 4.7.1.stable ] || { echo "the export templates are version '$VERSION', not 4.7.1.stable" >&2; exit 1; }

case "$(uname -s)" in
	Darwin) DIR="$HOME/Library/Application Support/Godot/export_templates/$VERSION" ;;
	MINGW*|MSYS*|CYGWIN*) DIR="$APPDATA/Godot/export_templates/$VERSION" ;;
	*) DIR="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$VERSION" ;;
esac
mkdir -p "$DIR"
mv "$WORK/unpacked/templates/"* "$DIR"/
echo "export templates $VERSION (SHA-512 $actual) in $DIR"
