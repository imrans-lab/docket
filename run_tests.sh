#!/usr/bin/env bash
## Run Docket unit tests in headless Godot.
##
## Usage:
##   ./run_tests.sh                       # auto-detect godot
##   GODOT=/path/to/godot ./run_tests.sh  # override

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve a Godot binary: explicit override, then PATH, then the usual install
# locations. Hardcoding /usr/local/bin misses Homebrew on Apple Silicon
# (/opt/homebrew) and the macOS app bundle.
if [[ -z "${GODOT:-}" ]]; then
	for candidate in \
		"$(command -v godot 2>/dev/null || true)" \
		"$(command -v godot4 2>/dev/null || true)" \
		/opt/homebrew/bin/godot \
		/usr/local/bin/godot \
		/usr/bin/godot \
		"/Applications/Godot.app/Contents/MacOS/Godot"
	do
		if [[ -n "$candidate" && -x "$candidate" ]]; then
			GODOT="$candidate"
			break
		fi
	done
fi

if [[ -z "${GODOT:-}" || ! -x "$GODOT" ]]; then
	echo "error: could not find a Godot binary." >&2
	echo "       Install Godot 4.6.2+ or set GODOT=/path/to/godot" >&2
	exit 1
fi

exec "$GODOT" --headless --path "$SCRIPT_DIR" -- test
