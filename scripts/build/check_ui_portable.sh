#!/usr/bin/env bash
# The Docket UI also ships inside hosts that embed it, such as Minerva, which
# run an older Godot and load none of Docket's storage code or its native
# SQLite extension. This check stages the panel exactly as
# package_plugin.py packages it (the files its scene loads, which that script
# requires to load each other only by relative path) into an empty project,
# imports it and parses every script with the given Godot. It fails on
# syntax that Godot cannot read and on any reference to another Docket class
# (DocketDB, TypeRegistry, AppState, VaultCrypto, ...), which cannot resolve
# there. It does not check which engine methods or properties exist on
# engine classes; a script loaded from a path string built at run time is
# not staged, so a res:// path to Docket's own files in a staged script
# fails too.
#
# Usage: check_ui_portable.sh <godot-binary>
set -euo pipefail

GODOT="${1:?usage: check_ui_portable.sh <godot-binary>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

failed=0
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
# Keeps Godot from reading or writing the user's own Godot data.
export HOME="$TEMP/home" XDG_DATA_HOME="$TEMP/home/data" XDG_CONFIG_HOME="$TEMP/home/config" XDG_CACHE_HOME="$TEMP/home/cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
version="$("$GODOT" --headless --version)" || { echo "Godot did not run: $GODOT"; exit 1; }
WORK="$TEMP/panel"
python3 "$ROOT/scripts/build/package_plugin.py" --out "$WORK" --dev-godot "$GODOT" --dev-checkout "$ROOT"
if grep -rnE "res://(scripts|data|addons)/" "$WORK/scripts"; then
	echo "A staged panel script names one of Docket's files by a res:// path, which is the host's project there (above)."
	failed=1
fi
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
done < <(find "$WORK/scripts" -name '*.gd' | sort)
if [ "$checked" -eq 0 ]; then
	echo "No panel scripts found to check."; failed=1
fi
if [ "$failed" -ne 0 ]; then
	echo "The UI does not parse in Godot $version without Docket's storage code."
	exit 1
fi
echo "UI portable: every script the panel ships parses in Godot $version on its own."
