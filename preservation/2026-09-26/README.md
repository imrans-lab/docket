# Stop checkpoint, 2026-09-26

This branch preserves task evidence only. It is not a Docket feature branch or a release candidate.

- `drain-inventory.txt` records local checkouts, refs, and dirty paths at the stop boundary. Its remote-tracking comparisons can be stale; compare with GitHub before treating a ref as unpublished.
- `vault-plan-v3.md` is an unfinished design plan. V1 S1 code and unrun tests are preserved separately at `codex/draft-vault-v1-s1-20260926` (`6208caa5`). No reader activation, native build, test, or final review was completed for that draft.
- `godot-sqlite-gsq2.patch` and `godot-sqlite-gsq3.patch` preserve two distinct staged source patch variants from the optional Save As investigation. A third checkout, `review-l1a5/gsq2`, had bytes identical to `gsq2`. These patches were not landed or validated as product changes. B8b is preserved separately at `codex/draft-deferred-b8b-20260926` (`91e968cd`).

The active Docket integration branch was pushed at `e4a8f980`. CI run `36210015681` passed all four jobs. The Minerva development branch was pushed at `1b2df5e`; CI run `36210105400` was still running when this record was made. Neither repo has been cut over to the new plugin, and the vault work is incomplete.
