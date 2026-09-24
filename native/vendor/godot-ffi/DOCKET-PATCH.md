# godot-ffi 0.4.5, patched for Docket

This is the crates.io release of `godot-ffi` 0.4.5 (MPL-2.0,
https://github.com/godot-rust/gdext), used through a `[patch.crates-io]`
entry in `native/docket_native/Cargo.toml`.

One change:

- `src/lib.rs`, `print_preamble`: the line godot-rust prints when the
  extension loads ("Initialize godot-rust (API …, runtime …, safeguards …)")
  goes to stderr instead of stdout. It is printed unconditionally, ignoring
  Godot's `--quiet` and `--no-header`, and Docket's stdio server keeps stdout
  for JSON-RPC only.

The crate's lockfile and Cargo.toml.orig were left out.

To move to a newer release, copy that release here and reapply this change.
