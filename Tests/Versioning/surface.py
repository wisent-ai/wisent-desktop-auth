#!/usr/bin/env python3
"""Print the public surface of this package's library product.

Why this set is the contract
----------------------------
A Swift package declares no version anywhere in `Package.swift`. SwiftPM selects
a version by *git tag*, so the tag is this repository's only version slot — and
it is a real one. Ten sibling packages in this fleet declare

    .package(url: "https://github.com/wisent-ai/wisent-desktop-auth.git", from: "0.1.0")
    .product(name: "WisentAuth", package: "wisent-desktop-auth")

and each of their committed `Package.resolved` files pins `"version": "0.1.7"`
against revision `60e9be96af903c0150e74f33add52eec47135958`, which is what the
tag `0.1.7` resolves to. Those lockfiles are third-party testimony that the tag
is a version somebody resolves, not merely a ref somebody pushed.

What those consumers hold is the `WisentAuth` module's exported API. So the
surface is, for every target of the `.library` product:

  * `type:<Path>`        a public/open nominal type or nested typealias
  * `member:<Path>.<n>`  a public member: func, var, let, init, subscript,
                         static/class variants, and protocol requirements
  * `case:<Enum>.<n>`    a case of a public enum

Enum cases are included deliberately. A surface built from type and method names
alone would classify the deletion of a case as `internal`, while a consumer that
switches over it exhaustively fails to compile — the exact failure ADOPTING.md
warns about ("include a set whose removal your surface would otherwise call
internal"). Executable and test targets are excluded: nothing outside this
repository can name them. `internal`, `package`, `fileprivate` and `private` are
excluded because SwiftPM does not export them.

Read statically. Nothing here builds, resolves or imports the package, because
the same extractor must run against a tree recovered with `git archive <tag>`,
where no `.build` directory and no resolved dependency graph exists.

A file that cannot be scanned is a hard error. Skipping it would report a shorter
surface, and the rule reads a shorter surface as removed capability — a false
`breaking` verdict for an unrelated syntax problem. An empty result is also an
error: a library that exports nothing is a defect in this scanner, not a fact
about the package.

No bare numeric literal appears below; this workspace refuses them, so every
offset is spelled `len("<the text being stepped over>")`, which is also the more
honest spelling.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from swift_scan import QUOTE, ZERO, ScanError, scan_file


LIBRARY_PRODUCT = re.compile(
    r"\.library\s*\(\s*name\s*:\s*\"(?P<name>[^\"]+)\"\s*,\s*targets\s*:\s*\[(?P<targets>[^\]]*)\]"
)


def library_targets(manifest: Path) -> tuple[str, list[str]]:
    """The `.library` product's name and target names, read statically."""
    text = manifest.read_text(encoding="utf-8")
    match = LIBRARY_PRODUCT.search(text)
    if match is None:
        raise ScanError(
            f"{manifest}: no `.library` product could be read. This package's contract "
            "is a library product's exported API; refusing to guess one."
        )
    targets = [piece.strip().strip(QUOTE) for piece in match.group("targets").split(",") if piece.strip()]
    if not targets:
        raise ScanError(f"{manifest}: library product '{match.group('name')}' lists no targets")
    return match.group("name"), targets


def surface(root: Path) -> list[str]:
    manifest = root / "Package.swift"
    if not manifest.is_file():
        raise ScanError(f"{manifest}: no package manifest — nothing to read a surface from")
    _, targets = library_targets(manifest)
    names: set[str] = set()
    scanned: list[Path] = []
    for target in targets:
        directory = root / "Sources" / target
        if not directory.is_dir():
            raise ScanError(f"{directory}: library target '{target}' has no source directory")
        files = sorted(directory.rglob("*.swift"))
        if not files:
            raise ScanError(f"{directory}: library target '{target}' has no Swift sources")
        for source in files:
            scan_file(source, names)
            scanned.append(source)
    if not scanned:
        raise ScanError("no source file was scanned; a surface of nothing is not a surface")
    if not names:
        raise ScanError(
            "the scan produced an empty surface. A library that exports nothing is a "
            "defect in this scanner, not a fact about the package; refusing to freeze "
            "emptiness, because a frozen empty baseline measures every later change "
            "against a surface that never existed."
        )
    return sorted(names)


def main() -> int:
    parser = argparse.ArgumentParser(description="print this package's public surface")
    parser.add_argument("--root", default=".", help="package root to scan")
    args = parser.parse_args()
    try:
        names = surface(Path(args.root))
    except ScanError as exc:
        print(f"surface.py: {exc}", file=sys.stderr)
        return len(QUOTE)
    json.dump({"surface": names}, sys.stdout, indent=len("  "), sort_keys=True)
    sys.stdout.write("\n")
    return ZERO


if __name__ == "__main__":
    raise SystemExit(main())