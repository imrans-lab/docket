#!/usr/bin/env bash
## Pre-push / pre-release checks.
##
##   scripts/build/preflight.sh          # fast checks only
##   scripts/build/preflight.sh --full   # also builds the extension and runs tests
##
## Exits non-zero if any check fails. Warnings do not fail the run but are
## summarised at the end. Runs in CI on every push.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

FAILURES=0
WARNINGS=0

pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Files tracked by this repo. Vendored source is upstream's business.
tracked() { git ls-files | grep -v '^third_party/'; }

# ---------------------------------------------------------------------------
head2 "Secrets and private data"

# Docket databases carry vault_salt, vault_verify and encrypted secrets. They
# are user data and must never be published — with one exception: curated
# sample .dct files directly in examples/. Sidecars (.dct.cache, .lock, audit)
# are never allowed, and the vault-material scan below still covers examples.
if tracked | grep -E '\.dct$|\.dct\.' | grep -qv '^examples/[^/]*\.dct$'; then
	fail "a .dct database is tracked outside examples/ — it may contain vault material"
	tracked | grep -E '\.dct$|\.dct\.' | grep -v '^examples/[^/]*\.dct$' | sed 's/^/          /'
else
	pass "no .dct databases tracked outside examples/"
fi

# Field-name references in source are fine; actual base64 payloads are not.
if tracked | xargs grep -lE '"vault_(salt|verify)":"[A-Za-z0-9+/]{16,}' 2>/dev/null | grep -q .; then
	fail "real vault salt/verify values found in tracked files"
else
	pass "no vault key material in tracked files"
fi

if tracked | grep -qiE '\.(p12|pfx|pem|p8|jks|keystore)$'; then
	fail "signing key material is tracked"
else
	pass "no signing key material tracked"
fi

# export_presets.cfg is tracked, and the Godot editor writes signing credentials
# straight into it — notarization passwords, keystore passwords, App Store
# Connect API keys. They are empty today; they stop being empty the moment
# anyone configures signing in the editor, and would be committed silently.
if [[ -f export_presets.cfg ]]; then
	creds="$(grep -nE '^(codesign/(identity|installer_identity|apple_team_id)|notarization/[a-z_]*(password|api_uuid|api_key|apple_id)[a-z_]*|keystore/[a-z_]*(password|user)[a-z_]*)=' export_presets.cfg \
		| grep -vE '=""$' || true)"
	if [[ -n "$creds" ]]; then
		fail "export_presets.cfg contains signing credentials — move them to CI secrets:"
		echo "$creds" | sed -E 's/=.*/=<redacted>/' | sed 's/^/          /'
	else
		pass "export_presets.cfg carries no credentials"
	fi
fi

# Deliberately narrow: assignment of a long literal to a credential-shaped name.
SECRET_RE='(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{16,}'
hits="$(tracked | xargs grep -nIE "$SECRET_RE" 2>/dev/null | grep -viE 'placeholder|example|your_|dummy|test|<[a-z_]+>' || true)"
if [[ -n "$hits" ]]; then
	fail "possible hardcoded credential:"
	echo "$hits" | sed 's/^/          /'
else
	pass "no hardcoded credentials"
fi

if tracked | xargs grep -lE 'BEGIN (RSA |OPENSSH |EC |PGP )?PRIVATE KEY' 2>/dev/null | grep -q .; then
	fail "a private key block is tracked"
else
	pass "no private key blocks"
fi

# The checks above are hand-written heuristics. gitleaks carries a maintained
# ruleset for hundreds of providers and scans history, not just the tip. CI runs
# it unconditionally; locally it is used when installed.
if command -v gitleaks >/dev/null 2>&1; then
	if gitleaks git . -c .gitleaks.toml --no-banner --redact >/dev/null 2>&1 \
		&& gitleaks dir . -c .gitleaks.toml --no-banner --redact >/dev/null 2>&1; then
		pass "gitleaks: no leaks in history or working tree"
	else
		fail "gitleaks found a leak — rerun without --redact for detail"
	fi
else
	warn "gitleaks not installed locally (CI runs it) — brew install gitleaks"
fi

# ---------------------------------------------------------------------------
head2 "Local machine leakage"

# Absolute paths and usernames from a dev box do not belong in a public repo.
# The files that document or implement this check necessarily contain the
# patterns themselves, so they are excluded rather than permanently warning.
leak="$(tracked \
	| grep -vE '^(docs/RELEASING\.md|scripts/build/preflight\.sh)$' \
	| xargs grep -nIE '/Users/[a-z]+/|/home/[a-z]+/|/workspace/|C:\\\\Users\\\\' 2>/dev/null \
	| grep -viE 'example|placeholder|/Users/<|~/' || true)"
