#!/usr/bin/env python3
"""Flag GitHub Actions script-injection risks.

`${{ ... }}` inside a `run:` block is substituted by the Actions runner *before*
the shell parses the script, so an attacker-influenced value becomes code. The
same value passed through `env:` is only ever a variable's value, so the check
has to distinguish the two — which needs block tracking, not a line grep.

Exit 0 when clean, 1 when a risky interpolation is found.
"""

import pathlib
import re
import sys

# Contexts an outside party can influence: dispatch inputs, PR titles and
# branch names, issue bodies, the triggering actor.
UNTRUSTED = (
    "github.event",
    "inputs.",
    "github.head_ref",
    "github.actor",
)

# Keys that start a non-script block, ending any run: we were inside.
BLOCK_KEY = re.compile(r"^\s*-?\s*(name|uses|with|if|env|id|continue-on-error)\s*:")
RUN_KEY = re.compile(r"^\s*-?\s*(run|shell)\s*:")
EXPR = re.compile(r"\$\{\{\s*([^}]+?)\s*\}\}")


def scan(path: pathlib.Path) -> list[str]:
    hits = []
    in_run = False
    for lineno, line in enumerate(path.read_text().split("\n"), 1):
        if RUN_KEY.match(line):
            in_run = True
        elif BLOCK_KEY.match(line):
            in_run = False
        if not in_run or "${{" not in line:
            continue
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        for expr in EXPR.findall(line):
            if any(k in expr for k in UNTRUSTED):
                hits.append(f"{path.name}:{lineno}  {expr}")
    return hits


def main() -> int:
    workflows = pathlib.Path(".github/workflows")
    if not workflows.is_dir():
        print("no .github/workflows directory")
        return 0

    hits: list[str] = []
    for f in sorted(workflows.glob("*.yml")) + sorted(workflows.glob("*.yaml")):
        hits.extend(scan(f))

    if hits:
        print("Untrusted context interpolated into a run: block —")
        print("pass the value via env: and reference it as a shell variable.")
        for h in hits:
            print(f"  {h}")
        return 1

    print("no untrusted context interpolated into run: blocks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
