# Signing and verification

## What Docket ships today

**Release binaries are unsigned.** There is no Apple Developer ID certificate
and no Windows Authenticode certificate behind these builds.

The release workflow can instead produce a **GPG signature over
`SHA256SUMS`**. The public key and its fingerprint are published in this
repository. The workflow currently permits a release without the signature, so
a release has an independent integrity guarantee only when it contains both
`SHA256SUMS` and `SHA256SUMS.asc`.

| Platform | Signing state | What users see |
|----------|---------------|----------------|
| macOS | Ad-hoc signed, **not** notarized | Gatekeeper warning on first launch |
| Linux | Unsigned (normal for Linux) | Nothing |
| Windows | Unsigned | SmartScreen "unrecognized publisher" |

## Verifying a signed release

```bash
# One time: import the release signing key shipped with this repository
gpg --import docs/docket-release-signing-key.asc

# Every download
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

Confirm the key you imported is the one you expect:

```
Primary:        178DFC3E42D55743B01865265BC259EB7ED2C464
Signing subkey: A52DE21E0A5A1CA48F429CE7623C6CAEBA657B8F
Preferred UID:  Docket Release Signing <ipeerbhai@aol.com>
```

Releases are signed by the **subkey**, which chains to the primary. The primary
secret key is held offline and is not in CI — what GitHub Actions holds is a
subkey-only export, so compromising a runner cannot mint new subkeys or revoke
the identity.

Importing the key from this repository means trusting this repository. To verify
independently, compare the fingerprint against a copy obtained by another route.

### Key rotation

| Key | Expires (UTC) |
|-----|---------------|
| Signing subkey `623C6CAEBA657B8F` | **2027-07-30** |
| Primary `5BC259EB7ED2C464` | 2029-07-29 |

**Signing stops working when the subkey expires, not the primary.** Extend or
rotate it before that date using the offline primary, then replace both
`docs/docket-release-signing-key.asc` and the `GPG_PRIVATE_KEY` secret.

Compare the imported key's full fingerprint with the README. A missing
signature, a missing published fingerprint, or a signature that fails to verify
means the release cannot be authenticated; do not treat the checksum file alone
as proof of origin.

## Installing an unsigned build

### macOS

The app is **ad-hoc signed**, which is what allows it to execute at all on Apple
Silicon — that is a kernel requirement, not a Gatekeeper one. It is not
notarized, so Gatekeeper still objects on first launch.

Right-click the app, choose **Open**, then confirm in the dialog. macOS
remembers the decision. Double-clicking will not offer the override.

If the app was quarantined by the browser and refuses regardless:

```bash
xattr -d com.apple.quarantine /Applications/Docket.app
```

**Mac Known Issue.** The bundle embeds the `libgdsqlite` GDExtension framework.
Every Mach-O inside the bundle must be signed with the same Developer ID and
have the hardened runtime enabled, or notarization is rejected. If the extension
fails to load at runtime after signing, enable
`codesign/entitlements/disable_library_validation` — library validation
otherwise refuses to load a library it considers foreign to the main binary.


### Windows

SmartScreen shows "Windows protected your PC". Click **More info** →
**Run anyway**.

### Linux

Extract and run. Nothing to bypass.
