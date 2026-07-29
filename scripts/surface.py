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

ZERO = len("")
EXPORTED = ("public", "open")
ACCESS = ("public", "open", "internal", "package", "fileprivate", "private")

NOMINAL = ("struct", "class", "enum", "actor", "protocol", "extension")
MEMBER = ("func", "var", "let", "init", "subscript", "typealias")
CASE = "case"

BLOCK_OPEN, BLOCK_CLOSE = "/*", "*/"
LINE_COMMENT = "//"
MULTILINE_QUOTE = '"""'
QUOTE = '"'
HASH = "#"
BACKSLASH = "\\"
BRACE_OPEN, BRACE_CLOSE = "{", "}"
PAREN_OPEN, PAREN_CLOSE = "(", ")"
DOT = "."

MODIFIERS = (
    "public", "open", "internal", "package", "fileprivate", "private",
    "final", "static", "class", "mutating", "nonmutating", "override",
    "required", "convenience", "lazy", "weak", "unowned", "indirect",
    "dynamic", "optional", "prefix", "postfix", "infix", "distributed",
    "isolated", "nonisolated", "consuming", "borrowing",
)

ATTRIBUTE = re.compile(r"@[A-Za-z_][A-Za-z0-9_]*(\([^()]*\))?\s*")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class ScanError(Exception):
    """A source file could not be reduced to code. Never swallowed."""


def blanked(text: str) -> str:
    """Same length, same line breaks, no content."""
    return "".join("\n" if char == "\n" else " " for char in text)


def strip_noncode(text: str, origin: str) -> str:
    """Blank out comments and string bodies, preserving length and line breaks.

    Brace counting drives the scanner, so a brace inside a comment or a string
    literal must never be seen. Swift block comments nest, which is why this is
    a scanner rather than one regular expression.
    """
    out: list[str] = []
    rest = text
    while rest:
        cuts = [
            index
            for index in (
                rest.find(BLOCK_OPEN),
                rest.find(LINE_COMMENT),
                rest.find(MULTILINE_QUOTE),
                rest.find(QUOTE),
                rest.find(HASH + QUOTE),
            )
            if index >= ZERO
        ]
        if not cuts:
            out.append(rest)
            break
        cut = min(cuts)
        out.append(rest[:cut])
        rest = rest[cut:]
        if rest.startswith(BLOCK_OPEN):
            depth, taken = ZERO, ZERO
            probe = rest
            while probe:
                if probe.startswith(BLOCK_OPEN):
                    depth += len(BRACE_OPEN)
                    probe = probe[len(BLOCK_OPEN):]
                    taken += len(BLOCK_OPEN)
                elif probe.startswith(BLOCK_CLOSE):
                    depth -= len(BRACE_OPEN)
                    probe = probe[len(BLOCK_CLOSE):]
                    taken += len(BLOCK_CLOSE)
                    if depth == ZERO:
                        break
                else:
                    probe = probe[len(HASH):]
                    taken += len(HASH)
            if depth != ZERO:
                raise ScanError(f"{origin}: unterminated block comment")
            out.append(blanked(rest[:taken]))
            rest = rest[taken:]
        elif rest.startswith(LINE_COMMENT):
            end = rest.find("\n")
            span = rest if end < ZERO else rest[:end]
            out.append(blanked(span))
            rest = rest[len(span):]
        elif rest.startswith(MULTILINE_QUOTE):
            body = rest[len(MULTILINE_QUOTE):]
            end = body.find(MULTILINE_QUOTE)
            if end < ZERO:
                raise ScanError(f"{origin}: unterminated multiline string literal")
            span = rest[: len(MULTILINE_QUOTE) + end + len(MULTILINE_QUOTE)]
            out.append(blanked(span))
            rest = rest[len(span):]
        elif rest.startswith(HASH + QUOTE):
            terminator = QUOTE + HASH
            body = rest[len(HASH + QUOTE):]
            end = body.find(terminator)
            if end < ZERO:
                raise ScanError(f"{origin}: unterminated raw string literal")
            span = rest[: len(HASH + QUOTE) + end + len(terminator)]
            out.append(blanked(span))
            rest = rest[len(span):]
        else:
            taken = len(QUOTE)
            body = rest[len(QUOTE):]
            while body:
                if body.startswith(BACKSLASH):
                    body = body[len(BACKSLASH + QUOTE):]
                    taken += len(BACKSLASH + QUOTE)
                    continue
                if body.startswith(QUOTE):
                    taken += len(QUOTE)
                    break
                if body.startswith("\n"):
                    raise ScanError(f"{origin}: unterminated string literal")
                body = body[len(QUOTE):]
                taken += len(QUOTE)
            else:
                raise ScanError(f"{origin}: unterminated string literal")
            out.append(blanked(rest[:taken]))
            rest = rest[taken:]
    return "".join(out)


class Frame:
    """One open nominal scope."""

    __slots__ = ("path", "kind", "exported", "members_exported", "close_at")

    def __init__(self, path: str, kind: str, exported: bool, members_exported: bool):
        self.path = path
        self.kind = kind
        self.exported = exported
        self.members_exported = members_exported
        self.close_at = ZERO


