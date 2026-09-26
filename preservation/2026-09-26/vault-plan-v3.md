# D6 #10 V1: Docket vault credential lifecycle, plan v3 (Astra fence ruling 01:40)

- Supersedes v2 (sha256 f471a9e9…). Design source: /agent-home/t/b5/v1-fence-astra-report-20260926.txt.
- Order S1 → S4 → S3 → S2, unchanged. No S1 code until this plan is accepted. Tests only after review and a grant.
- The Docket comma-tag oracle stays the current serial priority.

## The core change from v2: generation-scoped immutable accounts plus a durable pointer
- **Accounts are `vault-password/<epoch>/<tag>`**: one per reserved tag and never reused.
  - Native (store.rs `within`, :122) replaces the fixed three-account allowlist with a strict bounded grammar: epoch = 32 lowercase hex characters; tag = CoordRecord.parse_tag form.
  - AMENDED (Astra ruling 02:09, /agent-home/t/b5/v1-fixed-account-astra-report-20260926.txt): the three fixed names are REFUSED by native read/write/remove from S1 on. No supported Docket or Minerva product path used them (the product password is in prefs; S4 migrates Minerva's prefs source). They were callable in v0.3.0-rc.1, so entries created outside the product may exist: they stay in the store as unsupported orphans, and are not migrated, adopted, removed, counted as cleanup debt or covered by any erasure claim. status() probes the bare name "vault-password" as a reserved diagnostic only.
  - This is a Rust change: validation needs a fresh `docket_native` build from pinned toolchain 1.93.0, offline, as b8aval did in 57909 (new library hash and provenance), not the d7val1e library.
- **The durable pointer:** CoordState gains an active-account pointer and a retirement/cleanup ledger, in the same SQLite transaction discipline as commit_generation.
  - Publishing READY + pointer + intent phase is ONE atomic transaction.
  - The API enforces operation ownership and valid transitions: an op id is bound to its reserved tag; stale op ids are refused.
- **Readers follow only the committed pointer**, then CoordRecord validation (READY, no active intent, same epoch, tag == generation).
  - No discovery, highest-tag selection, fixed-slot fallback or orphan adoption.
  - Missing, corrupt or mismatched state fails closed.
  - Reinitialisation takes a fresh epoch; restored older state never reuses issued names.

## Invariants (Astra 1–6)
1. One write dispatch per account; immutable afterwards. An ambiguous write is never retried at that account: a new tag and account is allocated.
2. The intent (exact account, operation, expected record digest, pending mutation) is committed BEFORE dispatch. A crash with a pending mutation is ambiguous whatever the store returned.
3. Publication requires an acknowledged completion that was durably recorded, plus a verified readback. A lost acknowledgement means the candidate is abandoned and retired. A readback alone never promotes.
4. Retirement is irreversible: every active and recovery reference is durably removed and the account marked retired BEFORE deletion. A retired account can never become active.
5. Deletion targets exact retired accounts only; never "current", a prefix, or whatever the pointer names later.
6. Readers use only the pointer (above).

## Flows
- **Setup** (S1):
  1. reserve a tag;
  2. commit the intent;
  3. dispatch one write to the fresh account;
  4. durably record the acknowledgement;
  5. verify a readback;
  6. atomically publish READY, the pointer and the cleanup phase;
  7. cleanup bookkeeping;
  8. clear the intent LAST.
  - An ambiguous candidate is retired, and the next attempt uses a new account; after a restart the password may have to be entered again.
- **Change** (S3):
  1. journal the participants (canonical path, physical identity, source digest, salt, KDF cost, expected staged identity and digest);
  2. the old active account is the old credential (no fixed rotation copies);
  3. write and verify ONE fresh new account BEFORE touching any vault file;
  4. identity-checked canonical rewraps, keeping history and the 2FA outer layer, with each staged identity journaled before rename;
  5. once every participant is verified, atomically publish the new pointer and generation plus the cleanup phase;
  6. only then retire, then delete, the old account.
  - An uncertain replacement is reconciled by recorded identities and digests. Anything irreconcilable, missing or changed stays blocked; no guessing which password a partly rewrapped vault needs.
- **Forget** (S2): refused while there are affected open vaults or active administration. Intent → atomically publish a fresh FORGOTTEN generation with no pointer, retiring the former account → delete afterwards. A later setup uses a new account, so a late delete cannot touch it.
- **Migration** (S4):
  - The writer safeguard comes first.
  - Validate the legacy password against every open vault, then run the fresh-account setup.
  - A receipt tied to the source and the committed target is revalidated under coordination before the unchanged legacy field is removed atomically. Receipt and intent recovery information are kept through that removal.
  - A conflict or uncertainty keeps the legacy field; a different existing credential is never overwritten.

## Cleanup semantics: an explicit amendment to v2's "remove definitely, then clear the intent"
- Two claims are kept apart:
  - **fenced**: the account can never affect a credential Docket uses;
  - **deleted**: the store completed the removal, with no outstanding write that could recreate it.
- A successful delete or not_found does NOT prove "deleted" while an earlier write to that account is indeterminate.
- The active intent ends only after any unresolved cleanup is durably moved into the retained retirement ledger, in one transaction where possible.
- Cleanup debt is reported as outstanding, and exact-account deletion is retried when useful. Erasure is never claimed without evidence.
- Cleanup-only debt does not block the committed credential or a new generation.
- During an unresolved ACTIVE change, vault operations are `pending` and unrelated work stays available. Locks are released between recovery attempts.
- V1 accepts fenced, visible cleanup debt (including after Forget). If confirmed physical erasure were ever required, a genuine store completion mechanism would still be needed. That is out of V1 scope, per the ruling.

## S1 deliverable (the first code slice after acceptance)
- native: the account grammar (store.rs) and its refusal tests;
- CoordState: the pointer, intent transitions with ownership, retirement ledger, and atomic publish;
- VaultCredential: status, password (through the pointer) and setup, per the flow above, with recovery at startup.
- Readers unchanged (activation is S2).

## Evidence plan (Astra's 8 focused cases; the delayed-completion store double first, then separately granted native acceptance)
1. A fixed-slot write delayed past timeout, readback, delete and restart shows why probes cannot authorise reuse.
2. A generation write delayed until after retirement and a fresh setup: the active credential is unchanged; cleanup unresolved.
3. A remove delayed across Forget and a later setup cannot touch the new account.
4. A crash at every dispatch, acknowledgement and publication boundary: no redispatch to an ambiguous account; no publication from readback alone.
5. A crash after each participant rename, before the journal acknowledgement: identities and digests reconcile, including same-salt replacement; history and 2FA kept.
6. A crash after the pointer or FORGOTTEN commit and during the cleanup transfer: retirement information kept; recovery-needed accounts never deleted; the intent cleared last.
7. Migration crashes before and after publication and the prefs replacement: the source is kept on uncertainty; stale prefs writers do not restore it; conflicts are refused.
8. Malformed account names, stale op ids, epoch changes, duplicate store entries and record mismatch: no leakage; ordinary work stays available.
- Real-store evidence (Linux Secret Service, a persistent default collection, an isolated session bus) comes in the acceptance container.
