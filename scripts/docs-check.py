#!/usr/bin/env python3
"""Validate the documentation against the code it describes.

Docs drift silently: a renamed target, a dropped environment variable or a
retired image tag all keep the prose looking plausible. This asserts the
handful of invariants that are cheap to check and expensive to get wrong.

    python3 scripts/docs-check.py

Standard library only, so it runs anywhere.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = [ROOT / "README.md"] + sorted((ROOT / "docs").glob("*.md"))

failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)


def read(path: pathlib.Path) -> str:
    return path.read_text()


# ---------------------------------------------------------------------------
# 1. Every relative markdown link resolves, including its #anchor
# ---------------------------------------------------------------------------
def headings(path: pathlib.Path) -> set[str]:
    found = set()
    for line in read(path).splitlines():
        if line.startswith("#"):
            text = line.lstrip("#").strip()
            found.add(re.sub(r"[^\w\s-]", "", text.lower()).replace(" ", "-"))
    return found


anchors = {path: headings(path) for path in DOCS}

for path in DOCS:
    for _label, link in re.findall(r"\[([^\]]+)\]\(([^)]+)\)", read(path)):
        if link.startswith(("http://", "https://")):
            continue
        if link.startswith("#"):
            if link[1:] not in anchors[path]:
                fail(f"{path.relative_to(ROOT)}: anchor '{link}' has no matching heading")
            continue
        target_path, _, anchor = link.partition("#")
        target = (path.parent / target_path).resolve()
        if not target.exists():
            fail(f"{path.relative_to(ROOT)}: link target does not exist -> {link}")
        elif anchor and target in anchors and anchor not in anchors[target]:
            fail(f"{path.relative_to(ROOT)}: '{link}' - no such heading in {target_path}")


# ---------------------------------------------------------------------------
# 2. The environment variable table is .env.example, and the entrypoint reads it
# ---------------------------------------------------------------------------
entrypoint = read(ROOT / "entrypoint.sh")
envexample = set(re.findall(r"^([A-Z_]+)=", read(ROOT / ".env.example"), re.M))
config_doc = read(ROOT / "docs/configuration.md")
documented = set(re.findall(r"^\| `([A-Z_]+)` \|", config_doc, re.M))

for var in sorted(envexample - documented):
    fail(f"docs/configuration.md: {var} is in .env.example but not documented")
for var in sorted(documented - envexample):
    fail(f"docs/configuration.md: {var} is documented but not in .env.example")
for var in sorted(documented):
    if var not in entrypoint:
        fail(f"docs/configuration.md: {var} is documented but entrypoint.sh never reads it")

# ---------------------------------------------------------------------------
# 3. Targets: every --target and stage name in the docs exists in the Dockerfile
# ---------------------------------------------------------------------------
dockerfile = read(ROOT / "Dockerfile")
stages = set(re.findall(r"^FROM .* AS (\w+)", dockerfile, re.M))

for path in DOCS:
    text = read(path)
    for target in re.findall(r"--target (\w+)", text):
        if target not in stages:
            fail(f"{path.relative_to(ROOT)}: --target {target} is not a Dockerfile stage")
    for target in re.findall(r"\b(fetch|base|server|qol|coop8)\b", text):
        if target not in stages:
            fail(f"{path.relative_to(ROOT)}: mentions target '{target}', which no longer exists")

# Every stage must be documented, so a new one cannot appear unnoticed.
arch = read(ROOT / "docs/architecture.md")
for stage in sorted(stages):
    if f"`{stage}`" not in arch:
        fail(f"docs/architecture.md: Dockerfile stage '{stage}' is not documented")


# ---------------------------------------------------------------------------
# 4. Build argument defaults in the docs match the Dockerfile
# ---------------------------------------------------------------------------
declared = dict(re.findall(r"^ARG ([A-Z_]+)=(.*)$", dockerfile, re.M))
for name, default in re.findall(r"^\| `([A-Z_]+)` \| `([^`]*)` \|", arch, re.M):
    if name not in declared:
        fail(f"docs/architecture.md: build arg {name} is not declared in the Dockerfile")
    elif declared[name] != default:
        fail(
            f"docs/architecture.md: {name} default '{default}' "
            f"!= Dockerfile '{declared[name]}'"
        )


# ---------------------------------------------------------------------------
# 5. Tag policy: semver + latest only, no per-target tags anywhere
# ---------------------------------------------------------------------------
workflow = read(ROOT / ".github/workflows/publish.yaml")
pushed = set(re.findall(r"\$\{\{ env\.IMAGE \}\}:([\w.${}-]+)", workflow))
pushed = {tag for tag in pushed if "IMAGE" not in tag}

if "latest" not in pushed:
    fail("publish.yaml: does not push a 'latest' tag")
for tag in pushed:
    if tag.endswith(("-base", "-qol", "-coop8")) or tag in {"base", "qol", "coop8"}:
        fail(f"publish.yaml: still pushes a per-target tag '{tag}'")

for path in DOCS:
    for tag in re.findall(r"[\w.]+:(?:[\d.]+-(?:qol|coop8|base))", read(path)):
        fail(f"{path.relative_to(ROOT)}: advertises a retired tag '{tag}'")

# ---------------------------------------------------------------------------
# 6. The compression claim in the docs matches the workflow
# ---------------------------------------------------------------------------
if "compression=zstd" not in workflow:
    fail("publish.yaml: registry compression is not zstd")
level = re.search(r"compression-level=(\d+)", workflow)
if not level:
    fail("publish.yaml: no compression level set")
elif f"level {level.group(1)}" not in arch and f"zstd level {level.group(1)}" not in arch:
    fail(
        f"docs/architecture.md: does not mention the zstd level "
        f"{level.group(1)} the workflow actually uses"
    )

# ---------------------------------------------------------------------------
if failures:
    for f in failures:
        print(f"FAIL {f}")
    print(f"\n{len(failures)} problem(s)")
    sys.exit(1)

print(f"docs-check: {len(DOCS)} files, all invariants hold")
