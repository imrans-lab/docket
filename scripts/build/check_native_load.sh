#!/usr/bin/env bash
# Checks that a built Docket native library (native/docket_native) loads in a
# given Godot: it puts the library, under the repository's .gdextension, into
# an empty project, imports it, asks Godot whether the extension's classes
# exist, and makes a few calls: DocketCredentialStore.status without an
# operation, which must refuse and touches nothing, and one coordination
# operation opened, nested and closed. That takes and gives back the shared
# lock in the account's coordination directory, creating it if missing.
#
# Use it on the library exactly as it ships (the one inside an exported app),
# once per Godot a host runs: the extension targets an older API than
# Docket's own Godot, so each needs showing.
#
# Usage: check_native_load.sh <godot-binary> <library-file>
set -euo pipefail

GODOT="${1:?usage: check_native_load.sh <godot-binary> <library-file>}"
LIBRARY="${2:?usage: check_native_load.sh <godot-binary> <library-file>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLASSES=(DocketCoordLock DocketCoordOperation DocketCredentialStore)

test -s "$LIBRARY" || { echo "no library at $LIBRARY"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Keeps Godot from reading or writing the user's own Godot data.
export HOME="$WORK/home" XDG_DATA_HOME="$WORK/home/data" XDG_CONFIG_HOME="$WORK/home/config" XDG_CACHE_HOME="$WORK/home/cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
version="$("$GODOT" --headless --version)" || { echo "Godot did not run: $GODOT"; exit 1; }

# The library under its own name, with every entry of the repository's
# .gdextension pointed at it: an editor build asks for the debug entry, and
# this is the release library.
name="$(basename "$LIBRARY")"
mkdir -p "$WORK/addons/docket_native/bin"
cp "$LIBRARY" "$WORK/addons/docket_native/bin/$name"
sed -E "s#^([A-Za-z0-9._]+ = )\"res://addons/docket_native/bin/[^\"]*\"#\\1\"res://addons/docket_native/bin/$name\"#" \
	"$ROOT/addons/docket_native/docket_native.gdextension" > "$WORK/addons/docket_native/docket_native.gdextension"
grep -q "bin/$name\"" "$WORK/addons/docket_native/docket_native.gdextension" \
	|| { echo "the .gdextension has no library entry to point at $name"; exit 1; }
cat > "$WORK/project.godot" <<'EOF'
config_version=5

[application]
config/name="DocketNativeLoad"
EOF
{
	echo "extends SceneTree"
	echo "func _init() -> void:"
	echo "	var missing := []"
	for class in "${CLASSES[@]}"; do
		echo "	if not ClassDB.class_exists(\"$class\"): missing.append(\"$class\")"
	done
	echo "	if missing.is_empty():"
	echo "		var status: Dictionary = ClassDB.instantiate(\"DocketCredentialStore\").status(null)"
	echo "		if status.get(\"kind\") != \"refused\":"
	echo "			print(\"NATIVE CALL FAILED: \", status)"
	echo "			quit(1)"
	echo "			return"
	echo "		var opened: Dictionary = ClassDB.instantiate(\"DocketCoordLock\").open(0)"
	echo "		var nested: Dictionary = opened.operation.nested(0) if opened.has(\"operation\") else {}"
	echo "		if not nested.has(\"operation\") or nested.operation.close() != \"\" or opened.operation.close() != \"\" or opened.operation.is_open():"
	echo "			print(\"NATIVE CALL FAILED: \", opened, \" \", nested)"
	echo "			quit(1)"
	echo "			return"
	echo "		print(\"NATIVE LOAD OK\")"
	echo "		quit(0)"
	echo "	else:"
	echo "		print(\"NATIVE LOAD MISSING: \", missing)"
	echo "		quit(1)"
} > "$WORK/check.gd"

if ! "$GODOT" --headless --path "$WORK" --import > "$WORK/import.log" 2>&1; then
	echo "Import failed:"; cat "$WORK/import.log"; exit 1
fi
status=0
# --quit-after ends a run whose script stopped on an error before quitting;
# such a run never prints the OK line, so it still fails below.
"$GODOT" --headless --path "$WORK" --quit-after 600 --script res://check.gd > "$WORK/check.log" 2>&1 || status=$?
cat "$WORK/check.log"
if [ "$status" -ne 0 ] || ! grep -q "NATIVE LOAD OK" "$WORK/check.log"; then
	echo "$name does not load in Godot $version (exit $status)."
	exit 1
fi
echo "$name loads in Godot $version: ${CLASSES[*]} are registered."
