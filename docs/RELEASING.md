# Releasing

## Before you push

```bash
scripts/build/preflight.sh
```

Runs in CI on every push too, so a failure here is a failure there. It checks:

**Secrets and private data** — no `.dct` databases tracked (they carry
`vault_salt`, `vault_verify` and encrypted secrets), no real vault key material,
no `.p12`/`.pfx`/`.pem`/`.p8` signing keys, no credential-shaped assignments, no
private key blocks.

**Local machine leakage** — no `/Users/...`, `/home/...`, `/workspace/` or
`C:\Users\...` paths in tracked files, and export paths in `export_presets.cfg`
stay repo-relative. Godot rewrites `export_path` to wherever you last exported,
so this one catches a real and recurring mistake.

**Binaries (FCIB)** — delegates to `check_no_binaries.sh`.

**Consistency** — `project.godot`, the `GODOT_VERSION` pinned in the workflows,
and the docs agree; docs reference the same repo as `origin`; submodules sit on a
tagged commit rather than a drifting branch.

**Documentation** — internal links resolve, unfilled `<PLACEHOLDER>`s are
flagged, and both vendored MIT licences are present for packaging.

**Secret scanning** — `gitleaks` over both the full git history and the working
tree, using `.gitleaks.toml`. History matters: a secret committed and later
removed is still leaked. CI runs it unconditionally on a checksum-pinned binary;
locally it runs when installed (`brew install gitleaks`). Vendored `third_party/`
is excluded — the SQLite amalgamation trips the generic-api-key heuristic on long
hex constants, and that noise would train everyone to ignore the check.

**Workflow hardening** — third-party actions pinned to commit SHAs (a tag can be
moved by whoever owns that repo, and the release job holds `contents: write` plus
the signing key), and no untrusted context (`github.event.*`, `inputs.*`,
`github.head_ref`) interpolated into a `run:` block, where it would be
substituted before the shell parses it and execute as code.

**Export credentials** — `export_presets.cfg` is tracked, and the Godot editor
writes notarization passwords, keystore passwords, and App Store Connect API keys
directly into it. The check fails if any are non-empty.

**Syntax** — every shell script parses, every workflow is valid YAML.

Warnings do not fail the run. Failures exit non-zero.

## Before tagging a release

```bash
scripts/build/preflight.sh --full     # adds a full test-suite run
```

Then check by hand:

- [ ] Placeholders are filled — in particular the **GPG key fingerprint** in the
      README. `preflight.sh` warns rather than fails, because they are fine
      during development and only wrong in a tagged build.
- [ ] `GPG_PRIVATE_KEY` and `GPG_PASSPHRASE` exist as repository secrets.
      Without them the release still publishes, but `SHA256SUMS` is unsigned and
      the workflow emits a `::warning::` you have to go looking for.
- [ ] The vendored `godot-sqlite` pin is the version you mean to ship —
      `git submodule status`.
- [ ] `docs/SIGNING.md` still describes reality. If you have since bought an
      Apple certificate or been approved by SignPath, it is now wrong.

## Dependency updates

`.github/dependabot.yml` watches three ecosystems: GitHub Actions (weekly),
the vendored `third_party/godot-sqlite` submodule (weekly), and the Python
fallback's requirements (monthly).

One caveat on the submodule: Dependabot follows the default branch, but the pin
is deliberately a *tag*. Treat its PRs as a signal that upstream moved, then pin
the tag you want by hand and update `docs/SBOM.md` and `sbom.cdx.json` to match —
`preflight.sh` fails if they drift. This is also the only route by which the
bundled **SQLite** version changes, since it ships inside godot-sqlite's tree
rather than as a declared dependency.

## Cutting the release

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

The tag triggers `release.yml`, which for each of macOS (universal), Linux
x86_64 and Windows x86_64:

1. Builds the GDExtension from vendored source — both debug and release targets
2. Runs preflight, then the full test suite; a failure stops the release
3. Exports with the matching preset
4. Packages, with `LICENSE` and a generated `THIRD-PARTY-LICENSES.txt` alongside

Then a single publish job generates `SHA256SUMS` and creates the GitHub release.
It creates `SHA256SUMS.asc` only when `GPG_PRIVATE_KEY` is configured. A public
release should be treated as incomplete if that signature is absent.

## Things that will bite you

**Do not add files to the macOS `.app` after export.** Godot ad-hoc signs the
bundle during export, and adding anything to a signed bundle breaks the seal
(`a sealed resource is missing or invalid`). On Apple Silicon a broken signature
means the app will not launch at all — this is a kernel requirement, not a
Gatekeeper prompt you can click through. Licences are staged *next to* the
bundle for exactly this reason, and the workflow re-verifies the signature after
copying.

**Both GDExtension targets are required.** Exports load
`<platform>.release`; the Godot tool binary that runs the tests loads
`<platform>.debug`. Building only release leaves the extension failing to load
with `Can't open dynamic library: .` and roughly 50 tests failing in ways that
look like unrelated SQLite bugs.

**Release executables are unsigned.** See [SIGNING.md](SIGNING.md). Once the
public key and fingerprint are published, the GPG signature over `SHA256SUMS`
will be the integrity guarantee. Until then, development artifacts cannot be
independently authenticated.
