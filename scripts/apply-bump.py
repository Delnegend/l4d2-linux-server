#!/usr/bin/env python3
"""Rewrite the pinned upstreams in the Dockerfile and the documentation table.

Run by the update workflow after scripts/resolve-upstream.py reports a stale pin:

    scripts/apply-bump.py --game-manifest 4827977561765481436

Only the ARGs named on the command line are touched. The documentation table in
docs/architecture.md is updated alongside, because scripts/docs-check.py fails
the build if a documented default and the Dockerfile disagree - and that check
is what stops the pins the update workflow bumps from drifting away from the
table that claims to describe them.
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCKERFILE = ROOT / "Dockerfile"
ARCHITECTURE = ROOT / "docs" / "architecture.md"

# A long pin is documented truncated with an ellipsis, so the table is rewritten
# to the same shape rather than the full value.
TRUNCATE_AFTER = 8


def short(value: str) -> str:
    return value[:TRUNCATE_AFTER] + "…" if len(value) > TRUNCATE_AFTER else value


def set_dockerfile_arg(name: str, value: str) -> bool:
    text = DOCKERFILE.read_text()
    pattern = rf"^(ARG {name}=).*$"
    if not re.search(pattern, text, re.M):
        raise SystemExit(f"apply-bump: Dockerfile has no ARG {name}")
    new, count = re.subn(pattern, rf"\g<1>{value}", text, flags=re.M)
    if count != 1:
        raise SystemExit(f"apply-bump: ARG {name} matched {count} lines, expected 1")
    DOCKERFILE.write_text(new)
    return True


def set_doc_table(names: list[str], values: list[str]) -> bool:
    """Rewrite the value cell of one row of the build-argument table.

    Only the middle cell is replaced. The name cell and the description cell
    are captured and put back verbatim, so a pin bump cannot quietly delete the
    prose explaining what the argument does.
    """
    text = ARCHITECTURE.read_text()
    pattern = re.compile(
        r"^(\| " + re.escape(" / ".join(f"`{n}`" for n in names)) + r" \| )"
        r"`[^`]+`(?: / `[^`]+`)*"
        r"( \| .*)$",
        re.M,
    )
    if not pattern.search(text):
        raise SystemExit(f"apply-bump: docs/architecture.md has no table row for {' / '.join(names)}")
    cell = " / ".join(f"`{short(v)}`" for v in values)
    ARCHITECTURE.write_text(pattern.sub(lambda m: f"{m.group(1)}{cell}{m.group(2)}", text, count=1))
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-manifest")
    parser.add_argument("--launcher-manifest")
    parser.add_argument("--plugins-ref")
    parser.add_argument("--l4dtoolz-version")
    parser.add_argument("--l4dtoolz-build")
    args = parser.parse_args()

    changed = False
    if args.l4dtoolz_version or args.l4dtoolz_build:
        if not (args.l4dtoolz_version and args.l4dtoolz_build):
            raise SystemExit("apply-bump: l4dtoolz needs both --l4dtoolz-version and --l4dtoolz-build")
        changed |= set_dockerfile_arg("L4DTOOLZ_VERSION", args.l4dtoolz_version)
        changed |= set_dockerfile_arg("L4DTOOLZ_BUILD", args.l4dtoolz_build)
        changed |= set_doc_table(
            ["L4DTOOLZ_VERSION", "L4DTOOLZ_BUILD"], [args.l4dtoolz_version, args.l4dtoolz_build]
        )
    if args.plugins_ref:
        changed |= set_dockerfile_arg("L4D_PLUGINS_REF", args.plugins_ref)
        changed |= set_doc_table(["L4D_PLUGINS_REF"], [args.plugins_ref])
    if args.game_manifest:
        changed |= set_dockerfile_arg("GAME_MANIFEST", args.game_manifest)
        changed |= set_doc_table(["GAME_MANIFEST"], [args.game_manifest])
    if args.launcher_manifest:
        changed |= set_dockerfile_arg("LAUNCHER_MANIFEST", args.launcher_manifest)
        changed |= set_doc_table(["LAUNCHER_MANIFEST"], [args.launcher_manifest])

    if not changed:
        raise SystemExit("apply-bump: nothing to bump")


if __name__ == "__main__":
    main()
    print("apply-bump: Dockerfile and docs/architecture.md updated", file=sys.stderr)
