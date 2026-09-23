"""Static Swift scanner used by surface.py; see that script for the contract."""

from __future__ import annotations

import re
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
                    # Swift exports an explicitly `public` member of a public
                    # type from any extension, modified or not (the compiler
                    # refuses one on a type that is not public). The
                    # extension's own modifier only decides whether its
                    # unmodified members are exported.
                    frame = Frame(name, keyword, True, access in EXPORTED)
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

