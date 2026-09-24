#!/usr/bin/env bash
# The Docket UI (scripts/ui) also ships inside hosts that embed it, such as
# Minerva, which run an older Godot and load none of Docket's storage code or
# its native SQLite extension. This check copies scripts/ui plus the few pure
# helpers the UI may use into an empty project, imports it and parses every
# UI script with the given Godot. It fails on syntax that Godot cannot read
# and on any reference to another Docket class (DocketDB, TypeRegistry,
# AppState, VaultCrypto, ...), which cannot resolve there. It does not check
# which engine methods or properties exist on engine classes, and it cannot
# see a class loaded from a path string at runtime, so it also refuses any
# res://scripts/ path in the UI outside scripts/ui and the allowed helpers.
#
# Usage: check_ui_portable.sh <godot-binary>
set -euo pipefail

GODOT="${1:?usage: check_ui_portable.sh <godot-binary>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Pure helpers the UI may use; everything else in scripts/core stays out.
HELPERS=(type_catalog query_type_scope docket_fields user_prefs)

failed=0
# Any res://scripts/ path in the UI must be the UI's own or an allowed helper.
allowed="res://scripts/ui/[A-Za-z0-9_./-]*"
for helper in "${HELPERS[@]}"; do
	allowed+="|res://scripts/core/${helper}\\.gd"
done
paths="$(grep -rnoE 'res://scripts/[A-Za-z0-9_./-]*' "$ROOT/scripts/ui")" || [ $? -eq 1 ] || { echo "grep failed"; exit 1; }
if printf '%s\n' "$paths" | grep -E . | grep -vE ":(${allowed})\$"; then
	echo "scripts/ui refers to Docket scripts outside the UI other than its allowed helpers (above)."
	failed=1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Keeps Godot from reading or writing the user's own Godot data.
export HOME="$WORK/home" XDG_DATA_HOME="$WORK/home/data" XDG_CONFIG_HOME="$WORK/home/config" XDG_CACHE_HOME="$WORK/home/cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
version="$("$GODOT" --headless --version)" || { echo "Godot did not run: $GODOT"; exit 1; }
mkdir -p "$WORK/scripts/core"
cp -r "$ROOT/scripts/ui" "$WORK/scripts/ui"
for helper in "${HELPERS[@]}"; do
	cp "$ROOT/scripts/core/$helper.gd" "$WORK/scripts/core/"
	cp "$ROOT/scripts/core/$helper.gd.uid" "$WORK/scripts/core/" 2>/dev/null || true
done
cat > "$WORK/project.godot" <<'EOF'
config_version=5

[application]
config/name="DocketUIPortability"
EOF


if ! "$GODOT" --headless --path "$WORK" --import > "$WORK/import.log" 2>&1; then
	echo "Import failed:"; cat "$WORK/import.log"; failed=1
elif grep -E "SCRIPT ERROR|Parse Error|Compile Error" "$WORK/import.log"; then
	failed=1
fi
checked=0
while IFS= read -r script; do
	checked=$((checked + 1))
	name="${script#"$WORK"/}"
	log="$WORK/check.log"
	status=0
	"$GODOT" --headless --path "$WORK" --check-only --script "res://$name" > "$log" 2>&1 || status=$?
	if [ "$status" -ne 0 ] || grep -qE "SCRIPT ERROR|Parse Error|Compile Error|Failed to load script" "$log"; then
		echo "FAIL $name (exit $status)"
		cat "$log"
		failed=1
	fi
done < <(find "$WORK/scripts/ui" -name '*.gd' | sort)
if [ "$checked" -eq 0 ]; then
	echo "No UI scripts found to check."; failed=1
fi
if [ "$failed" -ne 0 ]; then
	echo "The UI does not parse in Godot $version without Docket's storage code."
	exit 1
fi
echo "UI portable: every scripts/ui script parses in Godot $version with only its allowed helpers."