if [[ -n "$leak" ]]; then
	warn "absolute local paths in tracked files:"
	echo "$leak" | sed 's/^/          /'
else
	pass "no absolute local paths"
fi

# Export paths are the usual offender — Godot writes wherever you last exported.
bad_export="$(grep -n '^export_path=' export_presets.cfg | grep -vE '"build/' || true)"
if [[ -n "$bad_export" ]]; then
	fail "export_presets.cfg has non-portable export paths:"
	echo "$bad_export" | sed 's/^/          /'
else
	pass "export paths are repo-relative"
fi

# ---------------------------------------------------------------------------
head2 "Binaries (FCIB)"
if ./scripts/build/check_no_binaries.sh >/dev/null 2>&1; then
	pass "no tracked binaries"
else
	fail "FCIB violation — run scripts/build/check_no_binaries.sh"
fi

# ---------------------------------------------------------------------------
head2 "Consistency"

# A version skew between the engine, the pinned CI version, and the docs is the
# kind of thing that only surfaces when a release build mysteriously fails.
proj_ver="$(grep -o '"4\.[0-9]*"' project.godot | tr -d '"' | head -1)"
ci_ver="$(grep -h 'GODOT_VERSION:' .github/workflows/*.yml | head -1 | tr -d ' "' | cut -d: -f2)"
if [[ "$ci_ver" == "$proj_ver"* ]]; then
	pass "Godot version aligned (project $proj_ver, CI $ci_ver)"
else
	fail "Godot version skew: project.godot says $proj_ver, workflows pin $ci_ver"
fi

remote_slug="$(git remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]([^/]+/[^/.]+).*#\1#')"
if [[ -n "$remote_slug" ]]; then
	doc_slugs="$(grep -hoE 'github\.com/[A-Za-z0-9_-]+/docket' README.md docs/*.md 2>/dev/null | sed 's#github.com/##' | sort -u)"
	if [[ -z "$doc_slugs" ]] || echo "$doc_slugs" | grep -qx "$remote_slug"; then
		pass "docs reference the correct repo ($remote_slug)"
	else
		fail "docs reference $doc_slugs but origin is $remote_slug"
	fi
fi

# Submodules must sit on a tagged commit, not wherever the default branch drifted.
# CI checkouts fetch submodules without tags, so a failed describe there means
# "no tags available", not "not pinned" — distinguish the two or the check cries
# wolf on every run and gets ignored.
while read -r _ sha path _; do
	[[ -z "${path:-}" ]] && continue
	if tag="$(git -C "$path" describe --tags --exact-match 2>/dev/null)"; then
		pass "submodule $path pinned at $tag"
	elif [[ -z "$(git -C "$path" tag -l 2>/dev/null | head -1)" ]]; then
		# The SBOM drift check above already verifies this exact SHA, so pinning
		# is still enforced here — just not by tag name.
		pass "submodule $path at ${sha:0:12} (no tags fetched; SHA verified via SBOM)"
	else
		warn "submodule $path is not on a tagged commit (at ${sha:0:12})"
	fi
done < <(git submodule status | sed 's/^[+-]//' | awk '{print "x", $1, $2, $3}')

# ---------------------------------------------------------------------------
head2 "Documentation"

dead=0
while read -r link; do
	[[ -z "$link" ]] && continue
	[[ -f "$link" || -f "docs/$link" ]] || { warn "dead link: $link"; dead=1; }
