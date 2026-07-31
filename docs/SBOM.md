# Software Bill of Materials

Everything that ends up inside a shipped Docket binary. Machine-readable form:
[`sbom.cdx.json`](sbom.cdx.json) (CycloneDX 1.5).

Docket checks in no binaries — every component below is compiled from source
pinned in `third_party/`, so this list describes what was actually built rather
than what a package manifest claims. See [BUILDING.md](BUILDING.md).

## Components

| Component | Version | Pinned at | Licence | Linked into binary |
|-----------|---------|-----------|---------|--------------------|
| Docket | — | this repository | MPL-2.0 | yes (GDScript) |
| [godot-sqlite](https://github.com/2shady4u/godot-sqlite) | v4.8 | `6550699fa70e4f2a4721f13acb0ca0cf90cd5038` | MIT | yes |
| [godot-cpp](https://github.com/godotengine/godot-cpp) | pinned by godot-sqlite | `58d1de720b8ffe9f8ffcdfe3a85148582cfd2e74` | MIT | yes |
| [SQLite](https://sqlite.org) | **3.51.0** | vendored amalgamation | Public domain | yes |
| [Godot Engine](https://godotengine.org) export templates | 4.6.3-stable | official release | MIT | yes |

## SQLite

Tracked here specifically because it is the component most likely to carry a
CVE and the least visible — it arrives as an amalgamation inside godot-sqlite's
source tree rather than as a declared dependency, so nothing else in the
toolchain would surface it.

- **Version:** 3.51.0
- **Source ID:** `2025-11-04 19:38:17 fb2c931ae597f8d00a37574ff67aeed3eced4e5547f9120744ae4bfa8e74527b`
- **Location:** `third_party/godot-sqlite/src/sqlite/sqlite3.c`
- **Licence:** public domain — no attribution obligation, included here for completeness

SQLite is **not** itself enumerated further in this SBOM: it is a single
self-contained amalgamation with no transitive dependencies of its own.

**Upgrading it is not directly in our control.** The vendored copy is whatever
godot-sqlite ships, so raising the SQLite version means bumping the godot-sqlite
pin (see BUILDING.md) and re-checking this file. If a SQLite CVE lands before
godot-sqlite updates, the options are to carry a patch under
`third_party/patches/` or to pin a godot-sqlite fork.

To verify the version currently in the tree:

```bash
grep -m1 '#define SQLITE_VERSION ' third_party/godot-sqlite/src/sqlite/sqlite3.h
```

## Not included

These are used to produce a release but do not ship inside it: SCons, Python,
the C++ toolchain, and the Godot editor binary used for exporting. The Godot
*export templates* do ship, and are listed above.

## Keeping this current

There is no automated dependency scanning yet. When bumping any pin:

1. Update the commit and version in the table above and in `sbom.cdx.json`
2. Re-run `grep SQLITE_VERSION` — a godot-sqlite bump usually moves SQLite too
3. Run `scripts/build/preflight.sh --full`
