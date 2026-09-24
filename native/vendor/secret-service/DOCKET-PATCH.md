# secret-service 5.2.0, patched for Docket

This is the crates.io release of `secret-service` 5.2.0 (MIT OR Apache-2.0,
https://github.com/open-source-cooperative/secret-service-rs), used through a
`[patch.crates-io]` entry in `native/docket_native/Cargo.toml`.

Two changes:

- `src/util.rs`: `exec_prompt` and `exec_prompt_blocking` no longer show a
  prompt or wait for it to complete. They dismiss it (best effort) and return
  `Error::Prompt`, so a request that needs the user's confirmation is refused
  instead. The unused prompt-completion helper went with them. Docket never
  asks for confirmation from a credential store.
- `src/session.rs`: a service public key longer than 128 bytes (the DH
  group's modulus) is refused with `Error::Crypto` before any arithmetic, so
  a misbehaving service cannot make key agreement run for long.

The repository's CI files and lockfile were left out.

To move to a newer release, copy that release here and reapply this change.
