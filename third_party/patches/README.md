# Patches to vendored source

Each patch here is applied to a pinned submodule by the build before it
compiles; the submodule's gitlink stays at the upstream commit.
`scripts/build/build_gdextension.sh` checks that the submodule is at its
pinned commit and that its tracked source is exactly that commit plus the
patch, applying the patch to a clean checkout and refusing anything else
(a partial application or local edits), so the source that is built is
always the recorded one. Build output and other untracked files are not
compared.

A patched submodule has local changes, so before moving the pin (or after
an interrupted build) reset it: `git -C third_party/godot-sqlite reset
--hard`, then `git submodule update --init --recursive`.

## godot-sqlite-read-only-query.patch

Base: `third_party/godot-sqlite` at its gitlink (9cbdb225, godot-sqlite 4.9,
SQLite 3.51.0).

Adds `SQLite.query_read_only(query_string, param_bindings = [])`: runs
exactly one statement on the object's own connection, and only if it reads.

- An authorizer allowing only `SELECT`, `READ`, `RECURSIVE`, functions other
  than `load_extension`, and `PRAGMA table_info` / `foreign_key_list` is
  installed before anything is prepared and removed after the statement is
  finalized (it covers a reprepare during a step). Everything else is denied
  (`SQLITE_DENY`, never `SQLITE_IGNORE`). A second call while one runs is
  refused.
- The text after the first statement may only prepare to nothing
  (whitespace, comments, empty statements); anything else, including a
  second read, is refused before the first is stepped. Empty input, input
  containing NUL, and input starting with an empty statement (`;SELECT 1`)
  are refused.
- The prepared statement must satisfy `sqlite3_stmt_readonly`, and that same
  statement is bound and executed.
- The bindings must match the statement's parameter count exactly; every
  `sqlite3_bind_*` result is checked.
- On any failure it returns false, `query_result` is empty and
  `error_message` holds the first SQLite or policy error.

It is a boundary on database operations, not a sandbox: functions registered
with `create_function` and loaded extensions run their own code. Docket
registers neither. Table-valued pragma functions (`SELECT * FROM
pragma_table_list`) reach the authorizer as reads, not pragmas, and are
allowed; they only read.

To move to another godot-sqlite release, apply the patch to it, resolve,
and regenerate the file from the submodule with `source_diff` in
`build_gdextension.sh` (the exact command it compares against).