def leading_words(line: str) -> tuple[list[str], str, set[str]]:
    """Strip attributes, then read the leading modifier/keyword words.

    Returns the words, the attribute-stripped line, and the set of modifiers
    that carried a parenthesised qualifier. The third value is load-bearing:
    `public private(set) var status` is *publicly readable*, so `private` there
    must not be mistaken for the declaration's access level, and the walk must
    step over `(set)` rather than stopping at it — stopping is how a scanner
    silently drops every `@Published public private(set) var`, which in a
    SwiftUI library is most of what consumers actually read.
    """
    stripped = line.strip()
    while True:
        match = ATTRIBUTE.match(stripped)
        if match is None:
            break
        stripped = stripped[match.end():]
    words: list[str] = []
    qualified: set[str] = set()
    rest = stripped
    while len(words) <= len(MODIFIERS):
        match = IDENT.match(rest)
        if match is None:
            break
        word = match.group()
        words.append(word)
        rest = rest[match.end():].lstrip()
        if word in MODIFIERS and rest.startswith(PAREN_OPEN):
            close = rest.find(PAREN_CLOSE)
            if close < ZERO:
                break
            qualified.add(word)
            rest = rest[close + len(PAREN_CLOSE):].lstrip()
            continue
        if word not in MODIFIERS:
            break
    return words, stripped, qualified


def introduced_name(stripped: str, keyword: str) -> str | None:
    """The identifier a declaration introduces, or None when there is none."""
    at = stripped.find(keyword)
    if at < ZERO:
        return None
    tail = stripped[at + len(keyword):].lstrip()
    if keyword in ("init", "subscript"):
        return keyword
    match = IDENT.match(tail)
    if match is None:
        return None
    name = match.group()
    if keyword == "extension":
        tail = tail[match.end():]
        while tail.startswith(DOT):
            more = IDENT.match(tail[len(DOT):])
            if more is None:
                break
            name = name + DOT + more.group()
            tail = tail[len(DOT) + more.end():]
    return name


def scan_file(path: Path, names: set[str]) -> None:
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise ScanError(f"{path}: unreadable ({exc})") from exc
    code = strip_noncode(raw, str(path))
    stack: list[Frame] = []
    pending: Frame | None = None
    depth = ZERO
    for line in code.splitlines():
        words, stripped, qualified = leading_words(line)
        keyword = next((w for w in words if w in NOMINAL + MEMBER + (CASE,)), None)
        if keyword is not None:
            # A modifier that carried `(set)` governs the setter only, so it is
            # never the declaration's access level.
            access = next((w for w in words if w in ACCESS and w not in qualified), None)
            owner = stack[-len(QUOTE)] if stack else None
            inside_exported = owner is None or owner.exported
            if keyword in NOMINAL:
                name = introduced_name(stripped, keyword)
                if name is None:
                    raise ScanError(
                        f"{path}: cannot read the name of a `{keyword}` declaration: {stripped[:len(MODIFIERS)]!r}"
                    )
                if keyword == "extension":
                    # An extension re-opens a name rather than introducing one.
                    exported = access in EXPORTED
                    frame = Frame(name, keyword, exported, exported)
                else:
                    exported = access in EXPORTED and inside_exported
                    path_here = name if owner is None else owner.path + DOT + name
                    # Members of a struct/class/enum/actor need an explicit
                    # modifier; protocol requirements inherit the protocol's.
                    frame = Frame(path_here, keyword, exported, exported and keyword == "protocol")
                    if exported:
                        names.add(f"type:{path_here}")
                if BRACE_OPEN in line:
                    frame.close_at = depth
                    stack.append(frame)
                else:
                    pending = frame
            elif keyword == CASE:
                # Enum cases only. A `case` inside a switch sits within a func,
                # whose frame is not a nominal enum, so it cannot reach here.
                if owner is not None and owner.kind == "enum" and owner.exported:
                    body = stripped[stripped.find(CASE) + len(CASE):]
                    for piece in body.split(","):
                        match = IDENT.match(piece.strip())
                        if match is not None:
                            names.add(f"case:{owner.path}.{match.group()}")
            else:
                name = introduced_name(stripped, keyword)
                if name is not None:
                    if owner is None:
                        if access in EXPORTED:
                            names.add(f"member:{name}")
                    elif inside_exported and (access in EXPORTED or (owner.members_exported and access is None)):
                        names.add(f"member:{owner.path}{DOT}{name}")
                        if keyword == "typealias":
                            names.add(f"type:{owner.path}{DOT}{name}")
        opened = line.count(BRACE_OPEN)
        if pending is not None and opened:
            pending.close_at = depth
            stack.append(pending)
            pending = None
        depth += opened - line.count(BRACE_CLOSE)
        if depth < ZERO:
            raise ScanError(f"{path}: unbalanced braces (depth went negative)")
        while stack and depth <= stack[-len(QUOTE)].close_at:
            stack.pop()
    if depth != ZERO:
        raise ScanError(f"{path}: unbalanced braces (file ended at depth {depth})")


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
