# Signing and verification

## What Docket ships today

**Release binaries are unsigned.** There is no Apple Developer ID certificate
and no Windows Authenticode certificate behind these builds.

The release workflow can instead produce a **GPG signature over
`SHA256SUMS`**. The signing key and public fingerprint have not been published
yet, and the workflow currently permits a release without the signature.
Therefore current development artifacts do not yet have an independent
integrity guarantee.

| Platform | Signing state | What users see |
|----------|---------------|----------------|
| macOS | Ad-hoc signed, **not** notarized | Gatekeeper warning on first launch |
| Linux | Unsigned (normal for Linux) | Nothing |
| Windows | Unsigned | SmartScreen "unrecognized publisher" |

## Verifying a signed release

Use these commands only after the README publishes the complete signing-key
fingerprint and the release contains both `SHA256SUMS` and `SHA256SUMS.asc`:

```bash
# One time: import the release signing key
gpg --recv-keys <KEY_FINGERPRINT>

# Every download
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

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