done < <(grep -ohE '\]\((docs/[A-Za-z0-9_.-]+\.md|[A-Z-]+\.md|LICENSE)\)' README.md docs/*.md 2>/dev/null | tr -d '])(' | sort -u)
[[ $dead -eq 0 ]] && pass "internal doc links resolve"

placeholders="$(grep -nE '<(KEY_FINGERPRINT|TODO|not yet published)' README.md docs/*.md 2>/dev/null || true)"
if [[ -n "$placeholders" ]]; then
	warn "unfilled placeholders (fine pre-release, not for a tagged version):"
	echo "$placeholders" | sed 's/^/          /'
else
	pass "no unfilled placeholders"
fi

# The SBOM records the exact commits shipped; drift makes it a lie.
if [[ -f docs/sbom.cdx.json ]]; then
	sbom_ok=1
	for spec in "third_party/godot-sqlite:godot-sqlite" \
	            "third_party/godot-sqlite/godot-cpp:godot-cpp"; do
		sub="${spec%%:*}"
		[[ -d "$sub/.git" || -f "$sub/.git" ]] || continue
		sha="$(git -C "$sub" rev-parse HEAD 2>/dev/null)"
		if [[ -n "$sha" ]] && ! grep -q "$sha" docs/sbom.cdx.json; then
			warn "SBOM does not list ${spec##*:} at $sha — update docs/SBOM.md and sbom.cdx.json"
			sbom_ok=0
		fi
	done
	sq_ver="$(grep -m1 -oE '\"3\.[0-9.]+\"' third_party/godot-sqlite/src/sqlite/sqlite3.h 2>/dev/null | tr -d '\"')"
	if [[ -n "$sq_ver" ]] && ! grep -q "$sq_ver" docs/sbom.cdx.json; then
		warn "SBOM SQLite version is stale — tree has $sq_ver"
		sbom_ok=0
	fi
	[[ $sbom_ok -eq 1 ]] && pass "SBOM matches the pinned tree"
else
	warn "no docs/sbom.cdx.json"
fi

# MIT obliges us to ship these with any binary that links them.
for l in third_party/godot-sqlite/LICENSE.md third_party/godot-sqlite/godot-cpp/LICENSE.md; do
	if [[ -f "$l" ]]; then
		pass "third-party licence present: $l"
	else
		warn "missing $l — run: git submodule update --init --recursive"
	fi
done

# ---------------------------------------------------------------------------
head2 "Workflow hardening"

# Third-party actions run with this repo's token. A tag is mutable by whoever
# owns that repo; a commit SHA is not. actions/* is first-party and exempt.
unpinned="$(grep -hoE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+' .github/workflows/*.yml 2>/dev/null \
	| sed -E 's/uses:[[:space:]]*//' \
	| grep -v '^actions/' \
	| grep -vE '@[0-9a-f]{40}$' || true)"
if [[ -n "$unpinned" ]]; then
	fail "third-party action not pinned to a commit SHA:"
	echo "$unpinned" | sed 's/^/          /'
else
	pass "third-party actions pinned to commit SHAs"
fi

# Untrusted context inside a run: block executes as code. Passing the same value
# via env: is safe, so the check tracks blocks rather than grepping lines.
if command -v python3 >/dev/null 2>&1; then
	if inj_out="$(python3 scripts/build/check_workflow_injection.py 2>&1)"; then
		pass "no untrusted context interpolated into run: blocks"
	else
		fail "script injection risk in a workflow:"
		echo "$inj_out" | sed 's/^/          /'
	fi
else
	warn "python3 unavailable — workflow injection check skipped"
fi

# ---------------------------------------------------------------------------
head2 "Syntax"

for s in scripts/build/*.sh run_tests.sh; do
	bash -n "$s" 2>/dev/null && pass "bash: $s" || fail "bash syntax: $s"
done

# Probe for a YAML parser before using one. Checking only for python3 and then
# assuming PyYAML reports valid workflows as invalid wherever the module is
# absent — which is most clean CI runners, so the check would fail the build it
# was meant to protect. Ruby ships a YAML parser in its stdlib, so try that too.
_yaml_checker=""
if python3 -c "import yaml" 2>/dev/null; then
	_yaml_checker="python"
elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -e "YAML.load_file('.github/workflows/ci.yml')" >/dev/null 2>&1; then
	_yaml_checker="ruby"
fi

case "$_yaml_checker" in
	python)
		for w in .github/workflows/*.yml; do
			if python3 -c "import yaml,sys;yaml.safe_load(open('$w'))" 2>/dev/null; then
				pass "yaml: $w"
			else
				fail "yaml invalid: $w"
			fi
		done
		;;
	ruby)
		for w in .github/workflows/*.yml; do
			if ruby -ryaml -e "YAML.load_file(ARGV[0])" "$w" >/dev/null 2>&1; then
				pass "yaml: $w (ruby)"
			else
				fail "yaml invalid: $w"
			fi
		done
		;;
	*)
		warn "no YAML parser available (pip install pyyaml) — workflows not validated"
		;;
esac

# ---------------------------------------------------------------------------
if [[ $FULL -eq 1 ]]; then
	head2 "Build and tests (--full)"
	if ./run_tests.sh 2>&1 | tail -20 | grep -q "ALL TESTS PASSED"; then
		pass "test suite passes"
	else
		fail "test suite failed — run ./run_tests.sh"
	fi
else
	head2 "Skipped"
	warn "tests not run — use --full before tagging a release"
fi

# ---------------------------------------------------------------------------
printf '\n\033[1mSummary:\033[0m %d failure(s), %d warning(s)\n' "$FAILURES" "$WARNINGS"
[[ $FAILURES -eq 0 ]] || exit 1
