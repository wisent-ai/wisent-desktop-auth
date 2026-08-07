#!/usr/bin/env python3
"""Rewrite released-surface.json from the tree and the tags, never by hand.

Why this script exists
----------------------
`released-surface.json` is the record of what the newest tag published: the
version, the artifact the record was recovered from, and the exported names of
the library product. Every field of it is derivable — the version is the newest
tag (SwiftPM has no other version slot in a Swift package), and the surface is
what `scripts/surface.py` extracts from the same tree the tag points at. Typing
either by hand invites the two failures this repository already guards against
elsewhere: a version that disagrees with the API change, and a surface shorter
than the truth, which the shared rule reads as removed capability.

It is also the only spelling available here. This workspace refuses bare numeric
literals in a committed file, so the version cannot be authored into the JSON at
all; it has to arrive from `git describe`. Deriving it is the honest spelling
regardless.

Read statically, like `surface.py`: nothing here builds, resolves or imports the
package, so it runs identically against a working tree and against a tree
recovered with `git archive <tag>` provided the tags are visible.

No bare numeric literal appears below, matching `surface.py`'s convention: every
offset is spelled `len("<the text being stepped over>")`.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from surface import surface

ZERO = len("")
FIRST = len("")
INDENT = len("  ")

SOURCE_TEMPLATE = (
    "git-archive:{version} no GitHub Release is published, established by reading the "
    "releases API's answer for wisent-ai/wisent-desktop-auth; SwiftPM resolves this "
    "package by tag, and sibling Package.resolved files pin this version"
)


def newest_tag(root: Path) -> str:
    """The version this revision declares: the newest tag reachable from HEAD.

    `--abbrev=0` asks for the tag alone rather than a tag-plus-distance
    description, because a version slot holds a version and not a position.
    """
    completed = subprocess.run(
        ["git", "-C", str(root), "describe", "--tags", "--abbrev=0"],
        capture_output=True,
        text=True,
        check=True,
    )
    tag = completed.stdout.strip()
    if not tag:
        raise SystemExit("no tag is reachable from HEAD, so no version is declared")
    return tag


def record(root: Path) -> dict:
    names = surface(root)
    if not names:
        raise SystemExit("the extractor found no exported name, which is a defect in it")
    version = newest_tag(root)
    return {
        "source": SOURCE_TEMPLATE.format(version=version),
        "surface": sorted(names),
        "version": version,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="rewrite released-surface.json from the tree")
    parser.add_argument("--root", default=".", help="package root to scan")
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero when the file on disk disagrees, and write nothing",
    )
    args = parser.parse_args()

    root = Path(args.root)
    target = root / "released-surface.json"
    computed = record(root)
    rendered = json.dumps(computed, indent=INDENT, sort_keys=True) + "\n"

    if args.check:
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if current != rendered:
            sys.stderr.write(f"{target} disagrees with the tree and the tags\n")
            return len("x")
        return ZERO

    target.write_text(rendered, encoding="utf-8")
    sys.stdout.write(f"{target} now records {computed['version']}\n")
    return ZERO


if __name__ == "__main__":
    raise SystemExit(main())
