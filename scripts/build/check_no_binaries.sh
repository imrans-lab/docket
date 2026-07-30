#!/usr/bin/env bash
## Enforce the FCIB rule: no compilable/executable binaries are tracked in git.
##
## Compiled artifacts must be produced from vendored source at build time, never
## committed. Source assets that have no compiled form (icons, images) are fine.
##
## Runs in CI and is safe to run locally: scripts/build/check_no_binaries.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Extensions that denote something executable or linkable.
PATTERN='\.(so|dylib|dll|exe|wasm|a|lib|o|obj|pdb|bin|class|jar|pyc|node)$|\.(framework|xcframework)/'

# Only files tracked by *this* repo — submodule contents are the upstream
# project's business, and they ship source, not binaries.
offenders="$(git ls-files | grep -Ei "$PATTERN" || true)"

if [[ -n "$offenders" ]]; then
	echo "FCIB violation: executable/compilable binaries are tracked in git:" >&2
	echo "$offenders" | sed 's/^/  /' >&2
	echo >&2
	echo "Build these from vendored source instead — see docs/BUILDING.md" >&2
	exit 1
fi

# Belt and braces: catch anything with executable magic that slipped in without
# a telltale extension. Compared as hex so no locale/encoding issues arise.
#   7f454c46 ELF   4d5a____ PE/COFF (MZ)
#   cffaedfe / cefaedfe Mach-O 64/32   cafebabe Mach-O universal
suspicious=""
while IFS= read -r f; do
	[[ -f "$f" ]] || continue
	case "$f" in
		*.png|*.jpg|*.jpeg|*.gif|*.ico|*.webp|*.svg|*.ttf|*.otf|*.woff*) continue ;;
	esac
	magic="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"
	case "$magic" in
		7f454c46|cffaedfe|cefaedfe|cafebabe|4d5a*)
			suspicious+="  $f"$'\n' ;;
	esac
done < <(git ls-files)

if [[ -n "$suspicious" ]]; then
	echo "FCIB violation: tracked files carry executable magic numbers:" >&2
	printf '%s' "$suspicious" >&2
	exit 1
fi

echo "FCIB check passed — no tracked binaries."
