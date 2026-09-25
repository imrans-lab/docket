#!/usr/bin/env bash
# Imports this project with the given Godot editor, twice, and fails unless
# both runs exit 0: an error exit or a crash (a signal) fails it, and each
# run's whole output stays in the log. The first run starts with no import
# cache (.godot must not exist yet) and builds the editor's class-doc cache
# in the user cache directory; the second loads that cache and so generates
# the native extensions' docs later in its startup, a separate path through
# the editor's startup and shutdown.
#
# Usage: import_project.sh <godot-editor>
set -euo pipefail

GODOT="${1:?usage: import_project.sh <godot-editor>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

[ ! -e "$ROOT/.godot" ] || { echo "$ROOT/.godot exists; the first import must start without it" >&2; exit 1; }
for run in initial cached; do
	echo "--- $run import ---"
	status=0
	"$GODOT" --headless --path "$ROOT" --import 2>&1 || status=$?
	[ "$status" -eq 0 ] || { echo "the $run import exited $status" >&2; exit 1; }
done
